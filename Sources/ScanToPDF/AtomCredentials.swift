import Foundation
import Security

/// Identifiants AtoM, rangés dans le Trousseau macOS — jamais dans config.json.
///
/// C'est le SEUL endroit du projet où l'application manipule un mot de passe : partout ailleurs
/// (partage SMB, verrou administrateur) c'est macOS qui l'invite et le vérifie. AtoM n'offrant aucune
/// autre voie d'écriture qu'un formulaire web authentifié, la session doit être ouverte par l'app.
enum AtomCredentials {
    private static let service = "com.scantopdf.atom"

    static func save(email: String, password: String) -> Bool {
        let base: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: email,
        ]
        SecItemDelete(base as CFDictionary)
        guard !password.isEmpty else { return true }        // effacer = enregistrer un mot de passe vide
        var add = base
        add[kSecValueData as String] = Data(password.utf8)
        add[kSecAttrAccessible as String] = kSecAttrAccessibleWhenUnlocked
        return SecItemAdd(add as CFDictionary, nil) == errSecSuccess
    }

    static func password(for email: String) -> String? {
        guard !email.isEmpty else { return nil }
        let q: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: email,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]
        var item: CFTypeRef?
        guard SecItemCopyMatching(q as CFDictionary, &item) == errSecSuccess,
              let d = item as? Data, let s = String(data: d, encoding: .utf8), !s.isEmpty else { return nil }
        return s
    }

    static func hasPassword(for email: String) -> Bool { password(for: email) != nil }
}
