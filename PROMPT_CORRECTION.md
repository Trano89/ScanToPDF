# Mission : correction de 5 vulnérabilités de sécurité

## Contexte du projet
- Langage et versions : Swift 5.9 (macOS 14+), Python 3.13, SwiftUI
- Rôle du programme : application macOS qui surveille un dossier de scans TIFF/PDF, les traite via un pipeline OCR/compression/PDF/A avec un moteur Python embarqué, et génère des fiches archivistiques ISAD(G) via Ollama local.
- Gestionnaire de dépendances : Swift Package Manager (Package.swift — aucune dépendance externe), Python via bundle autonome dans `Contents/Resources/python/` (Pillow, pikepdf, ocrmypdf watchdog).
- Fichiers concernés par cette mission : UpdateService.swift, archivage_workflow.py, SettingsView.swift

## Règles de travail
1. Traite les tâches dans l'ordre, une par une, sans interruption.
2. Après chaque tâche, relis le fichier modifié pour vérifier ta modification.
3. Ne modifie aucun fichier hors de la liste ci-dessus.
4. Ne change aucun comportement fonctionnel (les corrections doivent être transparentes).
5. Si une instruction ne correspond pas au code réel que tu lis, ARRÊTE-TOI sur cette tâche, signale l'écart, et passe à la suivante.

---

## T-01 — Race condition sur updateTarget (IDOR LAN) — HAUTE — CWE-284
**Fichier** : `Sources/ScanToPDF/UpdateService.swift`, ligne 342

**Problème** : `updateTarget` est lu via une closure synchrone mais peut être modifié par le handler `handleResults:` sur un autre thread entre l'appel et la création de la connexion NWConnection. Un pair B avec un build plus élevé peut remplacer A comme cible de téléchargement.

**Code actuel (à remplacer intégralement)** :
```swift
    func pullAndInstallApp() async -> String? {
        Self.ulog("client: début de la mise à jour")
        guard AppVersion.build > 0 else { return "Cette copie n'est pas une vraie application installée (build 0)." }
        let appPath = Bundle.main.bundlePath
        guard appPath.hasSuffix(".app") else { return "L'application n'est pas un bundle .app." }
        guard let target = queue.sync(execute: { updateTarget }) else { return "Aucun Mac source détecté." }
        let conn = NWConnection(to: target.endpoint, using: tlsParameters())
```

**Code corrigé** :
```swift
    func pullAndInstallApp() async -> String? {
        Self.ulog("client: début de la mise à jour")
        guard AppVersion.build > 0 else { return "Cette copie n'est pas une vraie application installée (build 0)." }
        let appPath = Bundle.main.bundlePath
        guard appPath.hasSuffix(".app") else { return "L'application n'est pas un bundle .app." }
        // Capturer target AVANT toute opération asynchrone pour éviter qu'un autre thread ne le modifie.
        let currentTarget: UpdateTarget?
        queue.sync { currentTarget = updateTarget }
        guard let target = currentTarget else { return "Aucun Mac source détecté." }
        // Verrouiller la cible : on ne la change plus pendant toute la durée du transfert.
        queue.async { self.updateTarget = nil }
        let conn = NWConnection(to: target.endpoint, using: tlsParameters())
```

**Imports / dépendances à ajouter** : aucun nouveau.

**Pourquoi cette correction fonctionne** : `currentTarget` est capturé de façon atomique dans le même bloc sync que la lecture originale. Ensuite `updateTarget` est remis à nil pour éviter qu'un second téléchargement utilise le même endpoint périmé. La variable locale `target` ne change plus pendant l'établissement de la connexion.

**IMPACT — fichiers appelants à vérifier** :
- AppModel.swift:243 → `await updateService.pullAndInstallApp()` (appel unique, sans boucle)

**Vérification** : `rg -n "queue.sync.*updateTarget" Sources/ScanToPDF/UpdateService.swift` doit retourner une seule occurrence (celle de T-01). L'ancienne pattern `queue.sync(execute: { updateTarget })` ne doit plus exister.

---

## T-02 — Secret LAN codé en dur — MOYENNE — CWE-798
**Fichier** : `Sources/ScanToPDF/UpdateService.swift`, ligne 23

**Problème** : La clé par défaut `"scantopdf-lan-v1"` est constante et connue. N'importe qui peut l'extraire du bundle et dériver la même clé TLS-PSK. Les lignes concernées sont 23, 119-127 (clusterPSK).

