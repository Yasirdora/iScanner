import Foundation

/// Runs a Vision request again when it fails for a reason that passes.
///
/// On a busy machine Vision's model runtime sometimes fails a request with
/// `e5rt_stream_completion_handler call failed`. A test that failed this way
/// three times in one full test run on a loaded Mac passed alone and in quiet
/// runs.
///
/// Only that error is retried, at most twice, after a short pause. Every other
/// error is thrown at once, as before. That includes the runtime's other
/// failure under load, `…create_precompiled_compute_operation… call failed`:
/// it took about 15 seconds each time and failed again on every retry, so a
/// retry would only make the caller wait longer for the same error.
package enum VisionRetry {
    /// The pause before each retry. Two retries, so a request runs at most
    /// three times and waits at most half a second longer than it did.
    package static let pauses: [Duration] = [.milliseconds(100), .milliseconds(400)]

    /// Whether `error` is the runtime's passing stream failure.
    ///
    /// The error's type is private to Apple, so it cannot be matched by type;
    /// its message is the only handle. If a later system words it
    /// differently, the error is thrown at once again, as before this retry.
    package static func isTransient(_ error: any Error) -> Bool {
        String(reflecting: error).contains("e5rt_stream_completion_handler call failed")
    }

    /// Runs `request`, and runs it again after each pause while it fails with
    /// the passing error. The last failure is thrown.
    package static func run<T>(
        pauses: [Duration] = pauses,
        _ request: () async throws -> T
    ) async throws -> T {
        for pause in pauses {
            do {
                return try await request()
            } catch let failure where isTransient(failure) {
                try await Task.sleep(for: pause)
            }
        }
        return try await request()
    }
}
