import XCTest
@testable import LosslessPlayer

final class TransportFaderTests: XCTestCase {
    private func gains(_ events: [TransportFader.Event]) -> [Float] {
        events.compactMap { if case .gain(let value) = $0 { return value }; return nil }
    }

    private func holdTicks(_ operation: TransportFader.Operation) -> Int {
        switch operation {
        case .load, .stop: return 60
        default: return 20
        }
    }

    func testEveryTransportActionWaitsForZeroBeforeRunning() {
        for operation in TransportFader.Operation.allCases {
            var fader = TransportFader()
            XCTAssertTrue(fader.request(operation, audible: true).isEmpty, "\(operation)")
            var values: [Float] = [1]
            var actions: [TransportFader.Operation] = []
            for _ in 0..<(75 + holdTicks(operation)) {
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
            for _ in 0..<105 { values += gains(fader.step()) }
            XCTAssertEqual(values.count, 176)
            XCTAssertEqual(values[75], 0)
            XCTAssertEqual(values.last, 1)
            XCTAssertEqual(fader.gain, 1)
            XCTAssertFalse(fader.isActive)
            XCTAssertTrue(fader.step().isEmpty)
        }
    }

    // Regression: round 1 performed at zero immediately; round 2 performed
    // after only 30 + 25 ms. Neither satisfies the full drain window below.
    func testPerformWaitsForEntireFadeAndSilentHoldForEveryOperation() {
        for operation in TransportFader.Operation.allCases {
            var fader = TransportFader()
            _ = fader.request(operation, audible: true)
            for tick in 1..<(75 + holdTicks(operation)) {
                XCTAssertFalse(fader.step().contains(.perform(operation)), "premature \(operation) at \(tick * 2) ms")
                if tick == 75 {
                    XCTAssertEqual(fader.gain, 0)
                    XCTAssertEqual(fader.phase, .holdSilent)
                }
                if tick >= 75 { XCTAssertEqual(fader.gain, 0) }
            }
            XCTAssertEqual(fader.step(), [.perform(operation)])
            XCTAssertEqual(fader.phase, .performing)
            XCTAssertEqual(fader.gain, 0)
        }
    }

    func testEndpointsAndMonotonicRaisedCosineAcrossMultipleRenderQuanta() {
        XCTAssertEqual(TransportFader.stepSeconds, 0.002)
        XCTAssertEqual(TransportFader.fadeOutSeconds, 0.150)
        XCTAssertEqual(TransportFader.fadeInSeconds, 0.200)
        XCTAssertEqual(TransportFader.Silence.renderStop.seconds, 0.040)
        XCTAssertEqual(TransportFader.Silence.reconfiguration.seconds, 0.120)
        XCTAssertEqual(TransportFader.zeroSeconds, 0.010)
        var fader = TransportFader()
        _ = fader.request(.seek, audible: true)
        var previous: Float = 1
        for tick in 1...75 {
            let events = fader.step()
            XCTAssertEqual(gains(events), [fader.gain])
            XCTAssertLessThan(fader.gain, previous)
            XCTAssertEqual(fader.gain, Float((1 + cos(.pi * Double(tick) / 75)) / 2), accuracy: 0.000001)
            previous = fader.gain
        }
        XCTAssertEqual(fader.gain, 0)
        for _ in 0..<20 { _ = fader.step() }
        fader.performed()
        for _ in 0..<5 { XCTAssertTrue(fader.step().isEmpty) }
        for tick in 1...100 {
            _ = fader.step()
            XCTAssertGreaterThan(fader.gain, previous)
            XCTAssertEqual(fader.gain, Float((1 - cos(.pi * Double(tick) / 100)) / 2), accuracy: 0.000001)
            previous = fader.gain
        }
        XCTAssertEqual(fader.gain, 1)
        XCTAssertFalse(fader.isActive)
    }

    func testExplicitHoldPolicyControlsSameFormatAndReconfigurationLoads() {
        for (silence, ticks) in [(TransportFader.Silence.renderStop, 20), (.reconfiguration, 60)] {
            var fader = TransportFader()
            _ = fader.request(.load, audible: true, silence: silence)
            for _ in 0..<75 { XCTAssertFalse(fader.step().contains(.perform(.load))) }
            XCTAssertEqual(fader.gain, 0)
            for _ in 0..<(ticks - 1) { XCTAssertTrue(fader.step().isEmpty) }
            XCTAssertEqual(fader.step(), [.perform(.load)])
        }
    }

    func testReplacementAtUndrainedZeroRequiresReconfigurationHold() {
        var fader = TransportFader()
        _ = fader.request(.pause, audible: true)
        for _ in 0..<85 { _ = fader.step() }
        _ = fader.request(.load, audible: true, silence: .reconfiguration)
        for _ in 0..<59 { XCTAssertTrue(fader.step().isEmpty) }
        XCTAssertEqual(fader.step(), [.perform(.load)])
    }

    func testZeroHoldStartsAfterPerformAcknowledgementAndRenderRestart() {
        var fader = TransportFader()
        _ = fader.request(.seek, audible: true)
        for _ in 0..<95 { _ = fader.step() }
        XCTAssertTrue(fader.step(elapsedSeconds: 1).isEmpty)
        XCTAssertEqual(fader.phase, .performing)
        XCTAssertEqual(fader.gain, 0)
        fader.performed()
        XCTAssertEqual(fader.phase, .holdZero)
        for _ in 0..<5 {
            XCTAssertTrue(fader.step().isEmpty)
            XCTAssertEqual(fader.gain, 0)
        }
        XCTAssertEqual(fader.phase, .rising)
        XCTAssertGreaterThan(gains(fader.step()).first!, 0)
    }

    func testLateWakeDoesNotConsumeHoldBeforeActualZeroWrite() {
        var fader = TransportFader()
        _ = fader.request(.stop, audible: true)
        XCTAssertEqual(fader.step(elapsedSeconds: 0.300), [.gain(0)])
        XCTAssertEqual(fader.phase, .holdSilent)
        XCTAssertTrue(fader.step(elapsedSeconds: 0.119).isEmpty)
        XCTAssertEqual(fader.step(elapsedSeconds: 0.001), [.perform(.stop)])
    }

    func testResumeReversesPendingPauseFromCurrentGainWithoutExecutingPause() {
        for turningTick in 1...74 {
            var fader = TransportFader()
            _ = fader.request(.pause, audible: true)
            for _ in 0..<turningTick { _ = fader.step() }
            let turningGain = fader.gain
            fader.resumeRendering()
            XCTAssertEqual(fader.gain, turningGain)
            XCTAssertNil(fader.pending)
            var previous = turningGain
            for _ in 0..<100 {
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
        for _ in 0..<17 { _ = fader.step() }
        let turningGain = fader.gain
        XCTAssertTrue(fader.request(.seek, audible: true).isEmpty)
        XCTAssertEqual(fader.gain, turningGain)
        _ = fader.step()
        XCTAssertLessThan(fader.gain, turningGain)
        let replacementGain = fader.gain
        XCTAssertTrue(fader.request(.load, audible: true).isEmpty)
        XCTAssertEqual(fader.gain, replacementGain)
        var actions: [TransportFader.Operation] = []
        for _ in 0..<135 {
            for event in fader.step() {
                if case .perform(let action) = event {
                    XCTAssertEqual(fader.gain, 0)
                    actions.append(action)
                }
            }
        }
        XCTAssertEqual(actions, [.load])
        fader.performed()
        for _ in 0..<105 { _ = fader.step() }
        XCTAssertEqual(fader.gain, 1)
        XCTAssertFalse(fader.isActive)
    }

    func testStoppedTransportRunsOnlyAfterExplicitZeroWrite() {
        for operation in TransportFader.Operation.allCases {
            var fader = TransportFader()
            XCTAssertEqual(fader.request(operation, audible: false), [.gain(0), .perform(operation)])
            fader.performed()
            for _ in 0..<5 { XCTAssertTrue(fader.step().isEmpty) }
            XCTAssertEqual(fader.gain, 0)
            for _ in 0..<100 { _ = fader.step() }
            XCTAssertEqual(fader.gain, 1)
            XCTAssertFalse(fader.isActive)
        }
    }

    func testConsecutiveStoppedLoadsDoNotBecomeAsynchronousDuringRecovery() {
        // PlayerStore.pause -> prepareForLoad -> load can all run while the
        // node is stopped, including during a preceding hold-zero or fade-in.
        for recoveryTicks in 0...105 {
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

    func testStartedButStillZeroTransportReusesPreparedSilence() {
        var fader = TransportFader()
        _ = fader.request(.load, audible: false)
        fader.performed()
        XCTAssertEqual(fader.request(.play, audible: false), [.gain(0), .perform(.play)])
        fader.performed()
        // The node is now playing, but no positive gain has been written.
        XCTAssertEqual(fader.request(.load, audible: true), [.gain(0), .perform(.load)])
        fader.performed()
        for _ in 0..<6 { _ = fader.step() }
        XCTAssertGreaterThan(fader.gain, 0)
        XCTAssertTrue(fader.request(.pause, audible: true).isEmpty)
        for _ in 0..<94 { XCTAssertFalse(fader.step().contains(.perform(.pause))) }
        XCTAssertEqual(fader.step(), [.perform(.pause)])
    }

    func testResumeAtUndrainedZeroDoesNotMakeNextOperationSkipSilentHold() {
        var fader = TransportFader()
        _ = fader.request(.pause, audible: true)
        for _ in 0..<75 { _ = fader.step() }
        fader.resumeRendering()
        XCTAssertEqual(fader.gain, 0)
        XCTAssertTrue(fader.request(.stop, audible: true).isEmpty)
        for _ in 0..<59 { XCTAssertTrue(fader.step().isEmpty) }
        XCTAssertEqual(fader.step(), [.perform(.stop)])
    }

    func testNestedLoadAndPlayReuseSilentPerformWindow() {
        var fader = TransportFader()
        _ = fader.request(.load, audible: true)
        for _ in 0..<135 { _ = fader.step() }
        XCTAssertEqual(fader.request(.load, audible: false), [.gain(0), .perform(.load)])
        XCTAssertEqual(fader.request(.play, audible: false), [.gain(0), .perform(.play)])
        XCTAssertEqual(fader.phase, .performing)
        fader.performed()
        XCTAssertEqual(fader.phase, .holdZero)
    }

    func testResumeDuringSilentHoldCancelsPauseAndKeepsRestartHold() {
        var fader = TransportFader()
        _ = fader.request(.pause, audible: true)
        for _ in 0..<80 { _ = fader.step() }
        fader.resumeRendering()
        XCTAssertEqual(fader.gain, 0)
        XCTAssertNil(fader.pending)
        for _ in 0..<5 { XCTAssertTrue(fader.step().isEmpty) }
        for _ in 0..<100 { XCTAssertFalse(fader.step().contains(.perform(.pause))) }
        XCTAssertEqual(fader.gain, 1)
    }

    func testInvalidateCancelsActionsAndSettlesBothDirections() {
        for steps in 0...240 {
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
            for _ in 0..<105 { _ = fader.step() }
            XCTAssertEqual(fader.gain, 1)
        }
    }
}
