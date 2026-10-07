import Foundation

/// Anything that repeatedly answers "is the other end there, and how fast".
protocol Probe: AnyObject {
    var onResult: ((Bool, TimeInterval?) -> Void)? { get set }
    var onFailure: ((String) -> Void)? { get set }
    func start()
    func stop()
    /// One line of internal counters for "Copy diagnostics" — empty if the probe
    /// has nothing interesting to say.
    var debugStats: String { get }
}
