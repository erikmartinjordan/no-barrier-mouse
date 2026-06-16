# No Barrier Mouse

<p align="center">
  <img src="assets/icon.png" alt="No Barrier Mouse icon" width="128" height="128" />
</p>

<p align="center">
  <strong>One mouse. Two Macs. No barrier.</strong>
</p>

<p align="center">
  <img src="https://img.shields.io/github/downloads/erikmartinjordan/no-barrier-mouse/total?label=Total%20downloads&style=flat-square" alt="Total downloads" />
</p>

A tiny macOS menu-bar app for sharing one mouse and keyboard between two Macs on the same local network.

## Requirements

- macOS 10.15 or newer
- Xcode Command Line Tools
- Accessibility permission on both Macs
- Input Monitoring permission on the controller Mac
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
.build/release/native/NoBarrierMouse.app
.build/release/intel/NoBarrierMouse.app
```

### Stable Development Signing

Do not use ad-hoc signing for repeated permission-sensitive testing. Ad-hoc
signatures are tied to the binary hash, so every rebuild can look like a
different app to macOS TCC and Accessibility/Input Monitoring may be requested
again.

Create a stable local signing identity once:

```sh
scripts/create-local-codesign-identity.sh
scripts/create-local-codesign-identity.sh --trust
make
make intel
```

The `--trust` step asks for Touch ID or your macOS password once so the local
certificate can be trusted for code signing.

After that, grant app permissions once to the rebuilt app. Future native/Intel
builds keep the same signing identity and bundle identifier, so macOS should
keep the permission grant across rebuilds.

For a production or distribution build, set `CODESIGN_IDENTITY` to an Apple
Development or Developer ID identity instead.

## Use

1. Open No Barrier Mouse on both Macs.
2. Choose `Controller` on the Mac with the physical mouse and keyboard.
3. Choose `Receiver` on the Mac you want to control.
4. Grant Accessibility permission on both Macs.
5. Grant Input Monitoring permission on the controller Mac.
6. Move through the controller's right screen edge to enter the receiver.
7. Move through the receiver's left screen edge, or press `Esc`, to return.

If the cursor moves but clicks or scrolling do not work, remove the old No Barrier Mouse entry from Privacy & Security, add the current app again, then reopen it.

If mouse and clicks work but the keyboard does not, grant Input Monitoring permission on the controller Mac, then quit and reopen No Barrier Mouse.

## Unattended E2E Test Mode

`--test-mode` runs a safe two-machine transition test with JSON diagnostics and automatic recovery. The iMac runs as `Controller`; the MacBook runs as `Receiver`.

One-time setup:

1. Grant Accessibility on both Macs.
2. Grant Input Monitoring on the iMac controller.
3. Enable Remote Login on the iMac so the MacBook can launch it over SSH.
4. Keep both Macs logged into their desktop sessions.

Build both bundles, then run the real video E2E from the MacBook:

```sh
make
make intel
scripts/run-e2e-imac-controller-video.sh erik@iMac-de-Erik.local 50
```

The script installs the native receiver locally, installs the Intel controller on the iMac, keeps both displays awake, captures both real screens, runs 50 crossings, validates `Cmd-V` and `Cmd-C`, and writes a side-by-side video plus JSON logs under `/tmp/no-barrier-e2e-real-*`.

The emergency hotkey is `Control-Option-Command-Escape`. In test mode, the watchdog saves diagnostics and recovers automatically if forwarding stalls or the controller cursor appears trapped at the right edge.

## Release Strategy

No Barrier Mouse uses Release Please with Conventional Commits for official GitHub Releases.

Use commit messages like:

- `feat: add clipboard sharing`
- `fix: reduce cursor delay`
- `docs: update install notes`

After changes land on `main`, Release Please opens or updates a release PR. Merge that PR when you are ready to publish. The release workflow then creates the GitHub Release and uploads the app bundles.

Each release contains only:

- `NoBarrierMouse-X.X.X-macOS.zip`
- `NoBarrierMouse-X.X.X-macOS-Intel.zip`

## Notes

The app is not notarized by default. macOS may require right-clicking the app and choosing `Open` the first time.
