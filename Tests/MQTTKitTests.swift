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
let host = ProcessInfo.processInfo.environment["MQTTKit_TEST_HOST"] ?? "test.mosquitto.org"
let port = Int(ProcessInfo.processInfo.environment["MQTTKit_TEST_PORT"] ?? "1883") ?? 1883
let topicToSub = "/a/topic/very/specific/topic/to/not/get/disturbed by other messages"
let messagePayload = "Some interesting content".data(using: .utf8)!
let willTopic = "/will546724975"
let willMessage = "disconnected".data(using: .utf8)!
let manyTopics = ["as34dsf","/afdwgf/+","/gmkorw04/hgw", "a3gri92/24g2gb/+/2g45d"]

class MQTTConnectedTests: XCTestCase {

    var mqtt: MQTTSession!

    override func setUp() {

        let connected = expectation(description: "Setup Connected")

        mqtt = MQTTSession(host: host, port: port)
        mqtt.didConnect = {_, success in
            if success {
                connected.fulfill()
            } else {
                XCTFail("Not connected")
            }
        }
        mqtt.connect()
        wait(for: [connected], timeout: timeout)
    }

    override func tearDown() {
        if mqtt == nil {
            return
        }

        if mqtt.state != .disconnected {
            let disconnected = expectation(description: "Tear Down Disconnected")

            mqtt.didDisconnect = {_,_ in
                disconnected.fulfill()
            }
            mqtt.disconnect()
            wait(for: [disconnected], timeout: timeout)

            self.mqtt = nil
        }
    }

    func testReconnect () {

        let reconnect = expectation(description: "Auto Reconnect")

        mqtt.didConnect = {m, connected in
            XCTAssert(connected)
            reconnect.fulfill()
        }

        // Close network connection internally
        mqtt.closeStreams()

        wait(for: [reconnect], timeout: 60)
    }

    func testDeinit() {

        let disconnect = expectation(description: "Disconnect")
        weak var mqttRef = mqtt

        mqtt?.didDisconnect = {_, _ in
            disconnect.fulfill()
        }

        mqtt = nil

        wait(for: [disconnect], timeout: timeout)

        XCTAssertNil(mqttRef)

    }


    func testWill() {
        let connected = expectation(description: "Connected")
        let subscribed = expectation(description: "Subscribed")
        let recievedWill = expectation(description: "Recieved Will")

        mqtt?.didSubscribe = {_,topics in
            XCTAssertEqual(willTopic, topics[0])
            subscribed.fulfill()
        }

        mqtt?.subscribe(to: willTopic)

        var options = MQTTOptions(host: host)
        options.will = MQTTMessage(topic: willTopic, payload: willMessage, qos: .QoS0, retained: false)
        options.autoReconnect = false
        let unstableMqtt = MQTTSession(options: options)

        unstableMqtt.connect { _ in
            connected.fulfill()
        }

        wait(for: [connected, subscribed], timeout: timeout)

        mqtt?.didRecieveMessage = {_, msg in
            XCTAssertEqual(msg.topic, willTopic)
            XCTAssertEqual(msg.payload, willMessage)
            recievedWill.fulfill()
        }

        unstableMqtt.closeStreams()
        wait(for: [recievedWill], timeout: TimeInterval(20))

    }

    func testKeepAlive() {
        let keepAliveFailExpectation = expectation(description: "Keep Alive")
        keepAliveFailExpectation.isInverted = true

        mqtt!.didDisconnect = {_, _ in
            keepAliveFailExpectation.fulfill()
        }

        mqtt?.didChangeState = {_, state in
            keepAliveFailExpectation.fulfill()
        }

        wait(for: [keepAliveFailExpectation], timeout: 60.0)
        mqtt.didDisconnect = nil
        mqtt.didChangeState = nil

        XCTAssertEqual(mqtt?.state, MQTTConnectionState.connected)
    }
}

class MQTTKitTests: XCTestCase {

    var mqtt: MQTTSession!

    override func setUp() {
        super.setUp()
        // Put setup code here. This method is called before the invocation of each test method in the class.
        mqtt = MQTTSession(host: host)
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
        let unsubExp = expectation(description: "Unsubscribe")
        let multiSubExp = expectation(description: "Subscribed to multible topics")
        let multiUnsubExp = expectation(description: "Unsubscribed to multible topics")
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

        mqtt.didSubscribe = {_, topics in

            print(topics)
            XCTAssertEqual(topics[0], topicToSub)

            subExp.fulfill()
        }


        mqtt.subscribe(to: topicToSub)
        wait(for: [subExp], timeout: timeout)


        mqtt.didRecieveMessage = {_, message in

            print("RECIEVED MESSAGE - TOPIC:", message.topic)

            XCTAssertEqual(topicToSub, message.topic)
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


        mqtt.publish(message: MQTTMessage(topic: topicToSub, payload: messagePayload, qos: .QoS2, retained: false))
        mqtt.publish(message: MQTTMessage(topic: topicToSub, payload: messagePayload, qos: .QoS0, retained: false))
        mqtt.publish(message: MQTTMessage(topic: topicToSub, payload: messagePayload, qos: .QoS1, retained: false))

        wait(for: [pubExpQoS0, pubExpQoS1, pubExpQoS2], timeout: timeout)

        mqtt.didUnsubscribe = {_, topics in
            XCTAssertEqual(topicToSub, topics[0])

            if topicToSub == topics[0] {
                unsubExp.fulfill()
            }
        }

        mqtt.unsubscribe(from: topicToSub)

        wait(for: [unsubExp], timeout: timeout)

        mqtt.didSubscribe = {_, topics in
            XCTAssertEqual(manyTopics.count, topics.count)

            for (index, topic) in topics.enumerated() {
                XCTAssertEqual(topic, manyTopics[index])
            }

            multiSubExp.fulfill()
        }


        let mappedTopics = manyTopics.map() { (topic) -> (String, MQTTQoSLevel) in
            return (topic, .QoS2)
        }
        mqtt.subscribe(to: mappedTopics)

        wait(for: [multiSubExp], timeout: timeout)

        mqtt.didUnsubscribe = {_, topics in

            XCTAssertEqual(manyTopics.count, topics.count)
            for (index, topic) in topics.enumerated() {
                XCTAssertEqual(topic, manyTopics[index])
            }

            multiUnsubExp.fulfill()
        }

        mqtt.unsubscribe(from: manyTopics)
        wait(for: [multiUnsubExp], timeout: timeout)

        mqtt.didDisconnect = {_, _ in
            disExp.fulfill()
        }

        mqtt.disconnect()
        wait(for: [disExp], timeout: timeout)
    }


    func testTopicMatch() {
        XCTAssertTrue(MQTTKit.match(filter: "/a/b/c", with: "/a/b/c"))
        XCTAssertTrue(MQTTKit.match(filter: "/a/+/c", with: "/a/b/c"))
        XCTAssertTrue(MQTTKit.match(filter: "/a/#", with: "/a/b/c"))
        XCTAssertTrue(MQTTKit.match(filter: "+/+/+/+", with: "/a/b/c"))
        XCTAssertTrue(MQTTKit.match(filter: "#", with: "/a/b/c"))
        XCTAssertTrue(MQTTKit.match(filter: "topic with/ space", with: "topic with/ space"))


        XCTAssertFalse(MQTTKit.match(filter: "/a", with: "a"))
        XCTAssertFalse(MQTTKit.match(filter: "/A/B/C", with: "/a/b/c"))
    }
}
