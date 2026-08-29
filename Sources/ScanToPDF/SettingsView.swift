import SwiftUI
import AppKit
import UniformTypeIdentifiers

/// Caractères séparateurs courants utilisables dans le regroupement de fichiers.
enum PageSeparator: String, Identifiable, CaseIterable {
    case dash = "-"
    case underscore = "_"
    case dot = "."
    case tilde = "~"
    case colon = ":"
    case space = " "

    var id: String { rawValue }
    var displayName: String {
        switch self {
        case .dash:       return "Tiret (-)"
        case .underscore: return "Souligné (_)"
        case .dot:        return "Point (.)"
        case .tilde:      return "Tilde (~)"
        case .colon:      return "Deux-points (:)"
        case .space:      return "Espace (\u{2009})"
        }
    }
}

/// Fenêtre de préférences, organisée en ONGLETS : une seule page devenait illisible.
/// Les réglages sont édités dans un BROUILLON et ne prennent effet qu'au bouton « Enregistrer »,
/// pour qu'une modification en cours de saisie ne parte jamais au moteur à moitié faite.
/// Les actions immédiates (monter un lecteur, verrouiller, choisir un fichier) restent instantanées.
struct SettingsView: View {
    @EnvironmentObject var model: AppModel
    @State private var draft: AppConfig = AppModel.shared.config
    @State private var passphrase: String = AppModel.shared.clusterPassphrase
    @State private var atomPassword: String = ""

    /// Liaison vers une valeur du BROUILLON (rien n'est appliqué avant « Enregistrer »).
    private func b<T>(_ kp: WritableKeyPath<AppConfig, T>) -> Binding<T> {
        Binding(get: { draft[keyPath: kp] }, set: { draft[keyPath: kp] = $0 })
    }
    private var dirty: Bool { draft != model.config }

    var body: some View {
        VStack(spacing: 0) {
            if model.legacyDetected { legacyBanner }
            if model.updateAvailable || model.updateInstalling { updateBanner }

            TabView {
                dossierTab.tabItem { Label("Dossier", systemImage: "folder") }
                traitementTab.tabItem { Label("Traitement", systemImage: "wand.and.stars") }
                filigraneTab.tabItem { Label("Filigrane", systemImage: "drop") }
                ficheTab.tabItem { Label("Fiche ISAD", systemImage: "doc.text.magnifyingglass") }
                publicationTab.tabItem { Label("Publication", systemImage: "externaldrive.connected.to.line.below") }
                applicationTab.tabItem { Label("Application", systemImage: "gearshape") }
            }
            .padding(.top, 8)

            Divider()
            footer
        }
        .frame(width: 580, height: 640)
        .onAppear {
            draft = model.config
            if model.config.isadEnabled { model.refreshOllamaModels() }
            if model.config.exportEnabled { model.refreshNASVolumes() }
        }
        // Les actions immédiates modifient la config hors brouillon : on resynchronise.
        .onChange(of: model.config) { _, new in
            if !dirty { draft = new } else { draft.nasLocked = new.nasLocked }
        }
        .onChange(of: draft.isadEnabled) { _, on in if on { model.refreshOllamaModels() } }
        .onChange(of: draft.exportEnabled) { _, on in if on { model.refreshNASVolumes() } }
    }

    // MARK: - barre de validation
    private var footer: some View {
        HStack(spacing: 12) {
            VStack(alignment: .leading, spacing: 2) {
                Text("ScanToPDF v\(AppVersion.short) (build \(AppVersion.build))")
                    .font(.caption).foregroundStyle(.secondary)
                if AppVersion.hasRevision {
                    Text("revision \(AppVersion.revision)").font(.caption2).foregroundStyle(.tertiary)
                }
            }
            Spacer()
            if dirty {
                Text("Modifications non enregistrées")
                    .font(.caption).foregroundStyle(.orange)
                Button("Annuler") { draft = model.config }
                Button("Enregistrer") { model.applyConfig(draft) }
                    .buttonStyle(.borderedProminent)
                    .keyboardShortcut(.defaultAction)
            } else if !model.status.isEmpty {
                Text(model.status).font(.caption).foregroundStyle(.secondary)
                    .lineLimit(1).truncationMode(.middle)
            }
        }
        .padding(.horizontal, 14).padding(.vertical, 10)
    }

