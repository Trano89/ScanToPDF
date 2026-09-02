import SwiftUI

/// Écran de confirmation avant publication dans AtoM.
/// Rien n'est envoyé sans validation explicite, et CHAQUE valeur reste modifiable — y compris
/// celles déjà présentes dans la notice : c'est l'archiviste qui tranche, pas le modèle.
///
/// Mise en page dans l'esprit des Réglages système : en-tête et pied en matière translucide,
/// champs présentés en sections groupées. La fenêtre est redimensionnable, la portée et contenu
/// pouvant désormais compter plusieurs paragraphes.
struct AtomPublishView: View {
    @EnvironmentObject var model: AppModel
    @State private var pub: AtomPublication
    @State private var busy = false
    @State private var message = ""
    @State private var manualInput = ""
    let onClose: () -> Void

    init(publication: AtomPublication, onClose: @escaping () -> Void) {
        _pub = State(initialValue: publication)
        self.onClose = onClose
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            Divider()
            if pub.notFound { notFoundPanel; Divider() }
            fieldsForm
                .disabled(pub.notFound)
                .opacity(pub.notFound ? 0.5 : 1)
            Divider()
            footer
        }
        .frame(minWidth: 640, idealWidth: 820, minHeight: 520, idealHeight: 700)
    }

    // MARK: - en-tête

    private var header: some View {
        HStack(alignment: .top, spacing: 14) {
            Image(systemName: pub.exists ? "doc.text.magnifyingglass" : "questionmark.folder")
                .font(.system(size: 21, weight: .medium))
                .foregroundStyle(.white)
                .frame(width: 40, height: 40)
                .background(
                    RoundedRectangle(cornerRadius: 9, style: .continuous)
                        .fill(pub.exists ? AnyShapeStyle(Color.accentColor.gradient)
                                         : AnyShapeStyle(Color.orange.gradient)))
            VStack(alignment: .leading, spacing: 5) {
                HStack(alignment: .firstTextBaseline, spacing: 10) {
                    Text(pub.exists ? "Mise à jour d'une notice existante"
                                    : "Notice introuvable dans AtoM")
                        .font(.title3.weight(.semibold))
                    Spacer(minLength: 8)
                    Text(pub.code)
                        .font(.system(.callout, design: .monospaced))
                        .foregroundStyle(.secondary)
                        .padding(.horizontal, 8).padding(.vertical, 3)
                        .background(Capsule().fill(.quaternary))
                        .textSelection(.enabled)
                }
                if pub.exists, let slug = pub.slug {
                    Text("Notice trouvée dans AtoM : /\(slug)")
                        .font(.callout).foregroundStyle(.secondary).textSelection(.enabled)
                } else {
                    Text("Aucune notice ne porte cette cote, dans aucune de ses deux écritures "
                         + "(« _ » et « / »). ScanToPDF ne crée jamais de notice : le catalogue "
                         + "reste maître de son arborescence.")
                        .font(.callout).foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                if pub.needsCodeMigration {
                    calloutLabel("La notice porte l'ancienne écriture « \(pub.matchedCode) ». "
                                 + "Publier la migrera vers « \(pub.code) ».",
                                 icon: "arrow.triangle.2.circlepath", tint: .orange)
                }
                calloutLabel("Seul le PDF/A final est publié dans AtoM (\(pub.pdf.lastPathComponent)) ; "
                             + "le dossier complet part sur le lecteur réseau.",
                             icon: "doc.badge.arrow.up", tint: .secondary)
            }
        }
        .padding(.horizontal, 18).padding(.vertical, 14)
        .background(.bar)
    }

    private func calloutLabel(_ text: String, icon: String, tint: Color) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 6) {
            Image(systemName: icon).font(.caption).imageScale(.small)
            Text(text).fixedSize(horizontal: false, vertical: true)
        }
        .font(.caption)
        .foregroundStyle(tint == .secondary ? AnyShapeStyle(.secondary) : AnyShapeStyle(tint))
    }

    // MARK: - champs

    private var fieldsForm: some View {
        Form {
            if pub.notFound {
                Section {
                    Text("Ce que ScanToPDF aurait publié — pour mémoire, tant qu'aucune notice "
                         + "n'est rattachée.")
                        .font(.callout).foregroundStyle(.secondary)
                }
            }
            ForEach($pub.fields) { $f in fieldSection($f) }
        }
        .formStyle(.grouped)
    }

    @ViewBuilder
    private func fieldSection(_ f: Binding<AtomFieldDiff>) -> some View {
        Section {
            if !f.wrappedValue.existing.isEmpty && f.wrappedValue.kind != .unchanged {
                LabeledContent("Dans AtoM") {
                    Text(f.wrappedValue.existing)
                        .foregroundStyle(.secondary)
                        .textSelection(.enabled).lineLimit(6)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                .font(.callout)
            }
            if f.wrappedValue.key == "genreAccessPoints" && !pub.genresEcartes.isEmpty {
                calloutLabel("Écartés car absents du thésaurus d'AtoM — ils ne sont pas créés pour "
                             + "éviter les doublons : " + pub.genresEcartes.joined(separator: ", "),
                             icon: "questionmark.circle", tint: .orange)
            }
            if f.wrappedValue.key == "eventDates" && !f.wrappedValue.existing.isEmpty {
                calloutLabel("AtoM ajoute les dates au lieu de les remplacer : celle déjà en "
                             + "place est conservée. La modifier ici en créerait une seconde.",
                             icon: "info.circle", tint: .secondary)
            }
            editor(for: f)
        } header: {
            HStack(spacing: 8) {
                Text(f.wrappedValue.label)
                badge(f.wrappedValue.kind)
                Spacer()
                if f.wrappedValue.kind != .unchanged {
                    Button("Conserver l'existant") {
                        f.wrappedValue.proposed = f.wrappedValue.existing
                    }
                    .buttonStyle(.link).font(.caption)
                }
            }
        }
    }

    @ViewBuilder
    private func editor(for f: Binding<AtomFieldDiff>) -> some View {
        if f.wrappedValue.multiline {
            TextEditor(text: f.proposed)
                .font(.system(.callout, design: .default))
                .scrollContentBackground(.hidden)
                .padding(6)
                .frame(minHeight: 110)
                .background(RoundedRectangle(cornerRadius: 6, style: .continuous)
                    .fill(Color(nsColor: .textBackgroundColor)))
                .overlay(RoundedRectangle(cornerRadius: 6, style: .continuous)
                    .strokeBorder(Color(nsColor: .separatorColor)))
        } else {
            TextField("", text: f.proposed)
                .textFieldStyle(.roundedBorder)
                .font(.callout)
        }
    }

    @ViewBuilder
    private func badge(_ kind: AtomFieldDiff.Kind) -> some View {
        switch kind {
        case .added:
            pill("AJOUT", tint: .green)
        case .modified:
            pill("MODIFIÉ", tint: .orange)
        case .unchanged:
            Text("inchangé").font(.caption2).foregroundStyle(.tertiary)
        }
    }

    private func pill(_ text: String, tint: Color) -> some View {
        Text(text)
            .font(.caption2.weight(.semibold))
            .foregroundStyle(tint)
            .padding(.horizontal, 7).padding(.vertical, 2)
            .background(Capsule().fill(tint.opacity(0.15)))
            .overlay(Capsule().strokeBorder(tint.opacity(0.35)))
    }

    // MARK: - notice introuvable

    /// Notice introuvable : trois issues, et aucune création. Soit la recherche recommence, soit
    /// l'archiviste désigne lui-même la notice, soit il renonce.
    private var notFoundPanel: some View {
        VStack(alignment: .leading, spacing: 10) {
            Label("Que faire ?", systemImage: "questionmark.circle")
                .font(.headline)
            HStack(spacing: 10) {
                Button {
                    busy = true; message = "Nouvelle recherche…"
                    Task {
                        let updated = await model.retryAtomLookup(pub)
                        await MainActor.run {
                            pub = updated; busy = false
                            message = updated.exists ? "Notice rattachée." : "Toujours introuvable."
                        }
                    }
                } label: { Label("Réessayer", systemImage: "arrow.clockwise") }
                    .disabled(busy)
                Button {
                    model.openAtomSearch(for: pub.code)
                } label: { Label("Chercher dans AtoM", systemImage: "safari") }
                Spacer()
            }
            Text("Recherche manuelle — collez l'adresse de la notice, son identifiant d'adresse, "
                 + "ou saisissez une autre cote :")
                .font(.callout).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            HStack(spacing: 8) {
                TextField("https://archives.fvjc.ch/index.php/…  ou  Be-a-S1-1989-1  ou  Be.a.S1.1989/1",
                          text: $manualInput)
                    .textFieldStyle(.roundedBorder)
                    .onSubmit { resolveManually() }
                Button("Rattacher") { resolveManually() }
                    .disabled(busy || manualInput.trimmingCharacters(in: .whitespaces).isEmpty)
            }
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.orange.opacity(0.08))
    }

    private func resolveManually() {
        let input = manualInput
        busy = true; message = "Recherche de « \(input) »…"
        Task {
            let updated = await model.resolveAtomManually(pub, input: input)
            await MainActor.run {
                pub = updated; busy = false
                message = updated.exists ? "Notice rattachée : /\(updated.slug ?? "")"
                                         : "Rien ne correspond à « \(input) »."
                if updated.exists { manualInput = "" }
            }
        }
    }

    // MARK: - pied

    private var footer: some View {
        HStack(spacing: 12) {
            if busy { ProgressView().controlSize(.small) }
            statusLine
            Spacer(minLength: 12)
            Button("Journal") { model.openAtomLog() }
                .help("Ouvre atom.log : le détail de la connexion, des champs du formulaire et du résultat")
            Button("Annuler") { onClose() }
                .keyboardShortcut(.cancelAction)
            Button("Mettre à jour dans AtoM") { publish() }
                .buttonStyle(.borderedProminent)
                .keyboardShortcut(.defaultAction)
                .disabled(busy || pub.notFound || pub.changedCount == 0)
        }
        .padding(.horizontal, 18).padding(.vertical, 12)
        .background(.bar)
    }

    /// Un succès, un échec et un simple décompte ne se lisent pas de la même façon : chacun porte
    /// son icône et sa couleur, plutôt qu'une ligne de texte uniforme.
    @ViewBuilder
    private var statusLine: some View {
        if message.isEmpty {
            Label(pub.notFound ? "Aucune notice rattachée — rien ne peut être envoyé."
                               : "\(pub.changedCount) champ(s) à envoyer",
                  systemImage: pub.notFound ? "exclamationmark.triangle" : "arrow.up.doc")
                .font(.callout).foregroundStyle(.secondary).lineLimit(2)
        } else if message.hasSuffix("…") {
            Label(message, systemImage: "ellipsis.circle")
                .font(.callout).foregroundStyle(.secondary).lineLimit(2)
        } else if message.hasPrefix("✅") {
            Label(message.replacingOccurrences(of: "✅ ", with: ""), systemImage: "checkmark.circle.fill")
                .font(.callout).foregroundStyle(.green).lineLimit(2)
        } else {
            Label(message, systemImage: "exclamationmark.circle.fill")
                .font(.callout).foregroundStyle(.orange).lineLimit(2)
        }
    }

    private func publish() {
        busy = true; message = "Publication…"
        let snapshot = pub
        Task {
            let result = await model.publishToAtom(snapshot)
            await MainActor.run {
                busy = false
                switch result {
                case .success:            message = "✅ Publié dans AtoM."
                case .failure(let error): message = error.localizedDescription
                }
            }
        }
    }
}
