import SwiftUI
import AppKit
import ServiceManagement
import UserNotifications

// Orchestrateur de l'application (instance unique partagée entre la barre de menus et le délégué).
@MainActor
final class AppModel: ObservableObject {
    static let shared = AppModel()

    @Published var config: AppConfig
    @Published var status: String = ""
    // Mise à jour réseau (invitation) :
    @Published var updateAvailable = false
    @Published var updatePeerName = ""
    @Published var updateInstalling = false
    private var updatePeerBuild = 0
    private var updateDismissedBuild = 0
    // Ancien automatisme (com.fvjc.archivage) détecté sur ce Mac → à supprimer (doublon).
    @Published var legacyDetected = false
    @Published var legacyRemoving = false
    // Export NAS : statut du montage affiché dans les réglages.
    @Published var nasStatus = ""

    private let configStore = ConfigStore()
    private let engine = Engine()
    private var updateService: UpdateService!
    private var prefsWindow: NSWindow?
    private var started = false

    private init() {
        self.config = configStore.config
        self.updateDismissedBuild = configStore.config.dismissedUpdateBuild

        engine.onLog = { [weak self] s in
            Task { @MainActor in self?.status = s }
        }
        updateService = UpdateService(nodeId: configStore.nodeId()) { [weak self] build, name in
            Task { @MainActor in
                guard let self, build > AppVersion.build, build > self.updateDismissedBuild, !self.updateInstalling else { return }
                self.updatePeerBuild = build
                self.updatePeerName = name
                self.updateAvailable = true
            }
        }
    }

    // Démarrage effectif (appelé une fois depuis applicationDidFinishLaunching).
    func bootstrap() {
        guard !started else { return }
        started = true
        // Persiste la config sur disque dès le 1er lancement : le moteur Python lit config.json, et
        // cela évite de rouvrir les préférences à chaque démarrage (le « 1er lancement » se détecte par
        // l'absence de ce fichier — vérifiée AVANT cet appel dans applicationDidFinishLaunching).
        configStore.save(config)
        requestNotifications()          // demande le droit « Notifications »
        applyLoginItem()                // démarrage avec le système (login item)
        engine.start(watchFolder: config.watchFolder)
        if config.networkEnabled { updateService.start() }   // déclenche l'invite « Réseau local »
        checkLegacyAutomation()          // ancien service en doublon → proposer sa suppression
        if config.exportEnabled { connectNAS() }             // monte le NAS (popup natif si besoin)
    }

    // MARK: - export NAS : montage du partage (popup de login natif macOS si nécessaire)
    func connectNAS() {
        let host = config.nasHost, share = config.nasShare, user = config.nasUser
        guard config.exportEnabled else { return }
        guard !share.isEmpty else { nasStatus = "Renseignez le nom du partage SMB."; return }
        nasStatus = "Connexion au NAS \(host)…"
        Task.detached { [weak self] in
            let path = MountManager.ensureMounted(host: host, share: share, user: user)
            await MainActor.run {
                self?.nasStatus = path != nil
                    ? "NAS monté : \(path!)"
                    : "NAS non monté (le repli Synology Drive sera utilisé)."
            }
        }
    }

    // MARK: - ancien automatisme (com.fvjc.archivage) — détection + suppression
    func checkLegacyAutomation() {
        let detected = LegacyCleanup.detected()
        legacyDetected = detected
        guard detected else { return }
        LegacyCleanup.log("Ancien automatisme détecté au lancement.")
        // Invite proactive (async → ne bloque pas le démarrage ; l'alerte s'affiche juste après).
        DispatchQueue.main.async { [weak self] in self?.promptLegacyRemoval() }
    }

    private func promptLegacyRemoval() {
        guard !legacyRemoving else { return }
        NSApp.activate(ignoringOtherApps: true)
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = "Ancien automatisme détecté"
        alert.informativeText = "Un ancien service d'archivage (« com.fvjc.archivage ») tourne encore et surveille le même dossier — il fait doublon avec ScanToPDF et doit être supprimé.\n\nScanToPDF peut le supprimer maintenant (votre mot de passe administrateur sera demandé)."
        alert.addButton(withTitle: "Supprimer maintenant")
        alert.addButton(withTitle: "Plus tard")
        if alert.runModal() == .alertFirstButtonReturn { removeLegacy() }
    }

    func removeLegacy() {
        guard !legacyRemoving else { return }
        legacyRemoving = true
        status = "Suppression de l'ancien automatisme…"
        Task.detached { [weak self] in
            let reason = LegacyCleanup.remove()   // invite mot de passe admin (bloquant hors thread principal)
            await MainActor.run {
                guard let self else { return }
                self.legacyRemoving = false
                self.legacyDetected = LegacyCleanup.detected()
                if reason == nil && !self.legacyDetected {
                    self.status = "Ancien automatisme supprimé."
                } else {
                    self.status = "Ancien automatisme : \(reason ?? "toujours présent")"
                }
            }
        }
    }

