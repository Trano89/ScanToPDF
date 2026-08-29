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
    let key: String             // nom du champ dans le formulaire AtoM
    let label: String
    let multiline: Bool
    let existing: String
    var proposed: String        // modifiable à la volée avant validation
    var kind: Kind { existing == proposed ? .unchanged : (existing.isEmpty ? .added : .modified) }
    var id: String { key }
}

/// Accès à l'instance AtoM. Tout passe par HTTPS ; la lecture d'une notice publique ne demande
/// aucune authentification, seule la publication en exige une.
///
/// ⚠️ AtoM n'expose AUCUN point d'accès REST d'écriture pour les descriptions (vérifié sur la
/// documentation 2.8 et sur l'instance : /api/… répond 404, le plugin n'est pas activé). La
/// publication emprunte donc le même chemin qu'un archiviste devant son navigateur : session
/// authentifiée, puis envoi du formulaire d'édition.
enum AtomClient {

    /// Les deux écritures possibles d'une même cote. L'ancienne convention du fonds sépare le numéro
    /// de document par « / » (Be.a.S1.1989/1), la nouvelle par « _ » (Be.a.S1.1989_1). AtoM ne doit
    /// contenir qu'UNE notice par document : il faut donc chercher les deux avant de conclure qu'elle
    /// n'existe pas, sous peine de créer un doublon.
    static func codeVariants(_ code: String) -> [String] {
        let under = code.replacingOccurrences(of: "/", with: "_")
        let slash = code.replacingOccurrences(of: "_", with: "/")
        return under == slash ? [under] : [under, slash]
    }

    /// Slug AtoM d'une cote. Vérifié sur l'instance : les points deviennent des tirets, le « _ » est
    /// CONSERVÉ (Dz.a.Y2.2017_2 → Dz-a-Y2-2017_2) alors que le « / » devient un tiret
    /// (Be.a.S1.1989/1 → Be-a-S1-1989-1). La casse est respectée.
    static func slug(forCode code: String) -> String {
        code.replacingOccurrences(of: ".", with: "-")
            .replacingOccurrences(of: "/", with: "-")
            .replacingOccurrences(of: " ", with: "-")
    }

    // MARK: - lecture d'une notice existante

    /// Résultat d'une recherche de notice : où elle se trouve et sous quelle écriture de cote.
    struct Match {
        let slug: String
        let record: AtomRecord
        let matchedCode: String     // la cote telle qu'AtoM la porte (avec « / » ou « _ »)
        /// La notice utilise l'ancienne écriture : sa cote devra être migrée vers « _ ».
        var needsCodeMigration: Bool { matchedCode.contains("/") }
    }

    /// Cherche la notice d'une cote, dans SES DEUX écritures (« _ » et « / »). Renvoie nil seulement
    /// si aucune des deux n'existe — c'est alors une création.
    static func findExisting(base: URL, code: String) async -> Match? {
        for variant in codeVariants(code) {
            // 1) adresse directe, immédiate
            let direct = slug(forCode: variant)
            if let html = await get(base.appendingPathComponent("index.php/\(direct)")),
               html.contains("class=\"field") {
                let r = parseRecord(html)
                return Match(slug: direct, record: r, matchedCode: bareCode(r.identifier, fallback: variant))
            }
            // 2) recherche plein texte sur la cote entre guillemets
            guard let q = "\"\(variant)\"".addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed),
                  let url = URL(string: base.absoluteString + "/index.php/informationobject/browse?sq0=\(q)&topLod=0"),
                  let list = await get(url) else { continue }
            let ignored: Set<String> = ["clipboard", "informationobject", "user", "search", "taxonomy",
                                        "repository", "actor", "index", "browse", "static"]
            guard let re = try? NSRegularExpression(pattern: #"href="/index\.php/([A-Za-z0-9][A-Za-z0-9_-]*)""#) else { continue }
            for m in re.matches(in: list, range: NSRange(list.startIndex..., in: list)) {
                guard let r0 = Range(m.range(at: 1), in: list) else { continue }
                let cand = String(list[r0])
                if ignored.contains(cand.lowercased()) || cand.count < 3 { continue }
                guard let html = await get(base.appendingPathComponent("index.php/\(cand)")),
                      html.contains("class=\"field") else { continue }
                let rec = parseRecord(html)
                let bare = bareCode(rec.identifier, fallback: variant)
                // On n'accepte le résultat que si la cote correspond vraiment à l'une des écritures.
                if codeVariants(code).contains(where: { $0.caseInsensitiveCompare(bare) == .orderedSame }) {
                    return Match(slug: cand, record: rec, matchedCode: bare)
                }
            }
        }
        return nil
    }

