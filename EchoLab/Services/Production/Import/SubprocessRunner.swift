import Foundation
import Darwin

struct SubprocessOutput: Equatable, Sendable {
  let exitStatus: Int32
  let standardOutput: String
  let standardError: String
}

enum SubprocessError: Error, Equatable, LocalizedError, Sendable {
  case launch(String)
  case unsuccessful(exitStatus: Int32, diagnostics: String)
  case cancelled

  var errorDescription: String? {
    switch self {
    case .launch(let detail): "Import helper could not start: \(detail)"
    case .unsuccessful(let status, let diagnostics): "Import helper exited with status \(status): \(diagnostics)"
    case .cancelled: "Import helper was cancelled."
    }
  }
}

actor SubprocessRunner {
  private static let diagnosticLimit = 32 * 1_024
  private static let cancellationGrace: TimeInterval = 2

  func run(
    executable: URL,
    arguments: [String],
    currentDirectory: URL? = nil,
    onOutput: @escaping @Sendable (String) -> Void = { _ in }
  ) async throws -> SubprocessOutput {
    let helperTemporaryDirectory = (currentDirectory ?? FileManager.default.temporaryDirectory)
      .appendingPathComponent("HelperTemporaryFiles", isDirectory: true)
    do {
      try FileManager.default.createDirectory(
        at: helperTemporaryDirectory, withIntermediateDirectories: true)
    } catch {
      throw SubprocessError.launch(
        "Could not create helper temporary directory: \(error.localizedDescription)")
    }
    let helperEnvironment = [
      "PATH": "/usr/bin:/bin:/usr/sbin:/sbin",
      "LANG": "en_US_POSIX",
      "TMPDIR": helperTemporaryDirectory.path,
      "TEMP": helperTemporaryDirectory.path,
      "TMP": helperTemporaryDirectory.path,
      "PYTHONDONTWRITEBYTECODE": "1",
      "PYTHONNOUSERSITE": "1",
    ]
    let active = ActiveProcess()
    return try await withTaskCancellationHandler(operation: {
      try await withCheckedThrowingContinuation { continuation in
        let process = Process()
        let stdout = Pipe()
        let stderr = Pipe()
        let output = OutputBuffer(limit: Self.diagnosticLimit)
        process.executableURL = executable
        process.arguments = arguments
        process.currentDirectoryURL = currentDirectory
        process.environment = helperEnvironment
        process.standardOutput = stdout
        process.standardError = stderr
        active.set(process)
        let receive: @Sendable (FileHandle, Bool) -> Void = { handle, isError in
          let data = handle.availableData
          guard !data.isEmpty else { return }
          let text = String(decoding: data, as: UTF8.self)
          output.append(text, isError: isError)
          onOutput(text)
        }
        stdout.fileHandleForReading.readabilityHandler = { receive($0, false) }
        stderr.fileHandleForReading.readabilityHandler = { receive($0, true) }
        process.terminationHandler = { completed in
          stdout.fileHandleForReading.readabilityHandler = nil
          stderr.fileHandleForReading.readabilityHandler = nil
          receive(stdout.fileHandleForReading, false)
          receive(stderr.fileHandleForReading, true)
          active.clear()
          let result = SubprocessOutput(
            exitStatus: completed.terminationStatus,
            standardOutput: output.standardOutput,
            standardError: output.standardError)
          if active.wasCancelled { continuation.resume(throwing: SubprocessError.cancelled) }
          else if completed.terminationStatus == 0 { continuation.resume(returning: result) }
          else {
            continuation.resume(
              throwing: SubprocessError.unsuccessful(
                exitStatus: result.exitStatus, diagnostics: output.diagnostics))
          }
        }
        do { try process.run() }
        catch {
          stdout.fileHandleForReading.readabilityHandler = nil
          stderr.fileHandleForReading.readabilityHandler = nil
          active.clear()
          continuation.resume(throwing: SubprocessError.launch(error.localizedDescription))
        }
      }
    }, onCancel: {
      active.cancel(after: Self.cancellationGrace)
    })
  }
}

private final class ActiveProcess: @unchecked Sendable {
  private let lock = NSLock()
  private var process: Process?
  private var cancelled = false

  func set(_ process: Process) { lock.lock(); self.process = process; lock.unlock() }
  func clear() { lock.lock(); process = nil; lock.unlock() }
  var wasCancelled: Bool { lock.lock(); defer { lock.unlock() }; return cancelled }
  func cancel(after grace: TimeInterval) {
    lock.lock()
    cancelled = true
    let target = process
    lock.unlock()
    target?.terminate()
    DispatchQueue.global().asyncAfter(deadline: .now() + grace) { [weak self, weak target] in
      guard let self, let target else { return }
      self.lock.lock(); let stillCurrent = self.process === target; self.lock.unlock()
      if stillCurrent && target.isRunning { kill(target.processIdentifier, SIGKILL) }
    }
  }
}

private final class OutputBuffer: @unchecked Sendable {
  private let lock = NSLock()
  private let limit: Int
  private var stdout = ""
  private var stderr = ""

  init(limit: Int) { self.limit = limit }
  func append(_ text: String, isError: Bool) {
    lock.lock()
    defer { lock.unlock() }
    if isError { stderr = bounded(stderr + text) }
    else { stdout = bounded(stdout + text) }
  }
  var standardOutput: String { lock.lock(); defer { lock.unlock() }; return stdout }
  var standardError: String { lock.lock(); defer { lock.unlock() }; return stderr }
  var diagnostics: String { standardError.isEmpty ? standardOutput : standardError }
  private func bounded(_ value: String) -> String {
    guard value.utf8.count > limit else { return value }
    return String(decoding: value.utf8.suffix(limit), as: UTF8.self)
  }
}
