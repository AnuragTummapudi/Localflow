import XCTest
import Shared

/// Keep feature tests independent of the user's saved preferences and vocabulary.
class LocalSettingsTestCase: XCTestCase {
    private var suiteName: String!
    private var defaults: UserDefaults!
    var settings: LocalFlowSettings!

    override func setUp() {
        super.setUp()
        suiteName = "LocalFlowTests.\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: suiteName)!
        settings = LocalFlowSettings(defaults: defaults)
    }

    override func tearDown() {
        defaults.removePersistentDomain(forName: suiteName)
        settings = nil
        defaults = nil
        suiteName = nil
        super.tearDown()
    }
}
