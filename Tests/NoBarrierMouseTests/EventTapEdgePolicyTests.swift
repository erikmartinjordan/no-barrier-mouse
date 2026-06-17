import XCTest
@testable import NoBarrierMouse

final class EventTapEdgePolicyTests: XCTestCase {
    func testReclaimCooldownBlocksMouseReentryAtEdge() {
        let policy = EventTapEdgePolicy()
        let reclaimedAt = CFAbsoluteTimeGetCurrent()
        let now = reclaimedAt + 0.1
        let maxX = CGFloat(1440)
        let x = policy.entryThreshold(maxX: maxX) + 1

        XCTAssertFalse(policy.shouldEnterRemote(
            now: now,
            reclaimedAt: reclaimedAt,
            x: x,
            dx: 20,
            isMouseMovement: true,
            keyboardShortcut: false,
            maxX: maxX
        ))
    }

    func testRightEdgeMouseEntryRequiresPositiveDeltaAfterCooldown() {
        let policy = EventTapEdgePolicy()
        let reclaimedAt = CFAbsoluteTimeGetCurrent()
        let now = reclaimedAt + policy.reclaimAbsorbWindow + 0.01
        let maxX = CGFloat(1440)
        let x = policy.entryThreshold(maxX: maxX) + 1

        XCTAssertFalse(policy.shouldEnterRemote(
            now: now,
            reclaimedAt: reclaimedAt,
            x: x,
            dx: 0,
            isMouseMovement: true,
            keyboardShortcut: false,
            maxX: maxX
        ))
        XCTAssertFalse(policy.shouldEnterRemote(
            now: now,
            reclaimedAt: reclaimedAt,
            x: x,
            dx: -1,
            isMouseMovement: true,
            keyboardShortcut: false,
            maxX: maxX
        ))
        XCTAssertTrue(policy.shouldEnterRemote(
            now: now,
            reclaimedAt: reclaimedAt,
            x: x,
            dx: 1,
            isMouseMovement: true,
            keyboardShortcut: false,
            maxX: maxX
        ))
    }

    func testKeyboardShortcutEntryBypassesMouseCooldown() {
        let policy = EventTapEdgePolicy()
        let reclaimedAt = CFAbsoluteTimeGetCurrent()

        XCTAssertTrue(policy.shouldEnterRemote(
            now: reclaimedAt + 0.1,
            reclaimedAt: reclaimedAt,
            x: 100,
            dx: 0,
            isMouseMovement: false,
            keyboardShortcut: true,
            maxX: 1440
        ))
    }

    func testManualRegressionSequenceEdgeDecisions() {
        let policy = EventTapEdgePolicy()
        let maxX = CGFloat(1440)
        let x = policy.entryThreshold(maxX: maxX) + 1

        var reclaimedAt = CFAbsoluteTimeGetCurrent()
        XCTAssertFalse(policy.shouldEnterRemote(now: reclaimedAt + 0.01, reclaimedAt: reclaimedAt, x: x, dx: 0, isMouseMovement: true, keyboardShortcut: false, maxX: maxX))
        XCTAssertTrue(policy.shouldEnterRemote(now: reclaimedAt + policy.reclaimAbsorbWindow + 0.01, reclaimedAt: reclaimedAt, x: x, dx: 4, isMouseMovement: true, keyboardShortcut: false, maxX: maxX))

        // Simulated Cmd+C on receiver, reclaim, local Cmd+V, then second entry/reclaim.
        reclaimedAt = CFAbsoluteTimeGetCurrent() + 10
        XCTAssertFalse(policy.shouldEnterRemote(now: reclaimedAt + 0.01, reclaimedAt: reclaimedAt, x: x, dx: -2, isMouseMovement: true, keyboardShortcut: false, maxX: maxX))
        XCTAssertFalse(policy.shouldEnterRemote(now: reclaimedAt + policy.reclaimAbsorbWindow + 0.01, reclaimedAt: reclaimedAt, x: x, dx: 0, isMouseMovement: true, keyboardShortcut: false, maxX: maxX))
        XCTAssertTrue(policy.shouldEnterRemote(now: reclaimedAt + policy.reclaimAbsorbWindow + 0.01, reclaimedAt: reclaimedAt, x: x, dx: 2, isMouseMovement: true, keyboardShortcut: false, maxX: maxX))
    }
}
