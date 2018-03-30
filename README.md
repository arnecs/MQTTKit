# MQTTKit

MQTT Client written in Swift

![Travis](https://img.shields.io/travis/arnecs/MQTTKit.svg)
[![Swift Version](https://img.shields.io/badge/Swift-4.0-F16D39.svg?style=flat)](https://developer.apple.com/swift)
![license](https://img.shields.io/github/license/arnecs/MQTTKit.svg)

## Getting Started

### Installing

#### Swift Package Manager
MQTTKit can be installed using [Swift Package Manager](https://github.com/apple/swift-package-manager), add MQTTKit to the dependency list in Package.swift:

```Swift
let package = Package(
    /*...*/
    dependencies: [
        .package(url: "https://github.com/arnecs/MQTTKit.git", from: "0.1.0")
    ]
    /*...*/
)
```

#### Carthage

MQTTKit can be installed using [Carthage](https://github.com/Carthage/Carthage), add this line in your Carthage file:

```
github "arnecs/MQTTKit"
```

#### Manually
Clone the project repository, and add it to the your project.
```
git clone https://github.com/arnecs/MQTTKit.git
```

## Usage

Use closures to get notified of events
```Swift

public var didRecieveMessage: ((_ mqtt: MQTTClient, _ message: MQTTMessage) -> Void)?
public var didRecieveConack: ((_ mqtt: MQTTClient, _ status: MQTTConnackResponse) -> Void)?
public var didSubscribe: ((_ mqtt: MQTTClient, _ topic: String) -> Void)?
public var didUnsubscribe: ((_ mqtt: MQTTClient, _ topic: String) -> Void)?
public var didConnect: ((_ mqtt: MQTTClient, _ connected: Bool) -> Void)?
public var didDisconnect: ((_ mqtt: MQTTClient, _ error: Error?) -> Void)?
public var didChangeState: ((_ mqtt: MQTTClient, _ state: MQTTConnectionState) -> Void)?
```


Connect to a MQTT Broker
```Swift
import MQTTKit

let mqtt = MQTTClient(host: "localhost")

mqtt.didConnect = {mqtt, connected in
  // Gets called when a connack.accepted is recieved
}
// Or
mqtt.didRecieveConnack = {mqtt, response in
  // Gets callen when connack is recieved
}

mqtt.connect()
```

Subscribe and unsubscribe to topics
```Swift
mqtt.didSubscribe = {mqtt, topic in
  // Gets called when suback is recieved
}

mqtt.didUnsubscribe  = {mqtt, topic in
  // Gets called when unsuback is recieved
}

mqtt.subscribe(to: "/my/topic")
mqtt.unsubscribe(from: "/my/topic")

```


Publish and recieved messages
```swift
let messagePayload = "Some interesting content".data(using: .utf8)!
mqtt.publish(to: "/my/topic", payload: messagePayload, qos: .QoS0, retained: false)

mqtt.didRecieveMessage = {mqtt, message in
  print(message)
}

```

## Running the tests
The tests requires a connection to a MQTT Broker. The address is located in the test file.

To start the tests, run:

```
swift test
```

or use `xcodebuild` to test for a specific platform:
```
xcodebuild clean test -scheme MQTTKit -destination "platform=macos"
xcodebuild clean test -scheme MQTTKit -destination "platform=iOS Simulator,name=iPhone 8"
xcodebuild clean test -scheme MQTTKit -destination "platform=tvOS Simulator,name=Apple TV"
```

## License

This project is licensed under the MIT License - see the [LICENSE.md](LICENSE.md) file for details
