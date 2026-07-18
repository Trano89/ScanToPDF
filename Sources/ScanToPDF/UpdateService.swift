import Foundation
import Network
import Security
import CryptoKit

// Découverte P2P (Bonjour) + mise à jour de l'app entre Mac du même réseau.
// Version allégée du SyncService d'ArchivesSearch : on ne garde QUE la mise à jour de l'application
// (aucune synchro d'index). Chaque Mac annonce son numéro de build ; s'il en existe un plus récent
// sur le réseau, on prévient l'app (invitation), et sur action de l'utilisateur on télécharge le
// bundle .app du pair (chiffré TLS-PSK), on le vérifie (SHA-256 + signature) puis on le remplace.
final class UpdateService {
    static let serviceType = "_scantopdf._tcp"
    static let appSecret = "scantopdf-lan-v1"   // clé partagée du cluster ScanToPDF (base de la clé TLS-PSK)

    private let nodeId: String
    private let onUpdateAvailable: (Int, String) -> Void

    private let queue = DispatchQueue(label: "scantopdf.update")
    private var listener: NWListener?
    private var browser: NWBrowser?
    private var refreshTask: Task<Void, Never>?

    private struct UpdateTarget { let endpoint: NWEndpoint; let build: Int }
    private var updateTarget: UpdateTarget?
    private var activeServes = 0                 // nb de transferts sortants en cours (anti-DoS)
    private static let maxServes = 3             // au-delà, on refuse (ditto d'un gros bundle = coûteux)

    // Une seule trame Codable, encodée en JSON, cadrée par longueur (UInt32 BE + payload).
    private struct Wire: Codable {
        var type: String
        var ab: String?    // tranche de l'archive, base64
        var ai: Int?       // index de la tranche
        var at: Int?       // nombre total de tranches
        var asz: Int64?    // taille de l'archive (octets)
        var bld: Int?      // numéro de build servi
        var sha: String?   // SHA-256 (hex) de l'archive complète
    }

    init(nodeId: String, onUpdateAvailable: @escaping (Int, String) -> Void) {
        self.nodeId = nodeId
        self.onUpdateAvailable = onUpdateAvailable
    }

