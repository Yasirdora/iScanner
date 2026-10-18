import Testing
import Foundation
import Vision
import ScanCore

// None of these tests runs Vision. Each one hands the retry a request that
// fails as told, and counts how often it is asked.

/// The shape of the errors Vision's model runtime throws on a busy machine:
/// an enum case with the runtime's message and a code, and no text of its
/// own. The real type is private to Apple, so a test cannot make one.
private enum ModelRuntimeError: Error {
    case e5rtError(String, UInt32)

    /// Seen three times in one full `swift test` on a loaded Mac; the same
    /// test passed alone and in quiet runs.
    static let streamFailed = e5rtError("e5rt_stream_completion_handler call failed", 10)
    /// Seen on the same Mac under load in another project's text reading. It
    /// took about 15 seconds each time and failed again on every retry.
    static let operationNotCreated = e5rtError(
        "e5rt_execution_stream_operation_create_precompiled_compute_operation_with_options call failed", 13
    )
}

private let noPause: [Duration] = [.zero, .zero]

@Test("Vision's stream failure on a busy machine is retried, and the request still answers")
func streamFailureIsRetried() async throws {
    var calls = 0
    let answer = try await VisionRetry.run(pauses: noPause) {
        calls += 1
        if calls == 1 { throw ModelRuntimeError.streamFailed }
        return 42
    }
    #expect(answer == 42)
    #expect(calls == 2)
}

@Test("Any other error is thrown at once, without a retry", arguments: [
    ModelRuntimeError.operationNotCreated as any Error,
    VisionError.internalError("e5rt"),
    VisionError.operationFailed("the request failed"),
    VisionError.invalidImage("the image is empty"),
    CancellationError(),
    CocoaError(.fileReadCorruptFile),
])
func otherErrorsAreNotRetried(_ error: any Error) async {
    var calls = 0
    let thrown = await #expect(throws: (any Error).self) {
        try await VisionRetry.run(pauses: noPause) { () async throws -> Int in
            calls += 1
            throw error
        }
    }
    #expect(calls == 1)
    #expect(thrown.map { String(reflecting: $0) } == String(reflecting: error))
}

@Test("A request that keeps failing runs three times in all, then its error is thrown")
func retryIsBounded() async {
    // The real pauses, so this also pins what a failing request costs.
    var calls = 0
    let clock = ContinuousClock()
    let start = clock.now
    await #expect(throws: ModelRuntimeError.self) {
        try await VisionRetry.run { () async throws -> Int in
            calls += 1
            throw ModelRuntimeError.streamFailed
        }
    }
    #expect(calls == 3)
    #expect(clock.now - start >= .milliseconds(500))
}
