import Foundation
import Network

// Montage du partage SMB du NAS. Le mot de passe n'est JAMAIS manipulé par l'app : on déclenche
// `open smb://…`, ce qui laisse macOS afficher SON dialogue de connexion natif (« login popup au cas où »)
// et gérer le Trousseau. On se contente de vérifier la joignabilité et l'apparition du point de montage.
enum MountManager {

    static func mountPath(share: String) -> String { "/Volumes/" + share }

    static func isMounted(share: String) -> Bool {
        !share.isEmpty && FileManager.default.fileExists(atPath: mountPath(share: share))
    }

    // Joignabilité TCP de host:445 (SMB), timeout court — évite de tenter un montage (et un popup)
    // quand le NAS n'est pas sur le réseau.
    static func reachable(host: String, timeout: TimeInterval = 2.0) -> Bool {
        guard !host.isEmpty, let port = NWEndpoint.Port(rawValue: 445) else { return false }
        let sem = DispatchSemaphore(value: 0)
        var ok = false
        let conn = NWConnection(host: NWEndpoint.Host(host), port: port, using: .tcp)
        conn.stateUpdateHandler = { state in
            switch state {
            case .ready: ok = true; sem.signal()
            case .failed, .cancelled: sem.signal()
            default: break
            }
        }
        conn.start(queue: DispatchQueue.global())
        _ = sem.wait(timeout: .now() + timeout)
        conn.cancel()
        return ok
    }

    // Monte le partage si nécessaire. Renvoie le chemin monté (/Volumes/<share>) ou nil.
    // ⚠️ Contient des attentes → appeler HORS du thread principal.
    @discardableResult
    static func ensureMounted(host: String, share: String, user: String) -> String? {
        guard !host.isEmpty, !share.isEmpty else { return nil }
        let path = mountPath(share: share)
        if FileManager.default.fileExists(atPath: path) { return path }   // déjà monté
        guard reachable(host: host) else { return nil }                   // NAS hors réseau → repli Drive

        var url = "smb://"
        if !user.isEmpty {
            url += (user.addingPercentEncoding(withAllowedCharacters: .urlUserAllowed) ?? user) + "@"
        }
        url += host + "/" + (share.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? share)

        // `open smb://…` : macOS monte le partage et affiche SON dialogue de login si le Trousseau
        // n'a pas encore les identifiants. L'app ne voit jamais le mot de passe.
        let p = Process(); p.executableURL = URL(fileURLWithPath: "/usr/bin/open"); p.arguments = [url]
        p.standardOutput = FileHandle.nullDevice; p.standardError = FileHandle.nullDevice
        do { try p.run(); p.waitUntilExit() } catch { return nil }

        // Attendre l'apparition du point de montage (laisse le temps de saisir les identifiants).
        let deadline = Date().addingTimeInterval(25)
        while Date() < deadline {
            if FileManager.default.fileExists(atPath: path) { return path }
            usleep(400_000)   // 0,4 s
        }
        return FileManager.default.fileExists(atPath: path) ? path : nil
    }
}
