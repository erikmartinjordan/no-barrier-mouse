# Build NoBarrierMouse
#   make         → .build/release/native/NoBarrierMouse.app (ad-hoc signed)
#   make intel   → .build/release/intel/NoBarrierMouse.app (ad-hoc signed)
#   make notarize   → native + Developer ID signing + notarization
#   make notarize-intel → Intel + Developer ID signing + notarization
#   make clean   → removes build artifacts
#
# Prerequisites for notarization:
#   1. Run scripts/setup-notarization.sh once
#   2. Have a Developer ID Application certificate in your keychain

ARCH ?= native

.PHONY: build native intel clean notarize notarize-intel

build: $(ARCH)

native: build-app.sh
	@bash build-app.sh native

intel: build-app.sh
	@bash build-app.sh intel

notarize: build-app.sh
	@NOTARIZE=true bash build-app.sh native

notarize-intel: build-app.sh
	@NOTARIZE=true bash build-app.sh intel

clean:
	rm -rf .build-native .build-intel .build/release
