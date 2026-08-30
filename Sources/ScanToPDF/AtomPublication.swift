import Foundation

/// Une publication en attente de validation : ce qui existe dans AtoM, ce que ScanToPDF propose,
/// et tout ce que l'utilisateur peut encore corriger avant l'envoi.
struct AtomPublication: Identifiable {
    let id = UUID()
    let code: String                 // cote locale, écriture « _ »
    let folder: URL                  // dossier projet (copié en entier sur le lecteur réseau)
    let pdf: URL                     // SEUL fichier publié dans AtoM : le PDF/A final
    var proposed: AtomRecord = AtomRecord()   // ce que propose la fiche, conservé pour recomparer
    var existing: AtomRecord = AtomRecord()   // la notice en ligne : l'import CSV apparie sur
                                              // sa cote, son titre et son dépôt
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
    /// Dépôt retenu — celui affiché dans la fenêtre, donc modifiable avant l'envoi.
    var repository: String {
        fields.first { $0.key == "repository" }?.proposed ?? existing.repository
    }

    /// Les seules valeurs à envoyer : celles réellement modifiées. L'import CSV accepte les
    /// mots-clés sous forme de texte — AtoM résout lui-même les termes — là où le formulaire
    /// d'édition exigeait des URL de thésaurus. Ils sont donc de nouveau publiables.
    var changes: [String: String] {
        Dictionary(uniqueKeysWithValues: fields.filter { $0.kind != .unchanged }.map { f in
            // Séparateur multi-valeurs du CSV d'AtoM : « | ».
            f.key.hasSuffix("AccessPoints")
                ? (f.key, f.proposed.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }
                                    .filter { !$0.isEmpty }.joined(separator: "|"))
                : (f.key, f.proposed)
        })
    }
}
