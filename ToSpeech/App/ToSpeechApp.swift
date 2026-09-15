import AppKit
import SwiftUI

@MainActor @Observable
final class ProductionLibraryBootstrap {
  let usesPreviewFixtures: Bool
  var model: ProductionLibraryModel?
  var practiceService: ProductionPracticeService?
  var practiceController: ProductionPracticeController?
  var shadowing: ProductionShadowingModel?
  var parakeetModels: ParakeetModelManager?
  var pronunciationModels: PronunciationModelManager?
  var error: String?

  init(previewFixtures: Bool) {
    usesPreviewFixtures = previewFixtures
    reload()
  }

  func reload() {
    guard !usesPreviewFixtures else {
      model = nil
      practiceService = nil
      practiceController = nil
      shadowing = nil
      parakeetModels = nil
      pronunciationModels = nil
      error = nil
      return
    }
    do {
      let paths = BackendPaths.live
      try paths.prepare()
      let database = try ProductionDatabase(url: paths.database)
      let ipaDictionary = try? OfflineIPADictionary.bundled()
      let transcriber = AppleSpeechAnalyzerTranscriber()
      let aligner = CoreMLWordAligner()
      let parakeet = ParakeetTranscriptionAdapter(database: database, paths: paths)
      parakeetModels = ParakeetModelManager(adapter: parakeet)
      let adapters = TranscriptionAdapterRegistry([parakeet])
      let ukPackage = UKReferencePackage(paths: paths)
      // eSpeak NG (in the UK package) spells out words the bundled dictionary lacks, for
      // both accents, in import, backfill and assessment.
      let g2p = UKG2P(package: ukPackage)
      let ipaFallback: IPAFallback = { try await g2p.pronunciation($0, accent: $1) }
      let library = ProductionLibraryModel(
        service: ProductionImportService(
          database: database, paths: paths, usesSpeechFallback: false, audioTranscriber: transcriber, transcriptionAdapters: adapters, wordAligner: aligner,
          ipaDictionary: ipaDictionary, ipaG2P: g2p))
      model = library
      let practice = ProductionPracticeService(database: database, paths: paths)
      practiceService = practice
      let controller = ProductionPracticeController(service: practice)
      practiceController = controller
      let buddyPackage = BuddyModelPackage(paths: paths)
      let phonePackage = PhoneScorerPackage(paths: paths)
      let xeusPackage = PhoneticXeusPackage(paths: paths)
      pronunciationModels = PronunciationModelManager(package: buddyPackage, phonePackage: phonePackage, ukPackage: ukPackage, xeusPackage: xeusPackage)
      // One UK adapter for both engines: XEUS scores delivery through it, and two warm encoder
      // sessions would hold ~1.5 GB each.
      let assessmentPolicy = AssessmentResourcePolicy.current()
      let ukAdapter = UKReferenceAdapter(package: ukPackage, idleTimeout: assessmentPolicy.idleTimeout)
      let assessment = PronunciationAssessmentService(database: database, paths: paths, dictionary: ipaDictionary,
        adapter: BuddyPronunciationAdapter(package: buddyPackage), scorer: PhoneScorerAdapter(package: phonePackage), ukScorer: ukAdapter, ukG2P: g2p, xeusScorer: PhoneticXeusAdapter(package: xeusPackage, ukPackage: ukPackage, ukAdapter: ukAdapter, policy: assessmentPolicy))
      pronunciationModels?.isBusy = { [weak assessment] in assessment?.isProcessing == true || assessment?.jobs.contains(where: \.isPending) == true }
      shadowing = ProductionShadowingModel(
        service: practice, controller: controller, dictation: DictationModel(storage: database),
        translationPreparer: AppleTranslationPreparer(database: database),
        ipaPreparer: ipaDictionary.map {
          IPAAnnotationPreparer(database: database, dictionary: $0, fallback: ipaFallback)
        },
        wordTimingPreparer: AlignedWordTimingPreparer(service: practice, aligner: aligner),
        matchingService: ContentMatchingService(database: database, paths: paths, adapters: adapters),
        assessmentService: assessment)
      error = nil
    } catch {
      model = nil
      practiceService = nil
      practiceController = nil
      shadowing = nil
      parakeetModels = nil
      pronunciationModels = nil
      self.error = error.localizedDescription
    }
  }

  func recoverPracticeTakes() async {
    guard let practiceService, let model else { return }
    do { try await practiceService.recoverPendingTakes() } catch { model.report(error) }
    await shadowing?.matchingService?.recover()
    await shadowing?.assessmentService?.recover()
  }
}

