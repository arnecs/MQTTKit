//
//  MQTTMessage.swift
//  MQTTKit
//
//  Created by Arne Christian Skarpnes on 30.03.2018.
//  Copyright © 2018 Arne Christian Skarpnes. All rights reserved.
//

import Foundation


public struct MQTTMessage {
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
    
    internal init?(packet: MQTTPacket) {
        guard packet.type == .publish else {
            return nil
        }
        
        topic = packet.topic ?? ""
        payload = packet.payload
        qos = packet.qos
        retained = packet.retained
    }
    
    internal var header: UInt8 {
        var header = MQTTPacket.Header.publish
        if retained {
            header |= MQTTPacket.Publish.retained
        }
        header |= qos.rawValue
        return header
    }
}
