import Foundation

/// Verrou par mot de passe ADMINISTRATEUR du Mac, sur le modèle du cadenas des Réglages Système.
/// Le mot de passe n'est jamais vu ni manipulé par l'application : c'est macOS qui l'invite et le
/// vérifie (osascript « with administrator privileges ») ; on ne reçoit qu'un succès ou un échec.
///
/// ⚠️ Portée réelle : ce verrou protège l'INTERFACE, pas le fichier de configuration. Quelqu'un
/// capable d'éditer config.json à la main le contourne. Il empêche une modification par inadvertance
/// ou par un tiers de passage, ce qui est son objet.
enum AdminAuth {

    /// Demande le mot de passe administrateur. `reason` s'affiche dans le dialogue macOS.
    /// Renvoie true si l'authentification a réussi.
    static func authenticate(reason: String) -> Bool {
        // `reason` provient de constantes du code, mais on échappe malgré tout : rien d'interpolé
        // dans un source AppleScript ne doit pouvoir en changer le sens.
        let safe = reason.replacingOccurrences(of: "\\", with: "\\\\")
                         .replacingOccurrences(of: "\"", with: "\\\"")
        let script = "do shell script \"/usr/bin/true\" with prompt \"\(safe)\" with administrator privileges"
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
        p.arguments = ["-e", script]
        p.standardOutput = FileHandle.nullDevice
        p.standardError = FileHandle.nullDevice
        do { try p.run(); p.waitUntilExit() } catch { return false }
        return p.terminationStatus == 0        // annulation ou mauvais mot de passe → non nul
    }
}
