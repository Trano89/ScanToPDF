# Audit de sécurité — ScanToPDF (v1.0.17)
Date : 2026-08-05 | Outils utilisés : semgrep 1.172.0, bandit 1.9.4 | Outils indisponibles : gitleaks, osv-scanner, trivy, pip-audit, cloc

## 1. Résumé exécutif
Application macOS SwiftUI + moteur Python embarqué pour la numérisation d'archives (TIFF/PDF → PDF/A-2b avec OCR et fiche ISAD(G) générée par LLM local). Surface d'attaque limitée : un seul utilisateur, LAN isolé.

**5 vulnérabilités identifiées** : 0 CRITIQUE, 1 HAUTE, 2 MOYENNE, 2 BASSE.
Le risque principal : le bundle `.app` reçu par mise à jour réseau est vérifié (SHA-256 + signature AD-HOC) mais son identité n'est pas liée à une autorité de certification — un attaquant sur le LAN peut remplacer l'app si le pair a un build plus élevé.

## 2. Tableau des vulnérabilités
| # | Sévérité | Titre | Fichier:ligne | CWE |
|---|----------|-------|---------------|-----|
| V-01 | HAUTE | IDOR sur updateTarget via queue.sync() race condition | UpdateService.swift:342 | CWE-284 |
| V-02 | MOYENNE | Secret LAN codé en dur, clé TLS-PSK reproductible | UpdateService.swift:23 | CWE-798 |
| V-03 | MOYENNE | HTTP non chiffré vers ISAD_HOST sans vérification TLS | archivage_workflow.py:959,1138 | CWE-319 |
| V-04 | BASSE | Permissions 0o775 sur les dossiers archivés | archivage_workflow.py:775 | CWE-281 |
| V-05 | BASSE | Notification macOS expose le chemin complet du projet | archivage_workflow.py:758,798 | CWE-200 |

## 3. Détail de chaque vulnérabilité

### V-01 — Race condition sur updateTarget (IDOR LAN) — HAUTE
- **Emplacement** : UpdateService.swift:342
- **Code concerné** :
```swift
let conn = NWConnection(to: target.endpoint, using: tlsParameters())
```
- **Explication** : `updateTarget` est lu via `queue.sync(execute:)` à la ligne 342. Entre l'appel à `pullAndInstallApp()` (ligne 337) et la création de la connexion NWConnection (ligne 343), un autre thread peut modifier `updateTarget` dans `handleResults:` (lignes 205-225). Concrètement, si l'utilisateur clique « Installer » alors qu'un pair A est en train d'annoncer son build, mais que le browser détecte UN PAIR B avec un build encore plus élevé avant que la connexion ne soit établie, l'app télécharge depuis B au lieu de A. Le TLS-PSK vérifie l'identité du pair pour la session, pas l'intention utilisateur.
- **Impact** : Un attaquant sur le LAN peut forcer l'installation d'un bundle en « pipelinant » une annonce entre deux clics utilisateur — ou un pair C plus récent remplace A pendant le téléchargement.
- **Correction proposée** :
```swift
// Ligne 342 → capturer target AVANT de créer la connexion
let currentTarget = queue.sync { updateTarget }
guard let target = currentTarget else { return "Aucun Mac source détecté." }
let conn = NWConnection(to: target.endpoint, using: tlsParameters())
```
- **Confiance** : Haute

### V-02 — Secret LAN codé en dur (clé TLS-PSK reproductible) — MOYENNE
- **Emplacement** : UpdateService.swift:23
- **Code concerné** :
```swift
static let appSecret = "scantopdf-lan-v1"   // clé partagée du cluster ScanToPDF (base de la clé TLS-PSK)
```
- **Explication** : Quand aucune phrase de cluster n'est définie, toutes les connexions LAN utilisent cette constante. La clé dérivée est `HKDF(SHA256("scantopdf-lan-v1"), salt="scantopdf-cluster-v2", info="tls-psk")`. N'importe qui connaît le secret peut extraire le binairе du bundle, dériver la même clé TLS-PSK et intercepter/servir des mises à jour.
- **Impact** : MITM sur toutes les communications LAN non chiffrées en mode par défaut.
- **Correction proposée** : Générer une clé aléatoire au 1er lancement et la stocker dans le Trousseau ou un fichier `~/.secure` avec permission 0600. Utiliser cette clé comme base HKDF si aucune phrase de cluster n'est définie.
- **Confiance** : Haute

