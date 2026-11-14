import XCTest
@testable import LosslessPlayer

final class TransportFaderTests: XCTestCase {
    private func gains(_ events: [TransportFader.Event]) -> [Float] {
        events.compactMap { if case .gain(let value) = $0 { return value }; return nil }
    }

    func testEveryTransportActionWaitsForZeroBeforeRunning() {
        for operation in TransportFader.Operation.allCases {
            var fader = TransportFader()
            XCTAssertTrue(fader.request(operation, audible: true).isEmpty, "\(operation)")
            var values: [Float] = [1]
            var actions: [TransportFader.Operation] = []
            for _ in 0..<55 {
                for event in fader.step() {
                    switch event {
                    case .gain(let value): values.append(value)
                    case .perform(let action):
                        XCTAssertEqual(values.last, 0, "\(operation) must run after the zero write")
                        XCTAssertEqual(fader.gain, 0)
                        actions.append(action)
                    }
                }
            }
            XCTAssertEqual(actions, [operation])
            XCTAssertEqual(fader.phase, .performing)
            fader.performed()
            for _ in 0..<40 { values += gains(fader.step()) }
            XCTAssertEqual(values.count, 61)
            XCTAssertEqual(values[30], 0)
            XCTAssertEqual(values.last, 1)
            XCTAssertEqual(fader.gain, 1)
            XCTAssertFalse(fader.isActive)
            XCTAssertTrue(fader.step().isEmpty)
        }
    }

    // Regression: the original five-step implementation emits perform on the
    // same step as gain(0), before any silent render time has elapsed.
    func testPerformWaitsForEntireFadeAndSilentHoldForEveryOperation() {
        for operation in TransportFader.Operation.allCases {
            var fader = TransportFader()
            _ = fader.request(operation, audible: true)
            for tick in 1...54 {
                XCTAssertFalse(fader.step().contains(.perform(operation)), "premature \(operation) at \(tick) ms")
                if tick == 30 {
                    XCTAssertEqual(fader.gain, 0)
                    XCTAssertEqual(fader.phase, .holdSilent)
                }
                if tick >= 30 { XCTAssertEqual(fader.gain, 0) }
            }
            XCTAssertEqual(fader.step(), [.perform(operation)])
            XCTAssertEqual(fader.phase, .performing)
            XCTAssertEqual(fader.gain, 0)
        }
    }

    func testEndpointsAndMonotonicRaisedCosineRampsWithinThirtyMilliseconds() {
        XCTAssertLessThanOrEqual(TransportFader.stepSeconds, 0.001)
        XCTAssertEqual(TransportFader.rampSeconds, 0.030)
        XCTAssertEqual(TransportFader.silentSeconds, 0.025)
        XCTAssertEqual(TransportFader.zeroSeconds, 0.010)
        var fader = TransportFader()
        _ = fader.request(.seek, audible: true)
        var previous: Float = 1
        for tick in 1...30 {
            let events = fader.step()
            XCTAssertEqual(gains(events), [fader.gain])
            XCTAssertLessThan(fader.gain, previous)
            XCTAssertEqual(fader.gain, Float((1 + cos(.pi * Double(tick) / 30)) / 2), accuracy: 0.000001)
            previous = fader.gain
        }
        XCTAssertEqual(fader.gain, 0)
        for _ in 0..<25 { _ = fader.step() }
        fader.performed()
        for _ in 0..<10 { XCTAssertTrue(fader.step().isEmpty) }
        for tick in 1...30 {
            _ = fader.step()
            XCTAssertGreaterThan(fader.gain, previous)
            XCTAssertEqual(fader.gain, Float((1 - cos(.pi * Double(tick) / 30)) / 2), accuracy: 0.000001)
            previous = fader.gain
        }
        XCTAssertEqual(fader.gain, 1)
        XCTAssertFalse(fader.isActive)
    }

    func testZeroHoldStartsAfterPerformAcknowledgementAndRenderRestart() {
        var fader = TransportFader()
        _ = fader.request(.seek, audible: true)
        for _ in 0..<55 { _ = fader.step() }
        XCTAssertTrue(fader.step(elapsedSeconds: 1).isEmpty)
        XCTAssertEqual(fader.phase, .performing)
        XCTAssertEqual(fader.gain, 0)
        fader.performed()
        XCTAssertEqual(fader.phase, .holdZero)
        for _ in 0..<10 {
            XCTAssertTrue(fader.step().isEmpty)
            XCTAssertEqual(fader.gain, 0)
        }
        XCTAssertEqual(fader.phase, .rising)
        XCTAssertGreaterThan(gains(fader.step()).first!, 0)
    }

    func testLateWakeDoesNotConsumeHoldBeforeActualZeroWrite() {
        var fader = TransportFader()
        _ = fader.request(.stop, audible: true)
        XCTAssertEqual(fader.step(elapsedSeconds: 0.060), [.gain(0)])
        XCTAssertEqual(fader.phase, .holdSilent)
        XCTAssertTrue(fader.step(elapsedSeconds: 0.024).isEmpty)
        XCTAssertEqual(fader.step(elapsedSeconds: 0.001), [.perform(.stop)])
    }

