import Foundation

enum EngineID: String, CaseIterable, Codable, Identifiable, Sendable {
  case phone, buddy, compact, ukReference, phoneticXeus
  var id: String { rawValue }
  var title: String {
    switch self {
    case .phone: "Phone Accentedness Scorer"
    case .buddy: "Buddy Pronunciation"
    case .compact: "Compact pronunciation engine"
    case .ukReference: "UK Reference"
    case .phoneticXeus: "PhoneticXeus · UK Experimental"
    }
  }
}

enum PackageStatus: String, Codable, Sendable {
  case unavailable, notInstalled, downloading, verifying, installed, failed
}

struct ModelPackage: Identifiable, Codable, Equatable, Sendable {
  var id: EngineID
  var subtitle: String
  var footprint: String
  var details: String
  var available: Bool
  var status: PackageStatus
  var progress: Double = 0
  var error: String?
}
