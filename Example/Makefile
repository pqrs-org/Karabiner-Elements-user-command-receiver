all:
	xcodebuild -project ExampleApp.xcodeproj -scheme ExampleApp -configuration Debug CODE_SIGNING_ALLOWED=NO CODE_SIGNING_REQUIRED=NO SYMROOT="$(CURDIR)/build" build

clean:
	xcodebuild -project ExampleApp.xcodeproj -scheme ExampleApp -configuration Debug CODE_SIGNING_ALLOWED=NO CODE_SIGNING_REQUIRED=NO SYMROOT="$(CURDIR)/build" clean
	rm -fr build
