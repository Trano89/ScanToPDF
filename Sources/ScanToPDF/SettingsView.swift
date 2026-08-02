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
        case .dash:   return "Tiret (-)"
        case .underscore: return "Souligné (_)"
        case .dot:  return "Point (.)"
        case .tilde:    return "Tilde (~)"
        case .colon:    return "Deux-points (:)"
        case .space:    return "Espace (\u{2009})"
        }
    }
}

// Fenêtre de préférences : dossier surveillé + cases à cocher des étapes du pipeline + réglages app.
struct SettingsView: View {
    @EnvironmentObject var model: AppModel
    @State private var folder: String = AppModel.shared.config.watchFolder
    @State private var passphrase: String = AppModel.shared.clusterPassphrase
    @State private var pageSepChar: PageSeparator = {
        guard let found = PageSeparator.allCases.first(where: { $0.rawValue == AppModel.shared.config.pageSeparator }) else { return .underscore }
        return found
    }()
    @State private var pageDelimChar: PageSeparator = {
        guard let found = PageSeparator.allCases.first(where: { $0.rawValue == AppModel.shared.config.pageDelimiter }) else { return .dash }
        return found
    }()
    // Champs NAS (édition locale, appliqués via « Enregistrer »).
    @State private var nasHost: String = AppModel.shared.config.nasHost
    @State private var nasShare: String = AppModel.shared.config.nasShare
    @State private var nasSubpath: String = AppModel.shared.config.nasSubpath
    @State private var nasUser: String = AppModel.shared.config.nasUser
    @State private var driveFolder: String = AppModel.shared.config.driveFolder

    // Binding pratique vers un booléen de la config (sauvegarde + application immédiate via model.update).
    private func toggle(_ kp: WritableKeyPath<AppConfig, Bool>) -> Binding<Bool> {
        Binding(get: { model.config[keyPath: kp] }, set: { v in model.update { $0[keyPath: kp] = v } })
    }

