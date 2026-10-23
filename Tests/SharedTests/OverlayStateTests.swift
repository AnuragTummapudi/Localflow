import XCTest
import Shared

final class OverlayStateTests: XCTestCase {
    func testHiddenStateHasNoControlsOrTranscript() {
        let state = OverlayState()
        XCTAssertEqual(state.phase, .hidden)
        XCTAssertNil(state.transcript)
        XCTAssertFalse(state.showsStop || state.showsCancel || state.showsConfirm || state.showsUndo)
    }

    func testLiveRevisionsReplaceAndDuplicatesAreIgnored() {
        var state = OverlayState()
        state.listen(mode: .pushToTalk)
        XCTAssertTrue(state.showsStop)
        XCTAssertFalse(state.showsCancel)
        XCTAssertTrue(state.update(PartialTranscript(text: "open Not")))
        XCTAssertTrue(state.update(PartialTranscript(text: "open Notes")))
        XCTAssertEqual(state.transcript?.text, "open Notes")
        XCTAssertFalse(state.update(PartialTranscript(text: "open Notes")))
    }

    func testHandsFreePromotionPreservesTranscriptAndAddsCancel() {
        var state = OverlayState()
        state.listen(mode: .pushToTalk)
        state.update(PartialTranscript(text: "keep recording"))
        state.listen(mode: .handsFree)
        XCTAssertEqual(state.phase, .handsFree)
        XCTAssertEqual(state.transcript?.text, "keep recording")
        XCTAssertTrue(state.showsStop && state.showsCancel)
    }

    func testFinalizationAndAllStatusStatesRejectLatePartials() {
        for phase in [OverlayPhase.thinking, .acting, .success, .confirmation, .error, .cancelled] {
            var state = OverlayState()
            state.listen(mode: .handsFree)
            state.update(PartialTranscript(text: "unfinished"))
            state.present(phase, message: OverlayMessage(title: "Notes", detail: "Opening…"))
            XCTAssertNil(state.transcript)
            XCTAssertFalse(state.update(PartialTranscript(text: "late revision")))
            XCTAssertEqual(state.message.title, "Notes")
            XCTAssertFalse(state.showsStop)
        }
    }

    func testConfirmationHasTwoExplicitControls() {
        var state = OverlayState()
        state.present(.confirmation, message: OverlayMessage(title: "Notes", detail: "Quit Notes?"))
        XCTAssertTrue(state.showsCancel && state.showsConfirm)
        XCTAssertFalse(state.showsStop || state.showsUndo)
    }

    func testUndoIsLimitedToSupportedTerminalStates() {
        var state = OverlayState()
        state.present(.cancelled, message: OverlayMessage(title: "Cancelled"), allowsUndo: true)
        XCTAssertTrue(state.showsUndo)
        state.present(.cancelled, message: OverlayMessage(title: "Cancelled"), allowsUndo: false)
        XCTAssertFalse(state.showsUndo)
        state.present(.success, message: OverlayMessage(title: "Copied"), allowsUndo: true)
        XCTAssertTrue(state.showsUndo)
        state.present(.success, message: OverlayMessage(title: "Sent"), allowsUndo: false)
        XCTAssertFalse(state.showsUndo)
        state.present(.acting, message: OverlayMessage(title: "Running"), allowsUndo: true)
        XCTAssertFalse(state.showsUndo)
    }

    func testHideAndNewRecordingClearStaleConfirmationAndUndo() {
        var state = OverlayState()
        state.present(.confirmation, message: OverlayMessage(title: "Old command"))
        state.hide()
        XCTAssertEqual(state, OverlayState())
        state.present(.cancelled, message: OverlayMessage(title: "Cancelled"), allowsUndo: true)
        state.listen(mode: .pushToTalk)
        XCTAssertFalse(state.showsUndo || state.showsConfirm)
        XCTAssertNil(state.transcript)
        XCTAssertEqual(state.message.title, "Listening…")
    }