**Code actuel (à remplacer intégralement)** :
```swift
    static let appSecret = "scantopdf-lan-v1"   // clé partagée du cluster ScanToPDF (base de la clé TLS-PSK)
```

Et les lignes 114-128 (`clusterPSK`) :
```swift
    private func clusterPSK() -> Data {
        if let phrase = ClusterSecret.load() {
            let derived = HKDF<SHA256>.deriveKey(inputKeyMaterial: SymmetricKey(data: Data(phrase.utf8)),
                                                 salt: Data("scantopdf-cluster-v2".utf8),
                                                 info: Data("tls-psk".utf8), outputByteCount: 32)
            return derived.withUnsafeBytes { Data($0) }
        }
        let key = SymmetricKey(data: Data(Self.appSecret.utf8))
        let mac = HMAC<SHA256>.authenticationCode(for: Data("scantopdf".utf8), using: key)
        return Data(mac)
    }
```

**Code corrigé** :
Ajouter une clé aléatoire générée au 1er lancement, stockée dans le Trousseau via ClusterSecret sous un compte séparé.

D'abord, modifier `ClusterSecret.swift` (lignes 9-61) pour ajouter un nouveau service de clé machine :

```swift
enum ClusterSecret {
    private static let service = "com.scantopdf.cluster"
    private static let account = "cluster-passphrase"
    // Nouvelle entrée : clé machine générée automatiquement (fallback quand aucune phrase n'est saisie).
    private static let keyService = "com.scantopdf.machine-key"
    private static let keyAccount = "machine-key"

    static func load() -> String? { ... } // inchangé

    @discardableResult
    static func save(_ phrase: String) -> Bool { ... } // inchangé

    @discardableResult
    static func clear() -> Bool { ... } // inchangé

    static var isSet: Bool { load() != nil }

    static func normalize(_ s: String) -> String { ... } // inchangé

    // --- Nouvelle clé machine ---

    /// Charge la clé machine (générée aléatoirement au 1er lancement).
    /// Retourne nil si aucune clé n'existe encore.
    static func loadMachineKey() -> Data? {
        let q: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: keyService,
            kSecAttrAccount as String: keyAccount,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]
        var item: CFTypeRef?
        guard SecItemCopyMatching(q as CFDictionary, &item) == errSecSuccess,
              let data = item as? Data else { return nil }
        return data
    }

    /// Génère une clé machine aléatoire (32 octets) et la stocke dans le Trousseau.
    /// Renvoie true si la clé a été créée ou existait déjà.
    @discardableResult
    static func ensureMachineKey() -> Bool {
        if let existing = loadMachineKey(), !existing.isEmpty { return true }
        let keyData = Data((0..<32).map { _ in UInt8.random(in: 0...255) })
        let base: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: keyService,
            kSecAttrAccount as String: keyAccount,
        ]
        SecItemDelete(base as CFDictionary)
        var add = base
        add[kSecValueData as String] = keyData
        add[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlock
        return SecItemAdd(add as CFDictionary, nil) == errSecSuccess
    }

    static func machineKey() -> Data? { loadMachineKey() }
}
```

Ensuite, modifier `clusterPSK()` dans UpdateService.swift (lignes 118-128) :

**Code actuel** :
```swift
    private func clusterPSK() -> Data {
        if let phrase = ClusterSecret.load() {
            let derived = HKDF<SHA256>.deriveKey(inputKeyMaterial: SymmetricKey(data: Data(phrase.utf8)),
                                                 salt: Data("scantopdf-cluster-v2".utf8),
                                                 info: Data("tls-psk".utf8), outputByteCount: 32)
            return derived.withUnsafeBytes { Data($0) }
        }
        let key = SymmetricKey(data: Data(Self.appSecret.utf8))
        let mac = HMAC<SHA256>.authenticationCode(for: Data("scantopdf".utf8), using: key)
        return Data(mac)
    }
```

**Code corrigé** :
```swift
    private func clusterPSK() -> Data {
        if let phrase = ClusterSecret.load() {
            let derived = HKDF<SHA256>.deriveKey(inputKeyMaterial: SymmetricKey(data: Data(phrase.utf8)),
                                                 salt: Data("scantopdf-cluster-v2".utf8),
                                                 info: Data("tls-psk".utf8), outputByteCount: 32)
            return derived.withUnsafeBytes { Data($0) }
        }
        // Clé machine générée aléatoirement et stockée dans le Trousseau.
        if let keyData = ClusterSecret.machineKey() {
            let derived = HKDF<SHA256>.deriveKey(inputKeyMaterial: SymmetricKey(data: keyData),
                                                 salt: Data("scantopdf-cluster-v2".utf8),
                                                 info: Data("tls-psk".utf8), outputByteCount: 32)
            return derived.withUnsafeBytes { Data($0) }
        }
        // Fallback : secret historique (premier lancement ou Trousseau inaccessible).
        let key = SymmetricKey(data: Data(Self.appSecret.utf8))
        let mac = HMAC<SHA256>.authenticationCode(for: Data("scantopdf".utf8), using: key)
        return Data(mac)
    }
```

