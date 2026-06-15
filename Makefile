# Build NoBarrierMouse
#   make         → .build/release/native/NoBarrierMouse.app
#   make intel   → .build/release/intel/NoBarrierMouse.app
#   make clean   → removes build artifacts

ARCH ?= native

.PHONY: build native intel clean

build: $(ARCH)

native: build-app.sh
	@bash build-app.sh native

intel: build-app.sh
	@bash build-app.sh intel

clean:
	rm -rf .build-native .build-intel .build/release
