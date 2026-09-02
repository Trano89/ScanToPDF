#!/bin/bash
# Tests de la chaîne de PUBLICATION AtoM (dates, genres, CSV, lecture de fiche).
#
# Ces vérifications vivaient dans un dossier temporaire et ont été perdues une fois : elles sont
# désormais dans le dépôt. Elles ne touchent AUCUN service réseau — tout est vérifié hors ligne sur
# des données figées, pour rester reproductibles et ne jamais écrire dans le catalogue.
#
# Usage : bash tests/atom.sh
set -uo pipefail
cd "$(dirname "$0")/.."

T="$(mktemp -d)"
trap 'rm -rf "$T"' EXIT
cp Sources/ScanToPDF/AtomClient.swift Sources/ScanToPDF/AtomPublication.swift "$T/"

cat > "$T/stub.swift" <<'SWIFT'
import Foundation
// L'application écrit son journal sur disque ; ici on ne veut ni fichier ni bruit.
enum FileLog { static func append(_ m: String, to n: String) {} }
SWIFT

cat > "$T/main.swift" <<'SWIFT'
import Foundation

var ko = 0
func c(_ libelle: String, _ ok: Bool) {
    print("  \(ok ? "✅" : "❌") \(libelle)")
    if !ok { ko += 1 }
}
func eq<T: Equatable>(_ libelle: String, _ obtenu: T, _ attendu: T) {
    let ok = obtenu == attendu
    print("  \(ok ? "✅" : "❌") \(libelle)" + (ok ? "" : "  → attendu \(attendu), obtenu \(obtenu)"))
    if !ok { ko += 1 }
}

print("═ Dates ═")
eq("mention de type retirée", AtomClient._sansTypeEvenement("2023 (Création/Production)"), "2023")
eq("date complète + mention", AtomClient._sansTypeEvenement("2023-11-05 (Création/Production)"), "2023-11-05")
eq("date nue intacte", AtomClient._sansTypeEvenement("2023-11-05"), "2023-11-05")
eq("période + mention", AtomClient._sansTypeEvenement("2003-12 - 2004-01 (Création)"), "2003-12 - 2004-01")
c("AAAA-MM-JJ publiable", AtomClient.dateISOValide("2023-11-05"))
c("AAAA-MM publiable", AtomClient.dateISOValide("2023-11"))
c("AAAA publiable", AtomClient.dateISOValide("2023"))
c("période publiable", AtomClient.dateISOValide("2003-12 - 2004-01-30"))
c("tiret long accepté", AtomClient.dateISOValide("2003-12 – 2004-01"))
c("mention de type refusée", !AtomClient.dateISOValide("2023 (Création/Production)"))
c("texte libre refusé", !AtomClient.dateISOValide("vers 1950"))
c("vide refusé", !AtomClient.dateISOValide(""))
eq("tiret long normalisé", AtomClient.normaliseDate("2003-12 – 2004-01"), "2003-12 - 2004-01")

func bornes(_ s: String) -> String { let r = AtomClient.isoRange(s); return "\(r.start)|\(r.end)" }
eq("bornes d'une période mixte", bornes("2003-12 - 2004-01-30"), "2003-12|2004-01-30")
eq("bornes d'une date simple", bornes("2004-03-14"), "2004-03-14|2004-03-14")
eq("aucune borne pour du texte", bornes("vers 1950"), "|")

print("═ Genres — alignement sur le thésaurus ═")
// Extrait réel du vocabulaire d'archives.fvjc.ch.
let vocab = ["Cahier des charges", "Programme", "Liste", "Notes", "Affiche", "Affiches",
             "Procès-verbal", "Règlement", "Compte rendu", "Échéancier"]
let a1 = AtomClient.alignerGenres(["cahier des charges", "programme", "liste", "notice"], sur: vocab)
eq("orthographe du catalogue restituée", a1.retenus, ["Cahier des charges", "Programme", "Liste"])
eq("terme inconnu écarté, jamais créé", a1.ecartes, ["notice"])
let a2 = AtomClient.alignerGenres(["proces-verbal", "REGLEMENT", "échéancier"], sur: vocab)
eq("casse et accents ignorés", a2.retenus, ["Procès-verbal", "Règlement", "Échéancier"])
let a3 = AtomClient.alignerGenres(["Affiche"], sur: vocab)
eq("singulier et pluriel non confondus", a3.retenus, ["Affiche"])
let a4 = AtomClient.alignerGenres(["Liste", "liste", "LISTE"], sur: vocab)
eq("doublons de proposition fusionnés", a4.retenus, ["Liste"])
let a5 = AtomClient.alignerGenres(["Programme"], sur: [])
c("vocabulaire vide → rien retenu, tout signalé", a5.retenus.isEmpty && a5.ecartes == ["Programme"])

