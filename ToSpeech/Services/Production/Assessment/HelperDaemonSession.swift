import AppKit
import Foundation
import OSLog

/// Releases a warm resource after an idle period. Every use bumps the generation; a wake-up whose
/// mark is stale — or that lands while the owner is busy — releases nothing.
struct IdleRelease: Sendable {
  let timeout: Duration
  let clock: any Clock<Duration>
  private(set) var generation = 0
  init(timeout: Duration, clock: any Clock<Duration>) { self.timeout = timeout; self.clock = clock }
  mutating func mark() -> Int { generation += 1; return generation }
  func isCurrent(_ mark: Int) -> Bool { mark == generation }
  func waitForIdle() async { try? await clock.sleep(for: timeout) }
}

/// One helper process speaking the JSON-lines daemon protocol: one line in, one line out.
protocol HelperTransport: Sendable {
  /// Starts the helper and returns its stdout lines. The stream finishes when the helper exits.
  ///
  /// One line in the stream may not come from the helper's stdout at all: right before it finishes,
  /// a transport that captures stderr may synthesize `{"status":"stderr","tail":"…"}` carrying the
  /// tail of what the helper wrote there (JSON-escaped, ≤4 KiB). A killed helper leaves nothing
  /// else, so the death the session is about to report can still say why. It carries no `id`,
  /// answers no request, and a transport that has no stderr tail to report emits none.
  func start() async throws -> AsyncStream<String>
  func send(_ line: String) async throws
  func terminate()
}

