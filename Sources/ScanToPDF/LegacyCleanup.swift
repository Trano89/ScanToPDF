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
        // Les commandes sont passées EN LIGNE à osascript. Écrire d'abord un script sur disque, puis
        // le faire exécuter EN ROOT, ouvrait une fenêtre d'élévation de privilège : un processus du
        // même compte — qui n'a PAS les droits root — pouvait réécrire le fichier entre sa création
        // et son exécution, et faire ainsi exécuter n'importe quoi en root. Plus de fichier, plus de
        // fenêtre. Les chemins restent des constantes internes, échappées pour le shell.
        var cmds = ["/bin/launchctl bootout system/\(label) 2>/dev/null",
                    "/bin/launchctl disable system/\(label) 2>/dev/null"]
        for pl in existingPlists() {
            cmds.append("/bin/launchctl unload \(shq(pl)) 2>/dev/null")
            cmds.append("/bin/rm -f \(shq(pl))")
        }
        cmds.append("exit 0")
        let shell = cmds.joined(separator: "; ")
        let osa = "do shell script \"\(asq(shell))\" with administrator privileges"
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
    /// Échappement pour une chaîne littérale AppleScript (contre-obliques puis guillemets).
    private static func asq(_ s: String) -> String {
        s.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"")
    }

    static func log(_ s: String) { FileLog.append(s, to: "legacy.log") }
}