    func start() {
        stop()
        startListener()
        startBrowser()
        refreshTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 15_000_000_000)   // 15 s
                self?.refreshAdvertisement()
            }
        }
    }

    func stop() {
        refreshTask?.cancel(); refreshTask = nil
        listener?.cancel(); browser?.cancel()
        listener = nil; browser = nil
        queue.async { self.updateTarget = nil }
    }

    // MARK: - TLS-PSK (clé pré-partagée)
    // Si une PHRASE SECRÈTE de cluster est définie (ClusterSecret), la clé en est dérivée (HKDF) → seuls
    // les Mac connaissant la phrase peuvent se découvrir/servir/recevoir une MAJ (durcissement, ferme la
    // porte à un hôte inconnu du LAN). Sinon, secret d'app historique (mode par défaut, compat découverte).
    private func clusterPSK() -> Data {
        if let phrase = ClusterSecret.load() {
            let derived = HKDF<SHA256>.deriveKey(inputKeyMaterial: SymmetricKey(data: Data(phrase.utf8)),
                                                 salt: Data("scantopdf-cluster-v2".utf8),
                                                 info: Data("tls-psk".utf8), outputByteCount: 32)
            return derived.withUnsafeBytes { Data($0) }
        }
        let key = SymmetricKey(data: Data(Self.appSecret.utf8))
        let mac = HMAC<SHA256>.authenticationCode(for: Data("scantopdf".utf8), using: key)
        return Data(mac)
    }

    private func tlsParameters() -> NWParameters {
        let tls = NWProtocolTLS.Options()
        let identity = "scantopdf"
        let keyDD = clusterPSK().withUnsafeBytes { DispatchData(bytes: $0) }
        let idDD = Data(identity.utf8).withUnsafeBytes { DispatchData(bytes: $0) }
        sec_protocol_options_add_pre_shared_key(tls.securityProtocolOptions, keyDD as __DispatchData, idDD as __DispatchData)
        sec_protocol_options_append_tls_ciphersuite(tls.securityProtocolOptions,
                                                    tls_ciphersuite_t(rawValue: TLS_PSK_WITH_AES_128_GCM_SHA256)!)
        let params = NWParameters(tls: tls)
        params.includePeerToPeer = false
        if let tcp = params.defaultProtocolStack.transportProtocol as? NWProtocolTCP.Options {
            tcp.connectionTimeout = 15
        }
        return params
    }

    private func txtRecord() -> NWTXTRecord {
        var t = NWTXTRecord()
        t["node"] = nodeId
        t["app"] = "\(AppVersion.build)"     // version de l'app (comparée entre Mac)
        t["mac"] = NetworkAdmin.macName()     // nom convivial du Mac
        return t
    }

    // MARK: - annonce (NWListener)
    private func startListener() {
        do {
            let l = try NWListener(using: tlsParameters())
            l.service = NWListener.Service(name: nodeId, type: Self.serviceType, domain: nil, txtRecord: txtRecord())
            l.newConnectionHandler = { [weak self] conn in self?.handleIncoming(conn) }
            l.stateUpdateHandler = { [weak self] state in
                guard let self else { return }
                // .failed est terminal (perte mDNSResponder, conflit de port…) → on recrée avec back-off,
                // sinon l'annonce s'éteindrait en silence.
                if case .failed(let e) = state {
                    Self.ulog("listener .failed: \(e.localizedDescription) — recréation dans 3s")
                    self.queue.asyncAfter(deadline: .now() + 3) { [weak self] in
                        guard let self, self.listener != nil else { return }
                        self.listener?.cancel(); self.startListener()
                    }
                }
            }
            l.start(queue: queue)
            listener = l
        } catch {
            Self.ulog("listener: échec démarrage — \(error.localizedDescription)")
        }
    }

    func refreshAdvertisement() {
        queue.async { [weak self] in
            guard let self, let l = self.listener else { return }
            l.service = NWListener.Service(name: self.nodeId, type: Self.serviceType, domain: nil, txtRecord: self.txtRecord())
        }
    }

    // MARK: - découverte (NWBrowser)
    private func startBrowser() {
        let b = NWBrowser(for: .bonjourWithTXTRecord(type: Self.serviceType, domain: nil), using: NWParameters())
        b.browseResultsChangedHandler = { [weak self] results, _ in self?.handleResults(results) }
        b.stateUpdateHandler = { [weak self] state in
            guard let self else { return }
            if case .failed(let e) = state {
                Self.ulog("browser .failed: \(e.localizedDescription) — recréation dans 3s")
                self.queue.asyncAfter(deadline: .now() + 3) { [weak self] in
                    guard let self, self.browser != nil else { return }
                    self.browser?.cancel(); self.startBrowser()
                }
            }
        }
        b.start(queue: queue)
        browser = b
    }

    // Retient le pair au build le plus élevé (> le nôtre) et prévient l'app.
    private func handleResults(_ results: Set<NWBrowser.Result>) {
        var bestBuild = AppVersion.build
        var bestEndpoint: NWEndpoint?
        var bestName = ""
        for r in results {
            guard case .bonjour(let txt) = r.metadata else { continue }
            let node = txt["node"] ?? ""
            if node.isEmpty || node == nodeId { continue }   // ignore soi-même
            let peerApp = Int(txt["app"] ?? "0") ?? 0
            if peerApp > bestBuild {
                bestBuild = peerApp
                bestEndpoint = r.endpoint
                bestName = txt["mac"].flatMap { $0.isEmpty ? nil : $0 } ?? String(node.prefix(8))
            }
        }
        // Notifie l'app s'il existe une version plus récente (l'install reste sur action utilisateur).
        if AppVersion.build > 0, let ep = bestEndpoint, bestBuild > AppVersion.build {
            updateTarget = UpdateTarget(endpoint: ep, build: bestBuild)   // (déjà sur la file du browser)
            onUpdateAvailable(bestBuild, bestName)
        }
    }

    // MARK: - service (répondeur) : sert NOTRE bundle à un pair plus ancien qui envoie « apppull »
    private func handleIncoming(_ conn: NWConnection) {
        conn.stateUpdateHandler = { [weak self] state in
            guard let self else { return }
            switch state {
            case .ready:
                // Watchdog serveur (symétrique au client) : un pair qui complète le TLS mais n'envoie
                // jamais d'entête laisserait la Task bloquée → on coupe après 60 s (fuite de FD évitée).
                let watchdog = Task { [weak conn] in
                    try? await Task.sleep(nanoseconds: 60_000_000_000); conn?.cancel()
                }
                Task {
                    defer { watchdog.cancel() }
                    do {
                        let frame0 = try await self.recv(conn)
                        if frame0.type == "apppull" {
                            // Anti-DoS : plafonne les transferts sortants simultanés (ditto = coûteux).
                            let allowed: Bool = self.queue.sync {
                                if self.activeServes >= Self.maxServes { return false }
                                self.activeServes += 1; return true
                            }
                            if allowed {
                                defer { self.queue.async { self.activeServes -= 1 } }
                                Self.ulog("serveur: demande de mise à jour reçue d'un pair")
                                await self.serveApp(conn)
                            } else {
                                Self.ulog("serveur: trop de transferts simultanés — refus")
                            }
                        }
                    } catch { }
                    conn.cancel()
                }
            case .failed, .cancelled:
                break
            default:
                break
            }
        }
        conn.start(queue: queue)
    }

    // Sert NOTRE bundle .app : archive ditto → tranches base64.
    private func serveApp(_ conn: NWConnection) async {
        guard AppVersion.build > 0, Bundle.main.bundlePath.hasSuffix(".app") else {
            Self.ulog("serveur: REFUS — pas lancé depuis un .app (build=\(AppVersion.build))")
            return
        }
        let bundle = Bundle.main.bundlePath
        // Chemin UNIQUE par transfert : deux pairs qui téléchargent en même temps ne se corrompent plus.
        let zipPath = NSTemporaryDirectory() + "scantopdf-serve-\(nodeId)-\(UUID().uuidString).zip"
        try? FileManager.default.removeItem(atPath: zipPath)
        let rc = runTool("/usr/bin/ditto", ["-c", "-k", "--keepParent", bundle, zipPath])
        guard rc == 0, let data = try? Data(contentsOf: URL(fileURLWithPath: zipPath)) else {
            Self.ulog("serveur: ECHEC ditto (rc=\(rc)) du bundle \(bundle)")
            return
        }
        defer { try? FileManager.default.removeItem(atPath: zipPath) }
        let sha = SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
        let sliceSize = 4 * 1024 * 1024
        let total = max(1, (data.count + sliceSize - 1) / sliceSize)
        Self.ulog("serveur: envoi build \(AppVersion.build), \(data.count) octets, \(total) tranche(s)")
        do {
            try await send(conn, Wire(type: "appinfo", at: total, asz: Int64(data.count), bld: AppVersion.build, sha: sha))
            var idx = 0, off = 0
            while off < data.count {
                let end = min(off + sliceSize, data.count)
                try await send(conn, Wire(type: "appchunk", ab: data.subdata(in: off..<end).base64EncodedString(), ai: idx, at: total))
                idx += 1; off = end
            }
            try await send(conn, Wire(type: "done"))
            Self.ulog("serveur: transfert terminé (\(total) tranche(s))")
        } catch {
            Self.ulog("serveur: coupure pendant l'envoi — \(error.localizedDescription)")
        }
    }

    // MARK: - client : télécharge le bundle du pair le plus récent, vérifie, installe.
    // Renvoie nil si l'aide de relance est lancée (l'app doit alors quitter), sinon une RAISON d'échec.
    func pullAndInstallApp() async -> String? {
        Self.ulog("client: début de la mise à jour")
        guard AppVersion.build > 0 else { return "Cette copie n'est pas une vraie application installée (build 0)." }
        let appPath = Bundle.main.bundlePath
        guard appPath.hasSuffix(".app") else { return "L'application n'est pas un bundle .app." }
        guard let target = queue.sync(execute: { updateTarget }) else { return "Aucun Mac source détecté." }
        let conn = NWConnection(to: target.endpoint, using: tlsParameters())
        let ready: Bool = await withCheckedContinuation { cont in
            var done = false
            conn.stateUpdateHandler = { state in
                switch state {
                case .ready: if !done { done = true; cont.resume(returning: true) }
                case .failed, .cancelled: if !done { done = true; cont.resume(returning: false) }
                default: break
                }
            }
            conn.start(queue: queue)
        }
        guard ready else { conn.cancel(); Self.ulog("client: ECHEC connexion au Mac source"); return "Connexion au Mac source impossible." }
        let watchdog = Task { [weak conn] in try? await Task.sleep(nanoseconds: 180_000_000_000); conn?.cancel() }
        defer { watchdog.cancel(); conn.cancel() }
        do {
            try await send(conn, Wire(type: "apppull"))
            let info = try await recv(conn)
            guard info.type == "appinfo", let total = info.at, let serverBuild = info.bld,
                  let expectedSha = info.sha, let asz = info.asz else {
                return "Le Mac source n'a pas pu envoyer sa version."
            }
            guard serverBuild > AppVersion.build else { return "Pas de version plus récente." }
            guard total > 0, total < 10_000, asz > 0, asz < 2_000_000_000 else { return "Taille d'archive invalide." }
            Self.ulog("client: réception build \(serverBuild), \(asz) octets, \(total) tranche(s)")
            var data = Data(); var got = 0
            while true {
                let m = try await recv(conn)
                if m.type == "done" { break }
                if m.type == "appchunk", let b = m.ab, let d = Data(base64Encoded: b) {
                    data.append(d); got += 1
                    if got > total || data.count > Int(asz) + 8_000_000 { return "Transfert trop volumineux." }
                }
            }
            guard got == total, Int64(data.count) == asz else { return "Transfert incomplet." }
            let sha = SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
            guard sha == expectedSha else { return "Vérification d'intégrité échouée." }
            return installDownloadedApp(zipData: data, appPath: appPath)
        } catch {
            Self.ulog("client: ECHEC transfert — \(error.localizedDescription)")
            return "Transfert interrompu."
        }
    }

    // Décompresse (ditto), retire la quarantaine, VÉRIFIE la signature et la version, met en scène
    // dans un dossier temporaire, puis lance l'aide de relance détachée qui échange les bundles.
    // Renvoie nil si l'aide est lancée (succès), sinon une RAISON d'échec.
    private func installDownloadedApp(zipData: Data, appPath: String) -> String? {
        let fm = FileManager.default
        let destApp = appPath
        let appName = (destApp as NSString).lastPathComponent
        let staging = NSTemporaryDirectory() + "scantopdf-staging-\(getpid())-\(UUID().uuidString)"
        try? fm.removeItem(atPath: staging)
        guard (try? fm.createDirectory(atPath: staging, withIntermediateDirectories: true)) != nil else { return "Dossier temporaire inaccessible." }
        let zipPath = staging + "/app.zip"
        guard (try? zipData.write(to: URL(fileURLWithPath: zipPath))) != nil else { try? fm.removeItem(atPath: staging); return "Écriture de l'archive impossible." }
        let rcX = runTool("/usr/bin/ditto", ["-x", "-k", zipPath, staging])
        guard rcX == 0 else { try? fm.removeItem(atPath: staging); return "Décompression échouée." }
        try? fm.removeItem(atPath: zipPath)
        let stagedApp: String = (try? fm.contentsOfDirectory(atPath: staging))?
            .first(where: { $0.hasSuffix(".app") }).map { staging + "/" + $0 } ?? (staging + "/" + appName)
        guard fm.fileExists(atPath: stagedApp) else { try? fm.removeItem(atPath: staging); return "Application extraite introuvable." }
        _ = runTool("/usr/bin/xattr", ["-dr", "com.apple.quarantine", stagedApp])
        let rcV = runTool("/usr/bin/codesign", ["--verify", "--deep", "--strict", stagedApp])
        guard rcV == 0 else { try? fm.removeItem(atPath: staging); return "Vérification de la signature échouée." }
        // Défense en profondeur : refuser un bundle dont l'identifiant diffère du nôtre.
        // ⚠️ Une signature AD-HOC ne prouve PAS l'identité du signataire — l'authentification réelle du
        // pair repose sur la phrase secrète du cluster (TLS-PSK). Pour une garantie FORTE, signer en
        // Developer ID + notariser et vérifier l'ancre (voir note sécurité).
        let expectedID = Bundle.main.bundleIdentifier ?? "com.antonin.scantopdf"
        guard bundleIdentifier(atPath: stagedApp) == expectedID else {
            try? fm.removeItem(atPath: staging); Self.ulog("client: REFUS — identifiant de bundle inattendu")
            return "Bundle reçu non reconnu (identifiant différent)."
        }
        guard bundleBuild(atPath: stagedApp) > AppVersion.build else { try? fm.removeItem(atPath: staging); return "La version reçue n'est pas plus récente." }
        // Aide de relance HORS du bundle remplacé, nom aléatoire + permissions 0700.
        let helper = NSTemporaryDirectory() + "scantopdf-relaunch-\(UUID().uuidString).sh"
        guard (try? Self.relaunchScript.write(toFile: helper, atomically: true, encoding: .utf8)) != nil else { try? fm.removeItem(atPath: staging); return "Préparation du redémarrage impossible." }
        try? fm.setAttributes([.posixPermissions: 0o700], ofItemAtPath: helper)
        let p = Process(); p.executableURL = URL(fileURLWithPath: "/bin/sh")
        // Arguments : helper OLD_PID STAGED_APP DEST_APP STAGING_DIR (le staging est nettoyé par le trap du script).
        p.arguments = [helper, "\(ProcessInfo.processInfo.processIdentifier)", stagedApp, destApp, staging]
        do { try p.run() } catch { try? fm.removeItem(atPath: staging); return "Lancement du redémarrage impossible." }
        Self.ulog("client: aide de relance lancée, l'app va redémarrer sur la nouvelle version")
        return nil
    }

    private func bundleBuild(atPath app: String) -> Int {
        guard let d = NSDictionary(contentsOfFile: app + "/Contents/Info.plist"),
              let v = d["CFBundleVersion"] as? String else { return 0 }
        return Int(v) ?? 0
    }

    private func bundleIdentifier(atPath app: String) -> String {
        (NSDictionary(contentsOfFile: app + "/Contents/Info.plist")?["CFBundleIdentifier"] as? String) ?? ""
    }

    @discardableResult
    private func runTool(_ path: String, _ args: [String]) -> Int32 {
        let p = Process(); p.executableURL = URL(fileURLWithPath: path); p.arguments = args
        p.standardOutput = Pipe(); p.standardError = Pipe()
        do { try p.run(); p.waitUntilExit() } catch { return -1 }
        return p.terminationStatus
    }

    // MARK: - cadrage longueur-préfixée (UInt32 BE + JSON)
    private func send(_ conn: NWConnection, _ msg: Wire) async throws {
        let payload = try JSONEncoder().encode(msg)
        var len = UInt32(payload.count).bigEndian
        var frame = Data(bytes: &len, count: 4); frame.append(payload)
        try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Void, Error>) in
            conn.send(content: frame, completion: .contentProcessed { error in
                if let error = error { cont.resume(throwing: error) } else { cont.resume() }
            })
        }
    }

    private func recv(_ conn: NWConnection) async throws -> Wire {
        let header = try await recvExactly(conn, 4)
        let len = header.withUnsafeBytes { Int(UInt32(bigEndian: $0.load(as: UInt32.self))) }
        guard len > 0, len < 64_000_000 else { throw SyncError.closed }
        let body = try await recvExactly(conn, len)
        return try JSONDecoder().decode(Wire.self, from: body)
    }

    private func recvExactly(_ conn: NWConnection, _ n: Int) async throws -> Data {
        var buf = Data()
        while buf.count < n {
            let chunk: Data = try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Data, Error>) in
                var resumed = false
                conn.receive(minimumIncompleteLength: 1, maximumLength: n - buf.count) { data, _, isComplete, error in
                    if resumed { return }; resumed = true
                    if let error = error { cont.resume(throwing: error); return }
                    if let data = data, !data.isEmpty { cont.resume(returning: data) }
                    else if isComplete { cont.resume(throwing: SyncError.closed) }
                    else { cont.resume(returning: Data()) }
                }
            }
            if chunk.isEmpty { throw SyncError.closed }
            buf.append(chunk)
        }
        return buf
    }

    // Journal de diagnostic : /Users/Shared/ScanToPDF/update.log
    static func ulog(_ s: String) { FileLog.append(s, to: "update.log") }

    // Aide de relance : attend la fin de l'app, échange les bundles (rename, même volume), relance.
    // SÉCURITÉ : aucune élévation de privilèges. L'échange n'a lieu QUE si le dossier de destination est
    // inscriptible sans droits admin (cas normal : /Applications pour un utilisateur admin). Sinon, on ne
    // fait rien (l'utilisateur copiera la nouvelle app à la main) — on ne détourne jamais un mot de passe
    // admin pour installer un bundle non authentifié.
    private static let relaunchScript = """
    #!/bin/sh
    set -u
    OLD_PID="$1"
    STAGED_APP="$2"
    DEST_APP="$3"
    STAGING_DIR="$4"
    DEST_DIR=$(dirname "$DEST_APP")
    OLD_ASIDE="$DEST_DIR/.ScanToPDF.old.$$"
    # Nettoie TOUJOURS le dossier de transit à la sortie (succès comme échec).
    trap '/bin/rm -rf "$STAGING_DIR" 2>/dev/null || true' EXIT

    i=0
    while /bin/kill -0 "$OLD_PID" 2>/dev/null; do
      sleep 0.2
      i=$((i + 1))
      if [ "$i" -ge 150 ]; then
        /bin/kill -TERM "$OLD_PID" 2>/dev/null || true
        sleep 1
        /bin/kill -9 "$OLD_PID" 2>/dev/null || true
        sleep 0.5
        break
      fi
    done

    /usr/bin/xattr -dr com.apple.quarantine "$STAGED_APP" 2>/dev/null || true

    SB=$(/usr/bin/defaults read "$STAGED_APP/Contents/Info" CFBundleVersion 2>/dev/null || echo 0)
    DB=$(/usr/bin/defaults read "$DEST_APP/Contents/Info" CFBundleVersion 2>/dev/null || echo 0)
    case "$SB" in (*[!0-9]*|"") SB=0 ;; esac
    case "$DB" in (*[!0-9]*|"") DB=0 ;; esac
    if [ "$SB" -le "$DB" ]; then /usr/bin/open "$DEST_APP"; exit 0; fi

    # Sans droits d'écriture sur le dossier de destination : on N'ÉLÈVE PAS — on relance l'existant.
    if [ ! -w "$DEST_DIR" ]; then
      /usr/bin/open "$DEST_APP"
      exit 1
    fi

    swap_ok=0
    if /bin/mv "$DEST_APP" "$OLD_ASIDE" 2>/dev/null; then
      if /bin/mv "$STAGED_APP" "$DEST_APP" 2>/dev/null; then
        swap_ok=1
      else
        /bin/mv "$OLD_ASIDE" "$DEST_APP" 2>/dev/null || true
      fi
    fi

    if [ "$swap_ok" -eq 0 ]; then
      [ -d "$DEST_APP" ] && /usr/bin/open "$DEST_APP"
      [ -d "$OLD_ASIDE" ] && /bin/mv "$OLD_ASIDE" "$DEST_APP" 2>/dev/null && /usr/bin/open "$DEST_APP"
      exit 1
    fi

    /usr/bin/xattr -dr com.apple.quarantine "$DEST_APP" 2>/dev/null || true
    /usr/bin/open "$DEST_APP"
    /bin/rm -rf "$OLD_ASIDE" 2>/dev/null || true
    exit 0
    """
}

enum SyncError: Error { case closed }
