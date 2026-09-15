import AppKit
import Observation
import OSLog
import SwiftUI
import WebKit

/// Commands are intentionally driven by the native source-audio clock. The
/// embedded player is a muted visual follower, never an alternate transport.
private enum YouTubeFollowerCommand: Encodable, Equatable {
  case cue(videoID: String, at: TimeInterval)
  case follow(at: TimeInterval)
  case pause

  enum CodingKeys: String, CodingKey { case action, videoID, seconds }
  enum Action: String, Encodable { case cue, follow, pause }

  func encode(to encoder: Encoder) throws {
    var container = encoder.container(keyedBy: CodingKeys.self)
    switch self {
    case .cue(let videoID, let seconds):
      try container.encode(Action.cue, forKey: .action)
      try container.encode(videoID, forKey: .videoID)
      try container.encode(seconds, forKey: .seconds)
    case .follow(let seconds):
      try container.encode(Action.follow, forKey: .action)
      try container.encode(seconds, forKey: .seconds)
    case .pause:
      try container.encode(Action.pause, forKey: .action)
    }
  }
}

enum YouTubeFollowerState: Equatable {
  case idle
  case loading
  case following
  case paused
  case unavailable
  case offline
}

@MainActor @Observable
final class YouTubeVideoFollower {
  private(set) var state: YouTubeFollowerState = .idle
  fileprivate private(set) var command: YouTubeFollowerCommand?
  private(set) var commandGeneration = 0
  /// Captions ride their own generation so a frequent follow tick can never
  /// coalesce the toggle out of the single command slot before it is applied.
  private(set) var captionsEnabled = false
  private(set) var captionGeneration = 0
  private(set) var pageID = UUID()
  private(set) var lastErrorCode: Int?
  fileprivate var source: YouTubeVisualSource?
  private let logger = Logger(subsystem: "com.unknownstudio.tospeech", category: "YouTubeFollower")
  private var lastFollowedSeconds: TimeInterval?
  private var wasFollowing = false

  func configure(source: YouTubeVisualSource?) {
    guard self.source != source else { return }
    self.source = source
    pageID = UUID()
    lastErrorCode = nil
    lastFollowedSeconds = nil
    wasFollowing = false
    guard let source else {
      state = .idle
      issue(.pause)
      return
    }
    state = .loading
    issue(.cue(videoID: source.videoID, at: 0))
  }

  /// Call from the native audio transport only. During countdown/capture the
  /// video is paused, which prevents source playback from overlapping a take.
  func follow(sourceSeconds: TimeInterval, isNativeAudioPlaying: Bool) {
    guard source != nil else { return }
    guard sourceSeconds.isFinite, sourceSeconds >= 0 else { return }
    guard state != .unavailable, state != .offline else { return }
    guard isNativeAudioPlaying else {
      if wasFollowing { issue(.pause) }
      wasFollowing = false
      if state != .loading { state = .paused }
      return
    }

    let needsSeek =
      !wasFollowing
      || lastFollowedSeconds.map { abs($0 - sourceSeconds) >= 0.45 } ?? true
    if needsSeek { issue(.follow(at: sourceSeconds)) }
    lastFollowedSeconds = sourceSeconds
    wasFollowing = true
    state = .following
  }

  func setCaptions(_ enabled: Bool) {
    guard captionsEnabled != enabled else { return }
    captionsEnabled = enabled
    captionGeneration &+= 1
  }

  func retry() {
    guard let source else { return }
    pageID = UUID()
    lastErrorCode = nil
    lastFollowedSeconds = nil
    wasFollowing = false
    state = .loading
    issue(.cue(videoID: source.videoID, at: 0))
  }

  func receive(event: String, code: Int? = nil) {
    switch event {
    case "ready":
      if state == .loading { state = .paused }
    case "error":
      // YouTube's error codes are intentionally not mapped to a fake recovery.
      // The source audio remains usable and the view falls back to its thumbnail.
      lastErrorCode = code
      logger.error("YouTube embedded player failed; code=\(code ?? -1)")
      state = .unavailable
      wasFollowing = false
    case "offline":
      state = .offline
      wasFollowing = false
    default: break
    }
  }

  private func issue(_ next: YouTubeFollowerCommand) {
    command = next
    commandGeneration &+= 1
  }
}

