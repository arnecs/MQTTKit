//
//  MQTTKit.swift
//

import Foundation
import Dispatch

fileprivate struct MQTTProtocol {
    static let Level: UInt8 = 4
    static let Name = "MQTT"
}

enum MQTTConnackResponse : UInt8 {
    case accepted =                     0x00
    case unacceptableProtocolVersion =  0x01
    case identifierRejected =           0x02
    case serverUnavailable =            0x03
    case badUsernameOrPassword =        0x04
    case notAuthorized =                0x05
    case reserved =                     0x06
}

enum MQTTConnectionState {
    case connected
    case connecting
    case disconnected
}

enum MQTTQoSLevel: UInt8 {
    case QoS0 = 0b0000_0000
    case QoS1 = 0b0000_0010
    case QoS2 = 0b0000_0100

    case Failure = 0x80
}

extension MQTTQoSLevel: Comparable {
    static func <(lhs: MQTTQoSLevel, rhs: MQTTQoSLevel) -> Bool {
        return lhs.rawValue < rhs.rawValue
    }
}


struct MQTTMessage {
    var topic: String
    var payload: Data
    var qos: MQTTQoSLevel
    var retained: Bool

    var string: String? {
        return String(bytes: payload, encoding: .utf8)
    }

    init(topic: String, payload: Data, qos: MQTTQoSLevel, retained: Bool) {
        self.topic = topic
        self.payload = payload
        self.qos = qos
        self.retained = retained
    }

    fileprivate init?(packet: MQTTPacket) {
        guard packet.type == .publish else {
            return nil
        }

        topic = packet.topic ?? ""
        payload = packet.payload
        qos = packet.qos
        retained = packet.retained
    }

    fileprivate var header: UInt8 {
        var header = MQTTPacket.Header.publish
        if retained {
            header |= MQTTPacket.Publish.retained
        }
        header |= qos.rawValue
        return header
    }
}

struct MQTTOptions {
    var host: String!
    private var _port: Int?
    var port: Int {
        get {
            return _port ?? (useTLS ? 8883 : 1883)
        }
        set {
            _port = newValue
        }
    }
    var cleanSession = true
    var will: MQTTWill?
    var password: String? = nil
    var username: String? = nil
    var keepAliveInterval: UInt16 = 10
    var clientId: String = UUID().uuidString
    
    var useTLS = false
    var autoReconnect: Bool = true
    var bufferSize: Int = 4096
    var readQosClass: DispatchQoS.QoSClass = .background
    
    init(host: String) {
        self.host = host
    }
}

struct MQTTWill {
    var qos: MQTTQoSLevel
    var retained: Bool
    var topic: String
    var message: String
}

// MARK: - MQTT Client

final class MQTTClient: NSObject, StreamDelegate {
    private var options: MQTTOptions
    private var inputStream: InputStream?
    private var outputStream: OutputStream?
    private var keepAliveTimer: Timer?
    private var writeQueue = DispatchQueue(label: "mqtt_write")
    private var messageId: UInt16 = 0
    private var pingCount = 0
    private var pendingPackets: [UInt16:MQTTPacket] = [:]

    // MARK: - Delegate Methods
    var didRecieveMessage: ((_ mqtt: MQTTClient, _ message: MQTTMessage) -> Void)?
    var didRecieveConack: ((_ mqtt: MQTTClient, _ status: MQTTConnackResponse) -> Void)?
    var didSubscribe: ((_ mqtt: MQTTClient, _ topic: String) -> Void)?
    var didUnsubscribe: ((_ mqtt: MQTTClient, _ topic: String) -> Void)?
    var didConnect: ((_ mqtt: MQTTClient, _ connected: Bool) -> Void)?
    var didDisconnect: ((_ mqtt: MQTTClient, _ error: Error?) -> Void)?
    var didChangeState: ((_ mqtt: MQTTClient, _ state: MQTTConnectionState) -> Void)?

    // MARK: - Public interface
    private(set) var state: MQTTConnectionState = .disconnected {
        didSet {
            guard state != oldValue else {
                return
            }
            switch state {
            case .connected:
                didConnect?(self, true)
            case .disconnected:
                didDisconnect?(self,nil)
            default:
                break
            }
            didChangeState?(self, state)
        }
    }
    