/// Keeps one model helper daemon warm. A helper costs seconds to load and gigabytes resident, so
/// the process starts lazily, is reused for every job, and is released after `idleTimeout`.
/// Nothing here is engine specific: the launch arguments decide which helper runs, and the
/// protocol is the shared one (`ready` / `complete` / `error` / `ping`). A helper answers one
/// request at a time, so requests are serialized here too.
actor HelperDaemonSession {
  enum Failure: Error, Equatable, LocalizedError {
    /// The process could not start, died, or stopped answering: the session may restart once.
    case transport(String)
    /// The helper answered `error` for this request. The daemon stays up.
    case helper(String)
    case timeout
    /// Two consecutive transport failures: the caller falls back to its one-shot path.
    case degraded
    var errorDescription: String? {
      switch self {
      case .transport(let detail): "Helper transport failed: \(detail)"
      case .helper(let message): "Helper rejected the request: \(message)"
      case .timeout: "Helper did not answer in time."
      case .degraded: "Helper daemon is unavailable."
      }
    }
    var isTransport: Bool { if case .transport = self { true } else { false } }
  }
  typealias Factory = @Sendable () -> any HelperTransport
  /// The `ready` line carries no id; it waits in the same map as a request.
  private static let readyKey = "ready"
  private struct Pending {
    var continuation: CheckedContinuation<Void, Error>?
    var result: Result<Void, Error>?
  }
  private let factory: Factory
  private let name: String
  private let requestTimeout: Duration
  private let readyTimeout: Duration
  private let clock: any Clock<Duration>
  private let log = Logger(subsystem: "com.unknownstudio.tospeech", category: "HelperDaemon")
  private var idle: IdleRelease
  private var transport: (any HelperTransport)?
  private var reader: Task<Void, Never>?
  private var idleTask: Task<Void, Never>?
  private var pending: [String: Pending] = [:]
  /// Lines from a replaced transport must not resolve requests of the current one.
  private var epoch = 0
  private var busy = false
  private var waiters: [CheckedContinuation<Void, Never>] = []
  private(set) var isDegraded = false
  /// The tail of what the running helper printed to stderr, kept so the death it is about to
  /// report says why. Cleared when a new helper starts.
  private(set) var lastHelperStderr: String?

  init(name: String, transport factory: @escaping Factory, idleTimeout: Duration = .seconds(600),
    requestTimeout: Duration = .seconds(240), readyTimeout: Duration = .seconds(120),
    clock: any Clock<Duration> = ContinuousClock()) {
    self.name = name
    self.factory = factory
    self.requestTimeout = requestTimeout
    self.readyTimeout = readyTimeout
    self.clock = clock
    idle = IdleRelease(timeout: idleTimeout, clock: clock)
  }
  init(executable: URL, arguments: [String], workingDirectory: URL? = nil,
    idleTimeout: Duration = .seconds(600), clock: any Clock<Duration> = ContinuousClock()) {
    self.init(name: executable.lastPathComponent,
      transport: { ProcessHelperTransport(executable: executable, arguments: arguments, workingDirectory: workingDirectory) },
      idleTimeout: idleTimeout, clock: clock)
  }

  /// Sends one request (the JSON of `request` is forwarded verbatim) and returns when the helper
  /// has written `output`.
  func run(request: URL, output: URL) async throws {
    await acquire()
    defer { release(); scheduleIdleRelease() }
    guard !isDegraded else { throw Failure.degraded }
    try Task.checkCancellation()
    let payload = try Self.payload(request: request, output: output)
    for attempt in 1...2 {
      do {
        try await ensureRunning()
        try await perform(payload)
        return
      } catch let failure as Failure {
        switch failure {
        case .transport(let detail):
          teardown()
          log.error("\(self.name, privacy: .public) daemon attempt \(attempt, privacy: .public) failed: \(detail, privacy: .public)")
          if attempt == 2 { isDegraded = true; throw Failure.degraded }
        case .helper(let message):
          log.error("\(self.name, privacy: .public) helper error: \(message, privacy: .public)")
          throw failure
        case .timeout:
          // A stuck helper must not poison the next job.
          teardown()
          throw failure
        case .degraded: throw failure
        }
      }
    }
    throw Failure.degraded
  }

  /// Terminates the helper. Safe to call when nothing is running.
  func shutdown() { teardown() }

  private static func payload(request: URL, output: URL) throws -> [String: Any] {
    let object = try JSONSerialization.jsonObject(with: Data(contentsOf: request))
    return ["request": object, "output": output.path]
  }

  private func perform(_ payload: [String: Any]) async throws {
    guard let transport else { throw Failure.transport("helper is not running") }
    let id = UUID().uuidString
    var message = payload
    message["id"] = id
    let data = try JSONSerialization.data(withJSONObject: message)
    reserve(id)
    defer { pending[id] = nil }
    do { try await transport.send(String(decoding: data, as: UTF8.self)) }
    catch { throw Failure.transport(error.localizedDescription) }
    try await wait(id, timeout: requestTimeout)
  }

  private func ensureRunning() async throws {
    if transport != nil { return }
    let transport = factory()
    epoch += 1
    lastHelperStderr = nil
    let current = epoch
    let lines: AsyncStream<String>
    do { lines = try await transport.start() }
    catch { transport.terminate(); throw Failure.transport(error.localizedDescription) }
    self.transport = transport
    reserve(Self.readyKey)
    reader = Task { [weak self] in
      for await line in lines { await self?.receive(line, epoch: current) }
      await self?.ended(epoch: current)
    }
    do { try await wait(Self.readyKey, timeout: readyTimeout) }
    catch is CancellationError { pending[Self.readyKey] = nil; throw CancellationError() }
    catch {
      pending[Self.readyKey] = nil
      throw (error as? Failure).map { $0.isTransport ? $0 : .transport($0.localizedDescription) }
        ?? .transport(error.localizedDescription)
    }
  }

  private func receive(_ line: String, epoch: Int) {
    guard epoch == self.epoch,
      let object = try? JSONSerialization.jsonObject(with: Data(line.utf8)) as? [String: Any] else { return }
    let status = object["status"] as? String
    let message = object["message"] as? String ?? "unknown helper error"
    guard let id = object["id"] as? String else {
      // `ready` carries no id, and neither does the helper's malformed-line error.
      if status == "ready" {
        log.info("\(self.name, privacy: .public) daemon ready in \(object["loadSeconds"] as? Double ?? 0, privacy: .public) s")
        resolve(Self.readyKey, .success(()))
      } else if status == "stderr", let tail = object["tail"] as? String, !tail.isEmpty {
        // The transport forwards the helper's stderr tail as it dies; a kill leaves nothing else.
        log.error("\(self.name, privacy: .public) helper stderr: \(tail, privacy: .public)")
        lastHelperStderr = tail
      } else if status == "error" { failAll(.helper(message)) }
      return
    }
    switch status {
    case "complete":
      log.info("\(self.name, privacy: .public) daemon answered in \(object["seconds"] as? Double ?? 0, privacy: .public) s")
      resolve(id, .success(()))
    case "error": resolve(id, .failure(Failure.helper(message)))
    default: break
    }
  }

  private func ended(epoch: Int) {
    guard epoch == self.epoch else { return }
    transport = nil
    reader = nil
    failAll(.transport(lastHelperStderr.map { "helper exited: \($0)" } ?? "helper exited"))
  }

  private func wait(_ key: String, timeout: Duration) async throws {
    // The session's clock, so a test can drive the ready and request timeouts.
    let timer = Task { [clock, weak self] in
      try? await clock.sleep(for: timeout)
      guard !Task.isCancelled else { return }
      await self?.resolve(key, .failure(Failure.timeout))
    }
    defer { timer.cancel() }
    try await withTaskCancellationHandler {
      try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
        guard var slot = pending[key] else {
          return continuation.resume(throwing: Failure.transport("request was dropped"))
        }
        if let result = slot.result { pending[key] = nil; continuation.resume(with: result) }
        else { slot.continuation = continuation; pending[key] = slot }
      }
    } onCancel: {
      Task { await self.resolve(key, .failure(CancellationError())) }
    }
  }

  private func reserve(_ key: String) { pending[key] = Pending() }
  private func resolve(_ key: String, _ result: Result<Void, Error>) {
    guard var slot = pending[key] else { return }
    if let continuation = slot.continuation { pending[key] = nil; continuation.resume(with: result) }
    else if slot.result == nil { slot.result = result; pending[key] = slot }
  }
  private func failAll(_ failure: Failure) {
    for key in Array(pending.keys) { resolve(key, .failure(failure)) }
  }

  private func teardown() {
    epoch += 1
    let current = transport
    transport = nil
    reader?.cancel(); reader = nil
    idleTask?.cancel(); idleTask = nil
    current?.terminate()
    failAll(.transport("helper stopped"))
  }

  private func scheduleIdleRelease() {
    guard transport != nil else { return }
    let mark = idle.mark()
    idleTask?.cancel()
    idleTask = Task { [idle, weak self] in
      await idle.waitForIdle()
      await self?.releaseIfIdle(mark)
    }
  }
  private func releaseIfIdle(_ mark: Int) {
    guard !busy, idle.isCurrent(mark), transport != nil else { return }
    log.info("\(self.name, privacy: .public) daemon released after idle")
    teardown()
  }

  /// One request at a time, first come first served: the gate is handed to the next waiter
  /// directly so a fresh call cannot jump the queue.
  private func acquire() async {
    guard busy else { busy = true; return }
    await withCheckedContinuation { waiters.append($0) }
  }
  private func release() {
    if waiters.isEmpty { busy = false } else { waiters.removeFirst().resume() }
  }
}

