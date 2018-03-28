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
let host = "localhost"
let topicToSub = "/a/topic"
let messagePayload = "Some interesting content".data(using: .utf8)!
let willTopic = "/will"
let willMessage = "disconnected"

class MQTTConnectedTests: XCTestCase {
    
    var mqtt: MQTTClient?
    
    override func setUp() {
        let connected = expectation(description: "Setup Connected")
        
        mqtt = MQTTClient(host: "localhost")
        
        mqtt?.connect() {_ in
            connected.fulfill()
        }
        
        wait(for: [connected], timeout: timeout)
        
    }
    
    override func tearDown() {
        
    
        guard let mqtt = mqtt, mqtt.state != .disconnected else {
            self.mqtt = nil
            return
        }
        
        let disconnected = expectation(description: "Tear Down Disconnected")
        
        mqtt.didDisconnect = {_,_ in
            disconnected.fulfill()
        }
        
        mqtt.disconnect()
        wait(for: [disconnected], timeout: timeout)
        self.mqtt = nil
    }
    
    func testAutoReconnect () {
        
        guard let mqtt = mqtt else {
            XCTFail("MQTTClient nil")
            return
        }
        
        let reconnect = expectation(description: "Auto Reconnect")

        mqtt.didConnect = {m, connected in
            XCTAssert(connected)
            reconnect.fulfill()
        }
        
        // Close network connection internally
        mqtt.closeStreams()
        
        wait(for: [reconnect], timeout: TimeInterval(20))
        
    }

    func testDeinit() {
        
        
        let disconnect = expectation(description: "Disconnect")
        weak var mqttRef = mqtt

        mqtt?.didDisconnect = {_, _ in
            disconnect.fulfill()
        }
        
        mqtt = nil
        
        wait(for: [disconnect], timeout: 3600)

        XCTAssertNil(mqttRef)
        
    }
    
    
    func testWill() {
        let connected = expectation(description: "Connected")
        let subscribed = expectation(description: "Subscribed")
        let recievedWill = expectation(description: "Recieved Will")
        
        mqtt?.didSubscribe = {_,topic in
            XCTAssertEqual(willTopic, topic)
            subscribed.fulfill()
        }

        
        mqtt?.subscribe(to: willTopic)
    
        var options = MQTTOptions(host: host)
        options.will = MQTTWill(qos: .QoS0, retained: false, topic: willTopic, message: willMessage)
        options.autoReconnect = false
        var unstableMqtt = MQTTClient(options: options)
        
        
        unstableMqtt.connect { _ in
            connected.fulfill()
        }
        
        wait(for: [connected, subscribed], timeout: timeout)
        
        mqtt?.didRecieveMessage = {_, msg in
            XCTAssertEqual(msg.topic, willTopic)
            XCTAssertEqual(msg.string, willMessage)
            
            recievedWill.fulfill()
        }
        
        unstableMqtt.closeStreams()
        
        wait(for: [recievedWill], timeout: TimeInterval(20))
        
        
    }

}

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


