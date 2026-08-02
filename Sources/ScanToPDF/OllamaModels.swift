import Foundation

// Liste des modèles installés dans Ollama (API locale /api/tags), pour proposer un MENU dans les
// préférences au lieu d'une saisie libre : un nom mal orthographié ou absent renvoie un 404 côté
// Ollama et aucune fiche n'est produite, sans que l'utilisateur comprenne pourquoi.
// Ollama n'est PAS bundlé (il reste sous le contrôle de l'utilisateur), mais s'il est installé sur ce
// Mac et arrêté, on le démarre : sinon la fonctionnalité paraît cassée alors que tout est en place.
enum OllamaModels {

    /// Modèles capables de GÉNÉRER du texte, triés par nom. Renvoie [] si Ollama est injoignable
    /// (best-effort : l'absence d'Ollama ne doit jamais bloquer la fenêtre de préférences).
    static func list(host: String) async -> [String] {
        let base = host.trimmingCharacters(in: .whitespaces)
            .trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        guard let url = URL(string: base + "/api/tags") else { return [] }
        var req = URLRequest(url: url)
        req.timeoutInterval = 5          // l'UI ne doit pas se figer si Ollama ne répond pas
        guard let (data, response) = try? await URLSession.shared.data(for: req),
              (response as? HTTPURLResponse)?.statusCode == 200 else { return [] }
        return parse(data)
    }

    /// Démarre Ollama s'il ne répond pas, puis attend qu'il soit prêt. Uniquement pour un serveur
    /// LOCAL : une adresse distante appartient à une autre machine, on n'y lance jamais rien.
    /// Renvoie la liste des modèles une fois le service disponible (vide si le démarrage a échoué).
    static func startIfNeeded(host: String) async -> [String] {
        guard ["localhost", "127.0.0.1", "[::1]"].contains(where: host.contains) else { return [] }
        guard launch() else { return [] }
        // L'app Ollama met quelques secondes à ouvrir son port : on réessaie jusqu'à 30 s.
        for _ in 0..<15 {
            try? await Task.sleep(nanoseconds: 2_000_000_000)
            let found = await list(host: host)
            if !found.isEmpty { return found }
        }
        return []
    }

    /// Lance l'app Ollama, à défaut le binaire en ligne de commande. true si un lancement a été tenté.
    private static func launch() -> Bool {
        let fm = FileManager.default
        if fm.fileExists(atPath: "/Applications/Ollama.app") {
            let p = Process()
            p.executableURL = URL(fileURLWithPath: "/usr/bin/open")
            p.arguments = ["-a", "/Applications/Ollama.app"]
            p.standardOutput = FileHandle.nullDevice; p.standardError = FileHandle.nullDevice
            if (try? p.run()) != nil { return true }
        }
        for cli in ["/usr/local/bin/ollama", "/opt/homebrew/bin/ollama",
                    "/Applications/Ollama.app/Contents/Resources/ollama"] where fm.isExecutableFile(atPath: cli) {
            let p = Process()
            p.executableURL = URL(fileURLWithPath: cli)
            p.arguments = ["serve"]
            p.standardOutput = FileHandle.nullDevice; p.standardError = FileHandle.nullDevice
            if (try? p.run()) != nil { return true }
        }
        return false
    }

    private static func parse(_ data: Data) -> [String] {
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let models = json["models"] as? [[String: Any]] else { return [] }
        return models.compactMap { entry -> String? in
            guard let name = entry["name"] as? String else { return nil }
            // « capabilities » écarte les modèles d'embedding, qui ne répondent pas à /api/generate.
            // Absent des anciennes versions d'Ollama → on conserve le modèle par défaut.
            if let caps = entry["capabilities"] as? [String], !caps.contains("completion") { return nil }
            return name
        }.sorted()
    }
}