/// The real transport: the helper binary with JSON lines over stdin/stdout.
final class ProcessHelperTransport: HelperTransport, @unchecked Sendable {
  /// Enough for the tail of a Python traceback: when the kernel kills the helper, its stderr is the
  /// only thing it leaves behind.
  private static let diagnosticsLimit = 4096
  private let executable: URL
  private let arguments: [String]
  private let workingDirectory: URL?
  private let lock = NSLock()
  private var process: Process?
  private var input: FileHandle?
  private var output: Pipe?
  private var diagnostics: Pipe?
  private var continuation: AsyncStream<String>.Continuation?
  private var buffer = Data()
  private var diagnosticsTail = Data()
  private var work: URL?
  private var ownsWork = false
  /// `terminate()` and the process's own termination handler can land together; the second one must
  /// not add a third reader to the pipes it is draining.
  private var finishing = false

  init(executable: URL, arguments: [String], workingDirectory: URL? = nil) {
    self.executable = executable
    self.arguments = arguments
    self.workingDirectory = workingDirectory
  }
  deinit { terminate() }

  func start() async throws -> AsyncStream<String> {
    // The daemon outlives every job's work directory, so by default it gets its own TMPDIR.
    let work = workingDirectory ?? FileManager.default.temporaryDirectory
      .appendingPathComponent("HelperDaemon-\(UUID().uuidString)", isDirectory: true)
    do { try FileManager.default.createDirectory(at: work, withIntermediateDirectories: true) }
    catch { throw SubprocessError.launch(error.localizedDescription) }
    let process = Process(), stdin = Pipe(), stdout = Pipe(), stderr = Pipe()
    process.executableURL = executable
    process.arguments = arguments
    process.currentDirectoryURL = work
    process.environment = [
      "PATH": "/usr/bin:/bin:/usr/sbin:/sbin", "LANG": "en_US_POSIX",
      "TMPDIR": work.path, "TEMP": work.path, "TMP": work.path,
      "PYTHONDONTWRITEBYTECODE": "1", "PYTHONNOUSERSITE": "1",
    ]
    process.standardInput = stdin
    process.standardOutput = stdout
    process.standardError = stderr
    // A helper that died (an OOM kill) leaves a pipe with no reader: the next write must fail with
    // EPIPE, not raise SIGPIPE and take the whole app down with it.
    _ = fcntl(stdin.fileHandleForWriting.fileDescriptor, F_SETNOSIGPIPE, 1)
    // Both read ends are non-blocking. The final drain runs on the session actor's thread, and a
    // blocking `read` there — the handler having taken the bytes `poll` saw — parks the actor for as
    // long as the helper takes to die. `O_NONBLOCK` makes every read here return or fail at once.
    for descriptor in [stdout.fileHandleForReading.fileDescriptor, stderr.fileHandleForReading.fileDescriptor] {
      let flags = fcntl(descriptor, F_GETFL)
      if flags >= 0 { _ = fcntl(descriptor, F_SETFL, flags | O_NONBLOCK) }
    }
    let (stream, continuation) = AsyncStream<String>.makeStream()
    lock.withLock {
      self.process = process; input = stdin.fileHandleForWriting
      output = stdout; diagnostics = stderr
      self.continuation = continuation; buffer = Data(); diagnosticsTail = Data()
      self.work = work; ownsWork = workingDirectory == nil; finishing = false
    }
    stdout.fileHandleForReading.readabilityHandler = { [weak self] handle in self?.receive(Self.read(handle)) }
    // Torch writes warnings here. Keep draining so the pipe never fills and blocks the helper, and
    // keep the tail: it is the only diagnosis a killed helper leaves.
    stderr.fileHandleForReading.readabilityHandler = { [weak self] handle in self?.collect(Self.read(handle)) }
    process.terminationHandler = { [weak self] _ in self?.finish() }
    do { try process.run() }
    catch {
      finish()
      throw SubprocessError.launch(error.localizedDescription)
    }
    HelperProcessRegistry.shared.add(process)
    return stream
  }

