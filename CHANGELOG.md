# Changelog

## [0.2.1](https://github.com/erikmartinjordan/no-barrier-mouse/compare/v0.2.0...v0.2.1) (2026-06-19)


### 🐛 Fixes

* keep benchmark artifacts out of Desktop ([561d9bb](https://github.com/erikmartinjordan/no-barrier-mouse/commit/561d9bb6047eadcc88a2a7423bdbab0ec1992121))
* smooth the transition between receiver and controller ([639832a](https://github.com/erikmartinjordan/no-barrier-mouse/commit/639832af2db0b1dcf7127517f6065f8c1a7b7861))
* stabilize synthetic handoff cursor recovery ([c9d672e](https://github.com/erikmartinjordan/no-barrier-mouse/commit/c9d672e14a6d79e1cdb05b044df2a2632598f3ed))

## [0.2.0](https://github.com/erikmartinjordan/no-barrier-mouse/compare/v0.1.0...v0.2.0) (2026-06-17)


### ✨ Features

* add AirDrop latency mode and unified settings panel ([c25658f](https://github.com/erikmartinjordan/no-barrier-mouse/commit/c25658f10c227f310c0286a680e9575fac1ff9fa))
* add Input Quality Monitor panel with frosted glass design and monochromatic minimalistic layout ([2971bdf](https://github.com/erikmartinjordan/no-barrier-mouse/commit/2971bdf5c3a8f52c3b6dfe714c5dadafc0c9166a))
* configurable edge policy, diagnostics snapshot, and emergency recovery in EventTap ([4354e66](https://github.com/erikmartinjordan/no-barrier-mouse/commit/4354e66fb893f7cf04b561cce93825959606f6b4))
* create-local-codesign-identity and run-e2e-imac-controller-video scripts ([b647665](https://github.com/erikmartinjordan/no-barrier-mouse/commit/b6476654f9d3b6e426953325e1aa402a4e002320))
* diagnostics snapshot, key event tracking, and permission side-effect suppression in RemoteInput ([8e9ef84](https://github.com/erikmartinjordan/no-barrier-mouse/commit/8e9ef84fd145165c01b439748b45554a92ba0b4d))
* E2E test runner with clipboard validation across cycles ([df002d4](https://github.com/erikmartinjordan/no-barrier-mouse/commit/df002d4989323168cf15f679b0da8eed007ba744))
* integrate E2E test runner, role persistence, and deferred event tap startup in AppDelegate ([eb58a81](https://github.com/erikmartinjordan/no-barrier-mouse/commit/eb58a81dfbc0dd81c21d37dba6561ddc0ecd5fbe))
* persist selected role across launches ([de93f10](https://github.com/erikmartinjordan/no-barrier-mouse/commit/de93f10a6781c659b092d8c7fca08fd07f2365b1))
* stable local code signing with configurable identity and keychain ([f269e0b](https://github.com/erikmartinjordan/no-barrier-mouse/commit/f269e0b585824f2be11899f40bd6315863713db6))


### 🐛 Fixes

* avoid direct peer-to-peer interfaces and prefer infrastructure ([dc16212](https://github.com/erikmartinjordan/no-barrier-mouse/commit/dc1621209676ef4226d138917bdb55a754bd81f6))
* cursor movement between screns (smooth and no delay) ([91a21c4](https://github.com/erikmartinjordan/no-barrier-mouse/commit/91a21c47b63fe2facacf5327981c4e82bf15f2bb))
* improve handoff ([95dba12](https://github.com/erikmartinjordan/no-barrier-mouse/commit/95dba120d10a4a760ea035e8d8ddfcf396c55f6e))
* nil window reference on RoleSelectionController close and re-select ([8cd6189](https://github.com/erikmartinjordan/no-barrier-mouse/commit/8cd61891d71b9b874814d618fe0395784d2085b7))
* replace boolean flags with ControlMode state machine, dispatch all state mutations on tap run loop ([14342c9](https://github.com/erikmartinjordan/no-barrier-mouse/commit/14342c9ace091d9c01f77fbb6070a130f1a7939e))
* resolve EventTap merge conflict ([0220a13](https://github.com/erikmartinjordan/no-barrier-mouse/commit/0220a139a117edd656e832af0da27b7c9182f159))
* simplify TCP mouse movement path ([da04840](https://github.com/erikmartinjordan/no-barrier-mouse/commit/da0484069aa4088a1662b884c34924c75dd03bc1))
* simplify UInt64 protocol decoding ([1b7f185](https://github.com/erikmartinjordan/no-barrier-mouse/commit/1b7f1854a721fb21c0e154616580a9409cbd2fa3))
* smooth receiver handoff to controller ([3c7d0b1](https://github.com/erikmartinjordan/no-barrier-mouse/commit/3c7d0b18aa1170a0e35c9a90999775f37bd5d79e))
* smooth receiver handoff to controller ([87c600e](https://github.com/erikmartinjordan/no-barrier-mouse/commit/87c600e698c6267a8fbf0a4a46be308182883721))


### 📖 Documentation

* E2E test mode setup, stable signing, and unattended video test workflow ([361ebdb](https://github.com/erikmartinjordan/no-barrier-mouse/commit/361ebdbebdda3764bcbab40ac01114a69ece86b9))


### ⚡ Performance

* eliminate input queue hop for mouseDelta, remove redundant postMove, increase TCP minimum length ([c837318](https://github.com/erikmartinjordan/no-barrier-mouse/commit/c837318dd7f48ebf813a73a6edbba92fd42b640e))
* reduce NWConnection receiver jitter and add latency instrumentation ([6eb00aa](https://github.com/erikmartinjordan/no-barrier-mouse/commit/6eb00aad18007e2bbcd91f502193bcf75627b4d5))


### ♻️ Refactoring

* remove raw socket benchmark ([18bff6c](https://github.com/erikmartinjordan/no-barrier-mouse/commit/18bff6c6b1b2eca6a7b49256bf3d8b532b762c5f))

## [0.1.0](https://github.com/erikmartinjordan/no-barrier-mouse/compare/v0.0.1...v0.1.0) (2026-06-11)


### ✨ Features

* add dual-monitor cursor jump with Y-position handoff and optimize remote input ([43c62f2](https://github.com/erikmartinjordan/no-barrier-mouse/commit/43c62f256365c82136e93b81bf560e41fec0a984))
* replace JSON LineCodec with binary WireCodec over TCP ([3e47148](https://github.com/erikmartinjordan/no-barrier-mouse/commit/3e4714874c5fc1ac5bac272860890f026b35fd88))


### 🐛 Fixes

* add two-phase handshake to ensure green icon means fully connected ([58df1d1](https://github.com/erikmartinjordan/no-barrier-mouse/commit/58df1d1dc055fda99a2b6b9420eda655af047b12))
* guard input monitoring APIs with #available(macOS 11, *) ([cf23181](https://github.com/erikmartinjordan/no-barrier-mouse/commit/cf2318159f17eb4872395a12bef1259a525960f6))
* improve mouse icon visibility with alpha fill ([eeccaf9](https://github.com/erikmartinjordan/no-barrier-mouse/commit/eeccaf9d45ca3ed2977898aa1a05da8c54ba224d))
* prevent double-connection race with deterministic ID-based connection direction and periodic re-browse ([8f14d36](https://github.com/erikmartinjordan/no-barrier-mouse/commit/8f14d36d1cf8844e97c6abc6a5995247525f3913))
* re-pin controller cursor on each delta flush to prevent drift when CGAssociateMouse fails on some macOS versions ([cd1af06](https://github.com/erikmartinjordan/no-barrier-mouse/commit/cd1af067941dd212d32a3463965bc02467ce9e40))
* remove force-unwrap from CGEventSource lazy init ([efea0de](https://github.com/erikmartinjordan/no-barrier-mouse/commit/efea0dedefca9ed4d2609c37b119f0366760d462))
* revert input queue optimization, keep everything on main queue ([b745a2c](https://github.com/erikmartinjordan/no-barrier-mouse/commit/b745a2c3e6c6fd17972234ea66e9cf05a6ccc9f2))


### ⚡ Performance

* improve input latency and release packaging ([da171ea](https://github.com/erikmartinjordan/no-barrier-mouse/commit/da171ea232e53d99faecb818b21e45accca0359c))
