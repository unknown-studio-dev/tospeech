#if DEBUG
import AppKit
import SwiftUI

@MainActor enum DictationNativeProbe {
  static func run() async throws {
    let audio = DictationPreviewAudio()
    let model = DictationModel(storage: DictationMemoryStorage(), player: audio)
    try await model.activate(DictationFixtures.sentences())
    let store = EchoStore(snapshot: PreviewFixtures.snapshot(), repository: .memory)
    guard let lesson = store.selectedLesson else { throw CocoaError(.coderValueNotFound) }
    let host = NSHostingView(rootView: DictationView(model: model,
      layout: .init(contentWidth: 1032, contentHeight: 752), lesson: lesson)
      .environment(store).environment(\.locale, Locale(identifier: "en")))
    let window = NSWindow(contentRect: .init(x: 0, y: 0, width: 1032, height: 752),
      styleMask: [.titled, .closable], backing: .buffered, defer: false)
    window.isReleasedWhenClosed = false
    window.contentView = host
    window.makeKeyAndOrderFront(nil)
    defer { model.suspend(); window.orderOut(nil); window.contentView = nil; window.close() }
    try await Task.sleep(for: .milliseconds(200))
    print("DICTATION_PROBE initial editor=\(textView(host) != nil) editable=\(textView(host)?.isEditable.description ?? "nil") canEdit=\(model.canEdit)")
    guard !model.canEdit else { throw CocoaError(.coderInvalidValue) }
    model.setLimit(nil); model.play(); audio.finish()
    try await Task.sleep(for: .milliseconds(200))
    print("DICTATION_PROBE unlocked editor=\(textView(host) != nil) editable=\(textView(host)?.isEditable.description ?? "nil")")
    guard let editor = textView(host), editor.isEditable, window.makeFirstResponder(editor)
    else { throw CocoaError(.coderInvalidValue) }
    editor.insertText("I", replacementRange: .init(location: 0, length: 0))
    guard let space = NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [],
      timestamp: 0, windowNumber: window.windowNumber, context: nil, characters: " ",
      charactersIgnoringModifiers: " ", isARepeat: false, keyCode: 49) else { throw CocoaError(.coderInvalidValue) }
    editor.keyDown(with: space)
    editor.insertText("never thought it would make such a difference.", replacementRange: editor.selectedRange())
    try await Task.sleep(for: .milliseconds(100))
    print("DICTATION_PROBE typed=\(model.current?.draft.answer ?? "nil")")
    guard model.current?.draft.answer == "I never thought it would make such a difference.",
      audio.played.count == 1 else { throw CocoaError(.coderInvalidValue) }
    print("DICTATION_PROBE checking replay")
    guard let replay = key("r", code: 15, window: window), window.performKeyEquivalent(with: replay)
    else { throw CocoaError(.coderInvalidValue) }
    try await Task.sleep(for: .milliseconds(100))
    guard audio.played.count == 2 else { throw CocoaError(.coderInvalidValue) }
    audio.finish()
    print("DICTATION_PROBE checking submit")
    guard let submit = key("\r", code: 36, window: window), window.performKeyEquivalent(with: submit)
    else { throw CocoaError(.coderInvalidValue) }
    try await Task.sleep(for: .milliseconds(100))
    guard model.phase == .result, model.attempt?.isExact == true else { throw CocoaError(.coderInvalidValue) }
    await model.flush()
    print("DICTATION_NATIVE_PROBE PASS: disabled before listen; native text input; Space types; Cmd-R replays; Cmd-Return submits 9/9; persistence flushed.")
  }

  private static func key(_ text: String, code: UInt16, window: NSWindow) -> NSEvent? {
    NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: .command,
      timestamp: 0, windowNumber: window.windowNumber, context: nil,
      characters: text, charactersIgnoringModifiers: text, isARepeat: false, keyCode: code)
  }
  private static func textView(_ view: NSView) -> NSTextView? {
    if let text = view as? NSTextView { return text }
    for child in view.subviews { if let text = textView(child) { return text } }
    return nil
  }
}
#endif