Enfin, ajouter l'initialisation de la clé machine dans `bootstrap()` d'AppModel.swift (ligne ~70-81) :
Après la ligne `configStore.save(config)`, ajouter un appel à `ClusterSecret.ensureMachineKey()`.

**Imports / dépendances à ajouter** : aucun — utilise `Security` déjà importé via ClusterSecret.

**Pourquoi cette correction fonctionne** : La clé machine est générée aléatoirement (32 octets de `UInt8.random`) et stockée dans le Trousseau macOS, accessible par le bundle ID mais pas lisible depuis un binaire brut. Chaque Mac a sa propre clé. Le fallback au secret historique maintient la compatibilité avec les installations existantes.

**IMPACT — fichiers appelants à vérifier** :
- UpdateService.swift:118 → `clusterPSK()` appelée dans `tlsParameters()` (ligne 130) et implicitement via `handleIncoming`/`pullAndInstallApp`.

**Vérification** : `rg -n "appSecret" Sources/ScanToPDF/UpdateService.swift` doit retourner la constante `appSecret = "scantopdf-lan-v1"` comme fallback unique (2 occurrences max). ClusterSecret.swift doit contenir `machineKey`, `ensureMachineKey`, `loadMachineKey`.

---

## T-03 — Validation de ISAD_HOST (URL non vérifiée) — MOYENNE — CWE-319
**Fichier** : `engine/archivage_workflow.py`, lignes 956-962 et 1125-1185

**Problème** : `ISAD_HOST` est une chaîne de config.json non validée. L'utilisateur peut la définir à n'importe quelle URL (http ou https). Les requêtes urllib n'ont ni vérification TLS ni restriction d'hôte. De plus, le suffixe `/` est retiré mais pas validé.

**Code actuel (à remplacer intégralement)** :
Lignes 194-207 :
```python
ISAD_HOST  = str(_CFG.get("isadHost", "http://localhost:11434")).strip().rstrip("/") or "http://localhost:11434"
# Bornes : un OCR de gros document ne doit pas gonfler la requête au LLM ni son temps de réponse.
# Fenêtre de contexte, FIXE. Ollama la plafonne à 4096 jetons par défaut quelle que soit la capacité
# du modèle, ce qui tronque le prompt en silence. On impose donc 128k jetons, sans la déduire de la
# taille du document : rien ne garantit que les pièces à venir ressembleront à celles déjà traitées.
ISAD_CTX         = 131072
# Budget de texte UTILE envoyé au modèle (le texte est compacté au préalable : ces caractères sont du
# vrai texte, là où 40 000 caractères bruts n'en contenaient qu'un millier). Dimensionné pour remplir
# la fenêtre ci-dessus sans risque de troncature, même dans l'hypothèse basse de 4 caractères par jeton.
ISAD_MAX_CHARS   = 480000
ISAD_TIMEOUT     = 900      # secondes d'attente max (inclut le chargement à froid du modèle, ~40 s)
ISAD_MAX_TOKENS  = 1500     # réponse bornée : huit champs n'en demandent pas davantage
ISAD_START_WAIT  = 45       # secondes laissées à Ollama pour répondre après un démarrage automatique
ISAD_MIN_TEXT    = 400      # en deçà, l'OCR n'a rien rendu d'exploitable → la fiche est signalée comme fragile
```

**Code corrigé** :
Ajouter ces constantes et cette fonction juste avant `ISAD_HOST` (ligne ~193) :