    func testAgentKeepsTranscriptAndControlsDuringNativeExecution() {
        var state = OverlayState()
        let text = PartialTranscript(text: "Open Notes and create a note")
        let action = OverlayMessage(title: "Notes", detail: "Opening…", symbol: "app")
        state.agent(transcript: text, message: action, recording: true, phase: .acting)
        XCTAssertEqual(state.transcript, text)
        XCTAssertEqual(state.agentMessage, action)
        XCTAssertTrue(state.showsStop && state.showsCancel)
        XCTAssertFalse(state.showsConfirm || state.showsUndo)
        state.agent(transcript: text, message: action, recording: false, phase: .confirmation)
        XCTAssertTrue(state.showsConfirm && state.showsCancel)
        XCTAssertFalse(state.showsStop)
        state.hide()
        XCTAssertEqual(state, OverlayState())
    }

    func testWidthExpandsInStepsAndRespectsBothCaps() {
        let small = OverlayLayout.width(textWidth: 40, phase: .listening, screenWidth: 1512)
        let large = OverlayLayout.width(textWidth: 300, phase: .listening, screenWidth: 1512)
        XCTAssertGreaterThan(large, small)
        XCTAssertEqual(large.truncatingRemainder(dividingBy: 16), 0)
        XCTAssertEqual(OverlayLayout.width(textWidth: 100_000, phase: .listening, screenWidth: 1512), 560)
        XCTAssertEqual(OverlayLayout.width(textWidth: 100_000, phase: .handsFree, screenWidth: 320), 272)
        XCTAssertEqual(OverlayLayout.width(textWidth: 20, phase: .confirmation, screenWidth: 1512), 360)
    }

    func testNotchUsesAuxiliaryGapInGlobalCoordinates() {
        let screen = CGRect(x: 1800, y: -300, width: 1512, height: 982)
        let left = CGRect(x: 1800, y: 644, width: 640, height: 38)
        let right = CGRect(x: 2660, y: 644, width: 652, height: 38)
        XCTAssertEqual(OverlayLayout.notchCenter(frame: screen, safeTop: 38, left: left, right: right), 2550)
        let panel = OverlayLayout.panelFrame(size: CGSize(width: 400, height: 72), screenFrame: screen,
            visibleFrame: screen.insetBy(dx: 0, dy: 38), safeTop: 38, left: left, right: right)
        XCTAssertEqual(panel.midX, 2550)
        XCTAssertEqual(panel.maxY, screen.maxY - 38 - 4)
        XCTAssertTrue(screen.contains(panel))
    }

    func testMissingOrInvalidNotchFallsBackToCenteredIsland() {
        let screen = CGRect(x: -1920, y: 200, width: 1920, height: 1080)
        let visible = CGRect(x: -1920, y: 200, width: 1920, height: 1055)
        for areas in [(CGRect?.none, CGRect?.none), (.some(.zero), .some(.zero)),
                      (.some(screen), .some(screen))] {
            XCTAssertNil(OverlayLayout.notchCenter(frame: screen, safeTop: 38, left: areas.0, right: areas.1))
            let panel = OverlayLayout.panelFrame(size: CGSize(width: 400, height: 72), screenFrame: screen,
                visibleFrame: visible, safeTop: 0, left: areas.0, right: areas.1)
            XCTAssertEqual(panel.midX, screen.midX)
            XCTAssertEqual(panel.maxY, visible.maxY - 4)
            XCTAssertTrue(screen.contains(panel))
        }
    }

    func testOversizedPanelStaysOnSmallDisplay() {
        let screen = CGRect(x: -100, y: -200, width: 320, height: 240)
        let panel = OverlayLayout.panelFrame(size: CGSize(width: 900, height: 400), screenFrame: screen,
            visibleFrame: screen, safeTop: 0)
        XCTAssertTrue(screen.contains(panel))
        XCTAssertEqual(panel.width, 304)
    }
}
