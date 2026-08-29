import Foundation

/// Une publication en attente de validation : ce qui existe dans AtoM, ce que ScanToPDF propose,
/// et tout ce que l'utilisateur peut encore corriger avant l'envoi.
struct AtomPublication: Identifiable {
    let id = UUID()
    let code: String                 // cote locale, écriture « _ »
    let folder: URL                  // dossier projet (copié en entier sur le lecteur réseau)
    let pdf: URL                     // SEUL fichier publié dans AtoM : le PDF/A final
    var slug: String?                // notice existante, nil = création
    var matchedCode: String = ""     // écriture trouvée dans AtoM (« _ » ou « / »)
    var fields: [AtomFieldDiff] = []

    var exists: Bool { slug != nil }
    /// La notice utilise l'ancienne écriture « / » : sa cote sera migrée vers « _ ».
    var needsCodeMigration: Bool { matchedCode.contains("/") }
    var changedCount: Int { fields.filter { $0.kind != .unchanged }.count }

    /// Les seules valeurs à envoyer : celles réellement modifiées.
    var changes: [String: String] {
        Dictionary(uniqueKeysWithValues: fields.filter { $0.kind != .unchanged }.map { ($0.key, $0.proposed) })
    }
}