/// The embedded player is a muted visual follower driven entirely by the app.
/// Swallowing all hit testing keeps every transport control in the native UI:
/// clicks, scrolls and taps never reach the YouTube iframe.
private final class NonInteractiveWebView: WKWebView {
  override func hitTest(_ point: NSPoint) -> NSView? { nil }
}

/// A narrow WebKit surface for the trusted, bundled parent page. It permits
/// only YouTube child-frame navigations and accepts status messages only from
/// its own main frame.
struct YouTubeVideoFollowerView: NSViewRepresentable {
  @Bindable var follower: YouTubeVideoFollower
  /// Explicit inputs so clock commands and the caption toggle invalidate the
  /// representable even when the follower reference and visible status have not
  /// changed.
  var commandGeneration: Int
  var captionGeneration: Int

  func makeCoordinator() -> Coordinator { Coordinator(follower: follower) }

  func makeNSView(context: Context) -> WKWebView {
    let configuration = WKWebViewConfiguration()
    configuration.userContentController.add(context.coordinator, name: "toSpeechYouTube")
    configuration.allowsAirPlayForMediaPlayback = false
    configuration.mediaTypesRequiringUserActionForPlayback = []
    let webView = NonInteractiveWebView(frame: .zero, configuration: configuration)
    webView.navigationDelegate = context.coordinator
    webView.setValue(false, forKey: "drawsBackground")
    // YouTube requires an HTTPS app identity as Referer, including in macOS
    // WebViews. A file:// base strips that header and the player returns 153.
    webView.loadHTMLString(Self.document, baseURL: Self.applicationOrigin)
    return webView
  }

  func updateNSView(_ webView: WKWebView, context: Context) {
    context.coordinator.follower = follower
    context.coordinator.applyPendingCommand(to: webView)
    context.coordinator.applyPendingCaptions(to: webView)
  }

  static func dismantleNSView(_ webView: WKWebView, coordinator: Coordinator) {
    webView.configuration.userContentController.removeScriptMessageHandler(
      forName: "toSpeechYouTube")
    webView.stopLoading()
  }

  final class Coordinator: NSObject, WKNavigationDelegate, WKScriptMessageHandler {
    var follower: YouTubeVideoFollower
    var lastGeneration = -1
    var lastCaptionGeneration = -1
    private var parentPageFinished = false
    private var initializedSource = false
    private let pageID: UUID

    init(follower: YouTubeVideoFollower) {
      self.follower = follower
      pageID = follower.pageID
    }

    func applyPendingCommand(to webView: WKWebView) {
      guard pageID == follower.pageID, parentPageFinished, lastGeneration != follower.commandGeneration,
        let command = follower.command,
        let data = try? JSONEncoder().encode(command),
        let json = String(data: data, encoding: .utf8)
      else { return }
      var script = ""
      // A source-audio tick can replace the cue before the page finishes loading.
      // Always initialize the video first, then deliver the latest transport intent.
      if !initializedSource, let source = follower.source,
        let cue = try? JSONEncoder().encode(YouTubeFollowerCommand.cue(videoID: source.videoID, at: 0)),
        let cueJSON = String(data: cue, encoding: .utf8)
      {
        script += "window.ToSpeechVideo.dispatch(\(cueJSON));"
        initializedSource = true
      }
      lastGeneration = follower.commandGeneration
      script += "window.ToSpeechVideo.dispatch(\(json));"
      webView.evaluateJavaScript(script) { [weak self] _, error in
        guard let self, self.pageID == self.follower.pageID, error != nil else { return }
        self.follower.receive(event: "error")
      }
    }

    /// Captions are idempotent and independent of the transport slot, so they
    /// carry their own generation and are reasserted whenever the toggle moves.
    func applyPendingCaptions(to webView: WKWebView) {
      guard pageID == follower.pageID, parentPageFinished,
        lastCaptionGeneration != follower.captionGeneration
      else { return }
      lastCaptionGeneration = follower.captionGeneration
      webView.evaluateJavaScript(
        "window.ToSpeechVideo.setCaptions(\(follower.captionsEnabled));", completionHandler: nil)
    }

    func userContentController(
      _ userContentController: WKUserContentController, didReceive message: WKScriptMessage
    ) {
      guard pageID == follower.pageID, message.name == "toSpeechYouTube", message.frameInfo.isMainFrame,
        let body = message.body as? [String: Any], let event = body["event"] as? String
      else { return }
      follower.receive(event: event, code: body["code"] as? Int)
    }