    /// « CH FVJC Be.a.S1.1989/1 » → « Be.a.S1.1989/1 » : AtoM préfixe la cote du code du service.
    static func bareCode(_ identifier: String, fallback: String) -> String {
        let parts = identifier.split(separator: " ")
        return parts.last.map(String.init) ?? fallback
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

    /// Compare la notice en ligne (éventuellement absente) avec ce que ScanToPDF propose.
    /// TOUTES les valeurs restent modifiables avant validation, y compris celles déjà dans AtoM.
    static func diff(existing: AtomRecord?, proposed: AtomRecord) -> [AtomFieldDiff] {
        let e = existing ?? AtomRecord()
        let j = { (a: [String]) in a.joined(separator: ", ") }
        return [
            AtomFieldDiff(key: "identifier",          label: "Cote",                          multiline: false,
                          existing: e.identifier,      proposed: proposed.identifier),
            AtomFieldDiff(key: "title",               label: "Titre",                         multiline: false,
                          existing: e.title,           proposed: proposed.title.isEmpty ? e.title : proposed.title),
            AtomFieldDiff(key: "extentAndMedium",     label: "Étendue matérielle et support", multiline: true,
                          existing: e.extentAndMedium, proposed: proposed.extentAndMedium),
            AtomFieldDiff(key: "archivalHistory",     label: "Histoire archivistique",        multiline: true,
                          existing: e.archivalHistory, proposed: proposed.archivalHistory),
            AtomFieldDiff(key: "scopeAndContent",     label: "Portée et contenu",             multiline: true,
                          existing: e.scopeAndContent, proposed: proposed.scopeAndContent),
            AtomFieldDiff(key: "subjectAccessPoints", label: "Mots-clés — Sujets",            multiline: false,
                          existing: j(e.subjects),     proposed: j(proposed.subjects)),
            AtomFieldDiff(key: "placeAccessPoints",   label: "Mots-clés — Lieux",             multiline: false,
                          existing: j(e.places),       proposed: j(proposed.places)),
            AtomFieldDiff(key: "nameAccessPoints",    label: "Mots-clés — Noms",              multiline: false,
                          existing: j(e.names),        proposed: j(proposed.names)),
            AtomFieldDiff(key: "genreAccessPoints",   label: "Mots-clés — Genres",            multiline: false,
                          existing: j(e.genres),       proposed: j(proposed.genres)),
        ]
    }



    /// Résout une saisie manuelle : adresse complète de la notice, identifiant d'adresse, ou cote.
    /// Sert quand la recherche automatique n'a rien trouvé et que l'archiviste sait, lui, où elle est.
    static func resolve(base: URL, input: String) async -> Match? {
        let t = input.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !t.isEmpty else { return nil }
        var candidate = t
        if let u = URL(string: t), u.scheme != nil, let last = u.pathComponents.last, !last.isEmpty {
            candidate = last
        }
        if let html = await get(base.appendingPathComponent("index.php/" + candidate)),
           html.contains("class=\"field") {
            let r = parseRecord(html)
            return Match(slug: candidate, record: r, matchedCode: bareCode(r.identifier, fallback: candidate))
        }
        return await findExisting(base: base, code: candidate)
    }

    /// Adresse de la recherche AtoM pour une cote, à ouvrir dans le navigateur.
    static func searchURL(base: URL, code: String) -> URL? {
        let q = "\"\(code)\"".addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? code
        return URL(string: base.absoluteString + "/index.php/informationobject/browse?sq0=" + q + "&topLod=0")
    }

    // MARK: - proposition issue de la fiche ISAD

    /// Construit la proposition à partir de la fiche « <cote>.txt » écrite par le moteur : sections
    /// « TITRE (ISAD x.y.z) » suivies d'un filet, mots-clés listés à puces.
    static func recordFromFiche(_ fiche: String, code: String) -> AtomRecord {
        var sections: [String: [String]] = [:]
        var current: String?
        var buffer: [String] = []
        func flush() { if let c = current { sections[c] = buffer }; buffer = [] }
        let lines = fiche.components(separatedBy: .newlines)
        for (i, raw) in lines.enumerated() {
            let line = raw.trimmingCharacters(in: .whitespaces)
            let next = i + 1 < lines.count ? lines[i + 1].trimmingCharacters(in: .whitespaces) : ""
            if !line.isEmpty, next.hasPrefix("\u{2500}\u{2500}") {
                flush()
                current = line.replacingOccurrences(of: "\\s*\\(ISAD[^)]*\\)", with: "", options: .regularExpression)
                    .trimmingCharacters(in: .whitespaces).uppercased()
                continue
            }
            if line.hasPrefix("\u{2500}\u{2500}") || line.hasPrefix("\u{2550}\u{2550}") { continue }
            if current != nil { buffer.append(raw) }
        }
        flush()
        func sectionText(_ key: String) -> String {
            (sections[key] ?? []).joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
        }
        func sectionList(_ key: String) -> [String] {
            (sections[key] ?? []).compactMap { l in
                let t = l.trimmingCharacters(in: .whitespaces)
                guard t.hasPrefix("\u{2022}") else { return nil }
                let v = t.dropFirst().trimmingCharacters(in: .whitespaces)
                return v.isEmpty || v.caseInsensitiveCompare("Inconnu") == .orderedSame ? nil : String(v)
            }
        }
        var r = AtomRecord()
        r.identifier      = code
        r.date            = sectionText("DATE DU DOCUMENT")
        r.extentAndMedium = sectionText("\u{c9}TENDUE ET SUPPORT")
        r.archivalHistory = sectionText("HISTOIRE ARCHIVISTIQUE")
        r.scopeAndContent = sectionText("PORT\u{c9}E ET CONTENU")
        r.subjects        = sectionList("MOTS-CL\u{c9}S \u{2014} SUJETS")
        r.places          = sectionList("MOTS-CL\u{c9}S \u{2014} LIEUX")
        r.names           = sectionList("POINTS D'ACC\u{c8}S MATI\u{c8}RES")
        let genre         = sectionText("TYPE DOCUMENTAIRE")
        r.genres          = genre.isEmpty || genre.caseInsensitiveCompare("Inconnu") == .orderedSame ? [] : [genre]
        return r
    }

    // MARK: - session authentifiée et publication

    enum AtomError: LocalizedError {
        case notLoggedIn, formUnavailable, fieldsNotFound([String]), rejected(String)
        var errorDescription: String? {
            switch self {
            case .notLoggedIn:           return "Connexion \u{e0} AtoM refus\u{e9}e \u{2014} v\u{e9}rifiez le courriel et le mot de passe."
            case .formUnavailable:       return "Formulaire d'\u{e9}dition inaccessible (droits insuffisants ?)."
            case .fieldsNotFound(let f): return "Champs introuvables dans le formulaire : " + f.joined(separator: ", ")
            case .rejected(let why):     return "AtoM a refus\u{e9} l'enregistrement : " + why
            }
        }
    }

    /// Ouvre une session ; le cookie est conservé par URLSession pour les requêtes suivantes.
    static func login(base: URL, email: String, password: String) async -> Bool {
        let loginURL = base.appendingPathComponent("index.php/user/login")
        guard let page = await get(loginURL) else { return false }
        let form = isolateForm(page, actionContains: "user/login") ?? page
        let token = inputValue(form, name: "_csrf_token") ?? ""
        let body = ["email": email, "password": password, "_csrf_token": token, "next": ""]
        guard let html = await post(loginURL, fields: body) else { return false }
        return html.contains("user/logout") || !html.contains("name=\"password\"")
    }

    static func isLoggedIn(base: URL) async -> Bool {
        guard let html = await get(base.appendingPathComponent("index.php")) else { return false }
        return html.contains("user/logout")
    }

    /// Champs du formulaire d'édition, DÉCOUVERTS et non devinés : une divergence de gabarit doit
    /// être signalée, jamais silencieusement ignorée.
    static func editFormFields(base: URL, slug: String) async -> [(name: String, value: String)]? {
        guard let html = await get(base.appendingPathComponent("index.php/" + slug + "/edit")),
              let form = isolateForm(html, actionContains: slug + "/edit") ?? isolateForm(html, actionContains: "/edit")
        else { return nil }
        return formFields(form)
    }

    /// Envoie les modifications. Tous les autres champs sont renvoyés inchangés : un formulaire
    /// Symfony partiellement soumis EFFACE ce qu'il ne reçoit pas.
    static func submitEdit(base: URL, slug: String, changes: [String: String]) async -> Result<Void, AtomError> {
        guard var fields = await editFormFields(base: base, slug: slug) else { return .failure(.formUnavailable) }
        var missing: [String] = []
        for (name, value) in changes {
            if let i = fields.firstIndex(where: { $0.name == name }) { fields[i].value = value }
            else if let i = fields.firstIndex(where: { $0.name == name + "[]" }) { fields[i].value = value }
            else { missing.append(name) }
        }
        if !missing.isEmpty { return .failure(.fieldsNotFound(missing)) }
        var body: [String: String] = [:]
        for f in fields where !f.name.isEmpty { body[f.name] = f.value }
        guard let html = await post(base.appendingPathComponent("index.php/" + slug + "/edit"), fields: body)
        else { return .failure(.rejected("aucune r\u{e9}ponse du serveur")) }
        if let err = firstMatch(html, "<div class=\"[^\"]*alert-danger[^\"]*\">(.*?)</div>") {
            return .failure(.rejected(plain(err)))
        }
        return .success(())
    }

    // MARK: - analyse de formulaire

    /// Isole UN formulaire : une page AtoM en contient plusieurs (recherche, connexion, édition) et
    /// analyser la page entière mélangerait leurs champs.
    static func isolateForm(_ html: String, actionContains needle: String) -> String? {
        guard let re = try? NSRegularExpression(pattern: "<form\\b[^>]*>.*?</form>",
                                                options: [.caseInsensitive, .dotMatchesLineSeparators])
        else { return nil }
        var fallback: String?
        for m in re.matches(in: html, range: NSRange(html.startIndex..., in: html)) {
            guard let r = Range(m.range, in: html) else { continue }
            let f = String(html[r])
            guard let head = f.range(of: ">") else { continue }
            let opening = String(f[..<head.upperBound]).lowercased()
            if opening.contains(needle.lowercased()) { return f }
            if fallback == nil, opening.contains("method=\"post\"") { fallback = f }
        }
        return fallback
    }

    /// Tous les champs postables : input, textarea, et l'option sélectionnée des select.
    static func formFields(_ html: String) -> [(name: String, value: String)] {
        var out: [(String, String)] = []
        if let re = try? NSRegularExpression(pattern: "<input\\b[^>]*>", options: [.caseInsensitive]) {
            for m in re.matches(in: html, range: NSRange(html.startIndex..., in: html)) {
                guard let r = Range(m.range, in: html) else { continue }
                let tag = String(html[r])
                let type = (attr(tag, "type") ?? "text").lowercased()
                guard type != "submit", type != "button", type != "file", let name = attr(tag, "name") else { continue }
                if (type == "checkbox" || type == "radio"), !tag.lowercased().contains("checked") { continue }
                out.append((name, attr(tag, "value") ?? ""))
            }
        }
        if let re = try? NSRegularExpression(pattern: "<textarea\\b([^>]*)>(.*?)</textarea>",
                                             options: [.caseInsensitive, .dotMatchesLineSeparators]) {
            for m in re.matches(in: html, range: NSRange(html.startIndex..., in: html)) {
                guard let a = Range(m.range(at: 1), in: html), let v = Range(m.range(at: 2), in: html),
                      let name = attr("<textarea" + String(html[a]) + ">", "name") else { continue }
                out.append((name, plain(String(html[v]))))
            }
        }
        if let re = try? NSRegularExpression(pattern: "<select\\b([^>]*)>(.*?)</select>",
                                             options: [.caseInsensitive, .dotMatchesLineSeparators]) {
            for m in re.matches(in: html, range: NSRange(html.startIndex..., in: html)) {
                guard let a = Range(m.range(at: 1), in: html), let inner = Range(m.range(at: 2), in: html),
                      let name = attr("<select" + String(html[a]) + ">", "name") else { continue }
                let body = String(html[inner])
                let sel = firstMatch(body, "<option[^>]*selected[^>]*value=\"([^\"]*)\"")
                    ?? firstMatch(body, "<option[^>]*value=\"([^\"]*)\"[^>]*selected")
                out.append((name, sel ?? ""))
            }
        }
        return out
    }

    static func inputValue(_ html: String, name: String) -> String? {
        formFields(html).first { $0.name == name }?.value
    }

    private static func attr(_ tag: String, _ name: String) -> String? {
        firstMatch(tag, "\\b" + name + "\\s*=\\s*\"([^\"]*)\"")
    }

    private static func firstMatch(_ s: String, _ pattern: String) -> String? {
        guard let re = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive, .dotMatchesLineSeparators]),
              let m = re.firstMatch(in: s, range: NSRange(s.startIndex..., in: s)),
              m.numberOfRanges > 1, let r = Range(m.range(at: 1), in: s) else { return nil }
        return String(s[r])
    }

    private static func post(_ url: URL, fields: [String: String]) async -> String? {
        var req = URLRequest(url: url)
        req.httpMethod = "POST"
        req.timeoutInterval = 45
        req.setValue("application/x-www-form-urlencoded; charset=utf-8", forHTTPHeaderField: "Content-Type")
        var cs = CharacterSet.alphanumerics
        cs.insert(charactersIn: "-._~")
        req.httpBody = fields.map { k, v in
            (k.addingPercentEncoding(withAllowedCharacters: cs) ?? k) + "=" +
            (v.addingPercentEncoding(withAllowedCharacters: cs) ?? v)
        }.joined(separator: "&").data(using: .utf8)
        guard let (data, _) = try? await URLSession.shared.data(for: req) else { return nil }
        return String(data: data, encoding: .utf8)
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