    init(host: String) {
        self.options = MQTTOptions(host: host)
    }

    init(options: MQTTOptions) {
        self.options = options
    }

    deinit {
        disconnect()
    }

    func connect(completion: ((_ success: Bool) -> ())? = nil) {
        pingCount = 0
        openStreams() { [weak self] streams in
            guard let strongSelf = self, let streams = streams else {
                completion?(false)
                return
            }

            strongSelf.disconnect()

            strongSelf.inputStream = streams.input
            strongSelf.outputStream = streams.output

            DispatchQueue.global(qos: strongSelf.options.readQosClass).async { [weak strongSelf] in
                // strongSelf?.readStream(input: streams.input, output: streams.output)
            }

            strongSelf.mqttConnect()
            strongSelf.delayedPing()

            strongSelf.messageId = 0x00

            completion?(true)
        }
    }

    func disconnect() {
        mqttDisconnect()
        closeStreams()
    }

    func subscribe(to topic: String) {
        mqttSubscribe(to: topic)
    }

    func unsubscribe(from topic: String) {
        mqttUnsubscribe(from: topic)
    }

    func publish(message: MQTTMessage) {
        mqttPublish(message: message)
    }

    func publish(to topic: String, payload: Data, qos: MQTTQoSLevel = .QoS0, retained: Bool = false) {
        let message = MQTTMessage(topic: topic, payload: payload, qos: qos, retained: retained)
        mqttPublish(message: message)
    }

    // MARK: - Keep alive timer
    
    private func startKeepAliveTimer() {
        
        guard options.keepAliveInterval > 0 else {
            return
        }
        
        keepAliveTimer = Timer.scheduledTimer(withTimeInterval: TimeInterval(options.keepAliveInterval), repeats: true, block: { [weak self] timer in
            // TODO: Ping count
            
            guard self?.outputStream?.streamStatus == .open else {
                timer.invalidate()
                self?.autoReconnect()
                return
            }
            
            
            self?.mqttPing()
        })
    }
    
    private func delayedPing() {
        let interval = options.keepAliveInterval
        let time = DispatchTime.now() + Double(interval / 2)
        DispatchQueue.main.asyncAfter(deadline: time) { [weak self] in

            // stop pinging server if client deallocated or stream closed
            guard self?.outputStream?.streamStatus == .open, self!.pingCount < 4 else {
                self?.state = .disconnected
                self?.closeStreams()
                self?.autoReconnect()
                return
            }

            self?.mqttPing()
            self?.delayedPing()
        }
    }

    private func autoReconnect() {
        guard self.options.autoReconnect else {
            self.disconnect()
            return
        }

        let interval = options.keepAliveInterval
        let time = DispatchTime.now() + Double(interval / 2)
        DispatchQueue.main.asyncAfter(deadline: time) { [weak self] in

            if self?.state == .disconnected {
                self?.connect()
                self?.autoReconnect()
            }
        }
    }

    // MARK: - Socket connection

    private func openStreams(completion: @escaping (((input: InputStream, output: OutputStream)?) -> ())) {
        var inputStream: InputStream?
        var outputStream: OutputStream?

        Stream.getStreamsToHost(withName: options.host,
                                port: options.port,
                                inputStream: &inputStream,
                                outputStream: &outputStream)

        guard let input = inputStream, let output = outputStream else {
            completion(nil)
            return
        }
        
        input.delegate = self
        output.delegate = self
        
        input.schedule(in: RunLoop.main, forMode: RunLoopMode.defaultRunLoopMode)
        output.schedule(in: RunLoop.main, forMode: RunLoopMode.defaultRunLoopMode)

        if options.useTLS {
            input.setProperty(StreamSocketSecurityLevel.tlSv1, forKey: .socketSecurityLevelKey)
            output.setProperty(StreamSocketSecurityLevel.tlSv1, forKey: .socketSecurityLevelKey)
        }

        DispatchQueue.global(qos: .userInitiated).async {
            input.open()
            output.open()

            while input.streamStatus == .opening || output.streamStatus == .opening {
                usleep(1000)
            }

            if input.streamStatus != .open || output.streamStatus != .open {
                completion(nil)
                return
            }

            completion((input, output))
        }
    }

