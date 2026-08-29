import SwiftUI

/// Demande de connexion à AtoM, présentée au PREMIER traitement de chaque exécution de l'application.
/// La session vaut jusqu'à la fermeture de l'app : au redémarrage suivant, la question est reposée.
/// Le mot de passe ne sert qu'à ouvrir la session en HTTPS ; il n'est écrit sur le disque que si
/// l'utilisateur demande explicitement à le conserver dans le Trousseau.
struct AtomLoginView: View {
    @EnvironmentObject var model: AppModel
    @State private var email: String
    @State private var password: String
    @State private var remember: Bool
    @State private var busy = false
    @State private var error = ""
    let onFinish: (Bool) -> Void

    init(email: String, password: String, remember: Bool, onFinish: @escaping (Bool) -> Void) {
        _email = State(initialValue: email)
        _password = State(initialValue: password)
        _remember = State(initialValue: remember)
        self.onFinish = onFinish
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 10) {
                Image(systemName: "lock.shield").font(.title2).foregroundStyle(Color.accentColor)
                VStack(alignment: .leading, spacing: 2) {
                    Text("Connexion à AtoM").font(.headline)
                    Text(model.config.atomBaseURL).font(.caption).foregroundStyle(.secondary)
                }
            }
            Text("Nécessaire pour publier les notices. La session reste ouverte jusqu'à la fermeture de ScanToPDF.")
                .font(.caption).foregroundStyle(.secondary)

            Grid(alignment: .leading, horizontalSpacing: 10, verticalSpacing: 8) {
                GridRow {
                    Text("Courriel").frame(width: 80, alignment: .trailing)
                    TextField("", text: $email).textFieldStyle(.roundedBorder)
                }
                GridRow {
                    Text("Mot de passe").frame(width: 80, alignment: .trailing)
                    SecureField("", text: $password).textFieldStyle(.roundedBorder)
                        .onSubmit { connect() }
                }
            }
            Toggle("Conserver le mot de passe dans le Trousseau", isOn: $remember)
                .font(.caption)

            if !error.isEmpty {
                Text(error).font(.caption).foregroundStyle(.orange).lineLimit(3)
            }

            HStack {
                if busy { ProgressView().controlSize(.small) }
                Spacer()
                Button("Ignorer") { onFinish(false) }
                Button("Se connecter") { connect() }
                    .buttonStyle(.borderedProminent)
                    .keyboardShortcut(.defaultAction)
                    .disabled(busy || email.isEmpty || password.isEmpty)
            }
        }
        .padding(18)
        .frame(width: 460)
    }

    private func connect() {
        busy = true; error = ""
        let e = email, p = password, keep = remember
        Task {
            let failure = await model.openAtomSession(email: e, password: p, remember: keep)
            await MainActor.run {
                busy = false
                if let why = failure { error = why } else { onFinish(true) }
            }
        }
    }
}
