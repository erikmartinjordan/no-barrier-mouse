# Latency Notes

## Current Input Pipeline

### Controller Mac (capture + send)

```
CGEventTap callback (main run loop)
  → EventTap.handle()
    → forward() — accumulate deltas, throttle at 2ms (500 Hz)
      → flushDelta() / sendPendingDelta() — synchronous if throttle elapsed, else DispatchQueue.main.asyncAfter
        → send?() → PeerNetwork.send() — encode + length-prefix + connection.send()
          → Network.framework TCP (noDelay, .interactiveVideo)
```

- CGEventTap runs at `.cghidEventTap` (before the HID driver processes events), `.headInsertEventTap`
- Mouse deltas are **coalesced** into `pendingDelta` and sent at ≤500 Hz
- Keyboard/button events **flush** pending deltas first (`flushDelta()`), then send immediately

### Receiver Mac (receive + apply)

```
Network.framework TCP receive (queue: .userInteractive)
  → receiveBuffer.append + tryReadMessage()
    → dispatchMessage()
      → before: DispatchQueue.main.async {...}
      → after:  inputQueue.async {...} (for mouse, keyboard, scroll, button)
                DispatchQueue.main.async {...} (for control messages)
        → onMessage?() → AppDelegate.handleNetworkMessage()
          → remoteInput.apply(message)
            → moveMouse() — CGWarpMouseCursorPosition + CGEvent.post(.mouseMoved)
```

### Key message types and their paths

| Type | Size (bytes) | Send path | Receive path |
|------|-------------|-----------|-------------|
| `mouseDelta` | 18-19 | EventTap.forward() → PeerNetwork.send() | inputQueue → RemoteInput.moveMouse() |
| `scroll` | 17 | EventTap.forward() → PeerNetwork.send() | inputQueue → RemoteInput (scroll event) |
| `key` / `flags` | 20 / 19 | EventTap.forward() → PeerNetwork.send() | inputQueue → RemoteInput (key event) |
| `mouseDown` / `mouseUp` | 2 | EventTap.forward() → PeerNetwork.send() | inputQueue → RemoteInput.postMouse() |
| `enter` / `release` | 6 / 1 | EventTap.enterRemoteControl() | main queue → RemoteInput.enterFromLeftEdge() |

## Instrumentation Added

### Timestamps

Every outgoing event message (`mouseDelta`, `scroll`, `key`, `flags`) carries a `sentAt: UInt64` field set via `mach_absolute_time()` right before the message is constructed. This allows the receiver to compute best-effort one-way latency.

### Stages measured

| Metric | Where captured | What it measures |
|--------|---------------|-----------------|
| **Capture-to-send** | EventTap.sendPendingDelta() | Time from CGEventTap callback entry to message construction. Includes delta accumulation + throttle wait. |
| **Receive-to-apply** | PeerNetwork.dispatchMessage() | Time from TCP data arrival to `onMessage` invocation. Includes dispatch queue wait. |
| **Network one-way** | PeerNetwork.recordLatency() | `mach_absolute_time` difference between sender and receiver. **Best-effort**: includes clock drift between machines. Use for trend analysis, not absolute measurement. |

### Rolling statistics

`LatencyTracker` accumulates samples in per-metric buffers (capacity 2000 each). Every 5 seconds it computes and prints:

```
[Latency] | C→S: p50=120µs p90=350µs p99=800µs max=2.1ms n=450 | R→A: p50=85µs p90=200µs p99=500µs max=1.5ms n=450 | Net: p50=4.2ms p90=8.5ms p99=15.3ms max=45ms n=450
```

- **C→S** (Capture-to-Send): time spent in EventTap + throttle
- **R→A** (Receive-to-Apply): dispatch queue latency
- **Net**: estimated one-way network + processing time

### Control

- Logging is always-on when connected (intentional: you asked to measure)
- To disable: set `LatencyTracker.shared.logInterval = 0` or guard behind a DEBUG flag
- Timer runs on a `.utility` QoS queue — does not interfere with the hot path

## Optimizations Applied

### 1. Dedicated input queue (receive side)

**Before**: all received messages dispatched through `DispatchQueue.main.async`, competing with AppKit rendering, menu timers, status bar updates.

**After**: `mouseDelta`, `scroll`, `key`, `flags`, `mouseDown`, `mouseUp` dispatched to a dedicated `.userInteractive` serial queue (`inputQueue`). Only control messages (`release`, `returnControl`, `activate`, `enter`) remain on main queue.

**Expected impact**: reduces receive-to-apply p50 by 50-200µs by eliminating main queue contention. On a busy main thread, the improvement could be 1-5ms.

**Safety**: All CoreGraphics functions used (`CGWarpMouseCursorPosition`, `CGEventPost`, `CGEventSource`) are documented as thread-safe. `CGEventSource` is initialized eagerly in `RemoteInput.init()` to avoid lazy-init races.