     func closeStreams() {
        inputStream?.close()
        outputStream?.close()

        inputStream = nil
        outputStream = nil
    }


    func stream(_ aStream: Stream, handle eventCode: Stream.Event) {
        
        print("handle stream", aStream, eventCode)
        
        switch eventCode {
        case .hasBytesAvailable:
            readStream(input: aStream as! InputStream)
        default:
            break
        }
    }

    // MARK: - Stream reading
    private func readStream(input: InputStream) {
        var packet: MQTTPacket!
        let messageBuffer = UnsafeMutablePointer<UInt8>.allocate(capacity: options.bufferSize)

        defer {
            messageBuffer.deinitialize(count: options.bufferSize)
            messageBuffer.deallocate(capacity: options.bufferSize)
        }

        mainReading: while input.streamStatus == .open && input.hasBytesAvailable {
            // Header
            let count = input.read(messageBuffer, maxLength: 1)
            if count == 0 {
                continue
            } else if count < 0 {
                break
            }

            if let _ = MQTTPacket.PacketType(rawValue: messageBuffer.pointee & MQTTPacket.Header.typeMask) {
                packet = MQTTPacket(header: messageBuffer.pointee)
            } else {
                // Not valid header
                continue
            }

            // Remaining Length
            var multiplier = 1
            var remainingLength = 0

            repeat {
                let count = input.read(messageBuffer, maxLength: 1)
                if count == 0 {
                    continue mainReading
                } else if count < 0 {
                    break mainReading
                }

                remainingLength += Int(messageBuffer.pointee & 127) * multiplier
                multiplier *= 128

                if multiplier > 2_097_152 { // 128 * 128 * 128 MAX LENGTH
                    // Error?
                    break mainReading
                }
            } while messageBuffer.pointee & 128 != 0



            // Variable header //

            if packet.type == .connack {
                // Connack response code
                let count = input.read(messageBuffer, maxLength: 2)
                if count == 0 {
                    continue
                } else if count < 0 {
                    return
                }
                remainingLength -= count
                packet.variableHeader.append(messageBuffer, count: count)
            }

            if packet.type == .publish {
                // Topic length
                var count = input.read(messageBuffer, maxLength: 2)
                if count == 0 {
                    continue
                } else if count < 0 {
                    return
                }

                let msb = messageBuffer[0], lsb = messageBuffer[1]
                let topicLength = Int((UInt16(msb) << 8) + UInt16(lsb))
                remainingLength -= count

                // Topic
                count = input.read(messageBuffer, maxLength: topicLength)
                if count == 0 {
                    continue
                } else if count < 0 {
                    return
                }

                remainingLength -= count
                packet.topic = String(bytesNoCopy: messageBuffer, length: topicLength, encoding: .utf8, freeWhenDone: false)
            }



            if packet.type.rawValue + packet.qos.rawValue >= (MQTTPacket.Header.publish + MQTTQoSLevel.QoS1.rawValue) && packet.type.rawValue <= MQTTPacket.Header.unsuback {

                let count = input.read(messageBuffer, maxLength: 2)
                if count == 0 {
                    continue
                } else if count < 0 {
                    return
                }
                remainingLength -= count

                let msb = messageBuffer[0], lsb = messageBuffer[1]
                let id = (UInt16(msb) << 8) + UInt16(lsb)

                packet.identifier = id
            }

            /*  Payload
                ..
                PUBLISH: Optional
                SUBACK: Required
            */

            var bytesRead = 0
            while remainingLength > 0 {
                let count = input.read(messageBuffer, maxLength: min(remainingLength, options.bufferSize))
                if count == 0 {
                    continue mainReading
                } else if count < 0 {
                    return
                }
                bytesRead += count
                remainingLength -= count

                // Append data
                let data = Data(bytes: messageBuffer, count: count)
                packet.payload.append(data)
            }

            handlePacket(packet)
        }
    }


