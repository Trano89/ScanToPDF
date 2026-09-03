import SwiftUI

/// Écran de relecture avant écriture dans le catalogue AtoM.
/// Rien n'est envoyé sans validation explicite, et CHAQUE valeur reste modifiable — y compris
/// celles déjà présentes dans la notice : c'est l'archiviste qui tranche, pas le modèle.
///
/// Parti pris de mise en page : le travail sur cet écran consiste à relire ce qui CHANGE. Les
/// champs modifiés s'ouvrent en entier, les inchangés se replient sur une ligne et se déplient au
/// clic — on passe de quatre champs visibles à neuf. Trois couleurs seulement, chacune portant un
/// sens : vert pour un ajout, orange pour une modification ou un avertissement, bleu pour l'action
/// principale ; aucun aplat décoratif.
struct AtomPublishView: View {
    @EnvironmentObject var model: AppModel
    @State private var pub: AtomPublication
    @State private var busy = false
    @State private var message = ""
    @State private var manualInput = ""
    @State private var toutAfficher = false
    @State private var deplies: Set<String> = []
    let onClose: () -> Void

    init(publication: AtomPublication, onClose: @escaping () -> Void) {
        _pub = State(initialValue: publication)
        self.onClose = onClose
    }

    // Zones d'ISAD(G) : l'ordre dans lequel une notice se lit.
    private static let zones: [(titre: String, cles: [String])] = [
        ("Identification", ["identifier", "title", "repository", "eventDates"]),
        ("Description",    ["extentAndMedium", "archivalHistory", "scopeAndContent"]),
        ("Indexation",     ["subjectAccessPoints", "placeAccessPoints",
                            "nameAccessPoints", "genreAccessPoints"]),
    ]