```python
# Validation stricte de ISAD_HOST : seul localhost est accepté par défaut.
_ISAD_VALID_HOSTS = {"localhost", "127.0.0.1", "::1"}


def _validate_isad_host(url: str) -> str | None:
    """Valide et nettoie l'URL Ollama. Retourne l'URL valide ou None si invalide."""
    from urllib.parse import urlparse
    parsed = urlparse(url)
    if not parsed.scheme or parsed.scheme not in ("http", "https"):
        return None
    host = parsed.hostname
    if not host:
        return None
    # Accepter localhost, 127.0.0.1, [::1], ou les adresses IP locales 192.168.x.x / 10.x.x.x
    if host in _ISAD_VALID_HOSTS or host.startswith("127.") or host == "::1":
        return f"{parsed.scheme}://{host}:{parsed.port}" if parsed.port else f"{parsed.scheme}://{host}"
    # Autoriser les adresses LAN privées (192.168.x.x, 10.x.x.x) — Ollama distant sur un autre Mac du réseau.
    if host.startswith("192.168.") or host.startswith("10."):
        return f"{parsed.scheme}://{host}:{parsed.port}" if parsed.port else f"{parsed.scheme}://{host}"
    # Rejeter les domaines externes (.com, .fr, etc.) sauf localhost explicite.
    if "." in host and not any(host.endswith(s) for s in (".local", ".lan")):
        return None
    return f"{parsed.scheme}://{host}:{parsed.port}" if parsed.port else f"{parsed.scheme}://{host}"
```

Puis modifier la ligne 194 :

**Code actuel** :
```python
ISAD_HOST  = str(_CFG.get("isadHost", "http://localhost:11434")).strip().rstrip("/") or "http://localhost:11434"
```

**Code corrigé** :
```python
_ISAD_HOST_RAW = str(_CFG.get("isadHost", "http://localhost:11434")).strip()
# Valider l'hôte : localhost par défaut, LAN privé autorisé. Les domaines externes (.com) sont rejetés.
ISAD_HOST = _validate_isad_host(_ISAD_HOST_RAW.rstrip("/")) or "http://localhost:11434"
```

**Imports / dépendances à ajouter** : `from urllib.parse import urlparse` dans `_validate_isad_host`.

**Pourquoi cette correction fonctionne** : Seuls localhost, 127.0.0.1, ::1, et les adresses LAN privées (192.168.x.x, 10.x.x.x) sont acceptés. Les domaines externes (.com, .fr) sont rejetés sauf `.local`/.lan (mDNS). Le scheme doit être http ou https. Un host invalide repli sur localhost par défaut.

**IMPACT — fichiers appelants à vérifier** :
- archivage_workflow.py:959 → `_ollama_alive()` utilise ISAD_HOST
- archivage_workflow.py:1133 → `_ollama_generate()` utilise ISAD_HOST
- engine/archivage_watcher.py:16 → ne lit pas ISAD_HOST directement

**Vérification** : `rg -n "_validate_isad_host" engine/archivage_workflow.py` doit retourner 2 occurrences (définition + utilisation). `ISAD_HOST` doit être assigné via `_validate_isad_host`.

---

## T-04 — Permissions trop permissives sur dossiers archivés — BASSE — CWE-281
**Fichier** : `engine/archivage_workflow.py`, lignes 769-786

**Problème** : `fix_permissions` applique 0o775 aux dossiers et 0o664 aux fichiers. Dans un contexte partagé, tout utilisateur du groupe staff peut lire les archives.

**Code actuel (à remplacer intégralement)** :
```python
def fix_permissions(path: Path, logger: logging.Logger):
    try:
        try:
            os.chown(path, -1, STAFF_GID)
        except PermissionError:
            pass
        os.chmod(path, 0o775)
        for item in path.rglob("*"):
            try:
                try:
                    os.chown(item, -1, STAFF_GID)
                except PermissionError:
                    pass
                os.chmod(item, 0o775 if item.is_dir() else 0o664)
            except (PermissionError, FileNotFoundError):
                pass
    except Exception as exc:
        logger.debug(f"Permissions non modifiées pour {path} : {exc}")
```

**Code corrigé** :
```python
def fix_permissions(path: Path, logger: logging.Logger):
    try:
        try:
            os.chown(path, -1, STAFF_GID)
        except PermissionError:
            pass
        os.chmod(path, 0o750)
        for item in path.rglob("*"):
            try:
                try:
                    os.chown(item, -1, STAFF_GID)
                except PermissionError:
                    pass
                os.chmod(item, 0o750 if item.is_dir() else 0o640)
            except (PermissionError, FileNotFoundError):
                pass
    except Exception as exc:
        logger.debug(f"Permissions non modifiées pour {path} : {exc}")
```

**Imports / dépendances à ajouter** : aucun.

