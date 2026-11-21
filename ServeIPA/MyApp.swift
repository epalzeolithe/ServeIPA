import AppKit
import SwiftUI

@main
struct ServeIPAApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @State private var store = IPAStore()

    var body: some Scene {
        WindowGroup("ServeIPA", id: "main") {
            ContentView(store: store)
                .task {
                    await store.startIfNeeded()
                }
        }
        .defaultSize(width: 820, height: 560)

        MenuBarExtra("ServeIPA", systemImage: store.serverState.symbolName) {
            ServerMenu(store: store)
        }

        Settings {
            ServeIPASettingsView(store: store)
        }
    }
}

private final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        guard let iconURL = Bundle.main.url(forResource: "AppIcon", withExtension: "icns"),
              let icon = NSImage(contentsOf: iconURL) else {
            return
        }
        NSApplication.shared.applicationIconImage = icon
    }
}

private struct ServerMenu: View {
    @Bindable var store: IPAStore
    @Environment(\.openWindow) private var openWindow
    @Environment(\.openSettings) private var openSettings

    var body: some View {
        Label(store.serverState.title, systemImage: store.serverState.symbolName)

        if let url = store.serverURL {
            Text(url.absoluteString)
            Button("Ouvrir dans Safari", systemImage: "safari") {
                store.openServerURL()
            }
            Button("Copier l’URL", systemImage: "doc.on.doc") {
                store.copyServerURL()
            }
        }

        Divider()

        if store.serverState == .running || store.serverState == .starting {
            Button("Arrêter le serveur", systemImage: "stop.fill") {
                Task { await store.stopServer() }
            }
            .disabled(store.serverState == .starting)
        } else {
            Button("Démarrer le serveur", systemImage: "play.fill") {
                Task { await store.startServer() }
            }
        }

        Button("Actualiser les IPA", systemImage: "arrow.clockwise") {
            Task { await store.refresh() }
        }
        .disabled(store.folderURL == nil || store.isScanning)

        Divider()

        Button("Ouvrir ServeIPA", systemImage: "macwindow") {
            openWindow(id: "main")
            NSApplication.shared.activate()
        }
        Button("Réglages…", systemImage: "gear") {
            openSettings()
            NSApplication.shared.activate()
        }

        Divider()

        Text("ServeIPA \(AppBuildInfo.current.summary)")
        Button("Mettre à jour ServeIPA…", systemImage: "arrow.triangle.2.circlepath") {
            NSApplication.shared.activate()
            Task { await store.updateServeIPA() }
        }
        .disabled(store.folderURL == nil || store.rebuildingBundleID != nil)

        Button("Quitter ServeIPA") {
            NSApplication.shared.terminate(nil)
        }
        .keyboardShortcut("q")
    }
}