    func testResumeReversesPendingPauseFromCurrentGainWithoutExecutingPause() {
        for turningTick in 1...29 {
            var fader = TransportFader()
            _ = fader.request(.pause, audible: true)
            for _ in 0..<turningTick { _ = fader.step() }
            let turningGain = fader.gain
            fader.resumeRendering()
            XCTAssertEqual(fader.gain, turningGain)
            XCTAssertNil(fader.pending)
            var previous = turningGain
            for _ in 0..<30 {
                let events = fader.step()
                XCTAssertFalse(events.contains(.perform(.pause)))
                XCTAssertGreaterThan(fader.gain, previous)
                previous = fader.gain
            }
            XCTAssertEqual(fader.gain, 1)
            XCTAssertFalse(fader.isActive)
        }
    }

    func testNewOperationReversesFadeInAndReplacesUnfinishedAction() {
        var fader = TransportFader()
        XCTAssertEqual(fader.request(.play, audible: false), [.gain(0), .perform(.play)])
        fader.performed()
        for _ in 0..<22 { _ = fader.step() }
        let turningGain = fader.gain
        XCTAssertTrue(fader.request(.seek, audible: true).isEmpty)
        XCTAssertEqual(fader.gain, turningGain)
        _ = fader.step()
        XCTAssertLessThan(fader.gain, turningGain)
        let replacementGain = fader.gain
        XCTAssertTrue(fader.request(.load, audible: true).isEmpty)
        XCTAssertEqual(fader.gain, replacementGain)
        var actions: [TransportFader.Operation] = []
        for _ in 0..<55 {
            for event in fader.step() {
                if case .perform(let action) = event {
                    XCTAssertEqual(fader.gain, 0)
                    actions.append(action)
                }
            }
        }
        XCTAssertEqual(actions, [.load])
        fader.performed()
        for _ in 0..<40 { _ = fader.step() }
        XCTAssertEqual(fader.gain, 1)
        XCTAssertFalse(fader.isActive)
    }

    func testStoppedTransportRunsOnlyAfterExplicitZeroWrite() {
        for operation in TransportFader.Operation.allCases {
            var fader = TransportFader()
            XCTAssertEqual(fader.request(operation, audible: false), [.gain(0), .perform(operation)])
            fader.performed()
            for _ in 0..<10 { XCTAssertTrue(fader.step().isEmpty) }
            XCTAssertEqual(fader.gain, 0)
            for _ in 0..<30 { _ = fader.step() }
            XCTAssertEqual(fader.gain, 1)
            XCTAssertFalse(fader.isActive)
        }
    }

    func testConsecutiveStoppedLoadsDoNotBecomeAsynchronousDuringRecovery() {
        // PlayerStore.pause -> prepareForLoad -> load can all run while the
        // node is stopped, including during a preceding hold-zero or fade-in.
        for recoveryTicks in 0...40 {
            var fader = TransportFader()
            _ = fader.request(.pause, audible: false)
            fader.performed()
            for _ in 0..<recoveryTicks { _ = fader.step() }
            for operation in [TransportFader.Operation.load, .load, .play] {
                XCTAssertEqual(fader.request(operation, audible: false), [.gain(0), .perform(operation)])
                fader.performed()
            }
            XCTAssertEqual(fader.gain, 0)
            XCTAssertEqual(fader.phase, .holdZero)
        }
    }

    func testNestedLoadAndPlayReuseSilentPerformWindow() {
        var fader = TransportFader()
        _ = fader.request(.load, audible: true)
        for _ in 0..<55 { _ = fader.step() }
        XCTAssertEqual(fader.request(.load, audible: false), [.gain(0), .perform(.load)])
        XCTAssertEqual(fader.request(.play, audible: false), [.gain(0), .perform(.play)])
        XCTAssertEqual(fader.phase, .performing)
        fader.performed()
        XCTAssertEqual(fader.phase, .holdZero)
    }

    func testResumeDuringSilentHoldCancelsPauseAndKeepsRestartHold() {
        var fader = TransportFader()
        _ = fader.request(.pause, audible: true)
        for _ in 0..<40 { _ = fader.step() }
        fader.resumeRendering()
        XCTAssertEqual(fader.gain, 0)
        XCTAssertNil(fader.pending)
        for _ in 0..<10 { XCTAssertTrue(fader.step().isEmpty) }
        for _ in 0..<30 { XCTAssertFalse(fader.step().contains(.perform(.pause))) }
        XCTAssertEqual(fader.gain, 1)
    }

    func testInvalidateCancelsActionsAndSettlesBothDirections() {
        for steps in 0...95 {
            var fader = TransportFader()
            _ = fader.request(.stop, audible: true)
            for _ in 0..<steps {
                let events = fader.step()
                if events.contains(.perform(.stop)) { fader.performed() }
            }
            XCTAssertEqual(fader.invalidate(), [.gain(1)])
            XCTAssertNil(fader.pending)
            XCTAssertFalse(fader.isActive)
            XCTAssertEqual(fader.gain, 1)
            XCTAssertTrue(fader.step().isEmpty)
            XCTAssertEqual(fader.request(.play, audible: false), [.gain(0), .perform(.play)])
            fader.performed()
            for _ in 0..<40 { _ = fader.step() }
            XCTAssertEqual(fader.gain, 1)
        }
    }
}
