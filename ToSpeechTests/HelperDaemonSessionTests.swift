import AppKit
import Darwin
import Foundation
import Testing
@testable import ToSpeech

/// A clock whose sleepers only wake when the test advances it.
private final class TestClock: Clock, @unchecked Sendable {
  struct Instant: InstantProtocol, Hashable {
    var offset: Duration
    func advanced(by duration: Duration) -> Instant { .init(offset: offset+duration) }
    func duration(to other: Instant) -> Duration { other.offset-offset }
    static func < (a: Instant, b: Instant) -> Bool { a.offset < b.offset }
  }
  private let lock = NSLock()
  private var current = Instant(offset: .zero)
  private var sleepers: [(id: Int, deadline: Instant, continuation: CheckedContinuation<Void, Error>)] = []
  private var identifiers = 0
  var now: Instant { lock.lock(); defer { lock.unlock() }; return current }
  var minimumResolution: Duration { .zero }
  var sleeperCount: Int { lock.lock(); defer { lock.unlock() }; return sleepers.count }
  func sleep(until deadline: Instant, tolerance: Duration?) async throws {
    let id = lock.withLock { identifiers += 1; return identifiers }
    try await withTaskCancellationHandler {
      try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
        lock.lock()
        guard current < deadline else { lock.unlock(); return continuation.resume() }
        sleepers.append((id, deadline, continuation))
        lock.unlock()
      }
    } onCancel: { self.cancel(id) }
  }
  func advance(by duration: Duration) {
    lock.lock()
    current = current.advanced(by: duration)
    let due = sleepers.filter { $0.deadline <= current }
    sleepers.removeAll { $0.deadline <= current }
    lock.unlock()
    for sleeper in due { sleeper.continuation.resume() }
  }
  private func cancel(_ id: Int) {
    lock.lock()
    let match = sleepers.first { $0.id == id }
    sleepers.removeAll { $0.id == id }
    lock.unlock()
    match?.continuation.resume(throwing: CancellationError())
  }
}

private final class StubHelperTransport: HelperTransport, @unchecked Sendable {
  private let lock = NSLock()
  private var continuation: AsyncStream<String>.Continuation?
  private var lines: [String] = []
  private var stops = 0
  private let announcesReady: Bool
  private let onSend: @Sendable (StubHelperTransport, String) -> Void

