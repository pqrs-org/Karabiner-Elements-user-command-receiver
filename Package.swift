// swift-tools-version: 6.2
import PackageDescription

let package = Package(
  name: "KarabinerElementsUserCommandReceiver",
  platforms: [
    .macOS(.v15)
  ],
  products: [
    .library(
      name: "KarabinerElementsUserCommandReceiver",
      targets: ["KarabinerElementsUserCommandReceiver"]
    ),
    .executable(
      name: "seq-user-command-bridge",
      targets: ["SeqUserCommandBridge"]
    ),
    .executable(
      name: "kar-uc-system-check",
      targets: ["KarUcSystemCheck"]
    ),
  ],
  targets: [
    .target(
      name: "KarabinerElementsUserCommandReceiver",
      swiftSettings: [
        .enableExperimentalFeature("StrictConcurrency")
      ]
    ),
    .executableTarget(
      name: "SeqUserCommandBridge",
      dependencies: ["KarabinerElementsUserCommandReceiver"],
      swiftSettings: [
        .enableExperimentalFeature("StrictConcurrency")
      ]
    ),
    .executableTarget(
      name: "KarUcSystemCheck",
      swiftSettings: [
        .enableExperimentalFeature("StrictConcurrency")
      ]
    ),
  ]
)
