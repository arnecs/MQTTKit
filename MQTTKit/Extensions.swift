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
