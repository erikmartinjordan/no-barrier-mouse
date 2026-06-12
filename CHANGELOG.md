# Changelog

## [0.2.0](https://github.com/erikmartinjordan/no-barrier-mouse/compare/v0.1.0...v0.2.0) (2026-06-12)


### ✨ Features

* add Input Quality Monitor panel with frosted glass design and monochromatic minimalistic layout ([2971bdf](https://github.com/erikmartinjordan/no-barrier-mouse/commit/2971bdf5c3a8f52c3b6dfe714c5dadafc0c9166a))


### 🐛 Fixes

* simplify TCP mouse movement path ([da04840](https://github.com/erikmartinjordan/no-barrier-mouse/commit/da0484069aa4088a1662b884c34924c75dd03bc1))
* simplify UInt64 protocol decoding ([1b7f185](https://github.com/erikmartinjordan/no-barrier-mouse/commit/1b7f1854a721fb21c0e154616580a9409cbd2fa3))


### ⚡ Performance

* eliminate input queue hop for mouseDelta, remove redundant postMove, increase TCP minimum length ([c837318](https://github.com/erikmartinjordan/no-barrier-mouse/commit/c837318dd7f48ebf813a73a6edbba92fd42b640e))
* reduce NWConnection receiver jitter and add latency instrumentation ([6eb00aa](https://github.com/erikmartinjordan/no-barrier-mouse/commit/6eb00aad18007e2bbcd91f502193bcf75627b4d5))

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
