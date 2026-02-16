EXAMPLE_XCODEBUILD = xcodebuild -project ExampleApp.xcodeproj -scheme ExampleApp -configuration Debug CODE_SIGNING_ALLOWED=NO CODE_SIGNING_REQUIRED=NO

build:
	swift build

build-bridge:
	swift build --product seq-user-command-bridge

build-bridge-release:
	swift build -c release --product seq-user-command-bridge

build-system-check:
	swift build --product kar-uc-system-check

run-bridge:
	swift run seq-user-command-bridge

run-bridge-release: build-bridge-release
	.build/release/seq-user-command-bridge

run-system-check:
	swift run kar-uc-system-check

test-bridge:
	python3 tools/bridge_smoke_test.py --build-if-missing --verbose

bench-bridge:
	python3 tools/bridge_latency_bench.py --build-if-missing --iterations 300 --warmup 40

clean:
	swift package clean

build-example: build
	(cd Example && $(EXAMPLE_XCODEBUILD) build)

clean-example:
	(cd Example && $(EXAMPLE_XCODEBUILD) clean)

build-all: build build-example

xcode:
	open -a Xcode .

xcode-example:
	open -a Xcode Example/ExampleApp.xcodeproj

send-command:
	python3 -c 'import json,socket,os; p=os.path.expanduser("~/.local/share/karabiner/tmp/karabiner_user_command_receiver.sock"); s=socket.socket(socket.AF_UNIX, socket.SOCK_DGRAM); s.sendto(json.dumps({"type":"test","value":1}).encode("utf-8"), p)'

swift-format:
	find * -name '*.swift' -print0 | xargs -0 swift-format -i

swiftlint:
	swiftlint
