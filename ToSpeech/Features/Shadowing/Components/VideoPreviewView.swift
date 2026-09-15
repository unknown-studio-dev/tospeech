import SwiftUI

enum VideoPreviewState: String, CaseIterable, Identifiable {
  case following = "Following audio"
  case paused = "Video paused"
  case syncing = "Syncing video"
  case buffering = "Video buffering"
  case offline = "Offline"
  case unavailable = "Video unavailable"
  case rateMismatch = "Video rate mismatch"
  var id: String { rawValue }
}

struct VideoPreviewView: View {
  @Environment(EchoStore.self) private var store
  @Environment(\.locale) private var locale
  var lesson: Lesson
  var onEdit: () -> Void
  var isProductionMode = false
  var productionFollower: YouTubeVideoFollower? = nil
  var productionThumbnailURL: URL? = nil
  var hasProductionVideo = false
  var onRetryProductionVideo: (() -> Void)? = nil
  var onToggleProductionVideo: (() -> Void)? = nil
  var concealsVideo = false
  @State private var state: VideoPreviewState = .following
  var body: some View {
    VStack(spacing: 8) {
      ZStack {
        if concealsVideo || !store.preferences.video || [.offline, .unavailable].contains(effectiveState) {
          productionThumbnail
        } else if let productionFollower {
          YouTubeVideoFollowerView(
            follower: productionFollower, commandGeneration: productionFollower.commandGeneration,
            captionGeneration: productionFollower.captionGeneration)
            .id(productionFollower.pageID)
        } else if isProductionMode {
          productionThumbnail
        } else {
          EchoTheme.canvas
          VStack(spacing: 12) {
            Image(systemName: "play.rectangle").font(EchoFont.body(size: 32))
            Text("YouTube · muted preview").font(EchoFont.body(size: 13))
            Text("Preview fixture · source audio remains master.").font(EchoFont.metadata)
              .foregroundStyle(EchoTheme.secondaryText)
          }
        }
      }.aspectRatio(16 / 9, contentMode: .fit)
        .clipShape(RoundedRectangle(cornerRadius: 12))
        .contextMenu {
          if !concealsVideo { Button("Chỉnh timing", action: onEdit) } // native-control: menu
          if !isProductionMode {
            Menu("Video preview state") {
              ForEach(VideoPreviewState.allCases) { item in
                Button(EchoLocalization.string(item.rawValue, locale: locale)) { state = item } // native-control: menu
              }
            }
          }
        }
      HStack(spacing: 8) {
        Label {
          EchoLocalizedText(
            concealsVideo ? "dictation.thumbnail" : store.preferences.video ? effectiveState.rawValue : "Video tắt · đang dùng audio gốc")
        } icon: {
          Image(systemName: "speaker.slash")
        }
        .font(EchoFont.metadata).foregroundStyle(EchoTheme.secondaryText).lineLimit(1)
        Spacer(minLength: 0)
        if !concealsVideo && store.preferences.video
          && [.syncing, .buffering, .offline, .unavailable, .rateMismatch].contains(effectiveState)
        {
          EchoButton("Thử lại", symbol: "arrow.clockwise") {
            if let onRetryProductionVideo { onRetryProductionVideo() }
            else { state = .following }
          }
        }
        if !concealsVideo, store.preferences.video, let productionFollower, hasProductionVideo {
          EchoButton(
            productionFollower.captionsEnabled ? "Tắt phụ đề" : "Bật phụ đề",
            symbol: productionFollower.captionsEnabled ? "captions.bubble.fill" : "captions.bubble"
          ) {
            productionFollower.setCaptions(!productionFollower.captionsEnabled)
          }
          .help("Bật/tắt phụ đề trên video YouTube. Điều khiển video hoàn toàn qua app.")
        }
        if !concealsVideo {
        EchoButton(store.preferences.video ? "Tắt video" : "Bật video", symbol: "video") {
          if let onToggleProductionVideo { onToggleProductionVideo() }
          else { store.preferences.video.toggle() }
        }
        .disabled(isProductionMode && !hasProductionVideo)
        .help(
          isProductionMode
            ? "Muted YouTube video follows the native source-audio clock."
            : "Video preview only; source audio settings stay unchanged.")
        }
      }.frame(height: 32)
    }
  }

  @ViewBuilder private var productionThumbnail: some View {
    if let productionThumbnailURL {
      AsyncImage(url: productionThumbnailURL) { image in
        image.resizable().scaledToFill()
      } placeholder: {
        EchoThumbnail(name: lesson.thumbnail, title: lesson.title)
      }
    } else {
      EchoThumbnail(name: lesson.thumbnail, title: lesson.title)
    }
  }

  private var effectiveState: VideoPreviewState {
    guard let productionFollower else { return isProductionMode ? .unavailable : state }
    switch productionFollower.state {
    case .following: return .following
    case .loading, .idle: return .syncing
    case .paused: return .paused
    case .unavailable: return .unavailable
    case .offline: return .offline
    }
  }
}
