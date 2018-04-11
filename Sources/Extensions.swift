//
//  Extensions.swift
//  MQTTKit
//
//  Created by Arne Christian Skarpnes on 28.03.2018.
//  Copyright © 2018 Arne Christian Skarpnes. All rights reserved.
//

import Foundation

internal extension Data {
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

internal extension UInt16 {
    init(msb: UInt8, lsb: UInt8) {
        self = UInt16(msb) << 8 + lsb
    }

    static func + (lhs: UInt16, rhs: UInt8) -> UInt16 {
        return lhs + UInt16(rhs)
    }
}

// MARK: - Public Static
public struct MQTTKit {
    static public func match(filter: String, with topic: String) -> Bool {
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
