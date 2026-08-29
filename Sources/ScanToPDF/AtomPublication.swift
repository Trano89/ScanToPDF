import Foundation

/// Une publication en attente de validation : ce qui existe dans AtoM, ce que ScanToPDF propose,
/// et tout ce que l'utilisateur peut encore corriger avant l'envoi.
struct AtomPublication: Identifiable {
    let id = UUID()
    let code: String                 // cote locale, écriture « _ »
    let folder: URL                  // dossier projet (copié en entier sur le lecteur réseau)
    let pdf: URL                     // SEUL fichier publié dans AtoM : le PDF/A final
    var proposed: AtomRecord = AtomRecord()   // ce que propose la fiche, conservé pour recomparer
    var slug: String?                // notice existante ; nil = INTROUVABLE (aucune création possible)
    var matchedCode: String = ""     // écriture trouvée dans AtoM (« _ » ou « / »)
    var fields: [AtomFieldDiff] = []

    var exists: Bool { slug != nil }
    /// Aucune notice trouvée : on ne crée jamais de notice depuis ScanToPDF — le catalogue reste
    /// maître de son arborescence. L'utilisateur réessaie, cherche à la main, ou renonce.
    var notFound: Bool { slug == nil }
    /// La notice utilise l'ancienne écriture « / » : sa cote sera migrée vers « _ ».
    var needsCodeMigration: Bool { matchedCode.contains("/") }
    var changedCount: Int { fields.filter { $0.kind != .unchanged }.count }

    /// Les seules valeurs à envoyer : celles réellement modifiées ET inscriptibles.
    var changes: [String: String] {
        Dictionary(uniqueKeysWithValues: fields.filter { $0.kind != .unchanged && $0.writable }
                                               .map { ($0.key, $0.proposed) })
    }
    /// Mots-clés proposés par la fiche qu'AtoM n'accepte pas sous forme de texte.
    var unwritable: [AtomFieldDiff] { fields.filter { $0.kind != .unchanged && !$0.writable } }
}