    // MARK: - permissions
    private func requestNotifications() {
        guard Bundle.main.bundleIdentifier != nil else { return }   // pas de notifications hors bundle
        UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound]) { _, _ in }
    }

    // MARK: - démarrage avec le système (SMAppService, macOS 13+)
    func applyLoginItem() {
        do {
            if config.startAtLogin {
                if SMAppService.mainApp.status != .enabled { try SMAppService.mainApp.register() }
            } else {
                if SMAppService.mainApp.status == .enabled { try SMAppService.mainApp.unregister() }
            }
        } catch {
            status = "Démarrage auto : \(error.localizedDescription)"
        }
    }

    // MARK: - modification de la configuration depuis les préférences
    // Les cases du pipeline (ocr/deskew/…) ne nécessitent qu'une sauvegarde : le workflow relit config.json
    // à chaque traitement. Seuls le dossier surveillé, le réseau et le login déclenchent une action immédiate.
    func update(_ mutate: (inout AppConfig) -> Void) {
        var c = config
        mutate(&c)
        let folderChanged = c.watchFolder != config.watchFolder
        let netChanged = c.networkEnabled != config.networkEnabled
        let loginChanged = c.startAtLogin != config.startAtLogin
        config = c
        configStore.save(c)
        if loginChanged { applyLoginItem() }
        if netChanged { c.networkEnabled ? updateService.start() : updateService.stop() }
        if folderChanged { engine.restart(watchFolder: c.watchFolder) }
    }

    // MARK: - actions utilitaires
    func processNow() {
        status = "Traitement en cours…"
        engine.runWorkflowOnce(watchFolder: config.watchFolder)
    }

    func openWatchFolder() {
        let path = config.watchFolder
        if !FileManager.default.fileExists(atPath: path) {
            try? FileManager.default.createDirectory(atPath: path, withIntermediateDirectories: true,
                                                     attributes: [.posixPermissions: 0o2775, .groupOwnerAccountID: 20])
        }
        NSWorkspace.shared.selectFile(nil, inFileViewerRootedAtPath: path)
    }

    // MARK: - fenêtre de préférences (gérée en AppKit → aucune fenêtre au démarrage/login)
    func openPreferences() {
        if prefsWindow == nil {
            let host = NSHostingController(rootView: SettingsView().environmentObject(self))
            let w = NSWindow(contentViewController: host)
            w.title = "ScanToPDF — Préférences"
            w.styleMask = [.titled, .closable, .miniaturizable]
            w.isReleasedWhenClosed = false
            w.setContentSize(NSSize(width: 460, height: 600))
            w.center()
            prefsWindow = w
        }
        NSApp.activate(ignoringOtherApps: true)
        prefsWindow?.makeKeyAndOrderFront(nil)
    }

    // MARK: - mise à jour réseau
    func installUpdate() {
        guard !updateInstalling else { return }
        updateInstalling = true
        updateAvailable = false
        status = "Téléchargement de la mise à jour…"
        Task {
            let reason = await updateService.pullAndInstallApp()
            await MainActor.run {
                if reason == nil {
                    self.status = "Installation… redémarrage"
                    NSApplication.shared.terminate(nil)
                } else {
                    self.updateInstalling = false
                    // Échec d'installation : on PERSISTE le build refusé (comme « Plus tard »), sinon un
                    // pair au build cassé re-proposerait la MAJ à chaque redémarrage (#15).
                    self.updateDismissedBuild = self.updatePeerBuild
                    self.config.dismissedUpdateBuild = self.updatePeerBuild
                    self.configStore.save(self.config)
                    self.status = "Mise à jour échouée : \(reason!)"
                }
            }
        }
    }

    func dismissUpdate() {
        updateDismissedBuild = updatePeerBuild
        updateAvailable = false
        config.dismissedUpdateBuild = updatePeerBuild
        configStore.save(config)
    }

    // MARK: - phrase secrète du cluster (durcissement optionnel de la MAJ réseau)
    var clusterPassphrase: String { ClusterSecret.load() ?? "" }
    func setClusterPassphrase(_ s: String) {
        ClusterSecret.save(s)
        // Reprendre la nouvelle clé TLS-PSK : on redémarre le service de découverte/MAJ.
        if config.networkEnabled { updateService.stop(); updateService.start() }
        status = ClusterSecret.isSet ? "Phrase secrète du réseau enregistrée." : "Phrase secrète du réseau effacée."
    }

    // MARK: - arrêt propre
    func quit() {
        engine.stop()
        NSApplication.shared.terminate(nil)
    }

    func engineStop() { engine.stop() }
}
