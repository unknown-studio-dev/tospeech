import SwiftUI

private enum PracticeOverlay: Identifiable {
  case word(String)
  case timing(String?)
  var id: String {
    switch self {
    case .word(let id): "word-\(id)"
    case .timing(let id): "timing-\(id ?? "sentence")"
    }
  }
}

struct ShadowingView: View {
  @Environment(EchoStore.self) private var store
  @State private var overlay: PracticeOverlay?
  @State private var selectedWordID: String?
  @State private var showingReview = false
  @State private var showingScenarios = false
  @State private var showingRepeatOptions = false

  var body: some View {
    GeometryReader { geometry in
      practiceContent(
        layout: ShadowingLayout(
          contentWidth: geometry.size.width,
          contentHeight: geometry.size.height)
      ).frame(width: geometry.size.width)
    }
  }

  @ViewBuilder private func practiceContent(layout: ShadowingLayout) -> some View {
    @Bindable var practice = store.practice
    Group {
      if let lesson = store.selectedLesson, let sentence = store.selectedSentence {
        ShadowingPracticeScaffold(
          layout: layout, showsReview: showingReview && selectedTake != nil,
          source: {
            VideoPreviewView(lesson: lesson, onEdit: { present(.timing(nil)) })
          },
          transcript: {
            TranscriptNavigatorView(lesson: lesson, contentScale: layout.controlScale)
          },
          sentence: {
            SentenceView(
              sentence: sentence, selectedWordID: $selectedWordID,
              readingScale: layout.readingScale,
              onReview: {
                if store.practice.interrupt() { showingReview = true }
              },
              onTakeReview: { take in
                guard store.practice.interrupt() else { return }
                store.reviewTakeID = take.id
                showingReview = true
              }, onWord: { showWord($0) })
          },
          review: {
            if let take = selectedTake {
              ShadowingReviewScaffold(
                layout: layout, onBack: { showingReview = false },
                source: {
                  VideoPreviewView(lesson: lesson, onEdit: { present(.timing(nil)) })
                },
                sentence: {
                  SentenceView(
                    sentence: take.sourceSnapshot, selectedWordID: $selectedWordID, compact: true,
                    onWord: { showWord($0, historical: true) })
                },
                panel: {
                  ReviewPanelView(
                    take: take,
                    onRecordAgain: {
                      showingReview = false
                      store.practice.clearScope()
                      store.practice.requestRecord()
                    },
                    onPracticePhrase: { ids in
                      guard take.sourceSnapshot.revision == sentence.revision else {
                        store.message = EchoCopy(
                          "This take uses an older sentence. Return to the current sentence to practise a phrase.")
                        return
                      }
                      showingReview = false
                      store.practice.beginPhrase(ids)
                    })
                })
            }
          },
          supplementary: {
            if ProcessInfo.processInfo.arguments.contains("--preview-scenarios") {
              DisclosureGroup("Preview scenarios", isExpanded: $showingScenarios) {
                PreviewScenariosView().padding(.top, 12)
              }
              .font(EchoFont.body(size: 11)).foregroundStyle(EchoTheme.muted)
            }
          },
          transport: {
            PracticeTransportView(
              onOptions: {
                if store.practice.interrupt() { showingRepeatOptions = true }
              }, onReview: { showingReview = true },
              compact: layout.contentWidth < 950, contentScale: layout.controlScale)
              .popover(isPresented: $showingRepeatOptions, arrowEdge: .top) {
                RepeatOptionsView(onClose: { showingRepeatOptions = false })
              }
          })
        .sheet(item: $overlay) { item in
          switch item {
          case .word(let id):
            WordPronunciationView(
              sentence: showingReview ? (selectedTake?.sourceSnapshot ?? sentence) : sentence,
              wordID: id,
              onEditTiming: { wordID in
                if showingReview, let take = selectedTake,
                  take.sourceSnapshot.revision != sentence.revision
                {
                  overlay = nil
                  store.message = EchoCopy(
                    "This is a historical word. Return to practice to edit the current sentence timing.")
                } else {
                  overlay = .timing(wordID)
                }
              }, onClose: { overlay = nil })
          case .timing(let id):
            TimingEditorView(
              lesson: lesson, sentence: sentence, wordID: id, onClose: { overlay = nil })
          }
        }
        .sheet(isPresented: $practice.permissionPresented) { MicrophonePreviewSheet() }
      } else {
        ScrollView {
          EchoEmptyState(
            title: "Choose a lesson to begin",
            message: "Your transcript, pronunciation guide and recordings will stay together here.",
            symbol: "headphones")
          EchoButton("Go to library", symbol: "books.vertical", kind: .primary) {
            store.navigate(.library)
          }
        }
      }
    }
      .onAppear { showingReview = store.reviewTakeID != nil }
      .onAppear {
        #if DEBUG
          if ProcessInfo.processInfo.arguments.contains("--word-preview"),
            let word = store.selectedSentence?.words.dropFirst(2).first
          {
            showWord(word.id)
          }
        #endif
      }
      .onChange(of: store.selectedSentenceID) {
        showingReview = false
        selectedWordID = nil
      }
      .toolbar {
        ToolbarItemGroup(placement: .primaryAction) {
          EchoButton("Tiến bộ", symbol: "chart.line.uptrend.xyaxis", size: .regular) {
            store.navigate(.progress)
          }
          EchoButton("Chỉnh timing", symbol: "slider.horizontal.3", size: .regular) {
            present(.timing(nil))
          }.disabled(store.selectedSentence == nil)
        }
      }
  }
  private var lessonTakes: [PracticeTake] {
    store.takes.filter {
      $0.lessonID == store.selectedLessonID && $0.sentenceID == store.selectedSentenceID
    }
  }
  private var selectedTake: PracticeTake? {
    store.takes.first { $0.id == store.reviewTakeID } ?? lessonTakes.last
  }
  private func showWord(_ id: String, historical: Bool = false) {
    guard !store.practice.phase.isCapture, store.practice.interrupt(),
      let sentence = historical ? selectedTake?.sourceSnapshot : store.selectedSentence
    else { return }
    selectedWordID = id
    store.practice.previewWord(sentence: sentence, wordID: id)
    overlay = .word(id)
  }
  private func present(_ value: PracticeOverlay) {
    if store.practice.interrupt() { overlay = value }
  }
}
