import Foundation

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