### 2. Configurable throttle

Added `ThrottleRate` enum with options: `immediate`, `hz1000`, `hz500` (default), `hz250`. Set via `EventTap.throttleRate`. For quick testing:

```swift
eventTap.throttleRate = .immediate   // no throttling, every event sent
eventTap.throttleRate = .hz250       // 4ms throttle
```

### 3. Keyboard never blocked by mouse

`flushDelta()` is called before every keyboard/button event in `EventTap.forward()`. This ensures any accumulated mouse deltas are sent before the key event, preventing the key from being queued behind pending deltas.

On the receive side, keyboard events go through the same input queue as deltas but are serialized after all prior deltas. This is inherent to single-channel TCP — the true fix requires a separate control channel (considered but deferred per your instructions).

### 4. TCP_NODELAY (already present)

`NWProtocolTCP.Options.noDelay = true` — disables Nagle's algorithm. Confirmed present in `PeerNetwork.makeParameters()`.

## How to Run a Latency Test

1. Build and install both versions:
   ```
   ./build-app.sh native   # for ARM Mac
   ./build-app.sh intel    # for Intel Mac (cross-compile from ARM)
   ```

2. Start both apps, select roles (one controller, one receiver)

3. Connect (wait for green icon)

4. Move mouse on controller — it should appear on receiver's screen

5. Watch the console output for latency log lines:
   ```
   tail -f /var/log/system.log | grep '\[Latency\]'
   ```
   Or run from Terminal to see stdout directly.

6. To measure specific scenarios:
   - **Idle network**: just normal mouse movement
   - **Loaded network**: run `ping -f <other-ip>` or iPerf in background
   - **Busy main thread**: open a heavy web page or run a rendering app on the receiver

## Interpreting the Numbers

- **p50 (median)**: typical latency. Half of events are faster than this.
- **p90**: 90th percentile. 1 in 10 events is slower than this. Good indicator of jitter.
- **p99**: 99th percentile. 1 in 100 events is this slow or worse. Catches outliers.
- **max**: worst sample in the window. Useful but noisy — one GC pause or scheduler hiccup shows up here.

For a good local network (WiFi with <1ms RTT), expect:
- C→S: 50-200µs (throttle adds up to 2ms by design)
- R→A: 50-500µs (depends on queue contention)
- Net: 2-10ms (WiFi + TCP framing)

### Current bottlenecks (estimated):

| Stage | p50 (est) | Bottleneck |
|-------|-----------|------------|
| Capture → encode | 50-200µs | Throttle timer on main queue, Data allocation per message |
| TCP send | 10-50µs | Length-prefix + copy |
| Network transit | 1-5ms | WiFi airtime, TCP ACK pacing |
| TCP receive + decode | 10-50µs | Data copy, decode branching |
| Dispatch queue | 5-100µs | inputQueue: near-zero wait; main queue: 50-500µs |
| Input injection | 50-200µs | CGWarpMouseCursorPosition + CGEventPost |

**Biggest win available**: moving to UDP for delta messages would eliminate TCP head-of-line blocking entirely (a lost TCP packet stalls ALL subsequent messages until retransmitted).

## Recommended Next Optimizations

1. **UDP channel for mouse deltas** (medium risk, high reward)
   - Route `.mouseDelta` over a separate UDP connection
   - Keep `.key`, `.mouseDown`, `.mouseUp`, `.scroll` on TCP for reliability
   - This eliminates head-of-line blocking: lost delta packets skip ahead, next corrects position
   - Risk: out-of-order delivery on the receiver (delta before enter, etc.)

2. **Reduce allocations in encode hot path** (low risk, moderate reward)
   - Use a shared `Data` buffer with `withUnsafeMutableBytes` instead of appending byte by byte
   - Pre-allocate fixed-size buffers for mouseDelta (18 bytes), key (20 bytes)
   - Could reduce capture-to-send by 20-50µs

3. **Thread the throttle timer on EventTap's own queue** (low risk, small reward)
   - Currently uses `DispatchQueue.main.asyncAfter` which queues on main
   - EventTap could use its own run loop source or a dedicated timer dispatch source
   - Would reduce chance of throttle timer being delayed by main thread work

4. **Batch mouse events at receiver** (medium risk, moderate reward)
   - If multiple delta messages arrive in quick succession, apply the sum in one `CGWarpMouseCursorPosition` call
   - Reduces CGEvent post rate from 500/s to ~60/s (display refresh rate)
   - Risk: slight added latency per event, perceptible smoothing

5. **Sequence numbers on delta messages** (low risk, useful for debugging)
   - Receiver can detect packet loss and gaps
   - Helps quantify the WiFi packet loss rate