    private var nbChanges: Int { pub.fields.filter { $0.kind != .unchanged }.count }
    private var nbAjouts: Int { pub.fields.filter { $0.kind == .added }.count }
    private var nbModifs: Int { pub.fields.filter { $0.kind == .modified }.count }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            entete
            if pub.notFound {
                Divider()
                panneauIntrouvable
            } else {
                barreDeRevue
            }
            Divider()
            corps
            Divider()
            pied
        }
        .frame(minWidth: 640, idealWidth: 820, minHeight: 520, idealHeight: 700)
    }

    // MARK: - en-tête

    private var entete: some View {
        HStack(alignment: .top, spacing: 12) {
            ZStack {
                RoundedRectangle(cornerRadius: 7, style: .continuous)
                    .fill((pub.exists ? Color.accentColor : Color.orange).opacity(0.16))
                Image(systemName: pub.exists ? "doc.text.magnifyingglass" : "questionmark.folder")
                    .font(.system(size: 15, weight: .medium))
                    .foregroundStyle(pub.exists ? Color.accentColor : Color.orange)
            }
            .frame(width: 30, height: 30)

            VStack(alignment: .leading, spacing: 3) {
                HStack(alignment: .firstTextBaseline, spacing: 10) {
                    Text(pub.exists ? "Mise à jour d'une notice"
                                    : "Aucune notice ne porte cette cote")
                        .font(.system(size: 16, weight: .semibold))
                    Spacer(minLength: 8)
                    Text(pub.code)
                        .font(.system(size: 11.5, design: .monospaced))
                        .foregroundStyle(.secondary)
                        .padding(.horizontal, 8).padding(.vertical, 2)
                        .background(RoundedRectangle(cornerRadius: 5).fill(.quaternary))
                        .textSelection(.enabled)
                }
                if pub.exists {
                    // Une seule ligne de contexte : où l'on écrit, dans quel dépôt, avec quel fichier.
                    HStack(spacing: 7) {
                        Text("/\(pub.slug ?? "")").textSelection(.enabled)
                        Text("·").foregroundStyle(.tertiary)
                        Text(pub.repository)
                        Text("·").foregroundStyle(.tertiary)
                        Text("\(pub.pdf.lastPathComponent) joint")
                    }
                    .font(.caption).foregroundStyle(.secondary).lineLimit(1)
                } else {
                    Text("Cherchée dans ses deux écritures, « _ » et « / ». ScanToPDF ne crée jamais "
                         + "de notice : le catalogue reste maître de son arborescence.")
                        .font(.caption).foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                if pub.needsCodeMigration {
                    note("La notice porte l'ancienne écriture « \(pub.matchedCode) ». Publier la "
                         + "migrera vers « \(pub.code) ».",
                         icone: "arrow.triangle.2.circlepath", teinte: .orange)
                }
            }
        }
        .padding(.horizontal, 18).padding(.top, 13).padding(.bottom, 11)
        .background(.bar)
    }

    /// Barre de revue : le filtre s'ouvre sur ce qui change, parce que c'est là qu'est le travail.
    private var barreDeRevue: some View {
        HStack(spacing: 12) {
            Picker("", selection: $toutAfficher) {
                Text("\(nbChanges) changement\(nbChanges > 1 ? "s" : "")").tag(false)
                Text("Tous les champs").tag(true)
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .fixedSize()
            Spacer()
            HStack(spacing: 12) {
                if nbAjouts > 0 { compteur(nbAjouts, "ajout", .green) }
                if nbModifs > 0 { compteur(nbModifs, "modifié", .orange) }
                Text("\(pub.fields.count - nbChanges) inchangés").foregroundStyle(.tertiary)
            }
            .font(.caption)
        }
        .padding(.horizontal, 18).padding(.bottom, 10)
        .background(.bar)
    }

    private func compteur(_ n: Int, _ mot: String, _ teinte: Color) -> some View {
        HStack(spacing: 5) {
            Circle().fill(teinte).frame(width: 7, height: 7)
            Text("\(n) \(mot)\(n > 1 ? "s" : "")").foregroundStyle(.secondary)
        }
    }

    // MARK: - corps

    private var corps: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 15) {
                ForEach(Self.zones, id: \.titre) { zone in
                    let indices = zone.cles.compactMap { cle in
                        pub.fields.firstIndex { $0.key == cle }
                    }.filter { i in
                        toutAfficher || pub.notFound || pub.fields[i].kind != .unchanged
                    }
                    if !indices.isEmpty { section(zone.titre, indices) }
                }
                if !toutAfficher && !pub.notFound && nbChanges == 0 {
                    Text("Aucun changement à envoyer : la notice porte déjà tout ce que la fiche "
                         + "propose.")
                        .font(.callout).foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            .padding(.horizontal, 18).padding(.vertical, 14)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .disabled(pub.notFound)
        .opacity(pub.notFound ? 0.45 : 1)
    }

    private func section(_ titre: String, _ indices: [Int]) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(titre.uppercased())
                .font(.system(size: 11, weight: .semibold)).kerning(0.5)
                .foregroundStyle(.secondary)
                .padding(.leading, 2)
            VStack(spacing: 0) {
                ForEach(Array(indices.enumerated()), id: \.element) { rang, i in
                    if rang > 0 { Divider().padding(.leading, 12) }
                    ligne($pub.fields[i])
                }
            }
            .background(RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(Color(nsColor: .controlBackgroundColor)))
            .overlay(RoundedRectangle(cornerRadius: 8, style: .continuous)
                .strokeBorder(Color(nsColor: .separatorColor)))
        }
    }

    /// Un champ modifié s'ouvre ; un champ inchangé tient sur une ligne et se déplie au clic.
    @ViewBuilder
    private func ligne(_ f: Binding<AtomFieldDiff>) -> some View {
        if f.wrappedValue.kind == .unchanged && !deplies.contains(f.wrappedValue.key) {
            Button {
                deplies.insert(f.wrappedValue.key)
            } label: {
                HStack(alignment: .firstTextBaseline, spacing: 10) {
                    Text(f.wrappedValue.label)
                        .font(.system(size: 13, weight: .medium))
                        .foregroundStyle(.primary)
                        .frame(width: 178, alignment: .leading)
                    Text(f.wrappedValue.proposed.isEmpty ? "—" : f.wrappedValue.proposed)
                        .font(.callout).foregroundStyle(.secondary).lineLimit(1)
                    Spacer(minLength: 8)
                    Text("inchangé").font(.caption).foregroundStyle(.tertiary)
                }
                .contentShape(Rectangle())
                .padding(.horizontal, 12).padding(.vertical, 7)
            }
            .buttonStyle(.plain)
        } else {
            VStack(alignment: .leading, spacing: 6) {
                HStack(spacing: 8) {
                    Text(f.wrappedValue.label).font(.system(size: 13, weight: .medium))
                    etat(f.wrappedValue.kind)
                    Spacer(minLength: 8)
                    if f.wrappedValue.kind != .unchanged {
                        Button("Conserver l'existant") {
                            f.wrappedValue.proposed = f.wrappedValue.existing
                        }
                        .buttonStyle(.link).font(.caption)
                    } else {
                        Button("Replier") { deplies.remove(f.wrappedValue.key) }
                            .buttonStyle(.link).font(.caption)
                    }
                }
                if !f.wrappedValue.existing.isEmpty && f.wrappedValue.kind != .unchanged {
                    // La valeur en place, rappelée en petit : subordonnée par la taille et le gris,
                    // sans cadre ni filet coloré.
                    HStack(alignment: .firstTextBaseline, spacing: 7) {
                        Text("ACTUEL")
                            .font(.system(size: 10, weight: .medium))
                            .foregroundStyle(.tertiary)
                        Text(f.wrappedValue.existing)
                            .font(.caption).foregroundStyle(.secondary)
                            .textSelection(.enabled).lineLimit(3)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
                avertissement(f.wrappedValue)
                saisie(f)
            }
            .padding(.horizontal, 12).padding(.vertical, 9)
        }
    }

    @ViewBuilder
    private func avertissement(_ f: AtomFieldDiff) -> some View {
        if f.key == "genreAccessPoints" && !pub.genresEcartes.isEmpty {
            note(pub.thesaurusIllisible
                 ? "Thésaurus injoignable : aucun genre publié cette fois, par prudence — "
                   + pub.genresEcartes.joined(separator: ", ")
                 : "Absents du thésaurus, non créés pour éviter les doublons — "
                   + pub.genresEcartes.joined(separator: ", "),
                 icone: "questionmark.circle", teinte: .orange)
        }
        if f.key == "eventDates" && !f.existing.isEmpty {
            note("AtoM ajoute les dates au lieu de les remplacer : celle en place est conservée.",
                 icone: "info.circle", teinte: .secondary)
        }
    }

    @ViewBuilder
    private func saisie(_ f: Binding<AtomFieldDiff>) -> some View {
        if f.wrappedValue.multiline {
            // L'étendue matérielle tient sur deux lignes, la portée sur dix : une hauteur unique
            // gaspillait l'écran en haut et le rationnait en bas.
            let hauteur: CGFloat = f.wrappedValue.key == "extentAndMedium" ? 56 : 112
            TextEditor(text: f.proposed)
                .font(.callout)
                .scrollContentBackground(.hidden)
                .padding(.horizontal, 7).padding(.vertical, 6)
                .frame(minHeight: hauteur)
                .background(cadreSaisie)
        } else {
            TextField("", text: f.proposed)
                .textFieldStyle(.plain)
                .font(.callout)
                .padding(.horizontal, 7).padding(.vertical, 6)
                .background(cadreSaisie)
        }
    }

    private var cadreSaisie: some View {
        RoundedRectangle(cornerRadius: 5, style: .continuous)
            .fill(Color(nsColor: .textBackgroundColor))
            .overlay(RoundedRectangle(cornerRadius: 5, style: .continuous)
                .strokeBorder(Color(nsColor: .separatorColor)))
    }

    private func note(_ texte: String, icone: String, teinte: Color) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 6) {
            Image(systemName: icone).font(.caption2)
            Text(texte).fixedSize(horizontal: false, vertical: true)
        }
        .font(.caption)
        .foregroundStyle(teinte == .secondary ? AnyShapeStyle(.secondary) : AnyShapeStyle(teinte))
    }

    @ViewBuilder
    private func etat(_ kind: AtomFieldDiff.Kind) -> some View {
        switch kind {
        case .added:     pastille("AJOUT", teinte: .green)
        case .modified:  pastille("MODIFIÉ", teinte: .orange)
        case .unchanged: Text("inchangé").font(.caption2).foregroundStyle(.tertiary)
        }
    }

    private func pastille(_ texte: String, teinte: Color) -> some View {
        Text(texte)
            .font(.system(size: 10, weight: .semibold)).kerning(0.3)
            .foregroundStyle(teinte)
            .padding(.horizontal, 6).padding(.vertical, 1)
            .background(Capsule().fill(teinte.opacity(0.15)))
            .overlay(Capsule().strokeBorder(teinte.opacity(0.35)))
    }

    // MARK: - notice introuvable

    /// Trois issues, et aucune création. La décision passe DEVANT les champs : tant qu'aucune
    /// notice n'est rattachée, relire les valeurs ne mène nulle part.
    private var panneauIntrouvable: some View {
        VStack(alignment: .leading, spacing: 11) {
            Text("RATTACHER LA NOTICE")
                .font(.system(size: 11, weight: .semibold)).kerning(0.5)
                .foregroundStyle(.secondary)
            HStack(spacing: 9) {
                Button {
                    busy = true; message = "Nouvelle recherche…"
                    Task {
                        let maj = await model.retryAtomLookup(pub)
                        await MainActor.run {
                            pub = maj; busy = false
                            message = maj.exists ? "Notice rattachée." : "Toujours introuvable."
                        }
                    }
                } label: { Label("Chercher à nouveau", systemImage: "arrow.clockwise") }
                    .disabled(busy)
                Button {
                    model.openAtomSearch(for: pub.code)
                } label: { Label("Ouvrir AtoM", systemImage: "magnifyingglass") }
                Spacer()
            }
            VStack(alignment: .leading, spacing: 6) {
                Text("Ou désignez-la vous-même — adresse de la notice, identifiant, ou autre cote :")
                    .font(.caption).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                HStack(spacing: 8) {
                    TextField("https://archives.fvjc.ch/index.php/…", text: $manualInput)
                        .textFieldStyle(.roundedBorder)
                        .onSubmit { resolveManually() }
                    Button("Rattacher") { resolveManually() }
                        .disabled(busy || manualInput.trimmingCharacters(in: .whitespaces).isEmpty)
                }
            }
        }
        .padding(.horizontal, 18).padding(.vertical, 14)
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func resolveManually() {
        let saisi = manualInput
        busy = true; message = "Recherche de « \(saisi) »…"
        Task {
            let maj = await model.resolveAtomManually(pub, input: saisi)
            await MainActor.run {
                pub = maj; busy = false
                message = maj.exists ? "Notice rattachée : /\(maj.slug ?? "")"
                                     : "Rien ne correspond à « \(saisi) »."
                if maj.exists { manualInput = "" }
            }
        }
    }

    // MARK: - pied

    private var pied: some View {
        HStack(spacing: 10) {
            if busy { ProgressView().controlSize(.small) }
            etatEnvoi
            Spacer(minLength: 12)
            Button("Journal") { model.openAtomLog() }
                .help("Ouvre atom.log : connexion, champs du formulaire, résultat de l'envoi")
            Button("Annuler") { onClose() }
                .keyboardShortcut(.cancelAction)
            Button("Mettre à jour") { publish() }
                .buttonStyle(.borderedProminent)
                .keyboardShortcut(.defaultAction)
                .disabled(busy || pub.notFound || nbChanges == 0)
        }
        .padding(.horizontal, 18).padding(.vertical, 10)
        .background(.bar)
    }

    /// Un succès, un refus et un simple décompte ne se lisent pas de la même façon.
    @ViewBuilder
    private var etatEnvoi: some View {
        if !message.isEmpty {
            if message.hasSuffix("…") {
                Label(message, systemImage: "ellipsis.circle")
                    .font(.callout).foregroundStyle(.secondary).lineLimit(2)
            } else if message.hasPrefix("✅") {
                Label(message.replacingOccurrences(of: "✅ ", with: ""),
                      systemImage: "checkmark.circle.fill")
                    .font(.callout).foregroundStyle(.green).lineLimit(2)
            } else {
                Label(message, systemImage: "exclamationmark.circle.fill")
                    .font(.callout).foregroundStyle(.orange).lineLimit(2)
            }
        } else if pub.notFound {
            Label("Aucune notice rattachée", systemImage: "exclamationmark.triangle")
                .font(.callout).foregroundStyle(.orange)
        } else {
            Label("\(nbChanges) champ\(nbChanges > 1 ? "s" : "") seront écrits dans AtoM",
                  systemImage: "square.and.arrow.up")
                .font(.callout).foregroundStyle(.secondary)
        }
    }

    private func publish() {
        busy = true; message = "Publication…"
        let instantane = pub
        Task {
            let resultat = await model.publishToAtom(instantane)
            await MainActor.run {
                busy = false
                switch resultat {
                case .success:              message = "✅ Publié dans AtoM."
                case .failure(let erreur):  message = erreur.localizedDescription
                }
            }
        }
    }
}