  func send(_ line: String) async throws {
    let (handle, running) = lock.withLock { (input, process?.isRunning ?? false) }
    guard let handle, running else { throw SubprocessError.launch("helper is not running") }
    // The helper can die between that check and this write; EPIPE is a transport failure like any
    // other, and the session restarts the helper once.
    do { try handle.write(contentsOf: Data((line+"\n").utf8)) }
    catch { throw SubprocessError.launch(error.localizedDescription) }
  }

  func terminate() {
    lock.lock()
    let current = process, handle = input
    lock.unlock()
    try? handle?.close()
    if let current, current.isRunning { current.terminate() }
    finish()
  }

  private func receive(_ data: Data) {
    guard !data.isEmpty else { return }
    lock.lock()
    buffer.append(data)
    var lines: [String] = []
    while let index = buffer.firstIndex(of: 0x0A) {
      lines.append(String(decoding: buffer[buffer.startIndex..<index], as: UTF8.self))
      buffer = Data(buffer[buffer.index(after: index)...])
    }
    let stream = continuation
    lock.unlock()
    for line in lines where !line.trimmingCharacters(in: .whitespaces).isEmpty { stream?.yield(line) }
  }

  /// Keeps the tail of the helper's stderr, dropping the oldest bytes.
  private func collect(_ data: Data) {
    guard !data.isEmpty else { return }
    lock.lock()
    diagnosticsTail.append(data)
    if diagnosticsTail.count > Self.diagnosticsLimit {
      diagnosticsTail = Data(diagnosticsTail.suffix(Self.diagnosticsLimit))
    }
    lock.unlock()
  }