    var body: some View {
        VStack(spacing: 0) {
            if model.legacyDetected { legacyBanner }
            if model.updateAvailable || model.updateInstalling { updateBanner }

            Form {
                Section("Dossier surveillé") {
                    TextField("Chemin", text: $folder)
                        .textFieldStyle(.roundedBorder)
                        .onSubmit { model.update { $0.watchFolder = folder } }
                    HStack {
                        Button("Choisir…") { chooseFolder() }
                        Button("Ouvrir le dossier") { model.openWatchFolder() }
                        Spacer()
                        Button("Traiter maintenant") { model.processNow() }
                    }
                    Text("Les TIFF et les PDF déposés ici sont traités de façon identique et convertis en PDF/A.")
                        .font(.caption).foregroundStyle(.secondary)
                }

                Section("Étapes du traitement") {
                    Toggle("OCR — couche texte (français + anglais)", isOn: toggle(\.ocr))
                    if model.config.ocr {
                        Picker("Mise en page (colonnes)", selection: Binding(
                            get: { model.config.tesseractPSM },
                            set: { v in model.update { $0.tesseractPSM = v } })) {
                            Text("Automatique (détecte les colonnes)").tag(3)
                            Text("Colonne unique").tag(4)
                            Text("Bloc de texte").tag(6)
                        }.padding(.leading, 18)
                        Picker("Binarisation (qualité scan)", selection: Binding(
                            get: { model.config.ocrThreshold },
                            set: { v in model.update { $0.ocrThreshold = v } })) {
                            Text("Adaptative (recommandé)").tag("adaptive-otsu")
                            Text("Sauvola (documents anciens)").tag("sauvola")
                            Text("Standard").tag("auto")
                        }.padding(.leading, 18)
                    }
                    Toggle("Rotation automatique de l'orientation", isOn: toggle(\.rotate))
                    if model.config.rotate {
                        Stepper(value: Binding(get: { model.config.rotateThreshold },
                                               set: { v in model.update { $0.rotateThreshold = v } }),
                                in: 2...60, step: 1) {
                            Text("Seuil de confiance : \(model.config.rotateThreshold) — plus élevé = moins d'erreurs")
                        }
                        .padding(.leading, 18)
                    }
                    Toggle("Redressement des pages inclinées (deskew)", isOn: toggle(\.deskew))
                    Toggle("Nettoyage de l'image (unpaper)", isOn: toggle(\.clean))
                    Toggle("Compression", isOn: toggle(\.compress))
                    if model.config.compress {
                        Stepper(value: Binding(get: { model.config.dpi },
                                               set: { v in model.update { $0.dpi = v } }),
                                in: 72...600, step: 25) {
                            Text("Résolution cible : \(model.config.dpi) DPI")
                        }
                        .padding(.leading, 18)
                    }
                    Toggle("Sortie PDF/A-2b (archivage normalisé)", isOn: toggle(\.pdfa))
                    Toggle("Supprimer les originaux après traitement", isOn: toggle(\.deleteOriginals))
                    Text(model.config.deleteOriginals
                         ? "⚠️ Les originaux (TIFF et PDF) seront supprimés après génération du PDF."
                         : "Les originaux (TIFF et PDF) sont conservés dans le sous-dossier du projet.")
                        .font(.caption).foregroundStyle(model.config.deleteOriginals ? .orange : .secondary)
                    Toggle("Notification macOS en fin de traitement", isOn: toggle(\.notify))
                }

                Section("Regroupement des fichiers") {
                    Text("Le moteur Python regroupe les TIFF par projet en lisant config.json. Ces caractères servent à séparer l'identifiant du document du numéro de page dans les noms de fichier (ex. « Eg.w.O0.1901_29-1.tif »). Par exemple : Ab.c.DE.9999-1.tif, Ab.c.DE.9999-2.tif seront regroupés en un seul PDF.")
                        .font(.caption).foregroundStyle(.secondary)
                    VStack(alignment: .leading, spacing: 6) {
                        Picker("Séparateur identifiant-projet", selection: Binding(
                            get: { pageSepChar },
                            set: { pageSepChar = $0; model.update { $0.pageSeparator = pageSepChar.rawValue } }
                        )) {
                            ForEach(PageSeparator.allCases) { sep in
                                Text(sep.displayName).tag(sep)
                            }
                        }
                        .padding(.leading, 18)
                        Text("Caractère entre l'identifiant du document et le n° de pagination. Ex. « _ » dans Eg.w.O0.1901_29-1.tif").font(.caption).foregroundStyle(.secondary)
                        Picker("Séparateur pagination", selection: Binding(
                            get: { pageDelimChar },
                            set: { pageDelimChar = $0; model.update { $0.pageDelimiter = pageDelimChar.rawValue } }
                        )) {
                            ForEach(PageSeparator.allCases) { sep in
                                Text(sep.displayName).tag(sep)
                            }
                        }
                        .padding(.leading, 18)
                        Text("Caractère entre le n° du document et le n° de page au sein d'une série. Ex. « - » dans Eg.w.O0.1901_29-1.tif pour séparer les pages Ab.c.DE.9999-1, 9999-2, etc.").font(.caption).foregroundStyle(.secondary)
                    }
                }

                Section("Filigrane") {
                    Toggle("Apposer un filigrane sur chaque page", isOn: toggle(\.watermarkEnabled))
                    if model.config.watermarkEnabled {
                        Picker("Type", selection: Binding(
                            get: { model.config.watermarkType },
                            set: { v in model.update { $0.watermarkType = v } })) {
                            Text("Texte").tag("text")
                            Text("Image (PNG)").tag("image")
                        }
                        .pickerStyle(.segmented)
                        if model.config.watermarkType == "image" {
                            HStack {
                                TextField("Fichier image (PNG, JPEG…)", text: Binding(
                                    get: { model.config.watermarkImagePath },
                                    set: { v in model.update { $0.watermarkImagePath = v } }))
                                    .textFieldStyle(.roundedBorder)
                                Button("Choisir…") { chooseWatermarkImage() }
                            }
                            Text(watermarkImageStatus)
                                .font(.caption).foregroundStyle(watermarkImageOK ? Color.secondary : Color.orange)
                        } else {
                            // Liaison DIRECTE : chaque frappe est persistée dans config.json (le champ ne
                            // dépend plus d'un « Entrée »/bouton — sinon le texte tapé pouvait être perdu).
                            TextField("Texte (ex. ARCHIVES FVJC)", text: Binding(
                                get: { model.config.watermarkText },
                                set: { v in model.update { $0.watermarkText = v } }))
                                .textFieldStyle(.roundedBorder)
                        }
                        Picker("Placement", selection: Binding(
                            get: { model.config.watermarkPosition },
                            set: { v in model.update { $0.watermarkPosition = v } })) {
                            Text("Diagonale").tag("diagonal")
                            Text("Centre").tag("center")
                            Text("Haut").tag("top")
                            Text("Bas").tag("bottom")
                            Text("Mosaïque").tag("tile")
                        }
                        Stepper(value: Binding(get: { model.config.watermarkOpacity },
                                               set: { v in model.update { $0.watermarkOpacity = v } }),
                                in: 5...100, step: 5) {
                            Text("Opacité : \(model.config.watermarkOpacity) %")
                        }
                        Toggle("En dur (fusionné, non supprimable)", isOn: toggle(\.watermarkHard))
                        Text(model.config.watermarkHard
                             ? "Fusionné définitivement dans le PDF (impossible à retirer)."
                             : "Ajouté comme calque « Filigrane » masquable/supprimable dans un lecteur PDF.")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                }

                Section("Fiche archivistique (ISAD)") {
                    Toggle("Générer une fiche texte ISAD à côté du PDF", isOn: toggle(\.isadEnabled))
                    if model.config.isadEnabled {
                        // Menu des modèles réellement installés sur ce Mac. Repli en saisie libre si
                        // Ollama est injoignable, pour pouvoir préparer le réglage hors ligne.
                        if model.ollamaModels.isEmpty {
                            TextField("Modèle Ollama", text: Binding(
                                get: { model.config.isadModel },
                                set: { v in model.update { $0.isadModel = v } }))
                                .textFieldStyle(.roundedBorder)
                        } else {
                            Picker("Modèle installé", selection: Binding(
                                get: { model.config.isadModel },
                                set: { v in model.update { $0.isadModel = v } })) {
                                ForEach(model.isadModelChoices, id: \.self) { name in
                                    Text(name).tag(name)
                                }
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
                        TextField("Adresse Ollama", text: Binding(
                            get: { model.config.isadHost },
                            set: { v in model.update { $0.isadHost = v } }))
                            .textFieldStyle(.roundedBorder)
                        Text("Après chaque PDF, le texte OCR est résumé par un modèle local (Ollama) en champs ISAD(G) : dates, étendue, histoire archivistique, portée et contenu, mots-clés. Le résultat est écrit dans un fichier « .txt » portant le même nom que le PDF. Ollama doit tourner sur ce Mac et le modèle être installé (« ollama pull \(model.config.isadModel) »). Si Ollama est injoignable, le PDF est produit normalement, sans fiche.")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                }

                Section("Application") {
                    Toggle("Démarrer avec le système", isOn: toggle(\.startAtLogin))
                    Toggle("Mises à jour entre Mac du réseau (Bonjour)", isOn: toggle(\.networkEnabled))
                    Toggle("Vérification des releases GitHub", isOn: toggle(\.remoteUpdateEnabled))
                    Text("Toutes les 24 h, l'app vérifie s'il existe une version plus récente sur GitHub.").font(.caption).foregroundStyle(.secondary)
                    if model.config.networkEnabled {
                        HStack {
                            SecureField("Phrase secrète (optionnelle)", text: $passphrase)
                                .textFieldStyle(.roundedBorder)
                                .onSubmit { model.setClusterPassphrase(passphrase) }
                            Button("Appliquer") { model.setClusterPassphrase(passphrase) }
                        }
                        Text("Sécurise les mises à jour : seuls les Mac partageant la MÊME phrase se mettent à jour entre eux. Laisser vide = tous les ScanToPDF du réseau.")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                }

                Section("Destination (NAS)") {
                    Toggle("Copier le résultat vers le NAS", isOn: toggle(\.exportEnabled))
                    if model.config.exportEnabled {
                        TextField("Serveur (IP ou nom)", text: $nasHost).textFieldStyle(.roundedBorder)
                        TextField("Partage SMB", text: $nasShare).textFieldStyle(.roundedBorder)
                        TextField("Sous-dossier racine (optionnel)", text: $nasSubpath).textFieldStyle(.roundedBorder)
                        TextField("Nom d'utilisateur", text: $nasUser).textFieldStyle(.roundedBorder)
                        HStack {
                            TextField("Dossier Synology Drive (repli)", text: $driveFolder).textFieldStyle(.roundedBorder)
                            Button("Choisir…") { chooseDriveFolder() }
                        }
                        HStack {
                            Button("Enregistrer") { saveNAS() }
                            Button("Se connecter au NAS") { saveNAS(); model.connectNAS() }
                            Spacer()
                        }
                        if !model.nasStatus.isEmpty {
                            Text(model.nasStatus).font(.caption).foregroundStyle(.secondary).lineLimit(2)
                        }
                        Text("Le résultat est classé selon son nom (« Eg.w.O0.… » → dossiers Eg / w / O0). Le mot de passe est demandé par macOS (Trousseau) — jamais stocké par l'app. NAS prioritaire, Synology Drive en repli.")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                }
            }
            .formStyle(.grouped)

            Divider()
            HStack(spacing: 12) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("ScanToPDF v\(AppVersion.short) (build \(AppVersion.build))")
                        .font(.caption).foregroundStyle(.secondary)
                    if AppVersion.hasRevision {
                        Text("revision \(AppVersion.revision)")
                            .font(.caption2).foregroundStyle(.tertiary)
                    }
                }
                Spacer()
                Button("Vérifier les MAJ…") { model.checkRemoteUpdates() }
                    .buttonStyle(.borderless)
                    .font(.caption)
                if !model.status.isEmpty {
                    Text(model.status).font(.caption).foregroundStyle(.secondary)
                        .lineLimit(1).truncationMode(.middle)
                }
            }
            .padding(.horizontal, 14).padding(.vertical, 8)
        }
        .frame(width: 460, height: 600)
        .onChange(of: model.config.watchFolder) { _, new in folder = new }
        .onChange(of: model.config.pageSeparator) { _, new in
            if let sep = PageSeparator(rawValue: new) { pageSepChar = sep }
        }
        .onChange(of: model.config.pageDelimiter) { _, new in
            if let sep = PageSeparator(rawValue: new) { pageDelimChar = sep }
        }
        // Liste des modèles Ollama : chargée à l'ouverture des préférences et à l'activation de la
        // fiche ISAD (pas au démarrage de l'app : inutile de solliciter Ollama tant qu'on n'y touche pas).
        .onAppear { if model.config.isadEnabled { model.refreshOllamaModels() } }
        .onChange(of: model.config.isadEnabled) { _, enabled in
            if enabled { model.refreshOllamaModels() }
        }
    }

    private var legacyBanner: some View {
        HStack(spacing: 10) {
            Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange)
            Text("Ancien automatisme détecté (« com.fvjc.archivage ») — il fait doublon.")
                .font(.callout).lineLimit(2)
            Spacer()
            if model.legacyRemoving {
                ProgressView().controlSize(.small)
            } else {
                Button("Supprimer") { model.removeLegacy() }.buttonStyle(.borderedProminent)
            }
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
                    Text("Version \(model.updateRemoteVersion) (vous avez la \(AppVersion.short)) — consultez les releases pour télécharger.")
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
        panel.directoryURL = URL(fileURLWithPath: folder)
        if panel.runModal() == .OK, let url = panel.url {
            folder = url.path
            model.update { $0.watchFolder = url.path }
        }
    }

    private func saveNAS() {
        model.update {
            $0.nasHost = nasHost.trimmingCharacters(in: .whitespaces)
            $0.nasShare = nasShare.trimmingCharacters(in: .whitespaces)
            $0.nasSubpath = nasSubpath.trimmingCharacters(in: .whitespaces)
            $0.nasUser = nasUser.trimmingCharacters(in: .whitespaces)
            $0.driveFolder = driveFolder.trimmingCharacters(in: .whitespaces)
        }
    }

    // Filigrane image : même validation que le moteur (chemin ABSOLU + fichier existant), affichée à
    // l'utilisateur — sinon un chemin invalide désactiverait le filigrane sans explication visible.
    private var watermarkImageOK: Bool {
        let p = model.config.watermarkImagePath
        return p.hasPrefix("/") && FileManager.default.fileExists(atPath: p)
    }

    private var watermarkImageStatus: String {
        if model.config.watermarkImagePath.isEmpty { return "Choisissez une image — la transparence du PNG est conservée." }
        return watermarkImageOK
            ? "Image trouvée : la transparence est conservée, l'opacité éclaircit le motif."
            : "⚠️ Fichier introuvable — aucun filigrane ne sera apposé."
    }

    private func chooseWatermarkImage() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = false
        panel.canChooseFiles = true
        panel.allowsMultipleSelection = false
        panel.allowedContentTypes = [.png, .jpeg, .tiff]
        if !model.config.watermarkImagePath.isEmpty {
            panel.directoryURL = URL(fileURLWithPath: model.config.watermarkImagePath).deletingLastPathComponent()
        }
        if panel.runModal() == .OK, let url = panel.url {
            model.update { $0.watermarkImagePath = url.path }
        }
    }

    private func chooseDriveFolder() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        if !driveFolder.isEmpty { panel.directoryURL = URL(fileURLWithPath: driveFolder) }
        if panel.runModal() == .OK, let url = panel.url {
            driveFolder = url.path
            saveNAS()
        }
    }

}
