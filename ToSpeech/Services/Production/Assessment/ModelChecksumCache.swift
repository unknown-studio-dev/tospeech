import Darwin
import Foundation

/// Remembers the SHA-256 of a model file so one process hashes it once per file version.
///
/// Package integrity is checked before every assessment, and the files are large: PhoneticXeus'
/// `model.safetensors` is 2,3 GB and the UK package's `pytorch_model.bin` 1,26 GB, so re-hashing them per
/// job cost ≈3 s of every job's latency (latency plan, W7). The bytes of a file cannot change
/// without its size, modification time or identity (device + inode) changing, so each hash is kept
/// against that stamp and recomputed as soon as `stat` disagrees — a replaced, repaired or tampered
/// file is hashed again and still has to match.
///
/// Deliberately not thread safe: one cache lives inside the package actor that owns those files, and
/// fresh installs keep hashing every byte they download or copy.
final class ModelChecksumCache {
  private struct Stamp: Equatable {
    let device: dev_t, inode: ino_t, size: off_t, seconds: Int, nanoseconds: Int
  }
  private let hasher: (URL) throws -> String
  private var entries: [String: (stamp: Stamp, hash: String)] = [:]

  init(hasher: @escaping (URL) throws -> String = { try BuddyModelPackage.checksum($0) }) {
    self.hasher = hasher
  }

  /// The file's SHA-256, computed at most once per (path, stamp).
  func hash(_ url: URL) throws -> String {
    // Stat first: a file that changes while it is being hashed keeps the older stamp, so the next
    // call sees the mismatch and hashes again.
    let stamp = Self.stamp(url)
    if let entry = entries[url.path], let stamp, entry.stamp == stamp { return entry.hash }
    let hash = try hasher(url)
    if let stamp { entries[url.path] = (stamp, hash) } else { entries[url.path] = nil }
    return hash
  }

  private static func stamp(_ url: URL) -> Stamp? {
    var info = stat()
    guard stat(url.path, &info) == 0 else { return nil }
    return .init(device: info.st_dev, inode: info.st_ino, size: info.st_size,
      seconds: info.st_mtimespec.tv_sec, nanoseconds: info.st_mtimespec.tv_nsec)
  }
}
