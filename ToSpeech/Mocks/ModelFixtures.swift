import Foundation

enum ModelFixtures {
  static let packages = [
    ModelPackage(
      id: .phone, subtitle: "Sound-by-sound feedback · US English",
      footprint: "9.24M parameters reported · total package unknown",
      details:
        "Whisper-tiny encoder. Local runtime, redistribution rights and real-speaker accuracy require validation. Installed is a preview fixture.",
      available: true, status: .installed),
    ModelPackage(
      id: .buddy, subtitle: "ONNX phoneme recognition · English",
      footprint: "357 MB checkpoint reported · total unknown",
      details:
        "Needs a calibrated scorer, a verified local bundle and license review. Not available for installation yet.",
      available: false, status: .unavailable),
    ModelPackage(
      id: .compact, subtitle: "Fabio Suizu · proprietary candidate",
      footprint: "17 MB claimed · local SDK unverified",
      details:
        "No verified local SDK, downloadable weights or redistribution rights. This is not an available integration.",
      available: false, status: .unavailable),
  ]
}
