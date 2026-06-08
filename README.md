# No Barrier Mouse

No Barrier Mouse is a tiny macOS menu-bar utility for sharing one keyboard and mouse between two Macs on the same local network.

It is currently designed for a simple two-Mac setup:

- one Mac runs as `Controller`
- one Mac runs as `Receiver`
- the controller sends mouse, click, scroll, and keyboard input to the receiver
- moving through the controller's right edge enters the receiver
- moving through the receiver's left edge returns control to the controller

## Status

This is an early working version, not a polished Barrier/Synergy replacement yet. It works best when both Macs are on the same fast local network, preferably Ethernet or strong Wi-Fi.

Recent latency improvements include TCP no-delay, a user-interactive network queue, and faster mouse delta forwarding. There can still be some lag because motion is currently sent as JSON messages over TCP.

## Requirements

- macOS 10.15 or newer
- Xcode Command Line Tools
- two Macs on the same local network
- Accessibility permission on both Macs
- Local Network permission if macOS asks for it

## Build

Install Xcode Command Line Tools, then run:

```sh
swift build
```

To build a native `.app` bundle:

```sh
chmod +x build-app.sh
./build-app.sh
```

That creates:

```text
.build/release/NoBarrierMouse.app
```

To build an Intel app for an older iMac from an Apple Silicon Mac:

```sh
./build-app.sh intel
```

That creates:

```text
.build/release/NoBarrierMouse-Intel.app
```

Copy the native app to the Apple Silicon Mac and the Intel app to the Intel Mac.

## Usage

Run the app on both Macs.

Choose roles:

- `Controller`: the Mac with the physical mouse and keyboard.
- `Receiver`: the Mac you want to control remotely.

When both apps connect, the menu-bar icon turns green and the menu says `Connected`.

Controls:

- Move through the controller Mac's right screen edge to enter the receiver.
- Move through the receiver Mac's left screen edge to return to the controller.
- Press `Esc` while controlling the receiver to return control.
- Press `Control + Option + Command + Right Arrow` on the controller to force entry.
- Press `Control + Option + Command + Escape` on the controller for emergency off.

## Permissions

No Barrier Mouse needs Accessibility permission on both Macs.

On each Mac:

1. Open No Barrier Mouse.
2. Choose the correct role.
3. If macOS asks, grant Accessibility permission.
4. If macOS asks, allow Local Network access.
5. If input does not work after changing permissions, quit and reopen the app.

If clicks, scrolling, or keyboard input do not work on the receiver while the cursor still moves, the receiver app almost certainly needs Accessibility permission. Remove any old No Barrier Mouse entry from Privacy & Security, add the rebuilt app again, then reopen it.

## Repository Hygiene

Do not commit generated build artifacts.

These should be ignored or removed from Git:

- `.build/`
- `.build-native/`
- `.build-intel/`
- `.DS_Store`
- generated `.app` bundles

The source files that should be committed are mainly:

- `Package.swift`
- `build-app.sh`
- `README.md`
- `.gitignore`
- `.gitattributes`
- `Sources/NoBarrierMouse/*.swift`

If generated files were already committed, remove them from Git while keeping them locally:

```sh
git rm -r --cached .build .build-native .build-intel .DS_Store
git add .gitignore README.md
git commit -m "Clean generated files and update README"
```

## Troubleshooting

If both Macs stay on `Waiting for another device`:

- make sure both Macs are on the same Wi-Fi or Ethernet network
- allow Local Network access for No Barrier Mouse
- check that VPNs or firewalls are not blocking local Bonjour/TCP traffic
- quit and reopen the app on both Macs

If the receiver cursor moves but clicks or scrolling do not work:

- grant Accessibility permission on the receiver
- remove old permission entries for previous app builds
- reopen the app after changing permissions

If the controller does not capture input:

- grant Accessibility permission on the controller
- choose `Controller` again from the menu-bar app
- quit and reopen the app if macOS permissions were changed

## Current Limits

- Designed for two Macs.
- Uses Bonjour/local network discovery.
- Uses JSON-over-TCP for input messages, so some latency is still expected.
- Clipboard sharing is not implemented.
- Display layout is fixed: controller exits right, receiver returns left.
- The app is unsigned, so macOS may require right-click `Open` the first time.
