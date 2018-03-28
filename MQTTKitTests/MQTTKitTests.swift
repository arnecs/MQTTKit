//
//  MQTTKitTests.swift
//  MQTTKitTests
//
//  Created by Arne Christian Skarpnes on 28.03.2018.
//  Copyright © 2018 Arne Christian Skarpnes. All rights reserved.
//

import XCTest
@testable import MQTTKit


let timeout: TimeInterval = 5
let topicToSub = "/a/topic"
let messagePayload = "Some interesting content".data(using: .utf8)!


class MQTTKitTests: XCTestCase {
    
    var mqtt: MQTTClient!
    
    override func setUp() {
        super.setUp()
        // Put setup code here. This method is called before the invocation of each test method in the class.
        mqtt = MQTTClient(host: "localhost")
    }
    
    override func tearDown() {
        // Put teardown code here. This method is called after the invocation of each test method in the class.
        mqtt?.disconnect()
        mqtt = nil
        
        super.tearDown()
    }
    
    func testMQTT() {
        
        let conExp = expectation(description: "Connection")
        let subExp = expectation(description: "Subscription")
        let pubExpQoS0 = expectation(description: "Publish QoS0")
        let pubExpQoS1 = expectation(description: "Publish QoS1")
        let pubExpQoS2 = expectation(description: "Publish QoS2")
        let disExp = expectation(description: "Disconnect")
        
        pubExpQoS0.expectedFulfillmentCount = 3
        pubExpQoS1.expectedFulfillmentCount = 3
        pubExpQoS2.expectedFulfillmentCount = 3
        
        mqtt.didConnect = {_, connected in
            
            guard connected else {
                XCTFail()
                return
            }
            
            conExp.fulfill()
        }
        
        mqtt.connect()
        wait(for: [conExp], timeout: timeout)
        
        mqtt.didSubscribe = {_, topic in
            XCTAssertEqual(topic, topicToSub)
            
            subExp.fulfill()
        }
        
        
        mqtt.subscribe(to: topicToSub)
        wait(for: [subExp], timeout: timeout)
        
        
        mqtt.didRecieveMessage = {_, message in
            XCTAssertEqual(topicToSub, message.topic)
            print(message)
            switch message.qos {
            case .QoS0:
                pubExpQoS0.fulfill()
            case .QoS1:
                pubExpQoS1.fulfill()
            case .QoS2:
                pubExpQoS2.fulfill()
            default:
                break
            }
        }
        
        mqtt.publish(to: topicToSub, payload: messagePayload, qos: .QoS0, retained: false)
        mqtt.publish(to: topicToSub, payload: messagePayload, qos: .QoS1, retained: false)
        mqtt.publish(to: topicToSub, payload: messagePayload, qos: .QoS2, retained: false)
        
        mqtt.publish(to: topicToSub, payload: messagePayload, qos: .QoS2, retained: false)
        mqtt.publish(to: topicToSub, payload: messagePayload, qos: .QoS1, retained: false)
        mqtt.publish(to: topicToSub, payload: messagePayload, qos: .QoS0, retained: false)
        
        mqtt.publish(to: topicToSub, payload: messagePayload, qos: .QoS2, retained: false)
        mqtt.publish(to: topicToSub, payload: messagePayload, qos: .QoS0, retained: false)
        mqtt.publish(to: topicToSub, payload: messagePayload, qos: .QoS1, retained: false)
        
        wait(for: [pubExpQoS0, pubExpQoS1, pubExpQoS2], timeout: timeout)
        
        mqtt.didDisconnect = {_, _ in
            disExp.fulfill()
        }
        
        mqtt.disconnect()
        wait(for: [disExp], timeout: timeout)
    }
    
    
    func testAutoReconnect () {
        
        let initalConnect = expectation(description: "Connected")
        let reconnect = expectation(description: "Auto Reconnect")
        let disconnect = expectation(description: "auto Disconnect")

        mqtt.connect() {connected in
            XCTAssert(connected)
            initalConnect.fulfill()
        }
        
        self.wait(for: [initalConnect], timeout: TimeInterval(20))
        
        mqtt.didDisconnect = {_,_ in
            disconnect.fulfill()
        }
        
        mqtt.didConnect = {m, connected in
            XCTAssert(connected)
            reconnect.fulfill()
            
            m.disconnect()
        }
        
        // Close network connection internally
        self.mqtt.closeStreams()
        
        wait(for: [reconnect, disconnect], timeout: TimeInterval(20))
        
    }
    
    
    
    func testMemoryLeak() {
        let exp = expectation(description: "Wait forever")
        let exp2 = expectation(description: "IDK")
        
        mqtt.connect() {_ in
            
            
            exp.fulfill()
        }
        
        
        wait(for: [exp], timeout: 3600)
        
        print("nil")
        mqtt = nil
        
        wait(for: [exp2], timeout: 3600)
        
    }
    
    func testTopicMatch() {
        XCTAssertTrue(MQTTClient.match(filter: "/a/b/c", with: "/a/b/c"))
        XCTAssertTrue(MQTTClient.match(filter: "/a/+/c", with: "/a/b/c"))
        XCTAssertTrue(MQTTClient.match(filter: "/a/#", with: "/a/b/c"))
        XCTAssertTrue(MQTTClient.match(filter: "+/+/+/+", with: "/a/b/c"))
        XCTAssertTrue(MQTTClient.match(filter: "#", with: "/a/b/c"))
        XCTAssertTrue(MQTTClient.match(filter: "topic with/ space", with: "topic with/ space"))
        
        
        XCTAssertFalse(MQTTClient.match(filter: "/a", with: "a"))
        XCTAssertFalse(MQTTClient.match(filter: "/A/B/C", with: "/a/b/c"))
    }
}


