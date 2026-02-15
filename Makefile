build:
	swift build

clean:
	swift package clean

build-example: build
	(cd Example && xcodebuild)

clean-example:
	(cd Example && xcodebuild clean)

build-all: build build-example

xcode:
	open -a Xcode .

xcode-example:
	open -a Xcode Example/ExampleApp.xcodeproj

send-command:
	echo '{"type":"test","value":1}' | socat - UNIX-SENDTO:$(HOME)/.local/share/karabiner/tmp/karabiner_user_command_receiver.sock

swift-format:
	find * -name '*.swift' -print0 | xargs -0 swift-format -i

swiftlint:
	swiftlint
