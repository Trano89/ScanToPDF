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
    var repository = ""          // Dépôt — l'import CSV apparie sur cote + titre + dépôt
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
    /// Publiable tel quel : l'import CSV d'AtoM accepte les mots-clés en texte, séparés par « | ».
    var writable: Bool { true }
}

/// Accès à l'instance AtoM. Tout passe par HTTPS ; la lecture d'une notice publique ne demande
/// aucune authentification, seule la publication en exige une.
///
/// ⚠️ AtoM n'expose AUCUN point d'accès REST d'écriture pour les descriptions (vérifié sur la
/// documentation 2.8 et sur l'instance : /api/… répond 404, le plugin n'est pas activé). La
/// publication emprunte donc le même chemin qu'un archiviste devant son navigateur : session
/// authentifiée, puis envoi du formulaire d'édition.
enum AtomClient {

    /// Journal dédié : /Users/Shared/ScanToPDF/atom.log. Sans lui, un échec de publication est
    /// indiagnosticable — c'est exactement ce qui s'est produit.
    static func log(_ s: String) { FileLog.append(s, to: "atom.log") }


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
                // La cote doit venir de la notice ELLE-MÊME. En repliant sur le code cherché quand
                // l'identifiant est illisible, la vérification se prouvait toute seule : n'importe
                // quelle page renvoyée par la recherche était acceptée comme « la » notice — une
                // notice sans rapport a ainsi été proposée à l'écriture.
                let bare = bareCode(rec.identifier, fallback: "")
                guard !bare.isEmpty else { continue }
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
        // Le dépôt n'est pas toujours porté par la notice : AtoM l'hérite du fonds et l'affiche
        // ici. L'import CSV, lui, remonte l'arborescence pour le retrouver.
        r.repository      = field(html, "Dépôt")
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
        guard let html = await post(loginURL, fields: body) else { log("connexion : aucune r\u{e9}ponse"); return false }
        let ok = html.contains("user/logout") || !html.contains("name=\"password\"")
        log("connexion « " + email + " » : " + (ok ? "OK" : "REFUS\u{c9}E") + " (jeton " + String(token.count) + " car.)")
        return ok
    }

    static func isLoggedIn(base: URL) async -> Bool {
        guard let html = await get(base.appendingPathComponent("index.php")) else { return false }
        return html.contains("user/logout")
    }

    /// Champs du formulaire d'édition, DÉCOUVERTS et non devinés : une divergence de gabarit doit
    /// être signalée, jamais silencieusement ignorée.
    static func editFormFields(base: URL, slug: String) async -> [(name: String, value: String)]? {
        guard let html = await get(base.appendingPathComponent("index.php/" + slug + "/edit")) else {
            log("formulaire d'\u{e9}dition inaccessible pour /" + slug + " (non connect\u{e9} ou droits insuffisants)")
            return nil
        }
        // Le repli « n'importe quel formulaire dont l'action contient /edit » a déjà isolé le
        // formulaire du COMPTE UTILISATEUR (mot de passe, groupes) sur une page qui n'était pas une
        // notice. On exige donc la signature d'une description archivistique avant d'écrire quoi que
        // ce soit : mieux vaut échouer que remplir le mauvais formulaire.
        let candidates = [isolateForm(html, actionContains: slug + "/edit"),
                          isolateForm(html, actionContains: "/edit")].compactMap { $0 }
        guard let form = candidates.first(where: { $0.contains("name=\"scopeAndContent\"") }) else {
            log(candidates.isEmpty
                ? "aucun formulaire d'\u{e9}dition dans la page /" + slug + "/edit"
                : "le formulaire de /" + slug + "/edit n'est PAS celui d'une notice — \u{e9}criture refus\u{e9}e")
            return nil
        }
        try? form.data(using: .utf8)?
            .write(to: URL(fileURLWithPath: "/Users/Shared/ScanToPDF/atom_formulaire.html"))
        return formFields(form)
    }

    /// Envoie les modifications. Tous les autres champs sont renvoyés inchangés : un formulaire
    /// Symfony partiellement soumis EFFACE ce qu'il ne reçoit pas.

    // Un HTTP 200 ne dit pas si AtoM a ENREGISTRÉ : il re-rend simplement la page. On identifie donc
    // l'état réel de la réponse et on la conserve sur disque — les refus de validation d'AtoM ne sont
    // pas dans une alerte globale mais collés à chaque champ, invisibles pour un test naïf.
    private static func diagnose(_ body: String) {
        try? body.data(using: .utf8)?
            .write(to: URL(fileURLWithPath: "/Users/Shared/ScanToPDF/atom_reponse.html"))
        let isForm  = body.contains("name=\"scopeAndContent\"")
        let isLogin = !isForm && body.contains("name=\"password\"")
        log("réponse : " + (isLogin ? "page de CONNEXION (session perdue)"
                          : isForm ? "formulaire d'édition RE-RENDU (enregistrement refusé)"
                                   : "page de consultation")
            + " — " + String(body.count) + " octets, copiée dans atom_reponse.html")
        for pattern in ["<ul class=\"error_list\">(.*?)</ul>",
                        "<div class=\"[^\"]*invalid-feedback[^\"]*\">(.*?)</div>",
                        "<div class=\"[^\"]*alert-danger[^\"]*\">(.*?)</div>",
                        "<div class=\"[^\"]*messages error[^\"]*\">(.*?)</div>"] {
            guard let re = try? NSRegularExpression(pattern: pattern,
                                                    options: [.caseInsensitive, .dotMatchesLineSeparators]) else { continue }
            for m in re.matches(in: body, range: NSRange(body.startIndex..., in: body)).prefix(8) {
                guard let r = Range(m.range(at: 1), in: body) else { continue }
                let msg = plain(String(body[r]))
                if !msg.isEmpty { log("  refus AtoM : " + msg) }
            }
        }
    }


    // MARK: - Publication par IMPORT CSV — la voie d'écriture documentée par AtoM
    //
    // AtoM n'a pas d'API REST d'écriture pour les descriptions : ses points d'accès REST se
    // limitent à la lecture (parcourir, lire, télécharger) et le greffon n'est même pas activé ici.
    // La méthode officielle est l'import CSV, disponible dans l'interface web, avec deux options
    // qui correspondent exactement au besoin :
    //   • updateType = match-and-update → met à jour la notice EN PLACE, les colonnes vides du CSV
    //     étant ignorées (on n'écrase donc jamais un champ qu'on ne remplit pas) ;
    //   • skipUnmatched = on → si aucune notice ne correspond, la ligne est ignorée. Aucune
    //     création n'est possible, ce qui est la règle posée pour ce catalogue.
    // L'appariement se fait sur cote + titre + dépôt (QubitInformationObject::getByTitleIdentifierAndRepo),
    // le dépôt étant résolu par héritage en remontant l'arborescence.
    // Avantage décisif : dans un CSV, les mots-clés sont du TEXTE, séparés par « | » — AtoM résout
    // lui-même les termes, là où le formulaire d'édition exigeait des URL de thésaurus.
    // L'import s'exécute en tâche de fond (Gearman) : on suit le compte rendu du travail.

    /// Colonnes du gabarit ISAD livré avec AtoM. L'ordre n'importe pas, les noms si.
    private static let csvColumns = [
        "legacyId", "parentId", "qubitParentSlug", "accessionNumber", "identifier", "title",
        "levelOfDescription", "extentAndMedium", "repository", "archivalHistory", "acquisition",
        "scopeAndContent", "appraisal", "accruals", "arrangement", "accessConditions",
        "reproductionConditions", "language", "script", "languageNote", "physicalCharacteristics",
        "findingAids", "locationOfOriginals", "locationOfCopies", "relatedUnitsOfDescription",
        "publicationNote", "digitalObjectPath", "digitalObjectURI", "generalNote",
        "subjectAccessPoints", "placeAccessPoints", "nameAccessPoints", "genreAccessPoints",
        "descriptionIdentifier", "institutionIdentifier", "rules", "descriptionStatus",
        "levelOfDetail", "revisionHistory", "languageOfDescription", "scriptOfDescription",
        "sources", "archivistNote", "publicationStatus", "culture",
    ]

    private static func csvCell(_ v: String) -> String {
        let flat = v.replacingOccurrences(of: "\r\n", with: "\n")
        guard flat.contains(",") || flat.contains("\"") || flat.contains("\n") else { return flat }
        return "\"" + flat.replacingOccurrences(of: "\"", with: "\"\"") + "\""
    }

    static func buildCSV(_ values: [String: String]) -> String {
        let header = csvColumns.joined(separator: ",")
        let row = csvColumns.map { csvCell(values[$0] ?? "") }.joined(separator: ",")
        return header + "\n" + row + "\n"
    }

    private static func multipart(_ fields: [(String, String)], fileName: String, csv: String,
                                  boundary: String) -> Data {
        var d = Data()
        func add(_ s: String) { d.append(s.data(using: .utf8)!) }
        for (n, v) in fields {
            add("--\(boundary)\r\nContent-Disposition: form-data; name=\"\(n)\"\r\n\r\n\(v)\r\n")
        }
        add("--\(boundary)\r\nContent-Disposition: form-data; name=\"file\"; filename=\"\(fileName)\"\r\n")
        add("Content-Type: text/csv\r\n\r\n")
        add(csv)
        add("\r\n--\(boundary)--\r\n")
        return d
    }

    /// Envoie le CSV à l'import d'AtoM et rend l'identifiant du travail lancé.
    private static func startImport(base: URL, csv: String, code: String) async -> Result<String, AtomError> {
        let formURL = URL(string: base.absoluteString + "/index.php/object/importSelect?type=csv")!
        guard let page = await get(formURL) else {
            log("page d'import inaccessible — non connecté ou droits insuffisants")
            return .failure(.formUnavailable)
        }
        guard let form = isolateForm(page, actionContains: "importSelect"),
              let token = firstMatch(form, "name=\"_csrf_token\"[^>]*value=\"([^\"]*)\"")
                       ?? firstMatch(form, "value=\"([^\"]*)\"[^>]*name=\"_csrf_token\"") else {
            log("formulaire d'import introuvable dans la page")
            return .failure(.formUnavailable)
        }
        let boundary = "----ScanToPDF\(UInt32.random(in: 0..<UInt32.max))"
        let fields = [("_csrf_token", token),
                      ("importType", "csv"),
                      ("objectType", "informationObject"),
                      ("updateType", "match-and-update"),
                      ("skipUnmatched", "on")]
        var req = URLRequest(url: URL(string: base.absoluteString + "/index.php/object/importSelect")!)
        req.httpMethod = "POST"
        req.timeoutInterval = 60
        req.setValue("multipart/form-data; boundary=\(boundary)", forHTTPHeaderField: "Content-Type")
        req.httpBody = multipart(fields, fileName: code + ".csv", csv: csv, boundary: boundary)
        log("import CSV : envoi de \(csv.count) octets — match-and-update, skipUnmatched")
        guard let (data, resp) = try? await URLSession.shared.upload(for: req, from: req.httpBody!) else {
            return .failure(.rejected("aucune réponse du serveur"))
        }
        let body = String(data: data, encoding: .utf8) ?? ""
        let status = (resp as? HTTPURLResponse)?.statusCode ?? 0
        try? body.data(using: .utf8)?
            .write(to: URL(fileURLWithPath: "/Users/Shared/ScanToPDF/atom_reponse.html"))
        guard let job = firstMatch(body, "jobs/report/id/([0-9]+)") else {
            if let err = firstMatch(body, "<div class=\"[^\"]*alert-danger[^\"]*\">(.*?)</div>") {
                log("import refusé par AtoM : " + plain(err))
                return .failure(.rejected(plain(err)))
            }
            log("import : aucun travail lancé (HTTP \(status)) — réponse dans atom_reponse.html")
            return .failure(.rejected("AtoM n'a pas lancé l'import (droits d'import manquants ?)"))
        }
        log("import CSV accepté — travail n° \(job)")
        return .success(job)
    }

    /// Suit le compte rendu du travail jusqu'à son terme. L'import tourne en tâche de fond : sans
    /// ouvrier (Gearman) actif côté serveur, il reste en attente — on le dit alors clairement.
    private static func awaitImport(base: URL, job: String) async -> Result<Void, AtomError> {
        let url = URL(string: base.absoluteString + "/index.php/jobs/report/id/" + job)!
        for attempt in 1...30 {
            try? await Task.sleep(nanoseconds: 2_000_000_000)
            guard let html = await get(url) else { continue }
            let text = plain(html)
            if text.contains("Skipping record") || text.contains("Unable to match") {
                // On recopie le verdict d'AtoM mot pour mot : c'est lui qui nomme la valeur en cause.
                for l in text.components(separatedBy: "\n") where l.contains("Unable to match")
                                                              || l.contains("Skipping record") {
                    log("  AtoM : " + l.trimmingCharacters(in: .whitespaces))
                }
                log("travail \(job) : notice NON appariée — AtoM a ignoré la ligne")
                return .failure(.rejected("aucune notice appariée dans AtoM (cote propre, titre ou dépôt différents)"))
            }
            if text.contains("Completed") || text.contains("Terminé") {
                log("travail \(job) : terminé après \(attempt * 2) s")
                return .success(())
            }
            if text.contains("Error") || text.contains("Erreur") {
                log("travail \(job) : en erreur — voir atom_reponse.html")
                try? html.data(using: .utf8)?
                    .write(to: URL(fileURLWithPath: "/Users/Shared/ScanToPDF/atom_reponse.html"))
                return .failure(.rejected("l'import a échoué côté AtoM (voir le journal du travail n° \(job))"))
            }
        }
        log("travail \(job) : toujours en attente après 60 s")
        return .failure(.rejected("import en attente depuis 60 s — aucun ouvrier AtoM (Gearman) ne semble actif"))
    }

    /// Publie une notice par import CSV, puis VÉRIFIE par relecture que la notice a bien changé.
    static func publishViaCsv(base: URL, slug: String, record: AtomRecord, pdf: URL,
                              changes: [String: String]) async -> Result<Void, AtomError> {
        // La « Cote » affichée par AtoM est la cote de RÉFÉRENCE : pays, dépôt et cotes des parents
        // assemblés (« CH FVJC Zz.z.Z1.2026_1 »). L'appariement de l'import porte sur la cote PROPRE
        // de la notice (« 2026_1 »), stockée dans information_object.identifier. Seul le formulaire
        // d'édition donne cette valeur telle quelle : on la lit là plutôt que de la déduire.
        guard let form = await editFormFields(base: base, slug: slug) else {
            return .failure(.formUnavailable)
        }
        let ownIdentifier = form.first { $0.name == "identifier" }?.value ?? ""
        let ownTitle = form.first { $0.name == "title" }?.value ?? record.title
        guard !ownIdentifier.isEmpty, !ownTitle.isEmpty else {
            return .failure(.rejected("cote ou titre absent de la notice — appariement impossible"))
        }
        var values: [String: String] = ["culture": "fr"]
        for (k, v) in changes where k != "identifier" { values[k] = v }
        values["identifier"] = ownIdentifier
        values["title"] = ownTitle
        values["repository"] = record.repository
        log("import CSV : cote propre « \(ownIdentifier) » (référence « \(record.identifier) »), "
            + "titre « \(ownTitle) », dépôt « \(record.repository)»"
            + (record.repository.isEmpty ? " — dépôt absent, appariement sur cote + titre" : ""))
        let csv = buildCSV(values)
        try? csv.data(using: .utf8)?
            .write(to: URL(fileURLWithPath: "/Users/Shared/ScanToPDF/atom_import.csv"))
        switch await startImport(base: base, csv: csv, code: slug) {
        case .failure(let e): return .failure(e)
        case .success(let job):
            if case .failure(let e) = await awaitImport(base: base, job: job) { return .failure(e) }
        }
        if case .failure(let e) = await verifySaved(base: base, slug: slug, changes: changes) {
            return .failure(e)
        }
        // Les données sont en ligne ; reste le PDF/A, seul fichier publié dans AtoM.
        return await attachPDF(base: base, slug: slug, pdf: pdf)
    }


    /// Attache le PDF/A final à la notice. AtoM n'accepte QU'UN objet numérique par description :
    /// si la notice en porte déjà un, sa page d'ajout redirige vers l'édition de cet objet — on le
    /// détecte et on conserve l'existant plutôt que de l'écraser.
    /// Route et champs vérifiés dans apps/qubit/modules/object/addDigitalObjectAction.class.php.
    static func attachPDF(base: URL, slug: String, pdf: URL) async -> Result<Void, AtomError> {
        guard let data = try? Data(contentsOf: pdf) else {
            log("PDF illisible : \(pdf.lastPathComponent)")
            return .failure(.rejected("PDF introuvable sur le disque"))
        }
        let pageURL = base.appendingPathComponent("index.php/" + slug + "/object/addDigitalObject")
        var req = URLRequest(url: pageURL)
        req.timeoutInterval = 30
        guard let (pd, presp) = try? await URLSession.shared.data(for: req) else {
            return .failure(.rejected("page d'ajout d'objet numérique inaccessible"))
        }
        let page = String(data: pd, encoding: .utf8) ?? ""
        // Redirigé vers l'édition d'un objet numérique = la notice en porte déjà un.
        if (presp.url?.absoluteString ?? "").contains("/digitalobject/") {
            log("objet numérique DÉJÀ présent sur /\(slug) — conservé, aucun remplacement")
            return .success(())
        }
        guard let form = isolateForm(page, actionContains: "addDigitalObject"),
              let token = firstMatch(form, "name=\"_csrf_token\"[^>]*value=\"([^\"]*)\"")
                       ?? firstMatch(form, "value=\"([^\"]*)\"[^>]*name=\"_csrf_token\"") else {
            log("formulaire d'ajout d'objet numérique introuvable (droits insuffisants ?)")
            return .failure(.formUnavailable)
        }
        let boundary = "----ScanToPDF\(UInt32.random(in: 0..<UInt32.max))"
        var body = Data()
        func add(_ t: String) { body.append(t.data(using: .utf8)!) }
        add("--\(boundary)\r\nContent-Disposition: form-data; name=\"_csrf_token\"\r\n\r\n\(token)\r\n")
        add("--\(boundary)\r\nContent-Disposition: form-data; name=\"file\"; filename=\"\(pdf.lastPathComponent)\"\r\n")
        add("Content-Type: application/pdf\r\n\r\n")
        body.append(data)
        add("\r\n--\(boundary)--\r\n")

        var post = URLRequest(url: pageURL)
        post.httpMethod = "POST"
        post.timeoutInterval = 300          // un PDF/A de plusieurs Mo sur une liaison lente
        post.setValue("multipart/form-data; boundary=\(boundary)", forHTTPHeaderField: "Content-Type")
        log("envoi du PDF « \(pdf.lastPathComponent) » (\(data.count / 1024) Ko) vers /\(slug)")
        guard let (rd, rresp) = try? await URLSession.shared.upload(for: post, from: body) else {
            return .failure(.rejected("envoi du PDF interrompu"))
        }
        let answer = String(data: rd, encoding: .utf8) ?? ""
        let landed = rresp.url?.absoluteString ?? ""
        // Succès : AtoM redirige vers la notice. Échec : il re-rend le formulaire d'ajout.
        if landed.contains("addDigitalObject") {
            try? answer.data(using: .utf8)?
                .write(to: URL(fileURLWithPath: "/Users/Shared/ScanToPDF/atom_reponse.html"))
            let why = firstMatch(answer, "<ul class=\"error_list\">(.*?)</ul>")
                   ?? firstMatch(answer, "<div class=\"[^\"]*alert-danger[^\"]*\">(.*?)</div>")
            log("PDF REFUSÉ : " + (why.map(plain) ?? "formulaire re-rendu, voir atom_reponse.html"))
            return .failure(.rejected("AtoM a refusé le PDF" + (why.map { " : " + plain($0) } ?? "")))
        }
        // AtoM ne redirige vers la notice QUE si le formulaire a été validé et l'objet enregistré
        // (addDigitalObjectAction : isValid → processForm → save → redirect). On relit tout de même
        // la notice pour confirmer. L'affichage d'un objet numérique dépendant du thème, l'absence
        // d'indice est signalée comme un doute à lever, non comme un échec : ce serait mentir dans
        // l'autre sens que de déclarer perdu un fichier qu'AtoM a bel et bien enregistré.
        let marks = ["uploads/r/", "digital-object", "digitalObject", "/digitalobject/"]
        if let after = await get(base.appendingPathComponent("index.php/" + slug)) {
            if marks.contains(where: after.contains) {
                log("✅ PDF attaché et vérifié sur /\(slug)")
            } else {
                log("PDF accepté par AtoM (redirection vers la notice) mais aucun objet numérique "
                    + "visible à la relecture — à contrôler sur la notice")
            }
        }
        return .success(())
    }

    /// Un import « terminé » ne prouve pas que NOTRE notice a changé : on relit et on compare.
    private static func verifySaved(base: URL, slug: String,
                                    changes: [String: String]) async -> Result<Void, AtomError> {
        guard let after = await get(base.appendingPathComponent("index.php/" + slug)) else {
            return .failure(.rejected("enregistrement non vérifiable (notice illisible après import)"))
        }
        let saved = parseRecord(after)
        let control = [("extentAndMedium", saved.extentAndMedium),
                       ("archivalHistory", saved.archivalHistory),
                       ("scopeAndContent", saved.scopeAndContent)]
        for (key, now) in control {
            guard let expected = changes[key] else { continue }
            let a = now.replacingOccurrences(of: "\n", with: " ").trimmingCharacters(in: .whitespaces)
            let b = expected.replacingOccurrences(of: "\n", with: " ").trimmingCharacters(in: .whitespaces)
            if a != b {
                log("ÉCHEC : « \(key) » vaut toujours « \(a.prefix(60)) » après import")
                return .failure(.rejected("la notice n'a pas été modifiée par l'import"))
            }
        }
        log("import VÉRIFIÉ par relecture de la notice")
        return .success(())
    }

    static func submitEdit(base: URL, slug: String, changes: [String: String]) async -> Result<Void, AtomError> {
        guard var fields = await editFormFields(base: base, slug: slug) else { return .failure(.formUnavailable) }
        log("champs du formulaire (" + String(fields.count) + ") : "
            + fields.map { $0.name }.joined(separator: ", "))
        var missing: [String] = []
        for (name, value) in changes {
            // AtoM nomme parfois ses champs « objet[champ] » ou « champ[] » : on accepte ces formes
            // plutôt que d'échouer sur une différence de gabarit.
            let i = fields.firstIndex { $0.name == name }
                ?? fields.firstIndex { $0.name == name + "[]" }
                ?? fields.firstIndex { $0.name.hasSuffix("[" + name + "]") }
                ?? fields.firstIndex { $0.name.hasSuffix("[" + name + "][]") }
            if let i {
                let target = fields[i].name
                fields[i].value = value
                // Champ multi-valeurs : on remplace la liste entière, sans laisser traîner les
                // anciennes occurrences à côté de la nouvelle valeur.
                var kept: [(name: String, value: String)] = []
                var seen = false
                for f in fields {
                    if f.name == target {
                        if seen { continue }
                        seen = true
                    }
                    kept.append(f)
                }
                fields = kept
                log("champ « " + name + " » → « " + target + " »")
            }
            else { missing.append(name) }
        }
        if !missing.isEmpty {
            log("ÉCHEC : champs introuvables — " + missing.joined(separator: ", "))
            return .failure(.fieldsNotFound(missing))
        }
        let body = fields.filter { !$0.name.isEmpty }
        guard let out = await postFull(base.appendingPathComponent("index.php/" + slug + "/edit"), pairs: body)
        else { return .failure(.rejected("aucune r\u{e9}ponse du serveur")) }
        // AtoM REDIRIGE vers la notice quand il a enregistré, et se contente de re-rendre le
        // formulaire quand il refuse : l'adresse finale distingue les deux à coup sûr, là où le
        // code HTTP vaut 200 dans les deux cas (la redirection étant suivie automatiquement).
        let stayedOnForm = out.finalURL.hasSuffix("/edit")
        log("envoi de " + String(body.count) + " champs → HTTP " + String(out.status)
            + " — " + (stayedOnForm ? "resté sur le formulaire (REFUS)" : "redirigé vers " + out.finalURL))
        diagnose(out.body)
        // Un code 200 ne prouve RIEN : sans session valide, AtoM renvoie sa page de connexion en 200.
        // On relit donc la notice et on vérifie que les valeurs sont bien celles envoyées.
        guard let after = await get(base.appendingPathComponent("index.php/" + slug)) else {
            return .failure(.rejected("enregistrement non v\u{e9}rifiable (notice illisible apr\u{e8}s envoi)"))
        }
        let saved = parseRecord(after)
        let control: [(String, String)] = [
            ("extentAndMedium", saved.extentAndMedium),
            ("archivalHistory", saved.archivalHistory),
            ("scopeAndContent", saved.scopeAndContent),
        ]
        for (key, now) in control {
            guard let expected = changes[key] else { continue }
            let a = now.replacingOccurrences(of: "\n", with: " ").trimmingCharacters(in: .whitespaces)
            let b = expected.replacingOccurrences(of: "\n", with: " ").trimmingCharacters(in: .whitespaces)
            if a != b {
                log("ÉCHEC : « " + key + " » vaut toujours « " + String(a.prefix(60)) + " » apr\u{e8}s envoi")
                return .failure(.rejected("la notice n'a pas \u{e9}t\u{e9} modifi\u{e9}e (session expir\u{e9}e ou droits insuffisants)"))
            }
        }
        log("enregistrement V\u{c9}RIFI\u{c9} par relecture de la notice")
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
    // Un navigateur n'envoie jamais un champ désactivé. AtoM garde dans son formulaire des lignes
    // de gabarit désactivées (événements, notes, niveaux enfants) que sa page clone en JavaScript :
    // les poster revient à soumettre des enregistrements vides, ce qu'AtoM refuse en bloc.
    private static func isDisabled(_ tag: String) -> Bool {
        tag.range(of: "(^|\\s)disabled(\\s|=|>|$)", options: [.regularExpression, .caseInsensitive]) != nil
    }

    private static func selectedOptions(_ body: String) -> [String] {
        guard let re = try? NSRegularExpression(pattern: "<option\\b([^>]*)>",
                                                options: [.caseInsensitive]) else { return [] }
        var out: [String] = []
        for m in re.matches(in: body, range: NSRange(body.startIndex..., in: body)) {
            guard let r = Range(m.range(at: 1), in: body) else { continue }
            let a = String(body[r])
            guard a.range(of: "(^|\\s)selected(\\s|=|>|$)", options: [.regularExpression, .caseInsensitive]) != nil,
                  let v = attr("<option" + a + ">", "value") else { continue }
            out.append(v)
        }
        return out
    }

    static func formFields(_ html: String) -> [(name: String, value: String)] {
        var out: [(String, String)] = []
        if let re = try? NSRegularExpression(pattern: "<input\\b[^>]*>", options: [.caseInsensitive]) {
            for m in re.matches(in: html, range: NSRange(html.startIndex..., in: html)) {
                guard let r = Range(m.range, in: html) else { continue }
                let tag = String(html[r])
                let type = (attr(tag, "type") ?? "text").lowercased()
                guard type != "submit", type != "button", type != "file", !isDisabled(tag),
                      let name = attr(tag, "name") else { continue }
                if (type == "checkbox" || type == "radio"), !tag.lowercased().contains("checked") { continue }
                out.append((name, attr(tag, "value") ?? ""))
            }
        }
        if let re = try? NSRegularExpression(pattern: "<textarea\\b([^>]*)>(.*?)</textarea>",
                                             options: [.caseInsensitive, .dotMatchesLineSeparators]) {
            for m in re.matches(in: html, range: NSRange(html.startIndex..., in: html)) {
                guard let a = Range(m.range(at: 1), in: html), let v = Range(m.range(at: 2), in: html),
                      !isDisabled(String(html[a])),
                      let name = attr("<textarea" + String(html[a]) + ">", "name") else { continue }
                out.append((name, plain(String(html[v]))))
            }
        }
        if let re = try? NSRegularExpression(pattern: "<select\\b([^>]*)>(.*?)</select>",
                                             options: [.caseInsensitive, .dotMatchesLineSeparators]) {
            for m in re.matches(in: html, range: NSRange(html.startIndex..., in: html)) {
                guard let a = Range(m.range(at: 1), in: html), let inner = Range(m.range(at: 2), in: html),
                      !isDisabled(String(html[a])),
                      let name = attr("<select" + String(html[a]) + ">", "name") else { continue }
                // Une liste à choix multiples porte AUTANT de valeurs que d'options sélectionnées
                // (les mots-clés d'une notice, par exemple). N'en retenir qu'une effaçait les autres.
                let sel = selectedOptions(String(html[inner]))
                if sel.isEmpty { out.append((name, "")) }
                else { for v in sel { out.append((name, v)) } }
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
        await postFull(url, pairs: fields.map { (name: $0.key, value: $0.value) })?.body
    }

    // Des PAIRES, et non un dictionnaire : un formulaire répète légitimement un même nom
    // (« subjectAccessPoints[] » porte un couple par terme). Un dictionnaire n'en gardait qu'un
    // seul — publier une notice en effaçait donc silencieusement tous les autres mots-clés.
    private static func postFull(_ url: URL, pairs: [(name: String, value: String)]) async -> (status: Int, body: String, finalURL: String)? {
        var req = URLRequest(url: url)
        req.httpMethod = "POST"
        req.timeoutInterval = 45
        req.setValue("application/x-www-form-urlencoded; charset=utf-8", forHTTPHeaderField: "Content-Type")
        var cs = CharacterSet.alphanumerics
        cs.insert(charactersIn: "-._~")
        req.httpBody = pairs.map { f in
            (f.name.addingPercentEncoding(withAllowedCharacters: cs) ?? f.name) + "=" +
            (f.value.addingPercentEncoding(withAllowedCharacters: cs) ?? f.value)
        }.joined(separator: "&").data(using: .utf8)
        guard let (data, resp) = try? await URLSession.shared.data(for: req) else { return nil }
        let code = (resp as? HTTPURLResponse)?.statusCode ?? 0
        return (code, String(data: data, encoding: .utf8) ?? "", resp.url?.absoluteString ?? "")
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