    private func handlePacket(_ packet: MQTTPacket) {

        print("\t\t<-", packet.type, packet.identifier ?? "")

        switch packet.type {
        case .connack:
            if let res = packet.connectionResponse {
                if res == .accepted {
                    state = .connected
                }
                didRecieveConack?(self, res)

            }

        case .publish:
            var duplicate = false
            if let id = packet.identifier {

                switch packet.qos {
                case .QoS1:
                    mqttPuback(id: id)
                    pendingPackets.removeValue(forKey: id)
                case .QoS2:
                    if let pending = pendingPackets[id], pending.type == .pubrec {
                        duplicate = true
                    }
                    mqttPubrec(id: id)

                default:
                    break
                }
            }


            if !duplicate, let msg = MQTTMessage(packet: packet) {
                didRecieveMessage?(self, msg)
            }

        case .pubrec:
            if let id = packet.identifier {
                mqttPubrel(id: id)
            }

        case .pubcomp:
            if let id = packet.identifier {
                pendingPackets.removeValue(forKey: id)
            }

        case .pubrel:
            if let id = packet.identifier {
                mqttPubcomp(id: id)
                pendingPackets.removeValue(forKey: id)
            }

        case .suback:
            if let id = packet.identifier, let topic = pendingPackets[id]?.topic, pendingPackets[id]?.type == .subscribe {
                pendingPackets.removeValue(forKey: id)
                didSubscribe?(self, topic)
            }
        case .unsuback:
            if let id = packet.identifier, let topic = pendingPackets[id]?.topic, pendingPackets[id]?.type == .unsubscribe {
                pendingPackets.removeValue(forKey: id)
                didUnsubscribe?(self, topic)
            }
        case .pingresp:
            pingCount = 0
            handlePendingPackets()

        case .disconnect:
            state = .disconnected

        default:
            print("Unhandled packet -", packet.type)
            break
        }
    }

    private func handlePendingPackets() {
        for var packet in pendingPackets.values {
            if packet.type == .publish {
                packet.dup = true
            }
            send(packet: packet)
        }
    }

    // MARK: - MQTT messages

    /**
     * |--------------------------------------
     * | 7 6 5 4 |     3    |  2 1  | 0      |
     * |  Type   | DUP flag |  QoS  | RETAIN |
     * |--------------------------------------
     */


    private func mqttConnect() {
        // http://docs.oasis-open.org/mqtt/mqtt/v3.1.1/os/mqtt-v3.1.1-os.html#_Toc398718028

        state = .connecting

        var connFlags: UInt8 = 0
        var packet = MQTTPacket(header: MQTTPacket.Header.connect)
        packet.payload += options.clientId

        // section 3.1.2.3
        if options.cleanSession {
            connFlags |= MQTTPacket.Connect.cleanSession
        }

        if let will = options.will {
            connFlags |= MQTTPacket.Connect.will
            packet.payload += will.topic
            packet.payload += will.message
            connFlags |= will.qos.rawValue << 2
        }

        if let username = options.username {
            connFlags |= MQTTPacket.Connect.username
            packet.payload += username
        }

        if let password = options.password {
            connFlags |= MQTTPacket.Connect.password
            packet.payload += password
        }

        packet.variableHeader += MQTTProtocol.Name // section 3.1.2.1
        packet.variableHeader += MQTTProtocol.Level // section 3.1.2.2
        packet.variableHeader += connFlags
        packet.variableHeader += options.keepAliveInterval // section 3.1.2.10

        send(packet: packet)
    }

    private func mqttDisconnect() {
        // http://docs.oasis-open.org/mqtt/mqtt/v3.1.1/os/mqtt-v3.1.1-os.html#_Toc398718090

        let packet = MQTTPacket(header: MQTTPacket.Header.disconnect)
        send(packet: packet)
        self.state = .disconnected
    }

    private func mqttSubscribe(to topic: String) {
        // http://docs.oasis-open.org/mqtt/mqtt/v3.1.1/os/mqtt-v3.1.1-os.html#_Toc398718063

        var packet = MQTTPacket(header: MQTTPacket.Header.subscribe)
        let id = nextMessageId()
        packet.identifier = id
        packet.variableHeader += id
        packet.payload += topic    // section 3.8.3
        packet.topic = topic
        packet.payload += UInt8(2) // QoS = 2

        send(packet: packet)
    }

    private func mqttUnsubscribe(from topic: String) {
        // http://docs.oasis-open.org/mqtt/mqtt/v3.1.1/os/mqtt-v3.1.1-os.html#_Toc398718072

        var packet = MQTTPacket(header: MQTTPacket.Header.subscribe)
        let id = nextMessageId()
        packet.identifier = id
        packet.variableHeader += id
        packet.payload += topic
        packet.topic = topic

        send(packet: packet)
    }

