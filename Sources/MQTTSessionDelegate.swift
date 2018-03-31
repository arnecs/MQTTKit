//
//  MQTTSessionDelegate.swift
//  MQTTKit
//
//  Created by Arne Christian Skarpnes on 31.03.2018.
//  Copyright © 2018 Arne Christian Skarpnes. All rights reserved.
//

import Foundation

public protocol MQTTSessionDelegate: class {
    func mqttSession(_ session: MQTTSession, didRecieveMessage: MQTTMessage)
    func mqttSession(_ session: MQTTSession, didSubscribeToTopics: [String], withMaxQoSLevel: [MQTTQoSLevel])
    func mqttSession(_ session: MQTTSession, didUnsubscribeToTopics: [String])
    func mqttSession(_ session: MQTTSession, didRecieveConnack: MQTTConnackResponse)
    func mqttSession(_ session: MQTTSession, didChangeState: MQTTConnectionState)
}

extension MQTTSessionDelegate {
    func mqttSession(_ session: MQTTSession, didRecieveMessage: MQTTMessage) {}
    func mqttSession(_ session: MQTTSession, didSubscribeToTopics: [String], withMaxQoSLevel: [MQTTQoSLevel]) {}
    func mqttSession(_ session: MQTTSession, didUnsubscribeToTopics: [String]) {}
    func mqttSession(_ session: MQTTSession, didRecieveConnack: MQTTConnackResponse) {}
    func mqttSession(_ session: MQTTSession, didChangeState: MQTTConnectionState) {}
}