**Pourquoi cette correction fonctionne** : 0o750/0o640 retire la permission de lecture au groupe, conservant l'accès propriétaire (rwx) et groupe (r-x pour dossiers). Le umask 0o002 déjà appliqué limite le groupe à r/w par défaut.

**IMPACT — fichiers appelants à vérifier** :
- archivage_workflow.py:1410 → `fix_permissions(project_dir, logger)` appelé dans finally de main()

**Vérification** : `rg -n "chmod" engine/archivage_workflow.py` doit retourner 0o750 et 0o640.

---

## T-05 — Notification expose chemin complet du projet — BASSE — CWE-200
**Fichier** : `engine/archivage_workflow.py`, lignes 736-763

**Problème** : Le titre de la notification macOS contient le nom du projet (ex. `Be.a.S1.1989_1`) et le corps peut contenir des chemins complets. Les notifications sont visibles par tout utilisateur regardant l'écran.

**Code actuel (à remplacer intégralement)** :
Lignes 746-750 :
```python
    message_short = (message[:200] + "…") if len(message) > 200 else message
    icon = "✅" if success else "❌"
    body = f"{icon} {message_short}"
    # SÉCURITÉ : le message ET le titre (qui contient le nom de projet = nom de fichier, non maîtrisé)
    # sont passés en ARGUMENTS à osascript via `on run argv`, JAMAIS interpolés dans le source AppleScript.
```

**Code corrigé** :
```python
    # SÉCURITÉ : ne montrer que le nom du fichier dans la notification, pas le chemin complet.
    try:
        message_short = Path(message).name if "/" in message else (message[:20] + "…" if len(message) > 20 else message)
    except Exception:
        message_short = message[:30] if len(message) > 30 else message
    icon = "✅" if success else "❌"
    body = f"{icon} {message_short}"
    # SÉCURITÉ : le titre contient uniquement la cote (court), le corps uniquement le nom du fichier.
    title_short = Path(message).stem if "/" in message else message[:20]
```

Et ligne 798, modifier l'appel de send_notification pour passer le chemin complet mais utiliser les courts dans l'affichage :

Ligne 1398 (dans process_project) :
```python
send_notification(project_name, f"{final_pdf.parent}/{final_pdf.name}", True, logger)
```
→ inchangé (le chemin complet est toujours transmis, seul le display change).

**Imports / dépendances à ajouter** : `from pathlib import Path` — déjà importée ligne 22.

**Pourquoi cette correction fonctionne** : La notification n'affiche plus que le nom du fichier ou la cote, sans le chemin complet `/Users/Shared/FVJC_SCAN/...`. Un utilisateur regardant l'écran ne voit pas où sont stockées les archives.

**IMPACT — fichiers appelants à vérifier** :
- archivage_workflow.py:798 → `send_notification` dans process_project (ligne 1398)
- archivage_workflow.py:1406 → `send_notification(project_name, str(exc), False, logger)` — `str(exc)` peut contenir un chemin, le code corrigé l'écrêttera.

**Vérification** : Après la correction, les notifications macOS affichent ≤30 caractères dans le corps.

---

## Vérification finale
Après toutes les tâches, exécute :
- `rg -n "appSecret" Sources/ScanToPDF/UpdateService.swift` → doit retourner 2 occurrences max (constante + fallback)
- `rg -n "_validate_isad_host" engine/archivage_workflow.py` → doit retourner 2 occurrences (définition + utilisation)
- `rg -n "0o750\|0o640" engine/archivage_workflow.py` → doit trouver les nouvelles permissions
- `rg -n "Path.*\.name" engine/archivage_workflow.py` → doit trouver le nom court dans send_notification

Puis relire chaque fichier modifié pour s'assurer :
1. Aucune erreur de syntaxe Swift/Python
2. Les imports sont cohérents (Security pour ClusterSecret, pathlib pour Path)
3. Aucun comportement fonctionnel changé (les tests manuels de build/install doivent passer)

## Ce qui N'EST PAS demandé
- Ne corrige pas les faux positifs : archivage_watcher.py:86 (try/except/pass), archivage_watcher.py:100 (try/except/pass), archivage_watcher.py:143 (subprocess.Popen sans shell=True — args constants)
- Ne touche pas à : Package.swift, main.swift, ScanToPDFApp.swift, SettingsView.swift (sauf ajout ligne ClusterSecret.ensureMachineKey dans bootstrap), Engine.swift, OllamaModels.swift, NetworkAdmin.swift, MountManager.swift
- Ne modifie pas les permissions 0o755/0o644 des fichiers temporaires dans temp_processing/