    private func mqttPublish(message: MQTTMessage) {

        var packet = MQTTPacket(header: message.header)
        packet.variableHeader += message.topic
        if message.qos > .QoS0 {
            let id = nextMessageId()
            packet.identifier = id
            packet.variableHeader += id
        }
        packet.payload = message.payload

        send(packet: packet)
    }

    private func mqttPing() {
        // http://docs.oasis-open.org/mqtt/mqtt/v3.1.1/os/mqtt-v3.1.1-os.html#_Toc398718081

        pingCount += 1
        let packet = MQTTPacket(header: MQTTPacket.Header.pingreq)
        send(packet: packet)
    }


    // MARK: - QoS 1 Reciever

    private func mqttPuback(id: UInt16) {
        var packet = MQTTPacket(header: MQTTPacket.Header.puback)
        packet.variableHeader += id
        packet.identifier = id
        send(packet: packet)
    }

    // MARK: - QoS 2 Sender

    private func mqttPubrel(id: UInt16) {
        var packet = MQTTPacket(header: MQTTPacket.Header.pubrel)
        packet.variableHeader += id
        packet.identifier = id
        send(packet: packet)
    }

    // MARK: - QoS 2 Reciever

    private func mqttPubrec(id: UInt16) {
        var packet = MQTTPacket(header: MQTTPacket.Header.pubrec)
        packet.variableHeader += id
        packet.identifier = id
        send(packet: packet)
    }

    private func mqttPubcomp(id: UInt16) {
        var packet = MQTTPacket(header: MQTTPacket.Header.pubcomp)
        packet.variableHeader += id
        packet.identifier = id
        send(packet: packet)
    }

    private func nextMessageId() -> UInt16 {
        messageId = messageId &+ 1
        return messageId
    }

    // MARK: - Send Packet

    private func send(packet: MQTTPacket) {

        if let id = packet.identifier {
            pendingPackets[id] = packet
        }

        guard let output = outputStream else { return }

        print(packet.type, packet.identifier ?? "", "->")

        let serialized = packet.encoded
        var toSend = serialized.count
        var sent = 0

        writeQueue.sync {
            while toSend > 0 {
                let count = serialized.withUnsafeBytes {
                    output.write($0.advanced(by: sent), maxLength: toSend)
                }
                if count < 0 {
                    return
                }
                toSend -= count
                sent += count
            }
        }
    }

    // MARK: - Public Static

    static func match(filter: String, with topic: String) -> Bool {

        let filterComponents = filter.components(separatedBy: "/")
        let topicComponents = topic.components(separatedBy: "/")

        guard filterComponents.count <= topicComponents.count else {
            return false
        }


        for i in 0..<filterComponents.count {
            let filterLevel = filterComponents[i], topicLevel = topicComponents[i]
            if  filterLevel == topicLevel || filterLevel == "+" {
                continue
            } else if filterLevel == "#" && i == filterComponents.count - 1 {
                return true
            } else {
                return false
            }
        }
        return true
    }
}

// MARK: - Packet
fileprivate struct MQTTPacket {

    var header: UInt8 = 0
    var variableHeader: Data = Data()
    var identifier: UInt16?
    var payload: Data = Data()
    var topic: String?

    var type: PacketType {
        get {
            return PacketType(rawValue: header & 0xF0) ?? PacketType(rawValue: 0)!
        }
        set {
            header &= ~MQTTPacket.Header.typeMask
            header |= newValue.rawValue
        }
    }

    var remainingLength: Data {

        var out = Data()
        var length = variableHeader.count + payload.count

        repeat {
            var encodedByte = UInt8(length % 128)
            length /= 128

            if length > 0 {
                encodedByte |= 128
            }
            out.append(encodedByte)

        } while length > 0

        return out
    }

    var encoded: Data {
        var bytes = Data(bytes: [header])
        bytes.append(remainingLength)
        bytes.append(variableHeader)
        bytes.append(payload)
        return bytes
    }

    init(header: UInt8) {
        self.header = header
    }

    init(header: MQTTPacket.Header) {
        self.init(header: header)
    }
}

