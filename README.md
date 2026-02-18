# Karabiner-Elements-user-command-receiver

This Swift package provides a receiver for Karabiner-Elements `send_user_command` commands.
By integrating this package to build your own server, you can execute arbitrary processing from Karabiner-Elements with low latency.

## Installation (Swift Package Manager)

Add the package to your `Package.swift`:

```swift
dependencies: [
  .package(url: "https://github.com/pqrs-org/Karabiner-Elements-user-command-receiver.git", from: "1.1.0")
],
targets: [
  .executableTarget(
    name: "YourApp",
    dependencies: [
      .product(name: "KarabinerElementsUserCommandReceiver", package: "Karabiner-Elements-user-command-receiver")
    ]
  )
]
```

## Usage

```swift
import KarabinerElementsUserCommandReceiver

let receiver = KEUserCommandReceiver(
  path: KEUserCommandReceiver.defaultSocketPath(),
  onJSON: { json in
    print("JSON:", json)
  },
  onError: { error in
    print("Error:", error)
  }
)

do {
  try await receiver.start()
  print("Listening:", KEUserCommandReceiver.defaultSocketPath())
} catch {
  print("Start failed:", error)
}
```

Note: You need to call `stop` when the receiver is no longer needed.

```swift
receiver.stop()
```

Please refer to the [Example](Example) for actual usage.
