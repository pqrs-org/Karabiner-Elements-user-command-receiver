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
    )
  ],
  targets: [
    .target(
      name: "KarabinerElementsUserCommandReceiver",
      swiftSettings: [
        .enableExperimentalFeature("StrictConcurrency")
      ]
    )
  ]
)
