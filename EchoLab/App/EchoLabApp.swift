import AppKit
import SwiftUI

@MainActor @Observable
final class ProductionLibraryBootstrap {
  let usesPreviewFixtures: Bool
  var model: ProductionLibraryModel?
  var practiceService: ProductionPracticeService?
  var practiceController: ProductionPracticeController?
  var shadowing: ProductionShadowingModel?
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
      error = nil
      return
    }
    do {
      let paths = BackendPaths.live
      try paths.prepare()
      let database = try ProductionDatabase(url: paths.database)
      let ipaDictionary = try? OfflineIPADictionary.bundled()
      let library = ProductionLibraryModel(
        service: ProductionImportService(
          database: database, paths: paths, ipaDictionary: ipaDictionary))
      model = library
      let practice = ProductionPracticeService(database: database, paths: paths)
      practiceService = practice
      let controller = ProductionPracticeController(service: practice)
      practiceController = controller
      shadowing = ProductionShadowingModel(
        service: practice, controller: controller,
        translationPreparer: AppleTranslationPreparer(database: database),
        ipaPreparer: ipaDictionary.map {
          IPAAnnotationPreparer(database: database, dictionary: $0)
        },
        wordTimingPreparer: AppleSpeechWordTimingPreparer(service: practice))
      error = nil
    } catch {
      model = nil
      practiceService = nil
      practiceController = nil
      shadowing = nil
      self.error = error.localizedDescription
    }
  }

  func recoverPracticeTakes() async {
    guard let practiceService, let model else { return }
    do { try await practiceService.recoverPendingTakes() } catch { model.report(error) }
  }
}

@main
struct EchoLabApp: App {
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
    Window("EchoLab", id: "main") {
      Group {
        if rendersPreviews {
          EchoTheme.canvas
        } else {
          AppRootView(
            productionLibrary: productionLibrary.model,
            productionShadowing: productionLibrary.shadowing,
            usesPreviewLibrary: productionLibrary.usesPreviewFixtures,
            productionLibraryError: productionLibrary.error,
            retryProductionLibrary: productionLibrary.reload
          ).environment(store).frame(minWidth: 1000, minHeight: 680)
            .environment(\.locale, store.preferences.language.locale)
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
          store.navigate(.settings)
          openWindow(id: "main")
        }
        .keyboardShortcut(",")
      }
      CommandMenu(store.preferences.language == .english ? "Practice" : "Luyện tập") {
        Button(store.preferences.language == .english ? "Library" : "Thư viện") {
          store.navigate(.library)
        }.keyboardShortcut("1")
        Button(store.preferences.language == .english ? "Shadowing" : "Luyện shadowing") {
          store.navigate(.shadowing)
        }.keyboardShortcut("2")
        Button(store.preferences.language == .english ? "Progress" : "Tiến bộ") {
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
        ? "EchoLab · UI Components" : "EchoLab · Thành phần UI",
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
