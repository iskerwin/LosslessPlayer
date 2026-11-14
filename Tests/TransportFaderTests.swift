import XCTest
@testable import LosslessPlayer

final class TransportFaderTests: XCTestCase {
    func testEveryTransportActionWaitsForZeroBeforeRunning() {
        for operation in TransportFader.Operation.allCases {
            var fader = TransportFader()
            XCTAssertTrue(fader.request(operation, audible: true).isEmpty, "\(operation)")
            var gains: [Float] = [1]
            var actions: [TransportFader.Operation] = []
            for _ in 0..<10 {
                for event in fader.step() {
                    switch event {
                    case .gain(let value): gains.append(value)
                    case .perform(let action):
                        XCTAssertEqual(gains.last, 0, "\(operation) must run after the zero write")
                        XCTAssertEqual(fader.gain, 0)
                        actions.append(action)
                    }
                }
            }
            XCTAssertEqual(actions, [operation])
            let expected: [Float] = [1, 0.8, 0.6, 0.4, 0.2, 0, 0.2, 0.4, 0.6, 0.8, 1]
            XCTAssertEqual(gains.count, expected.count)
            for (actual, expectedGain) in zip(gains, expected) {
                XCTAssertEqual(actual, expectedGain, accuracy: 0.000001)
            }
            XCTAssertEqual(gains[5], 0)
            XCTAssertEqual(gains.last, 1)
            XCTAssertEqual(fader.gain, 1)
            XCTAssertFalse(fader.isActive)
            XCTAssertTrue(fader.step().isEmpty)
        }
    }

    func testEndpointsAndMonotonicRampsWithinFortyMilliseconds() {
        var fader = TransportFader()
        _ = fader.request(.seek, audible: true)
        var previous = fader.gain
        for _ in 0..<5 {
            _ = fader.step()
            XCTAssertLessThan(fader.gain, previous)
            previous = fader.gain
        }
        XCTAssertEqual(fader.gain, 0)
        for _ in 0..<5 {
            _ = fader.step()
            XCTAssertGreaterThan(fader.gain, previous)
            previous = fader.gain
        }
        XCTAssertEqual(fader.gain, 1)
        XCTAssertFalse(fader.isActive)
        XCTAssertEqual(10 * TransportFader.stepSeconds, 0.040)
        XCTAssertLessThan(2 * TransportFader.rampSeconds, 0.050)
    }

    func testResumeReversesPendingPauseFromCurrentGainWithoutExecutingPause() {
        var fader = TransportFader()
        _ = fader.request(.pause, audible: true)
        _ = fader.step()
        _ = fader.step()
        let turningGain = fader.gain
        fader.resumeRendering()
        XCTAssertEqual(fader.gain, turningGain)
        XCTAssertNil(fader.pending)
        var events: [TransportFader.Event] = []
        for _ in 0..<5 { events += fader.step() }
        XCTAssertFalse(fader.isActive)
        XCTAssertFalse(events.contains(.perform(.pause)))
        XCTAssertGreaterThan(events.compactMap { if case .gain(let value) = $0 { return value }; return nil }.first!, turningGain)
        XCTAssertEqual(fader.gain, 1)
    }

    func testNewOperationReversesFadeInAndReplacesUnfinishedAction() {
        var fader = TransportFader()
        XCTAssertEqual(fader.request(.play, audible: false), [.gain(0), .perform(.play)])
        _ = fader.step()
        _ = fader.step()
        let turningGain = fader.gain
        XCTAssertTrue(fader.request(.seek, audible: true).isEmpty)
        XCTAssertEqual(fader.gain, turningGain)
        _ = fader.step()
        XCTAssertLessThan(fader.gain, turningGain)
        let replacementGain = fader.gain
        XCTAssertTrue(fader.request(.load, audible: true).isEmpty)
        XCTAssertEqual(fader.gain, replacementGain)
        var actions: [TransportFader.Operation] = []
        for _ in 0..<10 {
            for event in fader.step() {
                if case .perform(let action) = event {
                    XCTAssertEqual(fader.gain, 0)
                    actions.append(action)
                }
            }
        }
        XCTAssertEqual(actions, [.load])
        XCTAssertEqual(fader.gain, 1)
        XCTAssertFalse(fader.isActive)
    }

    func testStoppedTransportRunsOnlyAfterExplicitZeroWrite() {
        for operation in TransportFader.Operation.allCases {
            var fader = TransportFader()
            XCTAssertEqual(fader.request(operation, audible: false), [.gain(0), .perform(operation)])
            for _ in 0..<5 { _ = fader.step() }
            XCTAssertEqual(fader.gain, 1)
            XCTAssertFalse(fader.isActive)
        }
    }

    func testInvalidateCancelsActionsAndSettlesBothDirections() {
        for steps in 0...9 {
            var fader = TransportFader()
            _ = fader.request(.stop, audible: true)
            for _ in 0..<steps { _ = fader.step() }
            XCTAssertEqual(fader.invalidate(), [.gain(1)])
            XCTAssertNil(fader.pending)
            XCTAssertFalse(fader.isActive)
            XCTAssertEqual(fader.gain, 1)
            XCTAssertTrue(fader.step().isEmpty)
            XCTAssertEqual(fader.request(.play, audible: false), [.gain(0), .perform(.play)])
            for _ in 0..<5 { _ = fader.step() }
            XCTAssertEqual(fader.gain, 1)
        }
    }
}
