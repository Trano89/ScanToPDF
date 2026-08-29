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
    var updatePeerBuild: Int = 0             // build du Mac source (mise à jour LAN)
    @Published var updateRemoteVersion = ""  // version de la release GitHub (ex. « 1.0.8 »)
    @Published var updateIsRemote = false    // true si la MAU vient de GitHub (pas d'install auto)
    private var updateDismissedBuild = 0
    // Ancien automatisme (com.fvjc.archivage) détecté sur ce Mac → à supprimer (doublon).
    @Published var legacyDetected = false
    @Published var legacyRemoving = false
    // Export NAS : lecteurs réseau détectés, lecteur retenu et statut affiché dans les réglages.
    @Published var nasStatus = ""
    @Published var nasVolumes: [NetworkVolume] = []
    private var nasRemountTask: Task<Void, Never>?
    private var nasMountFailures = 0
    // Publication AtoM : notice en attente de validation et statut.
    @Published var atomPending: AtomPublication?
    private var atomQueue: [AtomPublication] = []   // un même passage peut terminer plusieurs projets
    /// Session AtoM ouverte pour CETTE exécution de l'application. Remise à zéro à chaque démarrage :
    /// la connexion est redemandée au premier traitement, jamais conservée d'une session à l'autre.
    @Published private(set) var atomSessionReady = false
    private var atomLoginWindow: NSWindow?
    @Published var atomStatus = ""
    private var atomWindow: NSWindow?
    // Fiche ISAD : modèles Ollama installés sur ce Mac (menu des préférences) + statut de la recherche.
    @Published var ollamaModels: [String] = []
    @Published var ollamaStatus = ""

    private let configStore = ConfigStore()
    private let engine = Engine()
    private var updateService: UpdateService!
    private var prefsWindow: NSWindow?
    private var started = false

    private init() {
        self.config = configStore.config
        self.updateDismissedBuild = configStore.config.dismissedUpdateBuild

        engine.onLog = { [weak self] s in
            Task { @MainActor in
                self?.status = s
                self?.noticeFinishedProject(in: s)
            }
        }
        updateService = UpdateService(nodeId: configStore.nodeId(),
                                      onUpdateAvailable: { [weak self] build, name in
            Task { @MainActor in
                guard let self, build > AppVersion.build, build > self.updateDismissedBuild, !self.updateInstalling else { return }
                self.updatePeerBuild = build
                self.updatePeerName = name
                self.updateAvailable = true
                self.updateIsRemote = false
            }
        }, onRemoteUpdateAvailable: { [weak self] version in
            Task { @MainActor in
                guard let self, !self.updateInstalling,
                      UpdateService.isNewer(version, than: AppVersion.short),
                      version != self.config.dismissedUpdateVersion else { return }
                self.updateRemoteVersion = version
                self.updatePeerName = "GitHub"
                self.updateAvailable = true
                self.updateIsRemote = true
            }
        })
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
        // Vérification GitHub : INDÉPENDANTE de la découverte LAN (elle fonctionne réseau local désactivé).
        updateService.setRemoteUpdates(config.remoteUpdateEnabled)
        checkLegacyAutomation()          // ancien service en doublon → proposer sa suppression
        if config.exportEnabled { connectNAS(); startNASWatch() }   // remonte le lecteur enregistré
    }

    // MARK: - export NAS : montage du partage (popup de login natif macOS si nécessaire)
    /// Relit les lecteurs réseau SMB montés (liste déroulante des préférences).
    func refreshNASVolumes() {
        nasVolumes = MountManager.networkVolumes()
        if nasVolumes.isEmpty && config.nasVolumePath.isEmpty {
            nasStatus = "Aucun lecteur réseau monté — connectez-le dans le Finder, puis actualisez."
        }
    }


    /// Pose ou retire le verrou. Le RETRAIT exige le mot de passe administrateur du Mac (comme le
    /// cadenas des Réglages Système) ; le poser n'a évidemment pas à être protégé.
    func setNASLock(_ locked: Bool) {
        if locked { update { $0.nasLocked = true }; nasStatus = "Réglages du lecteur verrouillés."; return }
        nasStatus = "Déverrouillage…"
        Task.detached { [weak self] in
            let ok = AdminAuth.authenticate(reason: "ScanToPDF veut déverrouiller le choix du lecteur réseau.")
            await MainActor.run { [weak self] in
                guard let self else { return }
                if ok { self.update { $0.nasLocked = false }; self.nasStatus = "Réglages déverrouillés." }
                else { self.nasStatus = "Déverrouillage refusé." }
            }
        }
    }

    /// Monte le lecteur enregistré s'il ne l'est plus.
    func connectNAS() {
        let path = config.nasVolumePath, from = config.nasMountFrom
        guard config.exportEnabled else { return }
        guard !path.isEmpty else { nasStatus = "Choisissez d'abord un lecteur réseau."; return }
        if MountManager.isMounted(path: path) { nasStatus = "Lecteur monté : \(path)"; return }
        nasStatus = "Montage de \(path)…"
        Task.detached { [weak self] in
            let ok = MountManager.remount(path: path, mountFrom: from)
            await MainActor.run { [weak self] in
                guard let self else { return }
                self.nasMountFailures = ok ? 0 : self.nasMountFailures + 1
                self.nasStatus = ok ? "Lecteur monté : \(path)"
                                    : "Lecteur injoignable — rien ne sera publié tant qu'il n'est pas monté."
                self.refreshNASVolumes()
            }
        }
    }

    /// Remonte le lecteur enregistré en arrière-plan s'il a été éjecté. Trois échecs consécutifs
    /// suspendent les tentatives : mieux vaut un statut explicite qu'un dialogue de connexion qui
    /// resurgit toutes les cinq minutes.
    private func startNASWatch() {
        nasRemountTask?.cancel()
        guard config.exportEnabled, !config.nasVolumePath.isEmpty else { return }
        nasRemountTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 300_000_000_000)   // 5 min
                guard let self else { return }
                let (path, from, tries) = await MainActor.run {
                    (self.config.nasVolumePath, self.config.nasMountFrom, self.nasMountFailures)
                }
                if path.isEmpty || tries >= 3 || MountManager.isMounted(path: path) { continue }
                let ok = MountManager.remount(path: path, mountFrom: from, timeout: 10)
                await MainActor.run { [weak self] in
                    guard let self else { return }
                    self.nasMountFailures = ok ? 0 : self.nasMountFailures + 1
                    if ok { self.nasStatus = "Lecteur remonté : \(path)" }
                }
            }
        }
    }

    // MARK: - fiche ISAD : modèles Ollama installés (menu des préférences)
    // Le modèle ENREGISTRÉ peut ne plus être installé (ou avoir été saisi à la main) : on le garde
    // dans la liste, sinon le menu afficherait une ligne vide au lieu de la valeur réellement utilisée.
    var isadModelChoices: [String] {
        let current = config.isadModel
        guard !current.isEmpty, !ollamaModels.contains(current) else { return ollamaModels }
        return ollamaModels + [current]
    }

    func refreshOllamaModels() {
        let host = config.isadHost
        ollamaStatus = "Recherche des modèles…"
        Task { [weak self] in
            var found = await OllamaModels.list(host: host)
            if found.isEmpty {
                // Ollama ne répond pas : s'il est installé ici, on le démarre plutôt que de renvoyer
                // l'utilisateur vers un terminal (le service met quelques secondes à s'ouvrir).
                await MainActor.run { [weak self] in self?.ollamaStatus = "Démarrage d'Ollama…" }
                found = await OllamaModels.startIfNeeded(host: host)
            }
            let models = found
            await MainActor.run { [weak self] in
                guard let self else { return }
                self.ollamaModels = models
                self.ollamaStatus = models.isEmpty
                    ? "Ollama introuvable ou sans modèle — installez-le et faites « ollama pull »."
                    : "\(models.count) modèle(s) installé(s)."
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
            await MainActor.run { [weak self] in
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
        let remoteChanged = c.remoteUpdateEnabled != config.remoteUpdateEnabled
        config = c
        configStore.save(c)
        if loginChanged { applyLoginItem() }
        if netChanged { c.networkEnabled ? updateService.start() : updateService.stop() }
        if remoteChanged { updateService.setRemoteUpdates(c.remoteUpdateEnabled) }
        if folderChanged { engine.restart(watchFolder: c.watchFolder) }
    }

    /// Applique en une fois un brouillon de configuration (bouton « Enregistrer » des préférences).
    /// Passe par update() pour conserver les effets de bord : dossier surveillé, réseau, login item.
    func applyConfig(_ new: AppConfig) {
        update { $0 = new }
        if new.exportEnabled { connectNAS() }
    }

    // MARK: - publication dans AtoM

    /// Repère « ✅ SUCCÈS : <cote> → <chemin du PDF> » dans le flux du moteur et prépare la publication.
    private func noticeFinishedProject(in line: String) {
        guard config.atomEnabled, line.contains("SUCCÈS"), let arrow = line.range(of: "→") else { return }
        let pdfPath = line[arrow.upperBound...].trimmingCharacters(in: .whitespaces)
        guard pdfPath.hasSuffix(".pdf") else { return }
        let pdf = URL(fileURLWithPath: pdfPath)
        prepareAtomPublication(pdf: pdf)
    }

    /// Ouvre la session AtoM. Renvoie un message d'échec explicite plutôt qu'un simple « refusé ».
    /// Renvoie nil en cas de succès, sinon le motif de l'échec.
    func openAtomSession(email: String, password: String, remember: Bool) async -> String? {
        guard let base = URL(string: config.atomBaseURL), base.scheme == "https" else {
            return "Adresse invalide : seul HTTPS est accepté."
        }
        let ok = await AtomClient.login(base: base, email: email, password: password)
        return await MainActor.run {
            if ok {
                self.atomSessionReady = true
                self.update { $0.atomEmail = email }
                if remember { _ = AtomCredentials.save(email: email, password: password) }
                self.atomStatus = "Session AtoM ouverte."
                return nil
            }
            self.atomStatus = "Connexion à AtoM refusée."
            return "Connexion refusée par AtoM — courriel ou mot de passe incorrect, ou compte sans droit d'édition." 
        }
    }

    /// S'assure qu'une session est ouverte, en demandant la connexion au PREMIER traitement.
    /// `done(false)` signifie que l'utilisateur a renoncé : la publication est alors abandonnée.
    private func ensureAtomSession(_ done: @escaping (Bool) -> Void) {
        if atomSessionReady { done(true); return }
        // Une seule fenêtre de connexion à la fois, même si plusieurs projets se terminent d'affilée.
        if atomLoginWindow != nil { done(false); return }
        let email = config.atomEmail
        let saved = AtomCredentials.password(for: email) ?? ""
        let view = AtomLoginView(email: email, password: saved, remember: !saved.isEmpty) { [weak self] ok in
            guard let self else { return }
            self.atomLoginWindow?.close(); self.atomLoginWindow = nil
            done(ok)
        }.environmentObject(self)
        let w = NSWindow(contentViewController: NSHostingController(rootView: view))
        w.title = "Connexion à AtoM"
        w.styleMask = [.titled, .closable]
        w.isReleasedWhenClosed = false
        w.center()
        atomLoginWindow = w
        NSApp.activate(ignoringOtherApps: true)
        w.makeKeyAndOrderFront(nil)
    }

    /// Construit la comparaison entre la notice AtoM (si elle existe, dans ses DEUX écritures de cote)
    /// et ce que propose la fiche ISAD, puis ouvre l'écran de confirmation.
    func prepareAtomPublication(pdf: URL) {
        // La connexion est demandée au PREMIER traitement de cette exécution ; renoncer annule la
        // publication mais ne touche en rien au PDF ni à la copie sur le lecteur réseau.
        ensureAtomSession { [weak self] ok in
            guard ok else { self?.atomStatus = "Publication AtoM ignorée (non connecté)."; return }
            self?.lookupAtomPublication(pdf: pdf)
        }
    }

    private func lookupAtomPublication(pdf: URL) {
        let folder = pdf.deletingLastPathComponent()
        let code = pdf.deletingPathExtension().lastPathComponent
        guard let base = URL(string: config.atomBaseURL) else { return }
        atomStatus = "Recherche de la notice « \(code) » dans AtoM…"
        Task { [weak self] in
            let fiche = folder.appendingPathComponent(code + ".txt")
            let text = (try? String(contentsOf: fiche, encoding: .utf8)) ?? ""
            var proposed = AtomClient.recordFromFiche(text, code: code)
            let match = await AtomClient.findExisting(base: base, code: code)
            // La cote proposée est TOUJOURS l'écriture « _ » : publier migre une ancienne notice.
            proposed.identifier = match.map { m in
                let prefix = m.record.identifier.replacingOccurrences(of: m.matchedCode, with: "")
                return prefix + code
            } ?? code
            var p = AtomPublication(code: code, folder: folder, pdf: pdf,
                                    proposed: proposed,
                                    slug: match?.slug, matchedCode: match?.matchedCode ?? code)
            p.fields = AtomClient.diff(existing: match?.record, proposed: proposed)
            await MainActor.run { [weak self] in
                guard let self else { return }
                self.atomStatus = match == nil ? "Nouvelle notice à créer." : "Notice existante trouvée."
                // Un passage du moteur peut terminer plusieurs projets : on les présente l'un après
                // l'autre plutôt que d'écraser la fenêtre en cours de relecture.
                if self.atomPending == nil { self.atomPending = p; self.openAtomWindow() }
                else if !self.atomQueue.contains(where: { $0.code == p.code }) { self.atomQueue.append(p) }
            }
        }
    }

    /// Envoie les seules valeurs modifiées, après validation dans l'écran de confirmation.
    func publishToAtom(_ p: AtomPublication) async -> Result<Void, Error> {
        guard let base = URL(string: config.atomBaseURL) else {
            return .failure(AtomClient.AtomError.rejected("adresse AtoM invalide"))
        }
        guard base.scheme == "https" else {
            return .failure(AtomClient.AtomError.rejected("seul HTTPS est accepté pour publier"))
        }
        // La session a été ouverte au premier traitement ; si le serveur l'a expirée entre-temps,
        // on la rouvre avec le mot de passe conservé, à défaut on redemande la connexion.
        if await !AtomClient.isLoggedIn(base: base) {
            let email = config.atomEmail
            guard let password = AtomCredentials.password(for: email),
                  await AtomClient.login(base: base, email: email, password: password) else {
                await MainActor.run { self.atomSessionReady = false }
                return .failure(AtomClient.AtomError.notLoggedIn)
            }
        }
        guard let slug = p.slug else {
            return .failure(AtomClient.AtomError.rejected(
                "aucune notice cible — ScanToPDF ne crée jamais de notice"))
        }
        switch await AtomClient.submitEdit(base: base, slug: slug, changes: p.changes) {
        case .success:            return .success(())
        case .failure(let e):     return .failure(e)
        }
    }

    /// Vérifie les identifiants sans rien publier.
    func testAtomLogin() {
        guard let base = URL(string: config.atomBaseURL), base.scheme == "https" else {
            atomStatus = "Adresse invalide : seul HTTPS est accepté."; return
        }
        let email = config.atomEmail
        guard let password = AtomCredentials.password(for: email) else {
            atomStatus = "Aucun mot de passe enregistré pour « \(email) »."; return
        }
        atomStatus = "Connexion à AtoM…"
        Task { [weak self] in
            let ok = await AtomClient.login(base: base, email: email, password: password)
            await MainActor.run { [weak self] in
                self?.atomStatus = ok ? "✅ Connexion réussie." : "Connexion refusée — vérifiez les identifiants."
            }
        }
    }

    /// Relance la recherche automatique (les deux écritures de cote) sur la publication en cours.
    func retryAtomLookup(_ p: AtomPublication) async -> AtomPublication {
        guard let base = URL(string: config.atomBaseURL) else { return p }
        let match = await AtomClient.findExisting(base: base, code: p.code)
        return await MainActor.run { apply(match: match, to: p) }
    }

    /// Rattache la publication à une notice désignée à la main (adresse, identifiant ou cote).
    func resolveAtomManually(_ p: AtomPublication, input: String) async -> AtomPublication {
        guard let base = URL(string: config.atomBaseURL) else { return p }
        let match = await AtomClient.resolve(base: base, input: input)
        return await MainActor.run { apply(match: match, to: p) }
    }

    /// Ouvre la recherche AtoM dans le navigateur, pour retrouver la notice à l'œil.
    func openAtomSearch(for code: String) {
        guard let base = URL(string: config.atomBaseURL),
              let url = AtomClient.searchURL(base: base, code: code) else { return }
        NSWorkspace.shared.open(url)
    }

    /// Recompose la comparaison à partir d'une notice retrouvée — la proposition, elle, ne bouge pas.
    private func apply(match: AtomClient.Match?, to p: AtomPublication) -> AtomPublication {
        var out = p
        out.slug = match?.slug
        out.matchedCode = match?.matchedCode ?? p.code
        var proposed = p.proposed
        if let m = match {
            // La cote proposée reste l'écriture « _ » : publier migre une notice en ancienne forme.
            let prefix = m.record.identifier.replacingOccurrences(of: m.matchedCode, with: "")
            proposed.identifier = prefix + p.code
        }
        out.fields = AtomClient.diff(existing: match?.record, proposed: proposed)
        atomStatus = match == nil ? "Toujours introuvable dans AtoM." : "Notice rattachée : /\(match!.slug)"
        return out
    }

    private func openAtomWindow() {
        guard let p = atomPending else { return }
        atomWindow?.close()
        let host = NSHostingController(rootView: AtomPublishView(publication: p) { [weak self] in
            guard let self else { return }
            self.atomWindow?.close(); self.atomWindow = nil
            self.atomPending = self.atomQueue.isEmpty ? nil : self.atomQueue.removeFirst()
            if self.atomPending != nil { self.openAtomWindow() }
        }.environmentObject(self))
        let w = NSWindow(contentViewController: host)
        w.title = "Publier dans AtoM — \(p.code)"
        w.styleMask = [.titled, .closable, .miniaturizable]
        w.isReleasedWhenClosed = false
        w.center()
        atomWindow = w
        NSApp.activate(ignoringOtherApps: true)
        w.makeKeyAndOrderFront(nil)
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
            w.setContentSize(NSSize(width: 580, height: 640))
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

    // « Plus tard » : on mémorise ce qui a été refusé. LAN = numéro de build, GitHub = version publiée
    // (deux espaces de valeurs distincts : refuser une version ne doit pas masquer les MAJ du réseau).
    func dismissUpdate() {
        updateAvailable = false
        if updateIsRemote {
            config.dismissedUpdateVersion = updateRemoteVersion
        } else {
            updateDismissedBuild = updatePeerBuild
            config.dismissedUpdateBuild = updatePeerBuild
        }
        configStore.save(config)
    }

    // Vérification manuelle immédiate des releases GitHub.
    func checkRemoteUpdates() {
        updateService.checkRemoteUpdates()
        status = "Vérification des MAJ…."
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
