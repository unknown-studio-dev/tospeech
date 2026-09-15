import Foundation
import SQLite3

struct OfflineIPAPronunciation: Codable, Equatable, Sendable {
  let ipa: String
  let source: String
  let sourceRevision: String
}

enum OfflineIPADictionaryError: Error, Equatable, LocalizedError, Sendable {
  case resourceMissing
  case databaseOpen(String)
  case query(String)

  var errorDescription: String? {
    switch self {
    case .resourceMissing: "The bundled offline IPA dictionary is missing."
    case .databaseOpen(let detail): "The offline IPA dictionary could not open: \(detail)"
    case .query(let detail): "The offline IPA dictionary could not be queried: \(detail)"
    }
  }
}

/// Read-only lookup over the release-built IPA database. A missing entry is an
/// honest result, not a request to generate or fetch a pronunciation remotely.
actor OfflineIPADictionary {
  private final class SQLiteHandle: @unchecked Sendable {
    let raw: OpaquePointer
    init(_ raw: OpaquePointer) { self.raw = raw }
    deinit { sqlite3_close_v2(raw) }
  }

  private let connection: SQLiteHandle
  private var database: OpaquePointer { connection.raw }

  init(url: URL) throws {
    var opened: OpaquePointer?
    guard
      sqlite3_open_v2(url.path, &opened, SQLITE_OPEN_READONLY | SQLITE_OPEN_FULLMUTEX, nil)
        == SQLITE_OK, let opened
    else {
      let detail = opened.map { String(cString: sqlite3_errmsg($0)) } ?? "Unknown SQLite error"
      if let opened { sqlite3_close_v2(opened) }
      throw OfflineIPADictionaryError.databaseOpen(detail)
    }
    connection = SQLiteHandle(opened)
  }

  static func bundled(bundle: Bundle = .main) throws -> OfflineIPADictionary {
    guard let url = bundle.url(forResource: "ipa", withExtension: "sqlite")
    else { throw OfflineIPADictionaryError.resourceMissing }
    return try OfflineIPADictionary(url: url)
  }

  func pronunciations(for word: String, accent: ReferenceAccent) throws -> [OfflineIPAPronunciation]
  {
    let key = Self.lookupKey(for: word)
    guard !key.isEmpty else { return [] }
    var statement: OpaquePointer?
    let sql = """
      SELECT ipa, source, source_revision
      FROM pronunciations
      WHERE accent = ? AND lookup_key = ?
      ORDER BY variant
      """
    guard sqlite3_prepare_v2(database, sql, -1, &statement, nil) == SQLITE_OK, let statement else {
      throw OfflineIPADictionaryError.query(String(cString: sqlite3_errmsg(database)))
    }
    defer { sqlite3_finalize(statement) }
    sqlite3_bind_text(
      statement, 1, accent == .uk ? "uk" : "us", -1,
      unsafeBitCast(-1, to: sqlite3_destructor_type.self))
    sqlite3_bind_text(
      statement, 2, key, -1, unsafeBitCast(-1, to: sqlite3_destructor_type.self))

    var results: [OfflineIPAPronunciation] = []
    while true {
      let status = sqlite3_step(statement)
      if status == SQLITE_DONE { break }
      guard status == SQLITE_ROW else {
        throw OfflineIPADictionaryError.query(String(cString: sqlite3_errmsg(database)))
      }
      guard let ipa = sqlite3_column_text(statement, 0),
        let source = sqlite3_column_text(statement, 1),
        let revision = sqlite3_column_text(statement, 2)
      else { throw OfflineIPADictionaryError.query("A pronunciation row was invalid.") }
      results.append(
        OfflineIPAPronunciation(
          ipa: String(cString: ipa), source: String(cString: source),
          sourceRevision: String(cString: revision)))
    }
    return results
  }

  /// Every stored pronunciation for one accent; used by tests to check the
  /// bundled data against the app's phone inventory.
  func allPronunciations(accent: ReferenceAccent) throws -> [(lookupKey: String, ipa: String, source: String)] {
    var statement: OpaquePointer?
    let sql = "SELECT lookup_key, ipa, source FROM pronunciations WHERE accent = ?"
    guard sqlite3_prepare_v2(database, sql, -1, &statement, nil) == SQLITE_OK, let statement else {
      throw OfflineIPADictionaryError.query(String(cString: sqlite3_errmsg(database)))
    }
    defer { sqlite3_finalize(statement) }
    sqlite3_bind_text(
      statement, 1, accent == .uk ? "uk" : "us", -1,
      unsafeBitCast(-1, to: sqlite3_destructor_type.self))
    var results: [(lookupKey: String, ipa: String, source: String)] = []
    while sqlite3_step(statement) == SQLITE_ROW {
      guard let key = sqlite3_column_text(statement, 0), let ipa = sqlite3_column_text(statement, 1),
        let source = sqlite3_column_text(statement, 2)
      else { throw OfflineIPADictionaryError.query("A pronunciation row was invalid.") }
      results.append((String(cString: key), String(cString: ipa), String(cString: source)))
    }
    return results
  }

  /// The spelling as stored in the database: lowercase letters, digits, apostrophe, hyphen.
  nonisolated static func lookupKey(for word: String) -> String {
    word.lowercased().replacingOccurrences(of: "’", with: "'").filter {
      $0.isLetter || $0.isNumber || $0 == "'" || $0 == "-" || $0 == "_"
    }
  }
}
