import Foundation

// Nom convivial du Mac (publié dans le TXT record Bonjour pour l'invitation de mise à jour).
enum NetworkAdmin {
    static func macName() -> String { Host.current().localizedName ?? "ce Mac" }
}
