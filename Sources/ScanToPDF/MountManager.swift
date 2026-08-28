import Foundation
import Darwin
import Network

/// Un lecteur réseau SMB monté sur ce Mac.
struct NetworkVolume: Identifiable, Hashable {
    let path: String        // point de montage, ex. « /Volumes/Archives »
    let mountFrom: String   // origine, ex. « //antonin@DS1513/Archives » — sert à remonter

    var id: String { path }
    var name: String { (path as NSString).lastPathComponent }
    /// URL de montage comprise par macOS (`open smb://…`).
    var smbURL: String { mountFrom.hasPrefix("//") ? "smb:" + mountFrom : mountFrom }
    /// Serveur extrait de l'origine, pour tester la joignabilité avant de tenter un montage.
    var host: String {
        let body = mountFrom.hasPrefix("//") ? String(mountFrom.dropFirst(2)) : mountFrom
        let afterUser = body.contains("@") ? String(body[body.index(after: body.firstIndex(of: "@")!)...]) : body
        return afterUser.split(separator: "/").first.map(String.init) ?? ""
    }
}

/// Destination réseau du résultat : UNIQUEMENT des lecteurs SMB montés.
/// Le mot de passe n'est jamais manipulé par l'application — c'est `open smb://…` qui laisse macOS
/// afficher son dialogue de connexion natif et gérer le Trousseau.
enum MountManager {

    /// Lecteurs SMB montés et proposables à l'utilisateur. On écarte les montages internes de macOS
    /// (Time Machine et tout ce qui est « nobrowse » ou caché sous /Volumes/.…) : ce ne sont pas des
    /// destinations d'archivage et ils encombreraient la liste.
    static func networkVolumes() -> [NetworkVolume] {
        var raw: UnsafeMutablePointer<statfs>?
        let count = getmntinfo(&raw, MNT_NOWAIT)
        guard count > 0, let list = raw else { return [] }
        var out: [NetworkVolume] = []
        for i in 0..<Int(count) {
            var fs = list[i]
            let type = withUnsafePointer(to: &fs.f_fstypename) {
                $0.withMemoryRebound(to: CChar.self, capacity: 16) { String(cString: $0) } }
            let on = withUnsafePointer(to: &fs.f_mntonname) {
                $0.withMemoryRebound(to: CChar.self, capacity: 1024) { String(cString: $0) } }
            let from = withUnsafePointer(to: &fs.f_mntfromname) {
                $0.withMemoryRebound(to: CChar.self, capacity: 1024) { String(cString: $0) } }
            let browsable = (fs.f_flags & UInt32(MNT_DONTBROWSE)) == 0
            guard type == "smbfs", browsable, !on.hasPrefix("/Volumes/.") else { continue }
            out.append(NetworkVolume(path: on, mountFrom: from))
        }
        return out.sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
    }

    static func isMounted(path: String) -> Bool {
        !path.isEmpty && FileManager.default.fileExists(atPath: path)
    }

    /// Joignabilité TCP de host:445 — évite de déclencher un dialogue de connexion quand le serveur
    /// n'est pas sur le réseau.
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

    /// Remonte le lecteur enregistré s'il ne l'est plus. Renvoie true s'il est monté au retour.
    /// ⚠️ Contient des attentes → appeler HORS du thread principal.
    @discardableResult
    static func remount(path: String, mountFrom: String, timeout: TimeInterval = 25) -> Bool {
        if isMounted(path: path) { return true }
        guard !mountFrom.isEmpty else { return false }
        let vol = NetworkVolume(path: path, mountFrom: mountFrom)
        guard reachable(host: vol.host) else { return false }

        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/open")
        p.arguments = [vol.smbURL]
        p.standardOutput = FileHandle.nullDevice
        p.standardError = FileHandle.nullDevice
        do { try p.run(); p.waitUntilExit() } catch { return false }

        // Laisse le temps au montage — et à une éventuelle saisie d'identifiants dans le dialogue macOS.
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if isMounted(path: path) { return true }
            usleep(400_000)
        }
        return isMounted(path: path)
    }
}
