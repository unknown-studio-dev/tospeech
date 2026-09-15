import Foundation

let arguments = CommandLine.arguments
precondition(arguments.count == 3, "usage: fix-macho-uuid <file> <UUID>")
let fileURL = URL(fileURLWithPath: arguments[1])
let hex = arguments[2].replacingOccurrences(of: "-", with: "")
precondition(hex.count == 32)
let uuid = stride(from: 0, to: hex.count, by: 2).map { offset in
  UInt8(hex[hex.index(hex.startIndex, offsetBy: offset)...hex.index(hex.startIndex, offsetBy: offset + 1)], radix: 16)!
}
var data = try Data(contentsOf: fileURL)
func value32(at offset: Int) -> UInt32 {
  data.withUnsafeBytes { $0.loadUnaligned(fromByteOffset: offset, as: UInt32.self).littleEndian }
}
precondition(value32(at: 0) == 0xFEEDFACF, "expected a 64-bit little-endian Mach-O")
let commandCount = Int(value32(at: 16))
var offset = 32
for _ in 0..<commandCount {
  let command = value32(at: offset)
  let size = Int(value32(at: offset + 4))
  precondition(size >= 8 && offset + size <= data.count, "malformed Mach-O load command")
  if command == 0x1B {
    data.replaceSubrange((offset + 8)..<(offset + 24), with: uuid)
    try data.write(to: fileURL, options: .atomic)
    exit(EXIT_SUCCESS)
  }
  offset += size
}
fatalError("LC_UUID was not found")