@main
struct ToSpeechApp: App {
  @NSApplicationDelegateAdaptor(AppLifecycle.self) private var lifecycle
  @State private var store: EchoStore
  @Environment(\.openWindow) private var openWindow
  @State private var productionLibrary: ProductionLibraryBootstrap
  init() {
    let process = ProcessInfo.processInfo
    let runningTests =
      NSClassFromString("XCTestCase") != nil
      || process.environment["XCTestConfigurationFilePath"] != nil
      || process.environment["XCInjectBundleInto"] != nil
    let previewFixtures = process.arguments.contains("--preview-fixtures") || runningTests
    let value = EchoStore(repository: previewFixtures ? .memory : .local)
    if let routeArg = process.arguments.first(where: { $0.hasPrefix("--route=") }),
      let route = AppRoute(rawValue: String(routeArg.dropFirst(8)))
    {
      value.route = route
    }
    if let languageArg = process.arguments.first(where: { $0.hasPrefix("--language=") }),
      let language = AppLanguage(rawValue: String(languageArg.dropFirst(11)))
    {
      value.preferences.language = language
    }
    _productionLibrary = State(
      initialValue: ProductionLibraryBootstrap(
        previewFixtures: previewFixtures))
    _store = State(initialValue: value)
  }
  var body: some Scene {
    Window("ToSpeech", id: "main") {
      Group {
        if rendersPreviews {
          EchoTheme.canvas
        } else if !productionLibrary.usesPreviewFixtures && !store.preferences.hasCompletedOnboarding {
          OnboardingView(
            parakeetModels: productionLibrary.parakeetModels,
            pronunciationModels: productionLibrary.pronunciationModels,
            storageReady: productionLibrary.model != nil,
            retryBootstrap: productionLibrary.reload
          )
          .id(productionLibrary.model == nil ? "onboarding-bootstrap-missing" : "onboarding-bootstrap-ready")
          .environment(store)
          .environment(\.locale, store.preferences.language.locale)
          .preferredColorScheme(.dark).tint(EchoTheme.accent)
          .frame(minWidth: 1000, minHeight: 680)
        } else {
          AppRootView(
            productionLibrary: productionLibrary.model,
            productionShadowing: productionLibrary.shadowing,
            usesPreviewLibrary: productionLibrary.usesPreviewFixtures,
            productionLibraryError: productionLibrary.error,
            retryProductionLibrary: productionLibrary.reload
          ).environment(store).frame(minWidth: 1000, minHeight: 680)
            .environment(\.locale, store.preferences.language.locale)
            .environment(\.parakeetModelManager, productionLibrary.parakeetModels)
            .environment(\.pronunciationModelManager, productionLibrary.pronunciationModels)
            .toolbar(removing: .title)
            .preferredColorScheme(.dark).tint(EchoTheme.accent)
            .background(
              WindowLifecycleGuard(
                store: store, productionShadowing: productionLibrary.shadowing)
            )
            .task {
              lifecycle.store = store
              lifecycle.productionShadowing = productionLibrary.shadowing
              if let model = productionLibrary.model {
                await model.resumePendingJobs()
              }
              await productionLibrary.recoverPracticeTakes()
              if ProcessInfo.processInfo.arguments.contains("--components") {
                openWindow(id: "ui-components")
              }
            }
        }
      }
    }
    .windowToolbarStyle(.unified)
    .windowResizability(.contentMinSize)
    .defaultSize(width: EchoMetrics.windowSize.width, height: EchoMetrics.windowSize.height)
    .commands {
      CommandGroup(replacing: .appSettings) {
        Button(store.preferences.language == .english ? "Settings…" : "Cài đặt…") {
          guard productionLibrary.usesPreviewFixtures || store.preferences.hasCompletedOnboarding else { return }
          store.navigate(.settings)
          openWindow(id: "main")
        }
        .keyboardShortcut(",")
      }
      CommandMenu(store.preferences.language == .english ? "Practice" : "Luyện tập") {
        Button(store.preferences.language == .english ? "Library" : "Thư viện") {
          guard productionLibrary.usesPreviewFixtures || store.preferences.hasCompletedOnboarding else { return }
          store.navigate(.library)
        }.keyboardShortcut("1")
        Button(store.preferences.language == .english ? "Shadowing" : "Luyện tập") {
          guard productionLibrary.usesPreviewFixtures || store.preferences.hasCompletedOnboarding else { return }
          store.navigate(.shadowing)
        }.keyboardShortcut("2")
        Button(store.preferences.language == .english ? "Progress" : "Tiến bộ") {
          guard productionLibrary.usesPreviewFixtures || store.preferences.hasCompletedOnboarding else { return }
          store.navigate(.progress)
        }.keyboardShortcut("3")
        Divider()
        Button(
          store.preferences.language == .english ? "Pause and keep take" : "Tạm dừng và giữ bản thu"
        ) {
          if store.route == .shadowing, let shadowing = productionLibrary.shadowing,
            !productionLibrary.usesPreviewFixtures
          {
            shadowing.pause()
          } else {
            store.practice.interrupt()
          }
        }.keyboardShortcut(".")
      }
      CommandMenu(store.preferences.language == .english ? "Design" : "Thiết kế") {
        Button(store.preferences.language == .english ? "UI Components…" : "Thành phần UI…") {
          openWindow(id: "ui-components")
        }
        .keyboardShortcut("d", modifiers: [.command, .option])
      }
    }
    Window(
      store.preferences.language == .english
        ? "ToSpeech · UI Components" : "ToSpeech · Thành phần UI",
      id: "ui-components"
    ) {
      if rendersPreviews {
        EchoTheme.canvas
      } else {
        ComponentGalleryView().environment(store)
          .environment(\.locale, store.preferences.language.locale)
      }
    }
    .defaultSize(width: 1180, height: 860).windowToolbarStyle(.unified)
  }

  private var rendersPreviews: Bool {
    ProcessInfo.processInfo.arguments.contains("--render-previews")
  }
}
