import Foundation

// Configuration persistée dans /Users/Shared/ScanToPDF/config.json.
// C'est CE fichier que lit le moteur Python (archivage_workflow.py) à chaque traitement :
// décocher une case ici change le comportement du pipeline sans recompiler.
struct AppConfig: Codable {
    var watchFolder: String = "/Users/Shared/FVJC_SCAN"   // dossier surveillé
    // Règle de regroupement des fichiers par projet / page (configurée via menu dans les préférences) :
    // Les noms suivent le schéma : <projectIdentifier><separator><pageN>.tif (ex. « Eg.w.O0.1901_29-1.tif »)
    // — pageSeparator : caractère entre l'identifiant projet et le n° de pagination (menu : -, _, ., ~, :, espace)
    // — pageDelimiter : caractère entre le n° du document et le n° de page au sein d'une série (ex. « - » dans Doc_29-1.tif)
    var pageSeparator: String = "_"   // sépare l'identifiant projet du n° de pagination (défaut : « _ »)
    var pageDelimiter: String = "-"   // sépare le n° du doc du n° de page au sein d'une série (défaut : « - »)
    // Étapes du pipeline (cases à cocher) :
    var ocr: Bool = true             // couche texte OCR (fra+eng)
    var tesseractPSM: Int = 3        // segmentation : 3=auto (détecte les COLONNES), 4=colonne unique, 6=bloc
    var ocrThreshold: String = "adaptive-otsu"  // binarisation Tesseract : adaptive-otsu / sauvola / auto
    var deskew: Bool = true          // redressement des pages inclinées
    var clean: Bool = true           // nettoyage image (unpaper)
    var rotate: Bool = true          // rotation automatique de l'orientation
    var rotateThreshold: Int = 15    // seuil de confiance OSD (plus élevé = moins de rotations ERRONÉES)
    var compress: Bool = true        // compression Ghostscript
    var dpi: Int = 150               // résolution cible de la compression
    var pdfa: Bool = true            // sortie PDF/A-2b (métadonnées) sinon PDF simple
    var notify: Bool = true          // notification macOS en fin de traitement
    // Suppression des originaux : opt-in EXPLICITE, OFF par défaut. Les originaux (TIFF ET PDF) sont
    // conservés dans le sous-dossier projet ; activé, ils sont supprimés à l'identique (jamais le résultat).
    var deleteOriginals: Bool = false
    // Filigrane apposé sur chaque page :
    var watermarkEnabled: Bool = false           // activer le filigrane
    var watermarkText: String = ""               // texte du filigrane (ex. « ARCHIVES FVJC »)
    var watermarkPosition: String = "diagonal"   // diagonal / center / top / bottom / tile
    var watermarkOpacity: Int = 20               // 0–100 (plus élevé = plus visible/sombre)
    var watermarkHard: Bool = true               // true = fusionné (non supprimable) ; false = calque OCG
    // Application :
    var startAtLogin: Bool = true    // démarrer avec le système (login item)
    var networkEnabled: Bool = true  // découverte réseau + invitation de mise à jour
    var remoteUpdateEnabled: Bool = true  // vérification périodique des releases GitHub
    var dismissedUpdateBuild: Int = 0 // build refusé via « Plus tard » (ne plus reproposer)
    // Export du résultat vers le NAS (Synology). Le dossier projet est classé selon son nom
    // (« Eg.w.O0.… » → Eg/w/O0/) sur le NAS SMB monté (priorité), sinon dans le dossier Synology Drive.
    var exportEnabled: Bool = false  // copier le dossier résultat vers le NAS / Synology Drive
    var nasHost: String = "192.168.0.100"  // serveur SMB (IP ou nom)
    var nasShare: String = ""        // nom du partage SMB (monté sous /Volumes/<share>)
    var nasSubpath: String = ""      // sous-dossier racine des archives sous le partage (optionnel)
    var nasUser: String = ""         // nom d'utilisateur SMB (le mot de passe passe par le dialogue macOS/Trousseau)
    var driveFolder: String = ""     // dossier Synology Drive local (repli si NAS non monté)

    init() {}

    // Décodage tolérant : une clé absente reprend la valeur par défaut.
    init(from decoder: Decoder) throws {
        self.init()   // repli sur les valeurs par défaut des propriétés → source UNIQUE de vérité
        let c = try decoder.container(keyedBy: CodingKeys.self)
        func d<T: Decodable>(_ key: CodingKeys, _ def: T) -> T { (try? c.decode(T.self, forKey: key)) ?? def }
        watchFolder = d(.watchFolder, watchFolder)
        pageSeparator = d(.pageSeparator, pageSeparator)
        pageDelimiter = d(.pageDelimiter, pageDelimiter)
        ocr = d(.ocr, ocr)
        tesseractPSM = d(.tesseractPSM, tesseractPSM)
        ocrThreshold = d(.ocrThreshold, ocrThreshold)
        deskew = d(.deskew, deskew)
        clean = d(.clean, clean)
        rotate = d(.rotate, rotate)
        rotateThreshold = max(2, min(60, d(.rotateThreshold, rotateThreshold)))
        compress = d(.compress, compress)
        dpi = max(72, min(600, d(.dpi, dpi)))     // borné : un config.json trafiqué ne casse pas gs
        pdfa = d(.pdfa, pdfa)
        notify = d(.notify, notify)
        deleteOriginals = d(.deleteOriginals, deleteOriginals)
        watermarkEnabled = d(.watermarkEnabled, watermarkEnabled)
        watermarkText = d(.watermarkText, watermarkText)
        watermarkPosition = d(.watermarkPosition, watermarkPosition)
        watermarkOpacity = max(0, min(100, d(.watermarkOpacity, watermarkOpacity)))
        watermarkHard = d(.watermarkHard, watermarkHard)
        startAtLogin = d(.startAtLogin, startAtLogin)
        networkEnabled = d(.networkEnabled, networkEnabled)
        dismissedUpdateBuild = d(.dismissedUpdateBuild, dismissedUpdateBuild)
        exportEnabled = d(.exportEnabled, exportEnabled)
        nasHost = d(.nasHost, nasHost)
        nasShare = d(.nasShare, nasShare)
        nasSubpath = d(.nasSubpath, nasSubpath)
        nasUser = d(.nasUser, nasUser)
        driveFolder = d(.driveFolder, driveFolder)
    }
}

