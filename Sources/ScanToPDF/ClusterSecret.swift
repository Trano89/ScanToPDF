import Foundation
import Security

// Phrase secrète OPTIONNELLE du cluster de mise à jour (comme un mot de passe Wi-Fi), stockée dans le
// Trousseau. Tous les Mac qui doivent se mettre à jour entre eux saisissent LA MÊME phrase ; la clé
// TLS-PSK en est dérivée. Sans phrase, on retombe sur le secret d'app historique (mode par défaut, pour
// ne pas rompre la découverte). Définir une phrase DURCIT la liaison : un Mac inconnu du réseau, ne
// connaissant pas la phrase, ne peut ni découvrir/servir ni recevoir de bundle.
enum ClusterSecret {
    private static let service = "com.scantopdf.cluster"
    private static let account = "cluster-passphrase"

    static func load() -> String? {
        let q: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]
        var item: CFTypeRef?
        guard SecItemCopyMatching(q as CFDictionary, &item) == errSecSuccess,
              let data = item as? Data, let s = String(data: data, encoding: .utf8) else { return nil }
        let t = normalize(s)
        return t.isEmpty ? nil : t
    }

    @discardableResult
    static func save(_ phrase: String) -> Bool {
        let value = normalize(phrase)
        if value.isEmpty { return clear() }
        let base: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
        SecItemDelete(base as CFDictionary)
        var add = base
        add[kSecValueData as String] = Data(value.utf8)
        add[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlock
        return SecItemAdd(add as CFDictionary, nil) == errSecSuccess
    }

    @discardableResult
    static func clear() -> Bool {
        let q: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
        let st = SecItemDelete(q as CFDictionary)
        return st == errSecSuccess || st == errSecItemNotFound
    }

    static var isSet: Bool { load() != nil }

    // Normalisation déterministe (identique sur tous les Mac) : NFC puis trim.
    static func normalize(_ s: String) -> String {
        s.precomposedStringWithCanonicalMapping.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
