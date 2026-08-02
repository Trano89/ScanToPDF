import Foundation

// Liste des modèles installés dans Ollama (API locale /api/tags), pour proposer un MENU dans les
// préférences au lieu d'une saisie libre : un nom mal orthographié ou absent renvoie un 404 côté
// Ollama et aucune fiche n'est produite, sans que l'utilisateur comprenne pourquoi.
// Ollama tourne HORS de l'app (rien n'est bundlé ni lancé) : on se contente de l'interroger.
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
              (response as? HTTPURLResponse)?.statusCode == 200,
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
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
