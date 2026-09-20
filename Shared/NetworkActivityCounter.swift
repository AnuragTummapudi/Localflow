import Foundation
import Combine

/// Counts LocalFlow network requests during the current app session.
public final class NetworkActivityCounter: ObservableObject, @unchecked Sendable {
    /// The single shared network counter.
    public static let shared = NetworkActivityCounter()

    /// The number of network requests made in this app session.
    @Published public private(set) var requestCount: Int = 0

    /// Creates a network activity counter.
    public init() {}

    /// Records a network request.
    ///
    /// Always hops to the main queue so `@Published` updates are UI-safe when
    /// called from URLSession delegate / background download tasks.
    public func recordRequest() {
        if Thread.isMainThread {
            requestCount += 1
        } else {
            DispatchQueue.main.async { [weak self] in
                self?.requestCount += 1
            }
        }
    }

    /// Resets the counter, intended for tests.
    public func reset() {
        requestCount = 0
    }
}
