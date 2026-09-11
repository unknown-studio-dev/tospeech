import AppKit
import Observation
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
  private var source: YouTubeVisualSource?
  private var lastFollowedSeconds: TimeInterval?
  private var wasFollowing = false

  func configure(source: YouTubeVisualSource?) {
    guard self.source != source else { return }
    self.source = source
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

  func retry() {
    guard let source else { return }
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
      _ = code
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

/// A narrow WebKit surface for the trusted, bundled parent page. It permits
/// only YouTube child-frame navigations and accepts status messages only from
/// its own main frame.
struct YouTubeVideoFollowerView: NSViewRepresentable {
  @Bindable var follower: YouTubeVideoFollower

  func makeCoordinator() -> Coordinator { Coordinator(follower: follower) }

  func makeNSView(context: Context) -> WKWebView {
    let configuration = WKWebViewConfiguration()
    configuration.userContentController.add(context.coordinator, name: "echoLabYouTube")
    configuration.allowsAirPlayForMediaPlayback = false
    let webView = WKWebView(frame: .zero, configuration: configuration)
    webView.navigationDelegate = context.coordinator
    webView.setValue(false, forKey: "drawsBackground")
    webView.loadHTMLString(Self.document, baseURL: Bundle.main.resourceURL)
    return webView
  }

  func updateNSView(_ webView: WKWebView, context: Context) {
    context.coordinator.follower = follower
    context.coordinator.applyPendingCommand(to: webView)
  }

  static func dismantleNSView(_ webView: WKWebView, coordinator: Coordinator) {
    webView.configuration.userContentController.removeScriptMessageHandler(
      forName: "echoLabYouTube")
    webView.stopLoading()
  }

  final class Coordinator: NSObject, WKNavigationDelegate, WKScriptMessageHandler {
    var follower: YouTubeVideoFollower
    var lastGeneration = -1
    private var parentPageFinished = false

    init(follower: YouTubeVideoFollower) { self.follower = follower }

    func applyPendingCommand(to webView: WKWebView) {
      guard parentPageFinished, lastGeneration != follower.commandGeneration,
        let command = follower.command,
        let data = try? JSONEncoder().encode(command),
        let json = String(data: data, encoding: .utf8)
      else { return }
      lastGeneration = follower.commandGeneration
      webView.evaluateJavaScript("window.EchoLabVideo && window.EchoLabVideo.dispatch(\(json));")
    }

    func userContentController(
      _ userContentController: WKUserContentController, didReceive message: WKScriptMessage
    ) {
      guard message.name == "echoLabYouTube", message.frameInfo.isMainFrame,
        let body = message.body as? [String: Any], let event = body["event"] as? String
      else { return }
      follower.receive(event: event, code: body["code"] as? Int)
    }

    func webView(
      _ webView: WKWebView, decidePolicyFor navigationAction: WKNavigationAction
    ) async -> WKNavigationActionPolicy {
      guard let url = navigationAction.request.url else { return .cancel }
      if navigationAction.targetFrame?.isMainFrame != false {
        return url.isFileURL || url.scheme == "about" ? .allow : .cancel
      }
      let host = url.host?.lowercased() ?? ""
      let allowed = [
        "youtube.com", "www.youtube.com", "youtube-nocookie.com", "www.youtube-nocookie.com",
      ]
      return allowed.contains(host) ? .allow : .cancel
    }

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
      parentPageFinished = true
      applyPendingCommand(to: webView)
    }

    func webView(
      _ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error
    ) { follower.receive(event: "offline") }

    func webView(
      _ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!,
      withError error: Error
    ) { follower.receive(event: "offline") }
  }

  private static let document = """
    <!doctype html><html><head><meta charset="utf-8"><style>
    html,body,#player{width:100%;height:100%;margin:0;background:#111318;overflow:hidden}
    </style></head><body><div id="player"></div><script>
    const queued=[]; let notify=(event,code)=>window.webkit.messageHandlers.echoLabYouTube.postMessage({event,code});
    let apiLoaded=false, player=null;
    function perform(command) {
      if (!apiLoaded) { queued.push(command); return; }
      if (command.action === 'cue') {
        if (!player) player = new YT.Player('player', {videoId:command.videoID, playerVars:{controls:0,rel:0,playsinline:1}, events:{
          onReady: e => { e.target.mute(); e.target.setVolume(0); notify('ready'); },
          onError: e => notify('error', e.data)
        }});
        else { player.mute(); player.cueVideoById({videoId:command.videoID,startSeconds:command.seconds}); }
      } else if (command.action === 'follow' && player) {
        player.mute(); player.setVolume(0); player.seekTo(command.seconds, true); player.playVideo();
      } else if (command.action === 'pause' && player) player.pauseVideo();
    }
    window.EchoLabVideo={dispatch:perform};
    function onYouTubeIframeAPIReady(){apiLoaded=true;queued.splice(0).forEach(perform);}
    </script><script src="https://www.youtube.com/iframe_api"></script></body></html>
    """
}
