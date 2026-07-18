import Foundation

// Détection et suppression de l'ANCIEN automatisme d'archivage (antérieur à ScanToPDF) :
// un LaunchDaemon/Agent « com.fvjc.archivage » qui lance /Users/Shared/code/archivage_watcher.py
// et surveille le même dossier → ferait doublon avec ScanToPDF.
// La suppression d'un daemon système appartient à root : élévation via osascript « administrator
// privileges » (une seule invite de mot de passe).
enum LegacyCleanup {
    static let label = "com.fvjc.archivage"
    // Le plist est le marqueur PERSISTANT (ce qui relance le service au boot). On se base dessus pour la
    // détection — fiable et sans faux positif (contrairement à un pgrep sur un chemin, qui matcherait un
    // simple éditeur ouvrant le fichier).
    static var plistCandidates: [String] {
        [
            "/Library/LaunchDaemons/\(label).plist",
            "/Library/LaunchAgents/\(label).plist",
            NSHomeDirectory() + "/Library/LaunchAgents/\(label).plist",
        ]
    }

    static func existingPlists() -> [String] {
        plistCandidates.filter { FileManager.default.fileExists(atPath: $0) }
    }

    static func detected() -> Bool { !existingPlists().isEmpty }

    // Supprime l'ancien automatisme (décharge le service + retire le(s) plist → il ne se relancera plus).
    // Renvoie nil si succès, sinon une RAISON d'échec (annulation, échec…).
    static func remove() -> String? {
        // Script exécuté EN ROOT via osascript. Chemins = constantes internes échappées (aucune entrée
        // utilisateur) → pas d'injection. On NE fait PAS de `pkill -f` sur un chemin (dangereux en root,
        // pourrait tuer un process tiers) : `bootout`/`unload` déchargent le service ET son process.
        var lines = ["#!/bin/sh", "set +e"]
        lines.append("/bin/launchctl bootout system/\(label) 2>/dev/null")
        lines.append("/bin/launchctl disable system/\(label) 2>/dev/null")
        for pl in existingPlists() {
            lines.append("/bin/launchctl unload \(shq(pl)) 2>/dev/null")
            lines.append("/bin/rm -f \(shq(pl))")
        }
        lines.append("exit 0")
        let script = lines.joined(separator: "\n")

        let tmp = NSTemporaryDirectory() + "scantopdf-legacy-\(UUID().uuidString).sh"
        guard (try? script.write(toFile: tmp, atomically: true, encoding: .utf8)) != nil else { return "Préparation impossible." }
        try? FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: tmp)
        defer { try? FileManager.default.removeItem(atPath: tmp) }

        let osa = "do shell script \"/bin/sh '\(tmp)'\" with administrator privileges"
        let p = Process(); p.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
        p.arguments = ["-e", osa]
        let err = Pipe(); p.standardOutput = Pipe(); p.standardError = err
        do { try p.run(); p.waitUntilExit() } catch { return "Lancement impossible." }
        if p.terminationStatus != 0 {
            let e = String(data: err.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
            if e.contains("-128") || e.lowercased().contains("cancel") { log("Suppression annulée par l'utilisateur."); return "Annulé." }
            log("Échec de la suppression (osascript rc=\(p.terminationStatus)).")
            return "Échec (droits refusés ?)."
        }
        if detected() { log("Plist toujours présent après suppression."); return "Toujours présent." }
        log("Ancien automatisme supprimé avec succès.")
        return nil
    }

    private static func shq(_ s: String) -> String { "'" + s.replacingOccurrences(of: "'", with: "'\\''") + "'" }

    static func log(_ s: String) { FileLog.append(s, to: "legacy.log") }
}
