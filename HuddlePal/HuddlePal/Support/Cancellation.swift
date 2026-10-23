import Foundation

extension Error {
    /// The work was called off, not failed: the screen that started it went
    /// away (switching tabs mid-load cancels its `.task`), or a newer request
    /// replaced it. URLSession reports that as `URLError.cancelled`, whose
    /// description is just "cancelled", so it must never reach the screen.
    var isCancellation: Bool {
        if self is CancellationError { return true }
        if let urlError = self as? URLError { return urlError.code == .cancelled }
        let error = self as NSError
        return error.domain == NSURLErrorDomain && error.code == NSURLErrorCancelled
    }
}