  init(ready: Bool = true, onSend: @escaping @Sendable (StubHelperTransport, String) -> Void = { _, _ in }) {
    announcesReady = ready
    self.onSend = onSend
  }
  func start() async throws -> AsyncStream<String> {
    let (stream, continuation) = AsyncStream<String>.makeStream()
    lock.withLock { self.continuation = continuation }
    if announcesReady { emit(#"{"status":"ready","loadSeconds":6.3,"head":null}"#) }
    return stream
  }
  func send(_ line: String) async throws {
    lock.withLock { lines.append(line) }
    onSend(self, line)
  }
  func terminate() {
    lock.lock(); stops += 1; let stream = continuation; continuation = nil; lock.unlock()
    stream?.finish()
  }
  func emit(_ line: String) {
    lock.lock(); let stream = continuation; lock.unlock()
    stream?.yield(line)
  }
  /// The helper process died without answering.
  func die() {
    lock.lock(); let stream = continuation; continuation = nil; lock.unlock()
    stream?.finish()
  }
  func complete(_ request: String) {
    emit(#"{"id":"\#(Self.id(request))","status":"complete","output":"/tmp/result.json","seconds":2.1}"#)
  }
  func fail(_ request: String, _ message: String) {
    emit(#"{"id":"\#(Self.id(request))","status":"error","message":"\#(message)"}"#)
  }
  var sent: [String] { lock.lock(); defer { lock.unlock() }; return lines }
  var terminations: Int { lock.lock(); defer { lock.unlock() }; return stops }
  static func id(_ line: String) -> String {
    let object = try? JSONSerialization.jsonObject(with: Data(line.utf8)) as? [String: Any]
    return object?["id"] as? String ?? ""
  }
}

private final class StubTransports: @unchecked Sendable {
  private let lock = NSLock()
  private var made: [StubHelperTransport] = []
  private let build: @Sendable () -> StubHelperTransport
  init(_ build: @escaping @Sendable () -> StubHelperTransport) { self.build = build }
  func make() -> any HelperTransport {
    let transport = build()
    lock.lock(); made.append(transport); lock.unlock()
    return transport
  }
  var all: [StubHelperTransport] { lock.lock(); defer { lock.unlock() }; return made }
}

private func waitUntil(_ condition: @Sendable () -> Bool) async throws {
  for _ in 0..<2000 {
    if condition() { return }
    try await Task.sleep(for: .milliseconds(2))
  }
  Issue.record("condition never became true")
}

/// Serialized: `appQuitTerminatesEveryLiveHelper` posts `willTerminateNotification`, which kills
/// every helper process registered at that moment — including the ones the other tests here run.
@Suite(.serialized) struct HelperDaemonSessionTests {
  private func requestFile(_ name: String = "request.json") throws -> URL {
    let directory = FileManager.default.temporaryDirectory
      .appendingPathComponent("HelperDaemonTests-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    let url = directory.appendingPathComponent(name)
    try Data(#"{"source":"/tmp/source.f32","take":"/tmp/take.f32","words":[]}"#.utf8).write(to: url)
    return url
  }

  @Test func firstRunWaitsForReadyThenResolvesOnTheMatchingCompleteLine() async throws {
    let request = try requestFile()
    let output = request.deletingLastPathComponent().appendingPathComponent("result.json")
    let transports = StubTransports { StubHelperTransport { transport, line in transport.complete(line) } }
    let session = HelperDaemonSession(name: "xeus", transport: transports.make)
    try await session.run(request: request, output: output)
    let sent = try #require(transports.all.first?.sent)
    #expect(sent.count == 1)
    let message = try #require(try JSONSerialization.jsonObject(with: Data(sent[0].utf8)) as? [String: Any])
    #expect(message["output"] as? String == output.path)
    #expect((message["id"] as? String)?.isEmpty == false)
    #expect((message["request"] as? [String: Any])?["source"] as? String == "/tmp/source.f32")
    await session.shutdown()
  }

  @Test func helperErrorIsReportedAndTheDaemonStaysUpForTheNextRequest() async throws {
    let request = try requestFile()
    let output = request.deletingLastPathComponent().appendingPathComponent("result.json")
    let transports = StubTransports {
      StubHelperTransport { transport, line in
        if transport.sent.count == 1 { transport.fail(line, "unsupported target") } else { transport.complete(line) }
      }
    }
    let session = HelperDaemonSession(name: "xeus", transport: transports.make)
    await #expect(throws: HelperDaemonSession.Failure.helper("unsupported target")) {
      try await session.run(request: request, output: output)
    }
    try await session.run(request: request, output: output)
    #expect(transports.all.count == 1)
    #expect(transports.all[0].sent.count == 2)
    #expect(await session.isDegraded == false)
    await session.shutdown()
  }

  @Test func aDeadHelperIsRestartedOnceAndTheSecondDeathDegradesTheSession() async throws {
    let request = try requestFile()
    let output = request.deletingLastPathComponent().appendingPathComponent("result.json")
    let transports = StubTransports { StubHelperTransport { transport, _ in transport.die() } }
    let session = HelperDaemonSession(name: "xeus", transport: transports.make)
    await #expect(throws: HelperDaemonSession.Failure.degraded) {
      try await session.run(request: request, output: output)
    }
    #expect(transports.all.count == 2)
    #expect(await session.isDegraded)
    await #expect(throws: HelperDaemonSession.Failure.degraded) {
      try await session.run(request: request, output: output)
    }
    #expect(transports.all.count == 2)
    await session.shutdown()
  }

  @Test func theHelperIsTerminatedAfterTheIdleTimeoutAndTheNextRunStartsAFreshOne() async throws {
    let request = try requestFile()
    let output = request.deletingLastPathComponent().appendingPathComponent("result.json")
    let clock = TestClock()
    let transports = StubTransports { StubHelperTransport { transport, line in transport.complete(line) } }
    let session = HelperDaemonSession(name: "xeus", transport: transports.make,
      idleTimeout: .seconds(600), clock: clock)
    try await session.run(request: request, output: output)
    try await waitUntil { clock.sleeperCount == 1 }
    clock.advance(by: .seconds(600))
    try await waitUntil { transports.all.first?.terminations == 1 }
    try await session.run(request: request, output: output)
    #expect(transports.all.count == 2)
    // A missed idle release must fail this test, not crash the whole test process.
    let fresh = try #require(transports.all.dropFirst().first)
    #expect(fresh.sent.count == 1)
    await session.shutdown()
  }

  @Test func concurrentRunsAreSerializedIntoOneRequestAtATime() async throws {
    let first = try requestFile("first.json"), second = try requestFile("second.json")
    let output = first.deletingLastPathComponent().appendingPathComponent("result.json")
    let transports = StubTransports { StubHelperTransport() }
    let session = HelperDaemonSession(name: "xeus", transport: transports.make)
    async let leading: Void = session.run(request: first, output: output)
    async let trailing: Void = session.run(request: second, output: output)
    let transport = try await { () -> StubHelperTransport in
      try await waitUntil { transports.all.first?.sent.isEmpty == false }
      return transports.all[0]
    }()
    try await Task.sleep(for: .milliseconds(20))
    #expect(transport.sent.count == 1)
    transport.complete(transport.sent[0])
    try await waitUntil { transport.sent.count == 2 }
    transport.complete(transport.sent[1])
    try await leading
    try await trailing
    #expect(StubHelperTransport.id(transport.sent[0]) != StubHelperTransport.id(transport.sent[1]))
    #expect(transports.all.count == 1)
    await session.shutdown()
  }

  /// The stub transport never exercises the pipes, so one round trip runs against a real process.
  @Test func theProcessTransportTalksToARealHelperOverStdinAndStdout() async throws {
    let request = try requestFile()
    let output = request.deletingLastPathComponent().appendingPathComponent("result.json")
    let script = #"""
      printf '{"status":"ready","loadSeconds":0.1}\n'
      while IFS= read -r line; do
        id=$(printf '%s' "$line" | sed -E 's/.*"id":"([^"]+)".*/\1/')
        printf '{"id":"%s","status":"complete","output":"x","seconds":0}\n' "$id"
      done
      """#
    let session = HelperDaemonSession(executable: URL(fileURLWithPath: "/bin/sh"), arguments: ["-c", script])
    try await session.run(request: request, output: output)
    try await session.run(request: request, output: output)
    await session.shutdown()
  }

  /// The helper's last line and its exit are one event. Once the readability handler is gone the
  /// final drain is the only thing that can still deliver that `complete` line; when the drain runs
  /// after the stream was closed it is dropped and the session sees a death instead. The answer
  /// still arrives on the restarted helper, so the count of helpers is what shows it, not the
  /// result. (The handler usually wins the race on an idle machine — this pins the property, and
  /// the drain is what holds it up when it does not.)
  @Test func theLastLineOfAnExitingHelperIsDeliveredInsteadOfLookingLikeADeath() async throws {
    let request = try requestFile()
    let output = request.deletingLastPathComponent().appendingPathComponent("result.json")
    let starts = request.deletingLastPathComponent().appendingPathComponent("starts.txt")
    let script = #"""
      printf 'start\n' >> "HELPER_STARTS"
      printf '{"status":"ready","loadSeconds":0}\n'
      IFS= read -r line
      id=$(printf '%s' "$line" | sed -E 's/.*"id":"([^"]+)".*/\1/')
      printf '{"id":"%s","status":"complete","output":"x","seconds":0}\n' "$id"
      exit 0
      """#.replacingOccurrences(of: "HELPER_STARTS", with: starts.path)
    // A fresh session per job: re-entering `run` before the closed stream has been observed would
    // start a second helper for reasons that have nothing to do with the drain.
    for _ in 0..<3 {
      let session = HelperDaemonSession(executable: URL(fileURLWithPath: "/bin/sh"), arguments: ["-c", script])
      try await session.run(request: request, output: output)
      #expect(await session.isDegraded == false)
      await session.shutdown()
    }
    let launches = try String(contentsOf: starts, encoding: .utf8).split(separator: "\n")
    #expect(launches.count == 3) // One helper per job — a dropped `complete` line costs a restart.
  }

  /// SIGPIPE regression: writing to a helper whose stdin has no reader left must throw EPIPE.
  /// Without `F_SETNOSIGPIPE` on the write end the same write raises SIGPIPE and kills the app.
  @Test func writingToAHelperThatClosedItsStdinThrowsInsteadOfRaisingSIGPIPE() async throws {
    let script = #"""
      exec 0<&-
      printf '{"status":"ready","loadSeconds":0}\n'
      exec sleep 5
      """#
    let transport = ProcessHelperTransport(executable: URL(fileURLWithPath: "/bin/sh"), arguments: ["-c", script])
    let lines = try await transport.start()
    var helper = lines.makeAsyncIterator()
    let ready = await helper.next()
    #expect(ready?.contains("ready") == true) // stdin is gone by the time the helper says this
    await #expect(throws: (any Error).self) { try await transport.send(#"{"id":"x"}"#) }
    transport.terminate()
  }

  @Test func aRequestThatIsNeverAnsweredTimesOutOnTheSessionClock() async throws {
    let request = try requestFile()
    let output = request.deletingLastPathComponent().appendingPathComponent("result.json")
    let clock = TestClock()
    let transports = StubTransports { StubHelperTransport() } // ready, then silence
    let session = HelperDaemonSession(name: "xeus", transport: transports.make,
      requestTimeout: .seconds(240), clock: clock)
    let job = Task { try await session.run(request: request, output: output) }
    try await waitUntil { transports.all.first?.sent.isEmpty == false }
    try await waitUntil { clock.sleeperCount == 1 }
    clock.advance(by: .seconds(240))
    await #expect(throws: HelperDaemonSession.Failure.timeout) { try await job.value }
    #expect(transports.all.count == 1)
    #expect(transports.all[0].terminations == 1) // a stuck helper is torn down, never reused
    await session.shutdown()
  }

  @Test func aHelperThatNeverReportsReadyTimesOutOnTheSessionClock() async throws {
    let request = try requestFile()
    let output = request.deletingLastPathComponent().appendingPathComponent("result.json")
    let clock = TestClock()
    let transports = StubTransports { StubHelperTransport(ready: false) }
    let session = HelperDaemonSession(name: "xeus", transport: transports.make,
      readyTimeout: .seconds(120), clock: clock)
    let job = Task { try await session.run(request: request, output: output) }
    // A helper that never loads is a transport failure: the session restarts it once, then degrades.
    for _ in 0..<2 {
      try await waitUntil { clock.sleeperCount == 1 }
      clock.advance(by: .seconds(120))
    }
    await #expect(throws: HelperDaemonSession.Failure.degraded) { try await job.value }
    #expect(transports.all.count == 2)
    #expect(transports.all.allSatisfy { $0.terminations >= 1 && $0.sent.isEmpty })
    await session.shutdown()
  }

  /// A killed helper leaves nothing but its stderr, so the death it causes has to carry it.
  @Test func theHelperStderrTailIsCarriedIntoTheTransportFailure() async throws {
    let request = try requestFile()
    let output = request.deletingLastPathComponent().appendingPathComponent("result.json")
    let script = #"""
      printf '{"status":"ready","loadSeconds":0}\n'
      IFS= read -r line
      printf 'RuntimeError: xeus helper ran out of memory\n' >&2
      exit 9
      """#
    let session = HelperDaemonSession(executable: URL(fileURLWithPath: "/bin/sh"), arguments: ["-c", script])
    await #expect(throws: HelperDaemonSession.Failure.degraded) {
      try await session.run(request: request, output: output)
    }
    let tail = try #require(await session.lastHelperStderr)
    #expect(tail.contains("RuntimeError: xeus helper ran out of memory"))
    await session.shutdown()
  }

  /// Spec L4: the XEUS adapter scores delivery through the app's one UK adapter. A second one would
  /// hold its own ~1.5 GB encoder session.
  @Test func theXeusAdapterScoresDeliveryThroughTheInjectedUKAdapter() async {
    let paths = BackendPaths(root: FileManager.default.temporaryDirectory
      .appendingPathComponent("PhoneticXeusInjection-\(UUID().uuidString)", isDirectory: true))
    let ukPackage = UKReferencePackage(paths: paths)
    let shared = UKReferenceAdapter(package: ukPackage, idleTimeout: .zero)
    let adapter = PhoneticXeusAdapter(package: PhoneticXeusPackage(paths: paths), ukPackage: ukPackage,
      ukAdapter: shared, policy: .warmParallel)
    #expect(await adapter.ukAdapter === shared)
    let standalone = PhoneticXeusAdapter(package: PhoneticXeusPackage(paths: paths), ukPackage: ukPackage)
    #expect(await standalone.ukAdapter !== shared) // the convenience path still builds its own
  }

  @Test func idleReleaseIgnoresStaleWakeUps() {
    var idle = IdleRelease(timeout: .seconds(600), clock: ContinuousClock())
    let first = idle.mark()
    #expect(idle.isCurrent(first))
    let second = idle.mark()
    #expect(!idle.isCurrent(first))
    #expect(idle.isCurrent(second))
  }

  @Test func lowMemoryMachinesKeepNothingWarm() {
    #expect(AssessmentResourcePolicy.current(physicalMemory: 8*1024*1024*1024) == .coldSequential)
    #expect(AssessmentResourcePolicy.current(physicalMemory: 12*1024*1024*1024) == .warmParallel)
    #expect(AssessmentResourcePolicy.current(physicalMemory: 18*1024*1024*1024) == .warmParallel)
    #expect(AssessmentResourcePolicy.coldSequential.idleTimeout == .zero)
    #expect(AssessmentResourcePolicy.coldSequential.overlapsBranches == false)
    #expect(AssessmentResourcePolicy.warmParallel.idleTimeout == .seconds(600))
    #expect(AssessmentResourcePolicy.warmParallel.overlapsBranches)
  }

  @Test func aColdSequentialSessionReleasesTheHelperRightAfterTheJob() async throws {
    let request = try requestFile()
    let output = request.deletingLastPathComponent().appendingPathComponent("result.json")
    let transports = StubTransports { StubHelperTransport { transport, line in transport.complete(line) } }
    let session = HelperDaemonSession(name: "xeus", transport: transports.make,
      idleTimeout: AssessmentResourcePolicy.coldSequential.idleTimeout)
    try await session.run(request: request, output: output)
    try await waitUntil { transports.all[0].terminations == 1 }
    #expect(transports.all[0].terminations == 1)
    await session.shutdown()
  }

  /// W1: the final drain runs on the session actor's own thread (`teardown() → terminate() →
  /// finish()`). A helper that keeps the stdout write end open and answers nothing must not be able
  /// to park it: with blocking reads the drain could wait for the helper to die, which is unbounded.
  @Test func tearingDownAStuckHelperDoesNotBlockTheSessionActor() async throws {
    let request = try requestFile()
    let output = request.deletingLastPathComponent().appendingPathComponent("result.json")
    let marker = request.deletingLastPathComponent().appendingPathComponent("sent.txt")
    let clock = TestClock()
    let script = #"""
      printf '{"status":"ready","loadSeconds":0}\n'
      IFS= read -r line
      printf 'sent\n' > "MARKER"
      exec sleep 30
      """#.replacingOccurrences(of: "MARKER", with: marker.path)
    let session = HelperDaemonSession(executable: URL(fileURLWithPath: "/bin/sh"), arguments: ["-c", script],
      clock: clock)
    let job = Task { try await session.run(request: request, output: output) }
    // The request is in the helper's hands and `sleep 30` now holds stdout open with no answer coming.
    try await waitUntil { FileManager.default.fileExists(atPath: marker.path) }
    try await waitUntil { clock.sleeperCount == 1 }
    let mark = ContinuousClock.now
    clock.advance(by: .seconds(240))
    await #expect(throws: HelperDaemonSession.Failure.timeout) { try await job.value }
    #expect(mark.duration(to: .now) < .seconds(1)) // teardown, terminate and both drains
    // The session is usable again: a fresh transport still runs and nothing is degraded.
    #expect(await session.isDegraded == false)
    await session.shutdown()
  }

  /// W2: `terminate()` and the process's own termination handler can land together. The second
  /// finisher must return at once instead of adding another reader to the pipes the first is
  /// draining — and the helper's lines must still arrive exactly once.
  @Test func concurrentTerminationsLeaveExactlyOneFinisherDrainingThePipes() async throws {
    let marker = try requestFile().deletingLastPathComponent().appendingPathComponent("written.txt")
    let script = #"""
      printf '{"status":"ready","loadSeconds":0}\n'
      printf '{"status":"second"}\n'
      printf 'written\n' > "MARKER"
      exec sleep 30
      """#.replacingOccurrences(of: "MARKER", with: marker.path)
    let transport = ProcessHelperTransport(executable: URL(fileURLWithPath: "/bin/sh"), arguments: ["-c", script])
    let lines = try await transport.start()
    let collector = Task { await lines.reduce(into: [String]()) { $0.append($1) } }
    // Both lines are in the pipe before anything is torn down; who delivers them — a readability
    // handler or the final drain — is the race this pins.
    try await waitUntil { FileManager.default.fileExists(atPath: marker.path) }
    let mark = ContinuousClock.now
    await withTaskGroup(of: Void.self) { group in
      for _ in 0..<4 { group.addTask { transport.terminate() } }
    }
    let collected = await collector.value // the stream finished: exactly one finisher closed it
    #expect(mark.duration(to: .now) < .seconds(1))
    #expect(collected.filter { $0.contains("ready") }.count == 1)
    #expect(collected.filter { $0.contains("second") }.count == 1)
  }

  /// W6: app quit must not leave a multi-gigabyte helper behind. The probe's own evidence is the
  /// stdin-EOF exit (it quits with `exit(0)`, which posts no notification), so the registry path is
  /// what this test covers: the notification, a live helper, and its pid.
  @Test func appQuitTerminatesEveryLiveHelper() async throws {
    let directory = try requestFile().deletingLastPathComponent()
    let pidFile = directory.appendingPathComponent("helper.pid")
    let script = #"""
      printf '%d\n' $$ > "PIDFILE"
      printf '{"status":"ready","loadSeconds":0}\n'
      exec sleep 30
      """#.replacingOccurrences(of: "PIDFILE", with: pidFile.path)
    let transport = ProcessHelperTransport(executable: URL(fileURLWithPath: "/bin/sh"), arguments: ["-c", script])
    let lines = try await transport.start()
    var helper = lines.makeAsyncIterator()
    #expect(await helper.next()?.contains("ready") == true)
    let text = try String(contentsOf: pidFile, encoding: .utf8).trimmingCharacters(in: .whitespacesAndNewlines)
    let pid = try #require(pid_t(text))
    #expect(kill(pid, 0) == 0) // `exec sleep 30` keeps the shell's pid and ignores stdin entirely
    NotificationCenter.default.post(name: NSApplication.willTerminateNotification, object: nil)
    var stopped = false
    for _ in 0..<500 where !stopped {
      if kill(pid, 0) != 0 { stopped = true; break }
      try await Task.sleep(for: .milliseconds(2))
    }
    #expect(stopped) // within ~1 s of the notification
    transport.terminate()
  }

  /// W3: the convenience initializer builds a UK adapter nothing else knows about. An injected one
  /// belongs to the service — releasing it here would drop the encoder of the engine being switched to.
  @Test func releasingXeusDropsOnlyTheUKAdapterItOwns() async {
    let paths = BackendPaths(root: FileManager.default.temporaryDirectory
      .appendingPathComponent("PhoneticXeusOwnership-\(UUID().uuidString)", isDirectory: true))
    let ukPackage = UKReferencePackage(paths: paths)
    let owner = PhoneticXeusAdapter(package: PhoneticXeusPackage(paths: paths), ukPackage: ukPackage)
    await owner.ukAdapter.cacheSourceForTesting()
    #expect(await owner.ukAdapter.hasCachedSource)
    await owner.release()
    #expect(await owner.ukAdapter.hasCachedSource == false)
    let shared = UKReferenceAdapter(package: ukPackage, idleTimeout: .zero)
    await shared.cacheSourceForTesting()
    let borrower = PhoneticXeusAdapter(package: PhoneticXeusPackage(paths: paths), ukPackage: ukPackage,
      ukAdapter: shared, policy: .warmParallel)
    await borrower.release()
    #expect(await shared.hasCachedSource) // the service owns this one
  }

  /// W5: the ~1.5 GB encoder session is built before the work that can fail, and a failed XEUS job
  /// cancels this branch as a matter of course. Whatever happens inside the scope, the session must
  /// leave it on the idle timer instead of staying resident with no timer at all.
  @Test func aThrowInsideTheEncoderScopeStillSchedulesTheIdleRelease() async throws {
    let clock = TestClock()
    let paths = BackendPaths(root: FileManager.default.temporaryDirectory
      .appendingPathComponent("UKEncoderRelease-\(UUID().uuidString)", isDirectory: true))
    let adapter = UKReferenceAdapter(package: UKReferencePackage(paths: paths),
      idleTimeout: .seconds(600), clock: clock)
    let directory = try #require(Bundle.main.resourceURL).appendingPathComponent("UKReference")
    await #expect(throws: BuddyError.invalidOutput) {
      try await adapter.failInsideTheEncoderScope(directory: directory)
    }
    #expect(await adapter.hasWarmEncoder) // built, and the job it belonged to is over
    try await waitUntil { clock.sleeperCount == 1 } // the idle timer exists — this is the fix
    clock.advance(by: .seconds(600))
    var released = false
    for _ in 0..<2000 where !released {
      if await adapter.hasWarmEncoder == false { released = true; break }
      try await Task.sleep(for: .milliseconds(2))
    }
    #expect(released)
  }
}
