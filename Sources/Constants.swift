//
//  Constants.swift
//  MQTTKit
//
//  Created by Arne Christian Skarpnes on 28.03.2018.
//  Copyright © 2018 Arne Christian Skarpnes. All rights reserved.
//

import Foundation

internal struct MQTTProtocol {
    static let Level: UInt8 = 4
    static let Name = "MQTT"
}

public enum MQTTConnackResponse: UInt8 {
    case accepted =                     0x00
    case unacceptableProtocolVersion =  0x01
    case identifierRejected =           0x02
    case serverUnavailable =            0x03
    case badUsernameOrPassword =        0x04
    case notAuthorized =                0x05
    case reserved =                     0x06
}

public enum MQTTConnectionState {
    case connected
    case connecting
    case disconnected
}

public enum MQTTQoSLevel: UInt8, Comparable {
    case qos0 = 0b0000_0000
    case qos1 = 0b0000_0010
    case qos2 = 0b0000_0100

    static let mostOnce = MQTTQoSLevel.qos0
    static let leastOnce = MQTTQoSLevel.qos1
    static let exactlyOnce = MQTTQoSLevel.qos2
    
    case failure = 0x80
}

public extension MQTTQoSLevel {
    static func < (lhs: MQTTQoSLevel, rhs: MQTTQoSLevel) -> Bool {
        return lhs.rawValue < rhs.rawValue
    }
}

// MARK: - Packet Constants
internal extension MQTTPacket {
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
        static let  typeMask: UInt8    = 0xF0
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
    
    struct Publish {
        static let retained: UInt8 =      0b0000_0001
        static let qos: UInt8 =           0b0000_0110
        static let dup: UInt8 =           0b0000_1000
    }

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