// Version de l'application, lue depuis l'Info.plist du bundle.
// `build` = numéro monotone (CFBundleVersion horodaté par build_app.sh) comparé entre Mac.
// build == 0 ⇒ exécution hors .app (swift run) : aucune mise à jour auto autorisée.
enum AppVersion {
    static var build: Int { Int(Bundle.main.infoDictionary?["CFBundleVersion"] as? String ?? "0") ?? 0 }
    static var short: String { Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "?" }
    // Révision git compilée dans le binaire (via -DAPP_GIT_COUNT / -DAPP_GIT_SHA dans build_app.sh).
    static var gitCount: Int { Int(_gitCount) ?? 0 }
    static var gitSha: String { _gitSha.isEmpty ? "?" : _gitSha }
    static var revision: String { "\(_gitCount):\(_gitSha.isEmpty ? "?" : _gitSha)" }
}

// Emplacements runtime. Base PARTAGÉE /Users/Shared/ScanToPDF (accessible à tous les comptes du Mac),
// repli par compte si le partagé est inaccessible.
enum AppPaths {
    static let sharedBase = URL(fileURLWithPath: "/Users/Shared/ScanToPDF", isDirectory: true)

    static let appSupport: URL = {
        let fm = FileManager.default
        if !fm.fileExists(atPath: sharedBase.path) {
            // setgid (2) → héritage du groupe ; group staff (gid 20) = tous les comptes locaux.
            try? fm.createDirectory(at: sharedBase, withIntermediateDirectories: true,
                                    attributes: [.posixPermissions: 0o2770, .groupOwnerAccountID: 20])
        }
        if fm.isWritableFile(atPath: sharedBase.path) { return sharedBase }
        let base = fm.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
            .appendingPathComponent("ScanToPDF", isDirectory: true)
        try? fm.createDirectory(at: base, withIntermediateDirectories: true)
        return base
    }()

    static var configURL: URL { appSupport.appendingPathComponent("config.json") }
    static var logsDir: URL { appSupport.appendingPathComponent("logs", isDirectory: true) }
    static var tempDir: URL { appSupport.appendingPathComponent("temp", isDirectory: true) }
    static var nodeIdURL: URL { appSupport.appendingPathComponent("node.id") }
}

// Journal fichier partagé (append), utilisé pour les diagnostics MAJ réseau et suppression legacy.
// Factorise ce qui était dupliqué entre UpdateService.ulog et LegacyCleanup.log.
enum FileLog {
    private static let iso = ISO8601DateFormatter()
    static func append(_ message: String, to name: String) {
        let path = AppPaths.appSupport.appendingPathComponent(name).path
        let line = "\(iso.string(from: Date()))  \(message)\n"
        if FileManager.default.fileExists(atPath: path), let h = FileHandle(forWritingAtPath: path) {
            h.seekToEndOfFile(); if let d = line.data(using: .utf8) { h.write(d) }; try? h.close()
        } else {
            try? line.write(toFile: path, atomically: true, encoding: .utf8)
        }
    }
}

final class ConfigStore {
    private(set) var config: AppConfig

    init() {
        if let data = try? Data(contentsOf: AppPaths.configURL),
           let cfg = try? JSONDecoder().decode(AppConfig.self, from: data) {
            self.config = cfg
        } else {
            self.config = AppConfig()
        }
    }

    func save(_ cfg: AppConfig) {
        self.config = cfg
        let enc = JSONEncoder()
        enc.outputFormatting = [.prettyPrinted, .sortedKeys]
        if let data = try? enc.encode(cfg) { try? data.write(to: AppPaths.configURL) }
    }

    // Identifiant stable de ce nœud (pour la découverte réseau), persisté entre les lancements.
    func nodeId() -> String {
        if let s = try? String(contentsOf: AppPaths.nodeIdURL, encoding: .utf8) {
            let t = s.trimmingCharacters(in: .whitespacesAndNewlines)
            if !t.isEmpty { return t }
        }
        let id = UUID().uuidString
        try? id.write(to: AppPaths.nodeIdURL, atomically: true, encoding: .utf8)
        return id
    }
}
