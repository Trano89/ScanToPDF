import SwiftUI
import AppKit

// Application « agent » : présente UNIQUEMENT une icône dans la barre des menus (aucune icône Dock,
// grâce à LSUIElement dans l'Info.plist). Le menu ne contient que deux entrées : Ouvrir et Quitter.
// (Pas de @main : l'entrée est main.swift, qui appelle ScanToPDFApp.main() — même schéma qu'ArchivesSearch,
//  nécessaire car main.swift contient du code top-level.)
struct ScanToPDFApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var delegate

    var body: some Scene {
        MenuBarExtra("ScanToPDF", systemImage: "doc.viewfinder") {
            MenuContent()
        }
    }
}

struct MenuContent: View {
    @ObservedObject private var model = AppModel.shared
    var body: some View {
        Button("Ouvrir") { model.openPreferences() }
        Button("Publier un dossier dans AtoM…") { model.publishExistingFolder() }
        Divider()
        Button("Quitter ScanToPDF") { model.quit() }
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    // Au lancement : on démarre les services. On n'ouvre la fenêtre de préférences QUE lors du tout
    // premier lancement (aucune config encore) → au démarrage système, l'app reste discrète (barre de menus).
    func applicationDidFinishLaunching(_ notification: Notification) {
        let firstRun = !FileManager.default.fileExists(atPath: AppPaths.configURL.path)
        AppModel.shared.bootstrap()
        if firstRun { AppModel.shared.openPreferences() }
    }

    // Double-clic sur l'app déjà lancée (login item) → ré-ouvre les préférences.
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        AppModel.shared.openPreferences()
        return true
    }

    func applicationWillTerminate(_ notification: Notification) {
        AppModel.shared.engineStop()
    }
}
