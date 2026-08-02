import Foundation

// Supervise le moteur Python EMBARQUÉ (Contents/Resources/python + engine/*.py) :
// - lance le watcher (file d'attente : surveille le dossier, déclenche le workflow) ;
// - relance automatiquement le watcher s'il meurt (OOM/segfault) ;
// - arrête proprement le sous-arbre (watcher + OCR) sans laisser d'orphelin ;
// - construit l'environnement d'exécution (binaires bundlés, TESSDATA_PREFIX, GS_LIB, config…).
final class Engine {
    var onLog: (String) -> Void = { _ in }
    private var watcher: Process?
    private var stopping = false
    private var currentWatchFolder = ""

    // Resources du bundle : .../ScanToPDF.app/Contents/Resources
    private var res: URL { Bundle.main.bundleURL.appendingPathComponent("Contents/Resources", isDirectory: true) }
    private var pythonBin: String { res.appendingPathComponent("python/bin/python3").path }
    private var binDir: String { res.appendingPathComponent("bin").path }
    private var tessdata: String { res.appendingPathComponent("share/tessdata").path }
    private var gsLib: String { res.appendingPathComponent("gs-lib").path }   // ressources Ghostscript embarquées
    private var watcherScript: String { res.appendingPathComponent("engine/archivage_watcher.py").path }
    private var workflowScript: String { res.appendingPathComponent("engine/archivage_workflow.py").path }

    var isBundled: Bool { FileManager.default.fileExists(atPath: pythonBin) }

    private func makeEnv(watchFolder: String) -> [String: String] {
        var e = ProcessInfo.processInfo.environment
        e["PATH"] = "\(binDir):/usr/bin:/bin:/usr/sbin:/sbin"
        e["TESSDATA_PREFIX"] = tessdata
        // Ghostscript relocalisé : il doit trouver gs_init.ps, ses ressources, fonts et profils ICC (autonomie).
        e["GS_LIB"] = "\(gsLib)/Resource/Init:\(gsLib)/lib:\(gsLib)/Resource/Font:\(gsLib)/Resource:\(gsLib)/fonts:\(gsLib)/iccprofiles:\(gsLib)"
        e["SCANTOPDF_GSLIB"] = gsLib                 // pour retrouver iccprofiles/srgb.icc (OutputIntent PDF/A)
        e["SCANTOPDF_CONFIG"] = AppPaths.configURL.path
        e["SCANTOPDF_GS"] = "\(binDir)/gs"
        e["SCANTOPDF_APPSUPPORT"] = AppPaths.appSupport.path
        // Règle de regroupement : le moteur la lit dans config.json (source UNIQUE de vérité). On ne
        // pose PLUS SCANTOPDF_PAGE_DELIMITER ici : cette variable était prioritaire côté Python et,
        // figée en dur, elle écrasait le séparateur choisi dans les préférences.
        e.removeValue(forKey: "SCANTOPDF_PAGE_DELIMITER")
        e["SCAN_DIR"] = watchFolder
        e["TMPDIR"] = AppPaths.tempDir.path
        // Tesseract/OCRmyPDF : 1 thread par page, parallélisation au niveau pages (Apple Silicon).
        e["OMP_THREAD_LIMIT"] = "1"
        e["OMP_NUM_THREADS"] = "1"
        // Python relocatable : ne pas hériter d'un PYTHONHOME/PYTHONPATH parasite du système.
        e.removeValue(forKey: "PYTHONHOME")
        e.removeValue(forKey: "PYTHONPATH")
        // CRITIQUE : ne JAMAIS écrire de .pyc dans le bundle (sinon la signature du .app est invalidée →
        // la mise à jour réseau échouerait). Bytecode pré-compilé au build. Sortie non tamponnée.
        e["PYTHONDONTWRITEBYTECODE"] = "1"
        e["PYTHONUNBUFFERED"] = "1"
        return e
    }

    func start(watchFolder: String) {
        guard isBundled else { onLog("Moteur Python embarqué introuvable dans le bundle."); return }
        try? FileManager.default.createDirectory(at: AppPaths.tempDir, withIntermediateDirectories: true)
        try? FileManager.default.createDirectory(at: AppPaths.logsDir, withIntermediateDirectories: true)
        // Le watcher gère lui-même la file d'attente ET le rattrapage initial (fichiers déjà présents).
        stop()
        stopping = false
        currentWatchFolder = watchFolder
        let p = Process()
        p.executableURL = URL(fileURLWithPath: pythonBin)
        p.arguments = [watcherScript]
        p.environment = makeEnv(watchFolder: watchFolder)
        let pipe = Pipe()
        p.standardOutput = pipe
        p.standardError = pipe
        pipe.fileHandleForReading.readabilityHandler = { [weak self] h in
            let d = h.availableData
            guard !d.isEmpty, let s = String(data: d, encoding: .utf8) else { return }
            let line = s.trimmingCharacters(in: .whitespacesAndNewlines)
            if !line.isEmpty { self?.onLog(line) }
        }
        // Mort inattendue du watcher (OOM/segfault) → relance (sauf arrêt volontaire), sinon la
        // surveillance s'éteindrait en silence. main.async : sérialise avec start/stop (appelés sur le main).
        p.terminationHandler = { [weak self] proc in
            DispatchQueue.main.async {
                guard let self, !self.stopping, self.watcher === proc else { return }
                self.watcher = nil
                self.onLog("Surveillance interrompue — relance dans 3 s.")
                let folder = self.currentWatchFolder
                DispatchQueue.main.asyncAfter(deadline: .now() + 3) { [weak self] in
                    guard let self, !self.stopping, self.watcher == nil else { return }
                    self.start(watchFolder: folder)
                }
            }
        }
        do {
            try p.run()
            watcher = p
            onLog("Surveillance active : \(watchFolder)")
        } catch {
            onLog("Échec du démarrage de la surveillance : \(error.localizedDescription)")
        }
    }

    // Lance UN passage du workflow (bouton « Traiter maintenant »). Sortie vers /dev/null : aucun pipe
    // non drainé ne peut bloquer le workflow (#12). Le verrou fichier gère la concurrence avec le watcher.
    func runWorkflowOnce(watchFolder: String) {
        guard isBundled else { return }
        let p = Process()
        p.executableURL = URL(fileURLWithPath: pythonBin)
        p.arguments = [workflowScript]
        p.environment = makeEnv(watchFolder: watchFolder)
        p.standardOutput = FileHandle.nullDevice
        p.standardError = FileHandle.nullDevice
        try? p.run()
    }

    // Arrêt SYNCHRONE et borné : SIGTERM (le watcher tue son sous-arbre OCR), attente, puis SIGKILL.
    func stop() {
        stopping = true
        guard let w = watcher else { return }
        watcher = nil
        (w.standardOutput as? Pipe)?.fileHandleForReading.readabilityHandler = nil
        w.terminationHandler = nil
        if w.isRunning {
            w.terminate()   // SIGTERM → handler Python : arrêt de l'observer + kill du groupe (OCR compris)
            let deadline = Date().addingTimeInterval(6)
            while w.isRunning && Date() < deadline { usleep(100_000) }   // 100 ms
            if w.isRunning { kill(w.processIdentifier, SIGKILL) }
        }
    }

    func restart(watchFolder: String) {
        stop()
        start(watchFolder: watchFolder)
    }
}