    func webView(
      _ webView: WKWebView, decidePolicyFor navigationAction: WKNavigationAction
    ) async -> WKNavigationActionPolicy {
      guard let url = navigationAction.request.url else { return .cancel }
      if navigationAction.targetFrame?.isMainFrame != false {
        return url == YouTubeVideoFollowerView.applicationOrigin || url.absoluteString == "about:blank"
          ? .allow : .cancel
      }
      let host = url.host?.lowercased() ?? ""
      let allowed = [
        "youtube.com", "www.youtube.com", "youtube-nocookie.com", "www.youtube-nocookie.com",
      ]
      return url.scheme == "https" && allowed.contains(host) ? .allow : .cancel
    }

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
      parentPageFinished = true
      applyPendingCommand(to: webView)
      applyPendingCaptions(to: webView)
    }

    func webView(
      _ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error
    ) {
      guard pageID == follower.pageID else { return }
      follower.receive(event: "offline")
    }

    func webView(
      _ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!,
      withError error: Error
    ) {
      guard pageID == follower.pageID else { return }
      follower.receive(event: "offline")
    }
  }

  static var applicationOrigin: URL {
    URL(string: "https://\((Bundle.main.bundleIdentifier ?? "com.unknownstudio.tospeech").lowercased())/")!
  }

  static let document = """
    <!doctype html><html><head><meta charset="utf-8">
    <meta name="referrer" content="strict-origin-when-cross-origin"><style>
    html,body,#player{width:100%;height:100%;margin:0;background:#111318;overflow:hidden}
    /* The player is a muted visual follower; blocking pointer events stops every
       hover chrome and click from ever reaching the cross-origin iframe. */
    #player,iframe{pointer-events:none!important}
    </style></head><body><div id="player"></div><script>
    \(playerScript)
    </script><script src="https://www.youtube.com/iframe_api" onerror="notify('offline')"></script></body></html>
    """

  static let playerScript = """
    const notify=(event,code)=>window.webkit.messageHandlers.toSpeechYouTube.postMessage({event,code});
    let apiLoaded=false, player=null, playerReady=false, source=null, desired={action:'pause'};
    let captionsOn=false;
    function applyTransport() {
      if (!playerReady) return;
      player.mute(); player.setVolume(0);
      if (desired.action === 'follow') {
        player.seekTo(desired.seconds, true); player.playVideo();
      } else player.pauseVideo();
    }
    // Module names differ across player versions ('captions' vs legacy 'cc');
    // acting on both keeps the toggle reliable regardless of which is active.
    function applyCaptions() {
      if (!playerReady) return;
      try {
        if (captionsOn) {
          player.loadModule('captions'); player.loadModule('cc');
        } else {
          // setOption clears the visible track immediately; unloadModule keeps it
          // from reappearing once the module (re)loads on playback.
          try { player.setOption('captions', 'track', {}); } catch (e) {}
          try { player.setOption('cc', 'track', {}); } catch (e) {}
          player.unloadModule('captions'); player.unloadModule('cc');
        }
      } catch (e) {}
    }
    function cueSource() {
      if (!apiLoaded || !source) return;
      if (!player) {
        player = new YT.Player('player', {
          videoId:source.videoID,
          playerVars:{controls:0,rel:0,playsinline:1,cc_load_policy:0,origin:window.location.origin},
          events:{
            onReady: e => {
              playerReady=true; e.target.mute(); e.target.setVolume(0);
              notify('ready'); applyTransport(); applyCaptions();
            },
            // The captions module becomes controllable only here; reasserting the
            // desired state fixes captions showing until the user toggled them.
            onApiChange: e => applyCaptions(),
            onError: e => notify('error', e.data)
          }
        });
      } else if (playerReady) {
        player.mute(); player.cueVideoById({videoId:source.videoID,startSeconds:source.seconds});
        applyTransport();
      }
    }
    function perform(command) {
      if (command.action === 'cue') {
        source=command; desired={action:'pause'}; cueSource();
      } else {
        desired=command; applyTransport();
      }
    }
    window.ToSpeechVideo={dispatch:perform,setCaptions:(on)=>{captionsOn=on;applyCaptions();}};
    function onYouTubeIframeAPIReady(){apiLoaded=true;cueSource();}
    """
}
