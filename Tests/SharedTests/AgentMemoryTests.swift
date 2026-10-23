import XCTest
@testable import Shared

@MainActor final class AgentMemoryTests: XCTestCase {
    private var directory: URL!
    override func setUp() {
        directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    }
    override func tearDown() { try? FileManager.default.removeItem(at: directory) }
    func testRoundTripInspectableLocalJSONAndExplicitReset() throws {
        let store = AgentMemoryStore(directory: directory)
        var value = AgentMemory()
        value.preferredApps = ["editor": "com.microsoft.VSCode"]
        value.applicationAliases = ["my code app": "Visual Studio Code"]
        value.folders = ["LocalFlow project": "/tmp/LocalFlow"]
        value.websites = ["placement portal": "https://example.com/placements"]
        value.workflows = ["start LocalFlow": ["open LocalFlow project", "open my terminal", "open http://localhost:3000"]]
        try store.save(value)
        XCTAssertEqual(AgentMemoryStore(directory: directory).memory, value)
        let bytes = try Data(contentsOf: store.fileURL)
        XCTAssertTrue(String(decoding: bytes, as: UTF8.self).contains("placement portal"))
        XCTAssertEqual((try FileManager.default.attributesOfItem(atPath: store.fileURL.path)[.posixPermissions] as? NSNumber)?.intValue, 0o600)
        store.record(AgentActivity(tool: "application.open", outcome: "completed", milliseconds: 10))
        try store.reset()
        XCTAssertEqual(store.memory, AgentMemory()); XCTAssertTrue(store.activity.isEmpty)
        XCTAssertEqual(AgentMemoryStore(directory: directory).memory, AgentMemory())
    }
    func testExternalEditsCannotBeSilentlyOverwritten() throws {
        let store = AgentMemoryStore(directory: directory)
        try store.save(AgentMemory())
        var edited = AgentMemory(); edited.preferredApps["browser"] = "Safari"
        try JSONEncoder().encode(edited).write(to: store.fileURL, options: .atomic)
        XCTAssertThrowsError(try store.save(AgentMemory()))
        store.reload(); XCTAssertEqual(store.memory, edited)
        try store.save(edited)
    }
    func testCorruptFilePreservedUntilExplicitReset() throws {
        let store = AgentMemoryStore(directory: directory); try store.save(AgentMemory())
        let corrupt = Data("not JSON".utf8); try corrupt.write(to: store.fileURL)
        store.reload(); XCTAssertNotNil(store.error)
        XCTAssertThrowsError(try store.save(AgentMemory()))
        XCTAssertEqual(try Data(contentsOf: store.fileURL), corrupt)
        try store.reset(); XCTAssertNil(store.error)
    }
    func testActivityIsBoundedAndNeverPersistsTranscriptSlots() throws {
        let store = AgentMemoryStore(directory: directory)
        for index in 0..<220 { store.record(AgentActivity(tool: "note.create", outcome: "completed", milliseconds: Double(index))) }
        XCTAssertEqual(store.activity.count, 200)
        XCTAssertEqual(AgentMemoryStore(directory: directory).activity.count, 200)
        let text = String(decoding: try Data(contentsOf: store.activityURL), as: UTF8.self)
        XCTAssertFalse(text.contains("transcript")); XCTAssertFalse(text.contains("arguments")); XCTAssertFalse(text.contains("body"))
        XCTAssertEqual(store.memory, AgentMemory(), "Activity must never learn commands")
    }
    func testRejectsAmbiguousAliasesAndUnsafeLocations() throws {
        var memory = AgentMemory(); memory.applicationAliases = [" Editor ": "VS Code"]; memory.websites = ["editor": "https://example.com"]
        XCTAssertThrowsError(try memory.validate())
        memory = AgentMemory(); memory.websites = ["portal": "javascript:alert(1)"]
        XCTAssertThrowsError(try memory.validate())
        memory.websites = ["portal": "https://user:secret@example.com"]
        XCTAssertThrowsError(try memory.validate())
        memory = AgentMemory(); memory.folders = ["project": "~/project"]
        XCTAssertThrowsError(try memory.validate())
    }
}
