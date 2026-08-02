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
    // Filigrane apposé sur chaque page (TEXTE ou IMAGE au choix) :
    var watermarkEnabled: Bool = false           // activer le filigrane
    var watermarkType: String = "text"           // « text » = texte, « image » = fichier PNG/JPEG
    var watermarkText: String = ""               // texte du filigrane (ex. « ARCHIVES FVJC »)
    var watermarkImagePath: String = ""          // chemin absolu de l'image (type « image »)
    var watermarkPosition: String = "diagonal"   // diagonal / center / top / bottom / tile
    var watermarkOpacity: Int = 20               // 0–100 (plus élevé = plus visible/sombre)
    var watermarkHard: Bool = true               // true = fusionné (non supprimable) ; false = calque OCG
    // Fiche archivistique ISAD(G) : après le PDF final, un LLM local (Ollama) résume le document
    // scanné en champs ISAD et écrit un « <nom>.txt » à côté du PDF. Opt-in, OFF par défaut (aucun
    // appel réseau ni fichier annexe tant que non coché). Ollama tourne hors de l'app (non bundlé).
    var isadEnabled: Bool = false               // générer la fiche texte ISAD à côté du PDF
    var isadModel: String = "qwen3.5:9b"        // modèle Ollama interrogé (doit être « pull » au préalable)
    var isadHost: String = "http://localhost:11434"  // URL de base de l'API Ollama locale
    // Contexte du fonds transmis au modèle, éditable dans les préférences. Sans lui le modèle invente
    // le sens des sigles (« FVJC » a déjà été développé en « Front des Veilleurs Juifs et Chrétiens »).
    // ⚠️ Ce texte par défaut doit rester identique à ISAD_CONTEXT_DEFAULT dans engine/archivage_workflow.py.
    var isadContext: String = AppConfig.defaultIsadContext

    static let defaultIsadContext = """
    CONTEXTE DU FONDS

    Les documents décrits proviennent des archives de la FVJC — Fédération vaudoise des jeunesses \
    campagnardes. Dans ce fonds, le sigle « FVJC » désigne toujours cette fédération et jamais autre chose.

    La FVJC fédère les sociétés de jeunesse des villages du canton de Vaud, en Suisse romande. Sauf \
    indication contraire explicite dans le document, les personnes, lieux et événements mentionnés se \
    rapportent au canton de Vaud et à la Suisse romande, et la langue des documents est le français.

    NATURE DES DOCUMENTS

    Le fonds réunit des pièces produites ou reçues par la fédération, par ses groupements régionaux et par \
    les sociétés de jeunesse des villages : procès-verbaux d'assemblées et de comités, rapports d'activité, \
    correspondance, statuts et règlements, programmes et brochures de manifestations, affiches, comptes et \
    budgets, listes de membres, coupures de presse, photographies légendées. Les documents sont le plus \
    souvent dactylographiés ou imprimés, parfois manuscrits.

    VOCABULAIRE DU FONDS

    - « jeunesse » ou « société de jeunesse » : association des jeunes d'un village.
    - « giron » : groupement régional de sociétés de jeunesse, et par extension la fête qu'il organise.
    - « cantonale » : grande manifestation réunissant l'ensemble de la fédération.
    - « camping » : terrain d'hébergement des participants pendant une manifestation.
    - « cortège », « bal », « cantine », « joutes », « comité », « caissier », « syndic », « commune » : \
    termes d'organisation associative ou d'administration communale vaudoise, à conserver dans ce sens.

    CONSIGNES DE DESCRIPTION

    - Décris uniquement ce qui figure dans le texte fourni ; n'ajoute aucune connaissance extérieure.
    - Ne développe JAMAIS un sigle qui ne t'est pas connu : recopie-le tel quel.
    - Le texte provient d'une reconnaissance optique et peut contenir des erreurs, des mots coupés ou des \
    accents manquants : ignore les coquilles évidentes sans en altérer le sens.
    - Ces notices alimentent un catalogue d'archives : reste factuel, neutre et concis, sans jugement de \
    valeur ni tournure promotionnelle.
    """
    // Application :
    var startAtLogin: Bool = true    // démarrer avec le système (login item)
    var networkEnabled: Bool = true  // découverte réseau + invitation de mise à jour
    var remoteUpdateEnabled: Bool = true  // vérification périodique des releases GitHub
    var dismissedUpdateBuild: Int = 0 // build LAN refusé via « Plus tard » (ne plus reproposer)
    var dismissedUpdateVersion: String = ""  // version GitHub refusée via « Plus tard » (ex. « 1.0.8 »)
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
        watermarkType = d(.watermarkType, watermarkType)
        watermarkText = d(.watermarkText, watermarkText)
        watermarkImagePath = d(.watermarkImagePath, watermarkImagePath)
        watermarkPosition = d(.watermarkPosition, watermarkPosition)
        watermarkOpacity = max(0, min(100, d(.watermarkOpacity, watermarkOpacity)))
        watermarkHard = d(.watermarkHard, watermarkHard)
        isadEnabled = d(.isadEnabled, isadEnabled)
        isadModel = d(.isadModel, isadModel)
        isadHost = d(.isadHost, isadHost)
        isadContext = d(.isadContext, isadContext)
        startAtLogin = d(.startAtLogin, startAtLogin)
        networkEnabled = d(.networkEnabled, networkEnabled)
        remoteUpdateEnabled = d(.remoteUpdateEnabled, remoteUpdateEnabled)   // sinon le réglage ne survivait pas au redémarrage
        dismissedUpdateBuild = d(.dismissedUpdateBuild, dismissedUpdateBuild)
        dismissedUpdateVersion = d(.dismissedUpdateVersion, dismissedUpdateVersion)
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
    // Révision git, écrite dans l'Info.plist par build_app.sh (« <count>:<sha> »). Elle passait autrefois
    // par « -D NOM=valeur », ce qui n'existe pas en Swift (un flag est présent ou absent, jamais valué) :
    // la valeur était donc toujours vide et la révision jamais affichée.
    static var revision: String { Bundle.main.infoDictionary?["SCGitRevision"] as? String ?? "" }
    static var hasRevision: Bool { !revision.isEmpty && revision != "0:none" }
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
