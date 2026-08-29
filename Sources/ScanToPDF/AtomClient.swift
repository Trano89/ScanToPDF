import Foundation

/// Une notice archivistique telle qu'AtoM la présente, réduite aux champs que ScanToPDF alimente.
struct AtomRecord: Equatable {
    var identifier = ""          // cote, ex. « CH FVJC Dz.a.Y2.2017_2 »
    var title = ""
    var date = ""
    var extentAndMedium = ""     // Étendue matérielle et support (ISAD 3.1.5)
    var archivalHistory = ""     // Histoire archivistique (ISAD 3.2.3)
    var scopeAndContent = ""     // Portée et contenu (ISAD 3.3.1)
    var subjects: [String] = []  // Mots-clés — sujets
    var places: [String] = []    // Mots-clés — lieux
    var names: [String] = []     // Mots-clés — noms
    var genres: [String] = []    // Mots-clés — genres
}

/// Différence entre la notice en ligne et ce que ScanToPDF propose, champ par champ.
struct AtomFieldDiff: Identifiable {
    enum Kind { case unchanged, added, modified }
    let label: String
    let existing: String
    var proposed: String        // modifiable à la volée avant validation
    var kind: Kind { existing == proposed ? .unchanged : (existing.isEmpty ? .added : .modified) }
    var id: String { label }
}

/// Accès à l'instance AtoM. Tout passe par HTTPS ; la lecture d'une notice publique ne demande
/// aucune authentification, seule la publication en exige une.
///
/// ⚠️ AtoM n'expose AUCUN point d'accès REST d'écriture pour les descriptions (vérifié sur la
/// documentation 2.8 et sur l'instance : /api/… répond 404, le plugin n'est pas activé). La
/// publication emprunte donc le même chemin qu'un archiviste devant son navigateur : session
/// authentifiée, puis envoi du formulaire d'édition.
enum AtomClient {

    /// Slug AtoM d'une cote : les points deviennent des tirets, la casse est conservée
    /// (« Dz.a.Y2.2017_2 » → « Dz-a-Y2-2017_2 »). Vérifié sur l'instance.
    static func slug(forCode code: String) -> String {
        code.replacingOccurrences(of: ".", with: "-")
            .replacingOccurrences(of: " ", with: "-")
    }

    // MARK: - lecture d'une notice existante

