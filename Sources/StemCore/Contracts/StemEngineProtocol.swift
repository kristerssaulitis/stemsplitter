import Foundation

/// The engine boundary (plan Approach B / Review Section 1): one actor that owns
/// the split pipeline.
///
/// FROZEN CONTRACT. Decisions encoded here, all from the approved plan:
/// - The pipeline runs as a Swift `Actor`; cancel and completion are serialized by
///   actor isolation (CEO row 14), which kills the cancel-vs-completion race.
/// - Single-flight: one split at a time (CEO row 13; S4 "picker disabled during
///   processing"). A second `split` before the first stream finishes is a caller
///   bug — implementations must reject it (e.g. emit `.failure(.generic(...))`
///   immediately) rather than interleave two pipelines.
/// - The engine streams: bounded inter-stage queue, 2-3 in-flight chunks per stage,
///   cooperative cancellation at chunk boundaries, writer teardown on cancel
///   (eng E1). No whole-file float buffers (memory invariant: peak <400 MB on the
///   iPhone 17 (A19) gate device).
/// - The input is a local file URL. The security-scoped copy out of PhotosPicker
///   (eng E5's tmp projection) is the app layer's job, not the engine's.
public protocol StemEngineProtocol: Actor {

    /// Split the audio in `sourceURL` (local file URL) into vocals + instrumental.
    ///
    /// Returns a stream of `PipelineEvent` ending in exactly one terminal event —
    /// `.failure(StemError)` or `.completed(SplitOutputs)` — before the stream
    /// finishes. Cancelled splits end with `.failure(.cancelled)`. Partial output
    /// is never left behind on failure or cancel (orphan dirs are the caller's
    /// SplitStore concern; the engine must not require cleanup to be safe to retry).
    ///
    /// The returned stream terminates when the terminal event is delivered; the
    /// iteration may `await` freely (backpressure is bounded by the inter-stage
    /// queue, so holding the consumer's iteration cannot grow memory unboundedly).
    func split(_ sourceURL: URL) async -> AsyncStream<PipelineEvent>

    /// Cooperatively cancel the in-flight split at the next chunk boundary
    /// (eng E1). Safe to call at any time, including after the stream finished
    /// (no-op). Serialized with pipeline state by actor isolation. The stream then
    /// emits `.failure(.cancelled)` and finishes; all partial output is discarded.
    func cancel() async
}