  /// Whatever is already readable, never a wait for more — the read ends are `O_NONBLOCK`, so an
  /// empty pipe fails with `EAGAIN` instead of parking the caller. Used by both readability handlers
  /// (where `availableData` would block on the very same descriptor) and by the final drain, which
  /// runs on the session actor's teardown path and must never wait for a helper to die.
  /// Capped at 4 MiB per call: a pipe that still has data leaves the descriptor readable, so the
  /// handler is simply called again.
  private static func read(_ handle: FileHandle) -> Data {
    let descriptor = handle.fileDescriptor
    guard descriptor >= 0 else { return Data() }
    var data = Data(), chunk = [UInt8](repeating: 0, count: 64*1024)
    for _ in 0..<64 {
      let count = chunk.withUnsafeMutableBytes { Darwin.read(descriptor, $0.baseAddress, $0.count) }
      if count > 0 { data.append(contentsOf: chunk[0..<count]); continue }
      // 0 is EOF; anything else is EAGAIN on an empty pipe, or a descriptor that is already gone.
      if count < 0 && errno == EINTR { continue }
      break
    }
    return data
  }

  /// The stderr tail as one protocol line, so the session learns why the helper died without the
  /// transport knowing anything about the session. JSON-escaped and capped at 4 KiB.
  private static func diagnosticsLine(_ tail: Data) -> String? {
    var text = String(decoding: tail, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
    guard !text.isEmpty else { return nil }
    while true {
      guard let data = try? JSONSerialization.data(withJSONObject: ["status": "stderr", "tail": text]) else { return nil }
      if data.count <= diagnosticsLimit || text.count <= 1 { return String(decoding: data, as: UTF8.self) }
      text = String(text.dropFirst(text.count/4 + 1))
    }
  }

  private func finish() {
    lock.lock()
    guard !finishing, process != nil || continuation != nil else { return lock.unlock() }
    finishing = true
    let stdout = output, stderr = diagnostics
    lock.unlock()
    stdout?.fileHandleForReading.readabilityHandler = nil
    stderr?.fileHandleForReading.readabilityHandler = nil
    // The helper's last line and its exit are one event. Drain both pipes while the stream is still
    // open, or the `complete` line it wrote on its way out is lost and the session reports a death.
    if let stdout { receive(Self.read(stdout.fileHandleForReading)) }
    if let stderr { collect(Self.read(stderr.fileHandleForReading)) }
    lock.lock()
    let stream = continuation, current = process, handle = input
    let tail = diagnosticsTail
    let directory = ownsWork ? work : nil
    continuation = nil; process = nil; input = nil; output = nil; diagnostics = nil
    diagnosticsTail = Data(); work = nil; ownsWork = false; finishing = false
    lock.unlock()
    if let current { HelperProcessRegistry.shared.remove(current) }
    try? handle?.close()
    if let line = Self.diagnosticsLine(tail) { stream?.yield(line) }
    stream?.finish()
    if let directory { try? FileManager.default.removeItem(at: directory) }
  }
}

/// App quit must not leave a multi-gigabyte helper behind. Closing stdin already ends it, but the
/// app may die before that is observed, so every live helper is terminated synchronously on quit.
final class HelperProcessRegistry: @unchecked Sendable {
  static let shared = HelperProcessRegistry()
  private let lock = NSLock()
  private var processes: [Process] = []
  private var observer: (any NSObjectProtocol)?

  func add(_ process: Process) {
    lock.lock()
    processes.append(process)
    if observer == nil {
      observer = NotificationCenter.default.addObserver(
        forName: NSApplication.willTerminateNotification, object: nil, queue: nil) { _ in
        HelperProcessRegistry.shared.terminateAll()
      }
    }
    lock.unlock()
  }
  func remove(_ process: Process) {
    lock.lock()
    processes.removeAll { $0 === process }
    lock.unlock()
  }
  func terminateAll() {
    lock.lock()
    let live = processes
    processes = []
    lock.unlock()
    for process in live where process.isRunning { process.terminate() }
  }
}