// MARK: - Publish Packet
fileprivate extension MQTTPacket {
    var retained: Bool {
        get {
            return header & MQTTPacket.Publish.retained > 0
        }
        set {
            header &= ~MQTTPacket.Publish.retained
            if newValue {
                header |= MQTTPacket.Publish.retained
            }
        }
    }

    var qos: MQTTQoSLevel {
        get {
            return MQTTQoSLevel(rawValue: header & MQTTPacket.Publish.qos) ?? .QoS0
        }
        set {
            header &= ~MQTTPacket.Publish.qos
            header |= newValue.rawValue
        }
    }

    var dup: Bool {
        get {
            return header & MQTTPacket.Publish.dup < 0
        }
        set {
            header &= ~MQTTPacket.Publish.dup
            if newValue {
                header |= MQTTPacket.Publish.dup
            }
        }
    }
}

// MARK: - Connack Packet
fileprivate extension MQTTPacket {

    var connectionResponse: MQTTConnackResponse? {
        if variableHeader.count >= 1 {
        let raw = variableHeader[1]
            return MQTTConnackResponse(rawValue: raw)
        }
        return nil
    }

    var sessionPresent: Bool? {
        if variableHeader.count >= 1 {
            return variableHeader[0] & 0x01 > 0
        }
        return nil
    }
}

// MARK: - Suback Packet
fileprivate extension MQTTPacket {
    var maxQoS: [MQTTQoSLevel?] {
        var qos = [MQTTQoSLevel?]()
        for lvl in payload {
            qos.append(MQTTQoSLevel(rawValue: lvl))
        }
        return qos
    }
}

// MARK: - Packet Constants
fileprivate extension MQTTPacket {

    enum PacketType: UInt8 {
        case connect =     0x10
        case connack =     0x20
        case publish =     0x30
        case puback =      0x40
        case pubrec =      0x50
        case pubrel =      0x60
        case pubcomp =     0x70
        case subscribe =   0x80
        case suback =      0x90
        case unsubscribe = 0xa0
        case unsuback =    0xb0
        case pingreq =     0xc0
        case pingresp =    0xd0
        case disconnect =  0xe0
    }

    struct Header {
        static let typeMask: UInt8 =          0xF0

        
        static let  connect: UInt8     = 0x10
        static let  connack: UInt8     = 0x20
        static let  publish: UInt8     = 0x30
        static let  puback: UInt8      = 0x40
        static let  pubrec: UInt8      = 0x50
        static let  pubrel: UInt8      = 0x62
        static let  pubcomp: UInt8     = 0x70
        static let  subscribe: UInt8   = 0x82
        static let  suback: UInt8      = 0x90
        static let  unsubscribe: UInt8 = 0xa2
        static let  unsuback: UInt8    = 0xb0
        static let  pingreq: UInt8     = 0xc0
        static let  pingresp: UInt8    = 0xd0
        static let  disconnect: UInt8  = 0xe0
    }


    // Publish
    struct Publish {
        static let retained: UInt8 =      0b0000_0001
        static let qos: UInt8 =           0b0000_0110
        static let dup: UInt8 =           0b0000_1000
    }
    // Connection
    struct Connect {
        static let cleanSession: UInt8  = 1 << 1
        static let will: UInt8          = 1 << 2
        static let willQoS0: UInt8      = 0 << 0
        static let willQos1: UInt8      = 1 << 3
        static let willQos2: UInt8      = 1 << 4
        static let willRetain: UInt8    = 1 << 5
        static let password: UInt8      = 1 << 6
        static let username: UInt8      = 1 << 7
    }
}

// MARK: - Extensions
fileprivate extension UInt8 {
    var string: String {

        var byte = ""
        for i in 0..<8 {
            byte = "\((self >> i) & 0b1)" + byte
        }
        return byte
    }
}


fileprivate extension Data {
    static func += (block: inout Data, byte: UInt8) {
        block.append(byte)
    }

    static func += (block: inout Data, short: UInt16) {
        block += UInt8(short >> 8)
        block += UInt8(short & 0xFF)
    }

    static func += (block: inout Data, string: String) {
        block += UInt16(string.utf8.count)
        block += string.data(using: .utf8)!
    }

}