    // MARK: - onglet Dossier
    private var dossierTab: some View {
        Form {
            Section("Dossier surveillé") {
                TextField("Chemin", text: b(\.watchFolder)).textFieldStyle(.roundedBorder)
                HStack {
                    Button("Choisir…") { chooseFolder() }
                    Button("Ouvrir le dossier") { model.openWatchFolder() }
                    Spacer()
                    Button("Traiter maintenant") { model.processNow() }
                }
                Text("Les TIFF et les PDF déposés ici sont traités de façon identique et convertis en PDF/A.")
                    .font(.caption).foregroundStyle(.secondary)
            }

            Section("Regroupement des fichiers") {
                Text("Un seul caractère détermine le découpage : celui qui précède le NUMÉRO DE PAGE. Tout ce qui le précède est la cote, conservée telle quelle pour le dossier et le PDF produit — TIFF et PDF suivent la même règle.")
                    .font(.caption).foregroundStyle(.secondary)
                Picker("Séparateur de pagination", selection: Binding(
                    get: { PageSeparator(rawValue: draft.pageDelimiter) ?? .dash },
                    set: { draft.pageDelimiter = $0.rawValue })) {
                    ForEach(PageSeparator.allCases) { Text($0.displayName).tag($0) }
                }
                Text("Avec « \(draft.pageDelimiter) » : Be.a.S1.1989_1\(draft.pageDelimiter)1, \(draft.pageDelimiter)2, \(draft.pageDelimiter)3 → un seul document « Be.a.S1.1989_1 » de 3 pages. Un fichier sans numéro de page devient un document d'une seule pièce, sous ce nom.")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
    }

    // MARK: - onglet Traitement
    private var traitementTab: some View {
        Form {
            Section("Reconnaissance de texte") {
                Toggle("OCR — couche texte (français + anglais)", isOn: b(\.ocr))
                if draft.ocr {
                    Picker("Mise en page (colonnes)", selection: b(\.tesseractPSM)) {
                        Text("Automatique (détecte les colonnes)").tag(3)
                        Text("Colonne unique").tag(4)
                        Text("Bloc de texte").tag(6)
                    }
                    Picker("Binarisation (qualité scan)", selection: b(\.ocrThreshold)) {
                        Text("Adaptative (recommandé)").tag("adaptive-otsu")
                        Text("Sauvola (documents anciens)").tag("sauvola")
                        Text("Standard").tag("auto")
                    }
                }
            }
            Section("Corrections d'image") {
                Toggle("Rotation automatique de l'orientation", isOn: b(\.rotate))
                if draft.rotate {
                    Stepper(value: b(\.rotateThreshold), in: 2...60, step: 1) {
                        Text("Seuil de confiance : \(draft.rotateThreshold) — plus élevé = moins d'erreurs")
                    }
                }
                Toggle("Redressement des pages inclinées (deskew)", isOn: b(\.deskew))
                Toggle("Nettoyage de l'image (unpaper)", isOn: b(\.clean))
            }
            Section("Sortie") {
                Toggle("Compression", isOn: b(\.compress))
                if draft.compress {
                    Stepper(value: b(\.dpi), in: 72...600, step: 25) {
                        Text("Résolution cible : \(draft.dpi) DPI")
                    }
                }
                Toggle("Sortie PDF/A-2b (archivage normalisé)", isOn: b(\.pdfa))
                Toggle("Supprimer les originaux après traitement", isOn: b(\.deleteOriginals))
                Text(draft.deleteOriginals
                     ? "⚠️ Les originaux (TIFF et PDF) seront supprimés après génération du PDF."
                     : "Les originaux (TIFF et PDF) sont conservés dans le sous-dossier du projet.")
                    .font(.caption).foregroundStyle(draft.deleteOriginals ? Color.orange : Color.secondary)
                Toggle("Notification macOS en fin de traitement", isOn: b(\.notify))
            }
        }
        .formStyle(.grouped)
    }

    // MARK: - onglet Filigrane
    private var filigraneTab: some View {
        Form {
            Section("Filigrane") {
                Toggle("Apposer un filigrane sur chaque page", isOn: b(\.watermarkEnabled))
                if draft.watermarkEnabled {
                    Picker("Type", selection: b(\.watermarkType)) {
                        Text("Texte").tag("text")
                        Text("Image (PNG)").tag("image")
                    }
                    .pickerStyle(.segmented)
                    if draft.watermarkType == "image" {
                        HStack {
                            TextField("Fichier image (PNG, JPEG…)", text: b(\.watermarkImagePath))
                                .textFieldStyle(.roundedBorder)
                            Button("Choisir…") { chooseWatermarkImage() }
                        }
                        Text(watermarkImageStatus)
                            .font(.caption).foregroundStyle(watermarkImageOK ? Color.secondary : Color.orange)
                    } else {
                        TextField("Texte (ex. ARCHIVES FVJC)", text: b(\.watermarkText))
                            .textFieldStyle(.roundedBorder)
                    }
                    Picker("Placement", selection: b(\.watermarkPosition)) {
                        Text("Diagonale").tag("diagonal")
                        Text("Centre").tag("center")
                        Text("Haut").tag("top")
                        Text("Bas").tag("bottom")
                        Text("Mosaïque").tag("tile")
                    }
                    Stepper(value: b(\.watermarkOpacity), in: 5...100, step: 5) {
                        Text("Opacité : \(draft.watermarkOpacity) %")
                    }
                    Toggle("En dur (fusionné, non supprimable)", isOn: b(\.watermarkHard))
                    Text(draft.watermarkHard
                         ? "Fusionné définitivement dans le PDF (impossible à retirer)."
                         : "Ajouté comme calque « Filigrane » masquable/supprimable dans un lecteur PDF.")
                        .font(.caption).foregroundStyle(.secondary)
                }
            }
        }
        .formStyle(.grouped)
    }

    // MARK: - onglet Fiche ISAD
    private var ficheTab: some View {
        Form {
            Section("Fiche archivistique (ISAD)") {
                Toggle("Générer une fiche texte ISAD à côté du PDF", isOn: b(\.isadEnabled))
                if draft.isadEnabled {
                    if model.ollamaModels.isEmpty {
                        TextField("Modèle Ollama", text: b(\.isadModel)).textFieldStyle(.roundedBorder)
                    } else {
                        Picker("Modèle installé", selection: b(\.isadModel)) {
                            ForEach(modelChoices, id: \.self) { Text($0).tag($0) }
                        }
                    }
                    HStack {
                        Button("Actualiser la liste") { model.refreshOllamaModels() }
                        Spacer()
                        if !model.ollamaStatus.isEmpty {
                            Text(model.ollamaStatus).font(.caption).foregroundStyle(.secondary)
                                .lineLimit(1).truncationMode(.middle)
                        }
                    }
                    TextField("Adresse Ollama", text: b(\.isadHost)).textFieldStyle(.roundedBorder)
                    Text("Après chaque PDF, le texte OCR est résumé par un modèle local en champs ISAD(G). Si Ollama n'est pas démarré, ScanToPDF le lance. En cas d'échec, le PDF est produit normalement, sans fiche.")
                        .font(.caption).foregroundStyle(.secondary)
                }
            }
            if draft.isadEnabled {
                Section("Contexte transmis au modèle") {
                    Text("Décrit le fonds pour éviter les contresens (sigles, lieux, vocabulaire). Envoyé tel quel avant chaque demande de description.")
                        .font(.caption).foregroundStyle(.secondary)
                    TextEditor(text: b(\.isadContext))
                        .font(.system(size: 11))
                        .frame(height: 200)
                        .overlay(RoundedRectangle(cornerRadius: 5).stroke(Color.secondary.opacity(0.35)))
                    HStack {
                        Button("Rétablir le contexte par défaut") {
                            draft.isadContext = AppConfig.defaultIsadContext
                        }
                        Spacer()
                        Text("\(draft.isadContext.count) caractères")
                            .font(.caption2).foregroundStyle(.tertiary)
                    }
                }
            }
        }
        .formStyle(.grouped)
    }

    // MARK: - onglet Publication
    private var publicationTab: some View {
        Form {
            Section("Lecteur réseau (SMB)") {
                Toggle("Publier le résultat sur un lecteur réseau", isOn: b(\.exportEnabled))
                if draft.exportEnabled {
                    Picker("Lecteur", selection: Binding(
                        get: { draft.nasVolumePath },
                        set: { path in
                            guard let v = model.nasVolumes.first(where: { $0.path == path }) else { return }
                            draft.nasVolumePath = v.path
                            draft.nasMountFrom = v.mountFrom
                        })) {
                        if draft.nasVolumePath.isEmpty {
                            Text("— aucun —").tag("")
                        } else if !model.nasVolumes.contains(where: { $0.path == draft.nasVolumePath }) {
                            Text("\((draft.nasVolumePath as NSString).lastPathComponent) (non monté)")
                                .tag(draft.nasVolumePath)
                        }
                        ForEach(model.nasVolumes) { Text($0.name).tag($0.path) }
                    }
                    .disabled(model.config.nasLocked)

                    HStack {
                        Button("Actualiser la liste") { model.refreshNASVolumes() }
                            .disabled(model.config.nasLocked)
                        Button("Monter maintenant") { model.connectNAS() }
                        Spacer()
                        Button {
                            model.setNASLock(!model.config.nasLocked)
                        } label: {
                            Label(model.config.nasLocked ? "Déverrouiller" : "Verrouiller",
                                  systemImage: model.config.nasLocked ? "lock.fill" : "lock.open")
                        }
                    }
                    TextField("Sous-dossier racine (optionnel)", text: b(\.nasSubpath))
                        .textFieldStyle(.roundedBorder)
                        .disabled(model.config.nasLocked)
                    if !model.nasStatus.isEmpty {
                        Text(model.nasStatus).font(.caption).foregroundStyle(.secondary).lineLimit(2)
                    }
                    Text(model.config.nasLocked
                         ? "🔒 Verrouillé : le mot de passe administrateur du Mac est requis pour changer de lecteur."
                         : "Seuls les lecteurs SMB montés sont proposés. Le lecteur retenu est remonté automatiquement s'il a été éjecté ; son mot de passe est demandé par macOS et gardé dans le Trousseau — jamais par l'application.")
                        .font(.caption).foregroundStyle(.secondary)
                    Text("Le résultat est classé selon sa cote (« Eg.w.O0.… » → dossiers Eg / w / O0). Sans lecteur monté, rien n'est publié. Le dossier COMPLET est copié.")
                        .font(.caption).foregroundStyle(.secondary)
                }
            }

            Section("Catalogue AtoM") {
                Toggle("Publier la notice dans AtoM", isOn: b(\.atomEnabled))
                if draft.atomEnabled {
                    TextField("Adresse (https uniquement)", text: b(\.atomBaseURL))
                        .textFieldStyle(.roundedBorder)
                    TextField("Courriel du compte AtoM", text: b(\.atomEmail))
                        .textFieldStyle(.roundedBorder)
                    HStack {
                        SecureField("Mot de passe", text: $atomPassword)
                            .textFieldStyle(.roundedBorder)
                        Button("Enregistrer") {
                            _ = AtomCredentials.save(email: draft.atomEmail, password: atomPassword)
                            atomPassword = ""
                        }
                        .disabled(draft.atomEmail.isEmpty || atomPassword.isEmpty)
                    }
                    HStack {
                        Button("Tester la connexion") { model.testAtomLogin() }
                            .disabled(draft.atomEmail.isEmpty)
                        Spacer()
                        Text(AtomCredentials.hasPassword(for: draft.atomEmail)
                             ? "Mot de passe enregistré dans le Trousseau"
                             : "Aucun mot de passe enregistré")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                    if !model.atomStatus.isEmpty {
                        Text(model.atomStatus).font(.caption)
                            .foregroundStyle(model.atomStatus.hasPrefix("✅") ? Color.green : Color.secondary)
                            .lineLimit(2)
                    }
                    Text("Après chaque traitement, une fenêtre montre ce qui existe déjà dans AtoM et ce que ScanToPDF propose, champ par champ. Toutes les valeurs restent modifiables, et rien n'est envoyé sans validation.")
                        .font(.caption).foregroundStyle(.secondary)
                    Text("La notice est recherchée par sa cote dans SES DEUX écritures (« _ » et « / ») afin de ne jamais créer de doublon ; une notice en ancienne écriture est migrée vers « _ ». Seul le PDF/A final concerne AtoM.")
                        .font(.caption).foregroundStyle(.secondary)
                }
            }
        }
        .formStyle(.grouped)
    }

    // MARK: - onglet Application
    private var applicationTab: some View {
        Form {
            Section("Démarrage et mises à jour") {
                Toggle("Démarrer avec le système", isOn: b(\.startAtLogin))
                Toggle("Mises à jour entre Mac du réseau (Bonjour)", isOn: b(\.networkEnabled))
                Toggle("Vérification des releases GitHub", isOn: b(\.remoteUpdateEnabled))
                Text("Toutes les 24 h, l'app vérifie s'il existe une version plus récente sur GitHub.")
                    .font(.caption).foregroundStyle(.secondary)
                HStack {
                    Button("Vérifier les mises à jour maintenant") { model.checkRemoteUpdates() }
                    Spacer()
                }
            }
            if draft.networkEnabled {
                Section("Réseau local") {
                    HStack {
                        SecureField("Phrase secrète (optionnelle)", text: $passphrase)
                            .textFieldStyle(.roundedBorder)
                        Button("Appliquer") { model.setClusterPassphrase(passphrase) }
                    }
                    Text("Sécurise les mises à jour : seuls les Mac partageant la MÊME phrase se mettent à jour entre eux. Laisser vide = tous les ScanToPDF du réseau.")
                        .font(.caption).foregroundStyle(.secondary)
                }
            }
        }
        .formStyle(.grouped)
    }

    // MARK: - bandeaux
    private var legacyBanner: some View {
        HStack(spacing: 10) {
            Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange)
            Text("Ancien automatisme détecté (« com.fvjc.archivage ») — il fait doublon.")
                .font(.callout).lineLimit(2)
            Spacer()
            if model.legacyRemoving { ProgressView().controlSize(.small) }
            else { Button("Supprimer") { model.removeLegacy() }.buttonStyle(.borderedProminent) }
        }
        .padding(.horizontal, 14).padding(.vertical, 8)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.thinMaterial)
    }

    private var updateBanner: some View {
        HStack(spacing: 10) {
            Image(systemName: "arrow.down.circle.fill").foregroundStyle(Color.accentColor)
            if model.updateInstalling {
                Text("Mise à jour en cours…").font(.callout)
                ProgressView().controlSize(.small)
            } else if model.updateIsRemote {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Nouvelle version disponible sur GitHub").font(.callout)
                    Text("Version \(model.updateRemoteVersion) (vous avez la \(AppVersion.short))")
                        .font(.caption).foregroundStyle(.secondary)
                }
                Spacer()
                Button("Voir sur GitHub") { openGitHubRelease() }.buttonStyle(.borderedProminent)
                Button("Plus tard") { model.dismissUpdate() }
            } else {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Mise à jour disponible (« \(model.updatePeerName) »).").font(.callout)
                    Text("Build \(model.updatePeerBuild)").font(.caption).foregroundStyle(.secondary)
                }
                Spacer()
                Button("Installer et redémarrer") { model.installUpdate() }.buttonStyle(.borderedProminent)
                Button("Plus tard") { model.dismissUpdate() }
            }
        }
        .padding(.horizontal, 14).padding(.vertical, 8)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.thinMaterial)
    }

    // MARK: - helpers
    /// Le modèle enregistré peut ne plus être installé : on le garde dans le menu pour que la valeur
    /// réellement utilisée reste visible au lieu d'une ligne vide.
    private var modelChoices: [String] {
        let current = draft.isadModel
        guard !current.isEmpty, !model.ollamaModels.contains(current) else { return model.ollamaModels }
        return model.ollamaModels + [current]
    }

    private var watermarkImageOK: Bool {
        let p = draft.watermarkImagePath
        return p.hasPrefix("/") && FileManager.default.fileExists(atPath: p)
    }

    private var watermarkImageStatus: String {
        if draft.watermarkImagePath.isEmpty { return "Choisissez une image — la transparence du PNG est conservée." }
        return watermarkImageOK
            ? "Image trouvée : la transparence est conservée, l'opacité éclaircit le motif."
            : "⚠️ Fichier introuvable — aucun filigrane ne sera apposé."
    }

    private func openGitHubRelease() {
        if let url = URL(string: "https://github.com/Trano89/ScanToPDF/releases") {
            NSWorkspace.shared.open(url)
        }
    }

    private func chooseFolder() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        panel.directoryURL = URL(fileURLWithPath: draft.watchFolder)
        if panel.runModal() == .OK, let url = panel.url { draft.watchFolder = url.path }
    }

    private func chooseWatermarkImage() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = false
        panel.canChooseFiles = true
        panel.allowsMultipleSelection = false
        panel.allowedContentTypes = [.png, .jpeg, .tiff]
        if !draft.watermarkImagePath.isEmpty {
            panel.directoryURL = URL(fileURLWithPath: draft.watermarkImagePath).deletingLastPathComponent()
        }
        if panel.runModal() == .OK, let url = panel.url { draft.watermarkImagePath = url.path }
    }
}
