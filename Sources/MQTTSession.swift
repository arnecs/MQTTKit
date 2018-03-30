//
//  MQTTClient.swift
//  MQTTKit
//
//  Created by Arne Christian Skarpnes on 30.03.2018.
//  Copyright © 2018 Arne Christian Skarpnes. All rights reserved.
//

import Foundation

final public class MQTTSession: NSObject, StreamDelegate {
    private var options: MQTTOptions
    private var inputStream: InputStream?
    private var outputStream: OutputStream?
    private lazy var lastServerResponse: Date = Date()
    private var writeQueue = DispatchQueue(label: "mqtt_write")
    private var messageId: UInt16 = 0
    private var pendingPackets: [UInt16:MQTTPacket] = [:]
    
    // MARK: - Delegate Methods
    public var didRecieveMessage: ((_ mqtt: MQTTSession, _ message: MQTTMessage) -> Void)?
    public var didRecieveConack: ((_ mqtt: MQTTSession, _ status: MQTTConnackResponse) -> Void)?
    public var didSubscribe: ((_ mqtt: MQTTSession, _ topic: String) -> Void)?
    public var didUnsubscribe: ((_ mqtt: MQTTSession, _ topic: String) -> Void)?
    public var didConnect: ((_ mqtt: MQTTSession, _ connected: Bool) -> Void)?
    public var didDisconnect: ((_ mqtt: MQTTSession, _ error: Error?) -> Void)?
    public var didChangeState: ((_ mqtt: MQTTSession, _ state: MQTTConnectionState) -> Void)?
    
    // MARK: - Public interface
    public private(set) var state: MQTTConnectionState = .disconnected {
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
    
    public init(host: String, port: Int = -1) {
        self.options = MQTTOptions(host: host)
        if port > 0 {
            self.options.port = port
        }
    }
    
    public init(options: MQTTOptions) {
        self.options = options
    }
    
    deinit {
        disconnect()
    }
    
    public func connect(completion: ((_ success: Bool) -> ())? = nil) {
        openStreams() { [weak self] streams in
            guard let strongSelf = self, let streams = streams else {
                completion?(false)
                return
            }
            strongSelf.closeStreams()
            
            strongSelf.inputStream = streams.input
            strongSelf.outputStream = streams.output
            
            strongSelf.mqttConnect()
            strongSelf.startKeepAliveTimer()
            
            strongSelf.messageId = 0x00
            
            completion?(true)
        }
    }
    
    public func disconnect() {
        mqttDisconnect()
        closeStreams()
    }
    
    public func subscribe(to topic: String) {
        mqttSubscribe(to: topic)
    }
    
    public func unsubscribe(from topic: String) {
        mqttUnsubscribe(from: topic)
    }
    
    public func publish(message: MQTTMessage) {
        mqttPublish(message: message)
    }
    
    public func publish(to topic: String, payload: Data, qos: MQTTQoSLevel = .QoS0, retained: Bool = false) {
        let message = MQTTMessage(topic: topic, payload: payload, qos: qos, retained: retained)
        mqttPublish(message: message)
    }
    
    // MARK: - Keep alive timer
    
    private func startKeepAliveTimer() {
        
        guard options.keepAliveInterval > 0 else {
            return
        }
        
        let time = DispatchTime.now() + Double(options.keepAliveInterval)
        DispatchQueue.main.asyncAfter(deadline: time) { [weak self] in
            
            guard let strongSelf = self, strongSelf.outputStream?.streamStatus == .open, -strongSelf.lastServerResponse.timeIntervalSinceNow < Double(strongSelf.options.keepAliveInterval) * 1.5  else {
                self?.state = .disconnected
                self?.autoReconnect()
                return
            }
            
            self?.mqttPingreq()
            self?.startKeepAliveTimer()
        }
    }
    
    private func autoReconnect() {
        
        guard self.options.autoReconnect else {
            self.closeStreams()
            return
        }
        
        if  -lastServerResponse.timeIntervalSinceNow < options.autoReconnectTimeout && self.state == .disconnected {
            connect()
            
            // Schedule next retry
            let time = DispatchTime.now() + Double(options.keepAliveInterval / 2)
            DispatchQueue.main.asyncAfter(deadline: time, execute: self.autoReconnect)
        }
    }
    
    // MARK: - Socket connection
    
    private func openStreams(completion: @escaping (((input: InputStream, output: OutputStream)?) -> ())) {
        var inputStream: InputStream?
        var outputStream: OutputStream?
        
        Stream.getStreamsToHost(
            withName: options.host,
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
    
    internal func closeStreams() {
        inputStream?.close()
        outputStream?.close()
        
        inputStream = nil
        outputStream = nil
    }
    
    // MARK: - Stream Delegate
    public func stream(_ aStream: Stream, handle eventCode: Stream.Event) {
        switch eventCode {
        case .hasBytesAvailable:
            if let input = aStream as? InputStream {
                readStream(input: input)
            }
        case .errorOccurred:
            //options.autoReconnect ? autoReconnect() : disconnect()
            break
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
        
        lastServerResponse = Date()
        
        //print("\t\t<-", packet.type, packet.identifier ?? "")
        
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
            handlePendingPackets()
            
        case .disconnect:
            state = .disconnected
            
        default:
            print("Unhandled packet -", packet.type)
            break
        }
        
        
        //startKeepAliveTimer()
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
            packet.payload += will.string ?? ""
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
    
    private func mqttPingreq() {
        // http://docs.oasis-open.org/mqtt/mqtt/v3.1.1/os/mqtt-v3.1.1-os.html#_Toc398718081
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
    
    // MARK: - Send Packet
    
    private func send(packet: MQTTPacket) {
        
        if let id = packet.identifier {
            pendingPackets[id] = packet
        }
        
        guard let output = outputStream else { return }
        
        // print(packet.type, packet.identifier ?? "", "->")
        
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
    
    private func nextMessageId() -> UInt16 {
        messageId = messageId &+ 1
        return messageId
    }
}
