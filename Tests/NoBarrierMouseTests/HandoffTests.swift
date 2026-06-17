import CoreGraphics
import XCTest
@testable import NoBarrierMouse

final class HandoffTests: XCTestCase {
    func testCarryCalculationPreservesLeftoverDelta() {
        let handoff = RemoteInput.leftEdgeHandoff(
            start: CGPoint(x: 3, y: 100),
            dx: -12,
            dy: 6,
            boundaryX: 1
        )

        XCTAssertEqual(handoff.carryDx, -10, accuracy: 0.0001)
        XCTAssertEqual(handoff.yAtBoundary, 101, accuracy: 0.0001)
        XCTAssertEqual(handoff.carryDy, 5, accuracy: 0.0001)
    }

    func testProtocolReturnControlRoundTrip() {
        let codec = WireCodec()
        let message = WireMessage.returnControl(y: 42.5, carryDx: -10.25, carryDy: 3.75, handoffID: 99)
        XCTAssertEqual(codec.decode(from: codec.encode(message)), message)
    }

    func testProtocolReturnControlDeltaRoundTrip() {
        let codec = WireCodec()
        let message = WireMessage.returnControlDelta(handoffID: 99, dx: -2.5, dy: 1.25)
        XCTAssertEqual(codec.decode(from: codec.encode(message)), message)
    }

    func testProtocolReturnControlAckRoundTrip() {
        let codec = WireCodec()
        let message = WireMessage.returnControlAck(handoffID: 99)
        XCTAssertEqual(codec.decode(from: codec.encode(message)), message)
    }

    func testLocalCooldownPolicyPassesLocalMouseMovementDecision() {
        let policy = EventTapEdgePolicy()
        let decision = policy.localDecision(
            now: 10.05,
            reclaimedAt: 10.0,
            x: 1438,
            isMouseMovement: true,
            keyboardShortcut: false,
            maxX: 1440
        )

        XCTAssertEqual(decision, .passLocal)
    }

    func testRemoteEntryWorksAfterCooldownExpires() {
        let policy = EventTapEdgePolicy()
        XCTAssertTrue(policy.shouldEnterRemote(
            now: 11.0,
            reclaimedAt: 10.0,
            x: 1438,
            isMouseMovement: true,
            keyboardShortcut: false,
            maxX: 1440
        ))
    }

    func testNormalReturnAnchorsAtSeam() {
        let policy = EventTapEdgePolicy()
        XCTAssertGreaterThanOrEqual(policy.reclaimWarpX(maxX: 1440), 1438)
    }
}
