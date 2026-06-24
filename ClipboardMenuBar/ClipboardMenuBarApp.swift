import AppKit
import SQLite3
import ServiceManagement
import SwiftData
import SwiftUI

enum AppIdentity {
    static let displayName = "Mac_win+v"
    static let bundleIdentifier = "com.example.Mac-win-v"
    static let previousBundleIdentifier = "com.example.ClipboardMenuBar"
}

@MainActor
final class AppServices: ObservableObject {
    static let shared = AppServices()

    @Published private(set) var panelController: PanelController?
    @Published private(set) var clipboardStore: ClipboardStore?
    @Published private(set) var accessibilityEnabled = PasteService.hasAccessibilityPermission(prompt: false)
    @Published private(set) var launchAtLoginEnabled = false
    @Published private(set) var launchAtLoginNeedsApproval = false
    @Published var statusMessage: String?

    let modelContainer: ModelContainer

    private var monitor: ClipboardMonitor?
    private var hotKeyManager: HotKeyManager?
    private var permissionRefreshTimer: Timer?

    private init() {
        do {
            modelContainer = try Self.makeModelContainer()
        } catch {
            fatalError("Failed to create SwiftData container: \(error)")
        }

        refreshSystemState()
        startPermissionRefreshTimer()
    }

    func start() {
        if clipboardStore != nil {
            refreshSystemState()
            return
        }

        let context = modelContainer.mainContext
        let imageStorage = ImageStorage(bundleIdentifier: Self.currentBundleIdentifier())
        let store = ClipboardStore(modelContext: context, imageStorage: imageStorage)
        let pasteService = PasteService()
        let panelController = PanelController(clipboardStore: store, pasteService: pasteService, appServices: self)
        let monitor = ClipboardMonitor(clipboardStore: store, imageStorage: imageStorage)
        let hotKeyManager = HotKeyManager { [weak panelController] in
            panelController?.toggle()
        }

        self.clipboardStore = store
        self.panelController = panelController
        self.monitor = monitor
        self.hotKeyManager = hotKeyManager

        monitor.start()
        hotKeyManager.registerOptionV()
        refreshSystemState()
    }

    func refreshSystemState() {
        let oldAccessibility = accessibilityEnabled
        accessibilityEnabled = PasteService.hasAccessibilityPermission(prompt: false)
        refreshLaunchAtLoginState()
        if oldAccessibility != accessibilityEnabled {
            panelController?.notifyPermissionStateChanged()
        }
    }

    func promptForAccessibilityPermission() {
        PasteService.requestAccessibilityPermission()
        refreshSystemState()
    }

    func setLaunchAtLogin(_ enabled: Bool) {
        do {
            if enabled {
                try SMAppService.mainApp.register()
            } else {
                try SMAppService.mainApp.unregister()
            }
            statusMessage = nil
        } catch {
            statusMessage = error.localizedDescription
        }

        refreshLaunchAtLoginState()
    }

    private func refreshLaunchAtLoginState() {
        switch SMAppService.mainApp.status {
        case .enabled:
            launchAtLoginEnabled = true
            launchAtLoginNeedsApproval = false
        case .requiresApproval:
            launchAtLoginEnabled = false
            launchAtLoginNeedsApproval = true
        default:
            launchAtLoginEnabled = false
            launchAtLoginNeedsApproval = false
        }
    }