    /// Cherche la notice correspondant à une cote. Essaie d'abord le slug direct (immédiat), puis la
    /// recherche plein texte sur la cote entre guillemets. Renvoie nil si aucune notice n'existe.
    static func findExisting(base: URL, code: String) async -> (slug: String, record: AtomRecord)? {
        let direct = slug(forCode: code)
        if let html = await get(base.appendingPathComponent("index.php/\(direct)")),
           html.contains("class=\"field") {
            return (direct, parseRecord(html))
        }
        guard let query = "\"\(code)\"".addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed),
              let url = URL(string: base.absoluteString + "/index.php/informationobject/browse?sq0=\(query)&topLod=0"),
              let list = await get(url) else { return nil }
        // Premier lien de notice de la page de résultats (on écarte les routes fonctionnelles).
        let pattern = #"href="/index\.php/([A-Za-z0-9][A-Za-z0-9_-]*)""#
        let ignored: Set<String> = ["clipboard", "informationobject", "user", "search", "taxonomy",
                                    "repository", "actor", "index", "browse"]
        guard let re = try? NSRegularExpression(pattern: pattern) else { return nil }
        for m in re.matches(in: list, range: NSRange(list.startIndex..., in: list)) {
            guard let r = Range(m.range(at: 1), in: list) else { continue }
            let candidate = String(list[r])
            if ignored.contains(candidate.lowercased()) || candidate.count < 3 { continue }
            if let html = await get(base.appendingPathComponent("index.php/\(candidate)")),
               html.contains("class=\"field") {
                return (candidate, parseRecord(html))
            }
        }
        return nil
    }

    /// Extrait les champs d'une page de notice. La mise en page d'AtoM est régulière :
    /// `<h3 …>Libellé</h3><div class="col-9 p-2">contenu</div>`, et les points d'accès sont
    /// regroupés dans des conteneurs `subjectAccessPoints`, `placeAccessPoints`, etc.
    static func parseRecord(_ html: String) -> AtomRecord {
        var r = AtomRecord()
        r.identifier      = field(html, "Cote")
        r.title           = field(html, "Titre")
        r.date            = field(html, "Date(s)")
        r.extentAndMedium = field(html, "Étendue matérielle et support")
        r.archivalHistory = field(html, "Histoire archivistique")
        r.scopeAndContent = field(html, "Portée et contenu")
        r.subjects        = accessPoints(html, "subjectAccessPoints")
        r.places          = accessPoints(html, "placeAccessPoints")
        r.names           = accessPoints(html, "nameAccessPoints")
        r.genres          = accessPoints(html, "genreAccessPoints")
        return r
    }

    private static func field(_ html: String, _ label: String) -> String {
        let escaped = NSRegularExpression.escapedPattern(for: label)
        let pattern = "<h3[^>]*>\\s*\(escaped)\\s*</h3>\\s*<div class=\"[^\"]*col-9 p-2\">(.*?)</div>"
        guard let re = try? NSRegularExpression(pattern: pattern, options: [.dotMatchesLineSeparators]),
              let m = re.firstMatch(in: html, range: NSRange(html.startIndex..., in: html)),
              let r = Range(m.range(at: 1), in: html) else { return "" }
        return plain(String(html[r]))
    }

    private static func accessPoints(_ html: String, _ container: String) -> [String] {
        guard let start = html.range(of: "class=\"\(container)\"") else { return [] }
        let rest = String(html[start.upperBound...])
        // On borne à la PREMIÈRE liste du conteneur : le dernier bloc de points d'accès serait sinon
        // suivi de la barre latérale (« Sujets associés », « Genres associés »…) et l'absorberait.
        guard let ulStart = rest.range(of: "<ul"), let ulEnd = rest.range(of: "</ul>") ,
              ulStart.lowerBound < ulEnd.lowerBound else { return [] }
        let slice = String(rest[ulStart.upperBound..<ulEnd.lowerBound])
        guard let re = try? NSRegularExpression(pattern: "<a [^>]*>([^<]+)</a>") else { return [] }
        var out: [String] = []
        for m in re.matches(in: slice, range: NSRange(slice.startIndex..., in: slice)) {
            if let r = Range(m.range(at: 1), in: slice) {
                let t = plain(String(slice[r]))
                if !t.isEmpty && !out.contains(t) { out.append(t) }
            }
        }
        return out
    }

    /// HTML → texte lisible : les sauts de ligne d'AtoM (`<br>`, `</p>`) deviennent de vrais retours,
    /// les balises sont retirées et les entités décodées (nommées et numériques).
    private static func plain(_ s: String) -> String {
        var t = s.replacingOccurrences(of: "<br/>", with: "\n")
            .replacingOccurrences(of: "<br>", with: "\n")
            .replacingOccurrences(of: "</p>", with: "\n")
        t = t.replacingOccurrences(of: "<[^>]+>", with: "", options: .regularExpression)
        for (e, c) in [("&nbsp;", " "), ("&amp;", "&"), ("&lt;", "<"), ("&gt;", ">"),
                       ("&quot;", "\""), ("&apos;", "'"), ("&laquo;", "«"), ("&raquo;", "»"),
                       ("&hellip;", "…"), ("&eacute;", "é"), ("&egrave;", "è"), ("&agrave;", "à")] {
            t = t.replacingOccurrences(of: e, with: c)
        }
        // Entités numériques (&#039; &#x27; …)
        if let re = try? NSRegularExpression(pattern: "&#(x?)([0-9A-Fa-f]+);") {
            for m in re.matches(in: t, range: NSRange(t.startIndex..., in: t)).reversed() {
                guard let whole = Range(m.range, in: t),
                      let hexR = Range(m.range(at: 1), in: t),
                      let numR = Range(m.range(at: 2), in: t) else { continue }
                let radix = t[hexR].isEmpty ? 10 : 16
                if let v = UInt32(t[numR], radix: radix), let u = Unicode.Scalar(v) {
                    t.replaceSubrange(whole, with: String(Character(u)))
                }
            }
        }
        // Espaces multiples issus de l'indentation du gabarit, sans écraser les retours à la ligne.
        t = t.replacingOccurrences(of: "[ \t]+", with: " ", options: .regularExpression)
        t = t.replacingOccurrences(of: " *\n *", with: "\n", options: .regularExpression)
        return t.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    // MARK: - comparaison

    /// Compare la notice en ligne (éventuellement vide) avec ce que ScanToPDF propose.
    static func diff(existing: AtomRecord?, proposed: AtomRecord) -> [AtomFieldDiff] {
        let e = existing ?? AtomRecord()
        let join = { (a: [String]) in a.joined(separator: ", ") }
        return [
            AtomFieldDiff(label: "Étendue matérielle et support", existing: e.extentAndMedium, proposed: proposed.extentAndMedium),
            AtomFieldDiff(label: "Histoire archivistique",        existing: e.archivalHistory, proposed: proposed.archivalHistory),
            AtomFieldDiff(label: "Portée et contenu",             existing: e.scopeAndContent, proposed: proposed.scopeAndContent),
            AtomFieldDiff(label: "Mots-clés — Sujets",            existing: join(e.subjects),  proposed: join(proposed.subjects)),
            AtomFieldDiff(label: "Mots-clés — Lieux",             existing: join(e.places),    proposed: join(proposed.places)),
            AtomFieldDiff(label: "Mots-clés — Noms",              existing: join(e.names),     proposed: join(proposed.names)),
            AtomFieldDiff(label: "Mots-clés — Genres",            existing: join(e.genres),    proposed: join(proposed.genres)),
        ]
    }

    // MARK: - HTTP

    private static func get(_ url: URL) async -> String? {
        var req = URLRequest(url: url)
        req.timeoutInterval = 20
        guard let (data, resp) = try? await URLSession.shared.data(for: req),
              (resp as? HTTPURLResponse)?.statusCode == 200 else { return nil }
        return String(data: data, encoding: .utf8)
    }
}