print("═ CSV d'import ═")
let csv = AtomClient.buildCSV([
    "identifier": "2023_1", "title": "Cahier des charges, Commission Théâtral",
    "repository": "Archives FVJC", "legacyId": "Db-k-Y1-2023_1",
    "scopeAndContent": "Un texte avec, une virgule et \"des guillemets\"\net un saut de ligne.",
    "genreAccessPoints": "Cahier des charges|Programme", "culture": "fr",
])
func cellules(_ s: String) -> [String: String] {
    var lignes: [[String]] = [], ligne: [String] = [], cel = "", guil = false
    var it = s.makeIterator(); var att: Character? = nil
    while let ch = att ?? it.next() {
        att = nil
        if guil {
            if ch == "\"" { if let n = it.next() { if n == "\"" { cel.append("\"") } else { guil = false; att = n } } else { guil = false } }
            else { cel.append(ch) }
        } else if ch == "\"" { guil = true }
        else if ch == "," { ligne.append(cel); cel = "" }
        else if ch == "\n" { ligne.append(cel); lignes.append(ligne); ligne = []; cel = "" }
        else { cel.append(ch) }
    }
    return Dictionary(uniqueKeysWithValues: zip(lignes[0], lignes[1]))
}
let cel = cellules(csv)
eq("cote propre dans la bonne colonne", cel["identifier"] ?? "", "2023_1")
eq("titre à virgule préservé", cel["title"] ?? "", "Cahier des charges, Commission Théâtral")
eq("clé stable transmise", cel["legacyId"] ?? "", "Db-k-Y1-2023_1")
eq("dépôt transmis", cel["repository"] ?? "", "Archives FVJC")
c("guillemets échappés", (cel["scopeAndContent"] ?? "").contains("\"des guillemets\""))
c("saut de ligne conservé dans la cellule", (cel["scopeAndContent"] ?? "").contains("\n"))
c("colonnes de date présentes", cel.keys.contains("eventDates") && cel.keys.contains("eventTypes"))
c("colonnes non renseignées vides", (cel["appraisal"] ?? "x").isEmpty)

print("═ Lecture de la fiche ISAD ═")
let fiche = """
DATE DU DOCUMENT  (ISAD 3.1.3)
──────────────────────────────
2015-02

ÉTENDUE ET SUPPORT  (ISAD 3.1.5)
──────────────────────────────
brochure de 2 pages

HISTOIRE ARCHIVISTIQUE  (ISAD 3.2.3)
──────────────────────────────
Ce document a été produit par le groupe de travail du Comité central de la Fédération
vaudoise des jeunesses campagnardes.

Il a été réalisé en février 2015.

MOTS-CLÉS — SUJETS
──────────────────────────────
• portfolio
• bénévolat

TYPE DOCUMENTAIRE
──────────────────────────────
• brochure
• portfolio
"""
let r = AtomClient.recordFromFiche(fiche, code: "Zz.z.Z1.2026_1")
c("phrase reconstituée sans coupure",
  r.archivalHistory.contains("de la Fédération vaudoise des jeunesses campagnardes"))
eq("paragraphes conservés", r.archivalHistory.components(separatedBy: "\n\n").count, 2)
eq("date lue", r.date, "2015-02")
eq("sujets lus", r.subjects, ["portfolio", "bénévolat"])
eq("type documentaire lu comme une liste", r.genres, ["brochure", "portfolio"])

print("═ Envoi ═")
var pub = AtomPublication(code: "Zz.z.Z1.2026_1", folder: URL(fileURLWithPath: "/tmp"),
                          pdf: URL(fileURLWithPath: "/tmp/x.pdf"))
pub.fields = AtomClient.diff(existing: AtomRecord(), proposed: r, repository: "Archives FVJC")
eq("mots-clés séparés par « | »", pub.changes["subjectAccessPoints"] ?? "", "portfolio|bénévolat")
eq("dépôt retenu", pub.repository, "Archives FVJC")
c("cote jamais envoyée telle quelle", pub.changes["identifier"] == nil || !pub.changes["identifier"]!.isEmpty)

print("")
print("  RÉUSSIS : \(ko == 0 ? "tous" : "voir ci-dessus")   ÉCHOUÉS : \(ko)")
exit(ko == 0 ? 0 : 1)
SWIFT

swiftc -O "$T"/*.swift -o "$T/atomtests" 2>&1 | grep -E "error" && exit 1
"$T/atomtests"