    private func startPermissionRefreshTimer() {
        permissionRefreshTimer?.invalidate()
        permissionRefreshTimer = Timer.scheduledTimer(withTimeInterval: 1.0, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.refreshSystemState()
            }
        }
        if let permissionRefreshTimer {
            RunLoop.main.add(permissionRefreshTimer, forMode: .common)
        }
    }

    private static func makeModelContainer() throws -> ModelContainer {
        let schema = Schema([ClipboardItem.self])
        let storeURL = try persistentStoreURL()
        try migrateLegacyStoreIfNeeded(to: storeURL)

        let configuration = ModelConfiguration(
            "ClipboardHistory",
            schema: schema,
            url: storeURL
        )

        return try ModelContainer(for: schema, configurations: [configuration])
    }

    private static func persistentStoreURL() throws -> URL {
        let appDirectory = try applicationSupportDirectory(
            for: currentBundleIdentifier(),
            baseDirectory: applicationSupportBaseDirectory(),
            create: true
        )
        return appDirectory.appendingPathComponent("ClipboardHistory.store", isDirectory: false)
    }

    private static func currentBundleIdentifier() -> String {
        Bundle.main.bundleIdentifier ?? AppIdentity.bundleIdentifier
    }

    private static func applicationSupportBaseDirectory() -> URL {
        let fileManager = FileManager.default
        return fileManager.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
    }

    private static func applicationSupportDirectory(
        for bundleIdentifier: String,
        baseDirectory: URL,
        create: Bool
    ) throws -> URL {
        let fileManager = FileManager.default
        let appDirectory = baseDirectory.appendingPathComponent(bundleIdentifier, isDirectory: true)
        if create {
            try fileManager.createDirectory(at: appDirectory, withIntermediateDirectories: true)
        }
        return appDirectory
    }

    static func migrateLegacyStoreIfNeeded(
        to storeURL: URL,
        baseDirectory: URL? = nil
    ) throws {
        let fileManager = FileManager.default
        let baseDirectory = baseDirectory ?? applicationSupportBaseDirectory()

        guard fileManager.fileExists(atPath: storeURL.path) == false else { return }

        if try migratePreviousBundleDataIfNeeded(to: storeURL, baseDirectory: baseDirectory) {
            return
        }

        let legacyStoreURL = baseDirectory.appendingPathComponent("default.store", isDirectory: false)

        guard fileManager.fileExists(atPath: legacyStoreURL.path),
              legacyStoreContainsClipboardItems(at: legacyStoreURL) else {
            return
        }

        for suffix in ["", "-wal", "-shm"] {
            let sourceURL = URL(fileURLWithPath: legacyStoreURL.path + suffix)
            let destinationURL = URL(fileURLWithPath: storeURL.path + suffix)

            guard fileManager.fileExists(atPath: sourceURL.path) else { continue }
            try fileManager.copyItem(at: sourceURL, to: destinationURL)
        }
    }

    private static func migratePreviousBundleDataIfNeeded(to storeURL: URL, baseDirectory: URL) throws -> Bool {
        let fileManager = FileManager.default
        let previousDirectory = try applicationSupportDirectory(
            for: AppIdentity.previousBundleIdentifier,
            baseDirectory: baseDirectory,
            create: false
        )
        let previousStoreURL = previousDirectory.appendingPathComponent("ClipboardHistory.store", isDirectory: false)

        guard fileManager.fileExists(atPath: previousStoreURL.path) else {
            return false
        }

        for suffix in ["", "-wal", "-shm"] {
            let sourceURL = URL(fileURLWithPath: previousStoreURL.path + suffix)
            let destinationURL = URL(fileURLWithPath: storeURL.path + suffix)

            guard fileManager.fileExists(atPath: sourceURL.path),
                  fileManager.fileExists(atPath: destinationURL.path) == false else {
                continue
            }
            try fileManager.copyItem(at: sourceURL, to: destinationURL)
        }

        let previousImagesURL = previousDirectory.appendingPathComponent("Images", isDirectory: true)
        let currentImagesURL = storeURL
            .deletingLastPathComponent()
            .appendingPathComponent("Images", isDirectory: true)
        var isDirectory: ObjCBool = false
        if fileManager.fileExists(atPath: previousImagesURL.path, isDirectory: &isDirectory),
           isDirectory.boolValue,
           fileManager.fileExists(atPath: currentImagesURL.path) == false {
            try fileManager.copyItem(at: previousImagesURL, to: currentImagesURL)
        }

        return true
    }

    private static func legacyStoreContainsClipboardItems(at storeURL: URL) -> Bool {
        var database: OpaquePointer?
        guard sqlite3_open_v2(storeURL.path, &database, SQLITE_OPEN_READONLY, nil) == SQLITE_OK else {
            if database != nil {
                sqlite3_close(database)
            }
            return false
        }

        defer { sqlite3_close(database) }

        let query = "SELECT 1 FROM sqlite_master WHERE type = 'table' AND name = 'ZCLIPBOARDITEM' LIMIT 1;"
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(database, query, -1, &statement, nil) == SQLITE_OK else {
            return false
        }

        defer { sqlite3_finalize(statement) }
        return sqlite3_step(statement) == SQLITE_ROW
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        Task { @MainActor in
            AppServices.shared.start()
        }
    }

    func applicationDidBecomeActive(_ notification: Notification) {
        Task { @MainActor in
            AppServices.shared.refreshSystemState()
        }
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        false
    }
}

struct SettingsView: View {
    @ObservedObject var services: AppServices

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text(AppIdentity.displayName)
                .font(.title2.weight(.semibold))

            Toggle(
                "Launch at Login",
                isOn: Binding(
                    get: { services.launchAtLoginEnabled },
                    set: { services.setLaunchAtLogin($0) }
                )
            )

            if services.launchAtLoginNeedsApproval {
                Text("macOS requires you to approve this app in Login Items after enabling launch at login.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }

            if services.accessibilityEnabled {
                Label("Accessibility permission granted", systemImage: "checkmark.circle.fill")
                    .foregroundStyle(.green)
            } else {
                VStack(alignment: .leading, spacing: 8) {
                    Text("Accessibility permission is required for automatic Cmd+V paste.")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                    HStack {
                        Button("Grant Accessibility Permission") {
                            services.promptForAccessibilityPermission()
                        }
                        Button("Refresh Status") {
                            services.refreshSystemState()
                        }
                    }
                }
            }

            if let statusMessage = services.statusMessage {
                Text(statusMessage)
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }

            Text("Hotkey: Option + V")
                .font(.footnote)
                .foregroundStyle(.secondary)
        }
        .padding(24)
        .frame(width: 420)
        .onAppear {
            services.refreshSystemState()
        }
    }
}

@main
struct ClipboardMenuBarApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @StateObject private var services = AppServices.shared

    var body: some Scene {
        MenuBarExtra {
            MenuBarContent(services: services)
        } label: {
            Label(AppIdentity.displayName, systemImage: "clipboard")
        }
        .modelContainer(services.modelContainer)
        .menuBarExtraStyle(.menu)

        Settings {
            SettingsView(services: services)
        }
        .modelContainer(services.modelContainer)
    }
}
