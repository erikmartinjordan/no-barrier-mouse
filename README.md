# No Barrier Mouse

![No Barrier Mouse icon](assets/icon.png)

A tiny macOS menu-bar app for sharing one mouse and keyboard between two Macs on the same local network.

## Requirements

- macOS 10.15 or newer
- Xcode Command Line Tools
- Accessibility permission on both Macs
- Local Network permission if macOS asks for it

## Build

Build the app for the current Mac:

```sh
./build-app.sh
```

Build the Intel app from an Apple Silicon Mac:

```sh
./build-app.sh intel
```

The app bundles are created in:

```text
.build/release/NoBarrierMouse.app
.build/release/NoBarrierMouse-Intel.app
```

## Use

1. Open No Barrier Mouse on both Macs.
2. Choose `Controller` on the Mac with the physical mouse and keyboard.
3. Choose `Receiver` on the Mac you want to control.
4. Grant Accessibility permission on both Macs.
5. Move through the controller's right screen edge to enter the receiver.
6. Move through the receiver's left screen edge, or press `Esc`, to return.

If the cursor moves but clicks or scrolling do not work, remove the old No Barrier Mouse entry from Privacy & Security, add the current app again, then reopen it.

## Release

GitHub Actions publishes releases when a tag like `v0.0.1` is pushed, or when the `Release` workflow is run manually.

Each release contains only:

- `NoBarrierMouse-0.0.1-macOS.zip`
- `NoBarrierMouse-0.0.1-macOS-Intel.zip`

## Notes

The app is unsigned and not notarized by default. macOS may require right-clicking the app and choosing `Open` the first time.
