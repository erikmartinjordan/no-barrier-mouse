# No Barrier Mouse

No Barrier Mouse is a tiny macOS menu-bar utility that shares one keyboard and mouse between two Macs on the same local network.

It is intentionally simple:

- both Macs run the same app
- the menu has `On` and `Quit`
- after turning on the first Mac, the menu title changes to `Waiting for another device`
- after turning on the second Mac, both menus change to `Connected`
- move the mouse through the right edge of one Mac to control the other Mac
- move the remote mouse to the left edge, or press `Esc`, to return control

## Build

Install Xcode Command Line Tools, then run this in the project folder:

```sh
swift build
```

To make a basic `.app` bundle:

```sh
chmod +x build-app.sh
./build-app.sh
open .build/release/NoBarrierMouse.app
```

For the 2013 Intel iMac, you can build an Intel app from the MacBook:

```sh
./build-app.sh intel
```

That creates:

```text
.build/release/NoBarrierMouse-Intel.app
```

Copy that app to the iMac.

## Roles

Run exactly one Mac as `Controller` and the other as `Receiver`.

- `Controller`: the Mac with the real Bluetooth mouse and keyboard attached.
- `Receiver`: the Mac you want to control remotely.

When connected, move through the controller Mac's right screen edge to control the receiver. You can also press `Control + Option + Command + Right Arrow` on the controller to force entry. While remote control is active, keyboard events are sent to the receiver.

To return control, press `Esc`, move the receiver cursor to the left edge, or press `Control + Option + Command + Escape` on the controller.

## Permissions

On both Macs, macOS must allow the app to control input:

1. Open the app.
2. Click the top-bar mouse-with-glasses icon.
3. Choose `On`.
4. When macOS asks, grant Accessibility permission.
5. If needed, also allow Local Network access.
6. Quit and reopen the app after changing permissions.

Accessibility is required for capturing keyboard/mouse events and recreating them on the other Mac.

If both Macs stay on `Waiting for another device`, check these first:

- both Macs are on the same Wi-Fi or Ethernet network
- VPNs/firewalls are not blocking local network traffic
- macOS Local Network permission is allowed for `NoBarrierMouse`
- quit and reopen the app on both Macs after changing permissions

## Current Limits

This is a first working version, not a full Barrier replacement.

- It uses Bonjour/local network discovery.
- It is designed for two Macs.
- The handoff edge is currently the right edge, and return is the remote left edge.
- Clipboard sharing is not implemented.
- The app is unsigned, so macOS may require right-click `Open` the first time.
- Both Macs must have Accessibility permission. The controller needs it to capture/suppress local input; the receiver needs it to recreate mouse and keyboard events.
