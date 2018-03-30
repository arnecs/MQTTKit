//
//  MQTTPacket.swift
//  MQTTKit
//
//  Created by Arne Christian Skarpnes on 28.03.2018.
//  Copyright © 2018 Arne Christian Skarpnes. All rights reserved.
//

import Foundation

// MARK: - Packet
internal struct MQTTPacket {
    
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
internal extension MQTTPacket {
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
internal extension MQTTPacket {
    
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
internal extension MQTTPacket {
    var maxQoS: [MQTTQoSLevel?] {
        var qos = [MQTTQoSLevel?]()
        for lvl in payload {
            qos.append(MQTTQoSLevel(rawValue: lvl))
        }
        return qos
    }
}

