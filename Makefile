.PHONY: build test clean build-example clean-example build-all

build:
	swift build

clean:
	swift package clean

build-example:
	swift build --package-path Examples/KarabinerElementsUserCommandReceiverApp

clean-example:
	swift package clean --package-path Examples/KarabinerElementsUserCommandReceiverApp

build-all: build build-example

swift-format:
	find * -name '*.swift' -print0 | xargs -0 swift-format -i

swiftlint:
	swiftlint

xcode:
	open -a Xcode .

xcode-example:
	open -a Xcode Examples/KarabinerElementsUserCommandReceiverApp

send-command:
	echo '{"type":"test","value":1}' | socat - UNIX-SENDTO:$(HOME)/.local/share/karabiner/tmp/karabiner_user_command_receiver.sock