### V-03 — HTTP non chiffré vers ISAD_HOST sans vérification TLS — MOYENNE
- **Emplacement** : archivage_workflow.py:959 et 1138
- **Code concerné** (ligne 959) :
```python
with urllib.request.urlopen(f"{ISAD_HOST}/api/tags", timeout=timeout) as resp:
    return resp.status == 200
```
- **Explication** : `ISAD_HOST` provient de config.json, éditable dans les préférences. L'utilisateur peut le définir à n'importe quelle URL (ex. `http://192.168.1.50:11434`). Aucune vérification TLS n'est faite — si ISAD_HOST est un serveur externe (https://ollama.evil.com), les données du document (contexte + texte OCR) sont envoyées en clair (HTTP) ou avec certificat auto-signé non validé (HTTPS). De plus, le timeout de 900s sur `/api/generate` laisse une fenêtre d'attaque de 15 min.
- **Impact** : Fuite du texte OCR (~480 000 caractères max) vers un serveur tiers ; injection de réponse malveillante par un attaquant man-in-the-middle.
- **Correction proposée** :
```python
# Ligne 930+ (avant _ollama_generate), ajouter une validation stricte :
_VALID_HOSTS = {"localhost", "127.0.0.1", "[::1]"}

def _validate_isad_host(url: str) -> bool:
    """Seuls les hôtes locaux sont acceptés."""
    from urllib.parse import urlparse
    parsed = urlparse(url)
    return parsed.hostname in _VALID_HOSTS if parsed.hostname else False
```
- **Confiance** : Haute

### V-04 — Permissions 0o775 sur dossiers archivés — BASSE
- **Emplacement** : archivage_workflow.py:775
- **Code concerné** :
```python
os.chmod(path, 0o775)
for item in path.rglob("*"):
    os.chmod(item, 0o775 if item.is_dir() else 0o664)
```
- **Explication** : Les fichiers archivés reçoivent des permissions 0o775 (dossiers) / 0o664 (fichiers), group owner `staff`. N'importe quel utilisateur du Mac peut lire les documents. Le umask par défaut de l'app est déjà 0o002, donc le groupe a déjà accès — ce chmod explicite ajoute un risque si le dossier se retrouve sur un partage NFS ou SMB où d'autres groupes peuvent accéder.
- **Impact** : Lecture non autorisée par tout utilisateur local du Mac (acceptable dans un contexte familial/bureau).
- **Correction proposée** : Remplacer 0o775/0o664 par 0o750/0o640 si les archives ne doivent être lisibles que par le propriétaire.
- **Confiance** : Moyenne (dépend du déploiement)

### V-05 — Notification expose chemin complet du projet — BASSE
- **Emplacement** : archivage_workflow.py:758,798
- **Code concerné** :
```python
r = subprocess.run(["launchctl", "asuser", uid, "osascript", "-e", osa, body, title],
                   capture_output=True, text=True, timeout=10)
```
- **Explication** : `title` contient le nom du projet (ex. `Be.a.S1.1989_1`) et `body` peut contenir des chemins complets via la variable `message`. Les notifications macOS affichent ces valeurs dans le centre de notification — un chemin comme `/Users/Shared/FVJC_SCAN/ProjetSecret/resultat.pdf` est visible par tout utilisateur regardant l'écran.
- **Impact** : Fuite d'information (chemin complet du dossier de travail).
- **Correction proposée** : Utiliser uniquement le nom du fichier dans la notification, pas le chemin complet.
```python
# Ligne 747 → au lieu de message[:200], utiliser :
message_short = Path(message).name if '/' in message else message[:15]
```
- **Confiance** : Haute

## 4. Faux positifs écartés
| Alerte | Fichier:ligne | Raison de l'écartement |
|--------|---------------|------------------------|
| urllib dynamique | archivage_workflow.py:959 | ISAD_HOST est contrôlé par l'utilisateur, pas une entrée externe arbitraire. LOW si on accepte que le config.json soit source de confiance. |
| subprocess.Popen (bandit) | archivage_watcher.py:143 | Pas de shell=True ; args sont [sys.executable, str(WORKFLOW_SCRIPT)] — deux constantes. LOW. |
| try/except/pass (bandit) | archivage_watcher.py:86,100 | Silences d'erreurs attendus sur kill/stat — pas un problème fonctionnel. |
| semgrep B310 (urllib) | archivage_workflow.py:959,1138 | ISAD_HOST est une URL locale par défaut ; le scheme n'est pas validé mais l'hôte est contrôlé par config.json. |

## 5. Zones non auditées
- **Python bundled** (`build/ScanToPDF.app/Contents/Resources/python/lib/`) : ~4000 fichiers stdlib Python — non scannés individuellement.
- **Binaires bundlés** (GS, Tesseract, OCRmyPDF, unpaper) : vulnérabilités potentielles dans ces outils tiers non vérifiées par `osv-scanner` (NON DISPONIBLE).
- **DMG releases** (`releases/ScanToPDF.dmg`) : pas de vérification de la signature Apple Notarization.
- **Dossier temp** (`temp_processing/`) : fichiers créés avec umask 0o002, potentiellement lisibles par le groupe pendant le traitement.
