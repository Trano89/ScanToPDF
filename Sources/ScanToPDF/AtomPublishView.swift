import SwiftUI

/// Écran de confirmation avant publication dans AtoM.
/// Rien n'est envoyé sans validation explicite, et CHAQUE valeur reste modifiable — y compris
/// celles déjà présentes dans la notice : c'est l'archiviste qui tranche, pas le modèle.
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
            if pub.notFound { notFoundPanel }
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    if pub.notFound {
                        Text("Ce que ScanToPDF aurait publié — pour mémoire, tant qu'aucune notice n'est rattachée :")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                    ForEach($pub.fields) { $f in fieldRow($f) }
                }
                .padding(16)
            }
            .disabled(pub.notFound)
            .opacity(pub.notFound ? 0.55 : 1)
            Divider()
            footer
        }
        .frame(width: 780, height: 660)
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 8) {
                Image(systemName: pub.exists ? "doc.text.magnifyingglass" : "questionmark.folder")
                    .foregroundStyle(pub.exists ? Color.accentColor : Color.orange)
                Text(pub.exists ? "Mise à jour d'une notice existante" : "Notice introuvable dans AtoM")
                    .font(.headline)
                Spacer()
                Text(pub.code).font(.system(.body, design: .monospaced)).foregroundStyle(.secondary)
            }
            if pub.exists, let slug = pub.slug {
                Text("Notice trouvée dans AtoM : /\(slug)")
                    .font(.caption).foregroundStyle(.secondary)
            } else {
                Text("Aucune notice ne porte cette cote, dans aucune de ses deux écritures (« _ » et « / »). ScanToPDF ne crée jamais de notice : le catalogue reste maître de son arborescence.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            if pub.needsCodeMigration {
                Label("La notice porte l'ancienne écriture « \(pub.matchedCode) ». Publier la migrera vers « \(pub.code) ».",
                      systemImage: "arrow.triangle.2.circlepath")
                    .font(.caption).foregroundStyle(.orange)
            }
            Text("Seul le PDF/A final est publié dans AtoM (\(pub.pdf.lastPathComponent)) ; le dossier complet part sur le lecteur réseau.")
                .font(.caption).foregroundStyle(.secondary)
        }
        .padding(14)
    }

    @ViewBuilder
    private func fieldRow(_ f: Binding<AtomFieldDiff>) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 8) {
                Text(f.wrappedValue.label).font(.subheadline).bold()
                switch f.wrappedValue.kind {
                case .added:     Text("AJOUT").font(.caption2).padding(.horizontal, 6).padding(.vertical, 2)
                                    .background(Color.green.opacity(0.2)).clipShape(Capsule())
                case .modified:  Text("MODIFIÉ").font(.caption2).padding(.horizontal, 6).padding(.vertical, 2)
                                    .background(Color.orange.opacity(0.25)).clipShape(Capsule())
                case .unchanged: Text("inchangé").font(.caption2).foregroundStyle(.tertiary)
                }
                Spacer()
                if f.wrappedValue.kind != .unchanged {
                    Button("Conserver l'existant") { f.wrappedValue.proposed = f.wrappedValue.existing }
                        .buttonStyle(.link).font(.caption)
                }
            }
            if !f.wrappedValue.existing.isEmpty && f.wrappedValue.kind != .unchanged {
                Text("Dans AtoM : \(f.wrappedValue.existing)")
                    .font(.caption).foregroundStyle(.secondary)
                    .textSelection(.enabled).lineLimit(4)
            }
            if f.wrappedValue.multiline {
                TextEditor(text: f.proposed)
                    .font(.system(size: 12)).frame(height: 90)
                    .overlay(RoundedRectangle(cornerRadius: 5).stroke(Color.secondary.opacity(0.35)))
            } else {
                TextField("", text: f.proposed).textFieldStyle(.roundedBorder)
            }
        }
    }


    /// Notice introuvable : trois issues, et aucune création. Soit la recherche recommence, soit
    /// l'archiviste désigne lui-même la notice, soit il renonce.
    private var notFoundPanel: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Que faire ?").font(.subheadline).bold()
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
            Text("Recherche manuelle — collez l'adresse de la notice, son identifiant d'adresse, ou saisissez une autre cote :")
                .font(.caption).foregroundStyle(.secondary)
            HStack {
                TextField("https://archives.fvjc.ch/index.php/…  ou  Be-a-S1-1989-1  ou  Be.a.S1.1989/1",
                          text: $manualInput)
                    .textFieldStyle(.roundedBorder)
                    .onSubmit { resolveManually() }
                Button("Rattacher") { resolveManually() }
                    .disabled(busy || manualInput.trimmingCharacters(in: .whitespaces).isEmpty)
            }
        }
        .padding(14)
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

    private var footer: some View {
        HStack {
            if busy { ProgressView().controlSize(.small) }
            Text(message.isEmpty
                 ? (pub.notFound ? "Aucune notice rattachée — rien ne peut être envoyé."
                                 : "\(pub.changedCount) champ(s) à envoyer")
                 : message)
                .font(.caption)
                .foregroundStyle(message.hasPrefix("✅") ? Color.green
                                 : (message.isEmpty ? Color.secondary : Color.orange))
                .lineLimit(2)
            Spacer()
            Button("Annuler") { onClose() }
            Button("Mettre à jour dans AtoM") { publish() }
                .buttonStyle(.borderedProminent)
                .disabled(busy || pub.notFound || pub.changedCount == 0)
        }
        .padding(14)
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
