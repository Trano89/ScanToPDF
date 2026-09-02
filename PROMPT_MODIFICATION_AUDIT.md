# === PROMPT DE MODIFICATION ARCHITECTURALE ET TECHNIQUE ===

## [CONTEXTE DE L'APPLICATION]
- **Stack technique complète :**
  - macOS SwiftUI AppKit, Swift 5.9, macOS 13+
  - Moteur embarqué Python 3 + watchdog, Pillow, ocrmypdf, pikepdf
  - Binaires bundlés : Tesseract OCR, Ghostscript, ImageMagick/Pillow-SIMD
  - LLM local optionnel : Ollama via HTTP localhost:11434 pour fiche ISAD(G)
  - Publication réseau SMB, synchronisation LAN mDNS/Bonjour TLS-PSK
  - Config via `/Users/Shared/ScanToPDF/config.json` + variables d'environnement

- **Architecture globale :**
  - App Swift (`Sources/ScanToPDF/*.swift`) UI, préférences, service de mise à jour P2P `UpdateService.swift`, client AtoM `AtomClient.swift`, gestion montage NAS `MountManager.swift`
  - Engine Python `engine/archivage_watcher.py` : watcher watchdog + file d'attente worker unique, débounce 3s, stabilité 1s
  - Engine Python `engine/archivage_workflow.py` : verrou fcntl, détection/regroupement par `pageDelimiter`, isolation des originaux, fusion TIFF/PDF, OCR via ocrmypdf, compression Ghostscript, filigrane, export NAS, génération ISAD
  - Logs dans `/Users/Shared/ScanToPDF/logs/`, temp dans `temp_processing/`

## [CONCERTATION & IMPACTS ATOMIQUE]
Résumé de la concertation :
- Les corrections SecOps sur `UpdateService.swift` impactent l'Async/Concurrence : capture atomique de `updateTarget` avant création NWConnection évite race condition et reste compatible avec le watchdog de mise à jour.
- La sécurisation du secret TLS-PSK LAN ne casse pas la découverte Bonjour ; la génération de clé aléatoire au premier lancement est stockée dans le Trousseau, dérivée via HKDF si aucune phrase de cluster.
- La validation stricte de l'hôte ISAD empêche l'exfiltration OCR ; le module ISAD est optionnel et non bloquant, donc pas d'impact sur le pipeline PDF.
- Les modifications de permissions 0o750/0o640 sur dossiers archivés sont compatibles avec l'umask 0o002 actuel ; le chmod explicite remplace l'ancien 0o775.
- La suppression des chemins complets dans les notifications macOS ne touche pas le logging, qui garde les chemins complets pour le diagnostic.
- Le correctif d'orphelin watcher : le PID parent est vérifié dans la boucle d'attente, arrêt propre du worker et observer évite les watchers survivants qui captent le moteur sans être entendus par l'app.
- Aucun impact sur le regroupement TIFF/PDF, le délimiteur de pagination, ni sur la génération ISAD.

## [PLAN DE MODIFICATION STRUCTURÉ PAR COMPOSANT]

### COMPOSANT 1 : UpdateService - Sécurité LAN et race condition
- Agents impliqués : SecOps Auth, SecOps Secrets, Async/Concurrence, SecOps Injections
- Modifications requises :
  * `Sources/ScanToPDF/UpdateService.swift` ligne 342-345 : capturer `updateTarget` avant création connexion
    - Remplacer `let conn = NWConnection(to: target.endpoint, using: tlsParameters())` par capture atomique :
      `let currentTarget = queue.sync { updateTarget }; guard let target = currentTarget else { return "..." }`
  * `Sources/ScanToPDF/UpdateService.swift` ligne 23 : secret dur
    - Supprimer `static let appSecret = "scantopdf-lan-v1"`
    - Implémenter génération clé aléatoire au premier lancement, stockage Trousseau `com.antonin.scantopdf.clusterKey`, fallback à la constante uniquement en mode développement
    - Modifier `clusterPSK()` pour utiliser clé stockée
  * `Sources/ScanToPDF/UpdateService.swift` ligne 345 : libérer cible après capture pour éviter réutilisation périmée
- Impact sur les autres modules : Aucun, la découverte Bonjour reste identique

### COMPOSANT 2 : Sécurité ISAD et hôte Ollama
- Agents impliqués : SecOps Secrets, SecOps Injections, Intégration Systèmes
- Modifications requises :
  * `engine/archivage_workflow.py` ligne 200-217 : `_validate_isad_host` existante, renforcer
    - Interdire `http://` non local : accepter uniquement `http`/`https` avec hôte dans `localhost,127.0.0.1,[::1]` ou privé RFC1918
    - Journaliser rejet hôte dans `_ISAD_HOST_REJECTED`
  * `engine/archivage_workflow.py` ligne 959,1138 : envelopper `urllib.request.urlopen` avec validation préalable
    - Appeler `_validate_isad_host` avant tout appel, lever `RuntimeError` si hôte rejeté
  * `Sources/ScanToPDF/SettingsView.swift` : ajouter validation UI de `isadHost`, bloquer sauvegarde si hôte non autorisé
- Impact : ISAD désactivé si hôte invalide, PDF produit quand même

### COMPOSANT 3 : Permissions et fuites d'information
- Agents impliqués : SecOps Secrets, Gestion des Erreurs, Documentation & Clean Code
- Modifications requises :
  * `engine/archivage_workflow.py` ligne 775 : remplacer `os.chmod(path, 0o775)` par `0o750`, fichiers `0o640`
  * `engine/archivage_workflow.py` ligne 758,798 : notifications macOS
    - Remplacer `message[:200]` par `message_short = Path(message).name if '/' in message else message[:15]`
    - Utiliser uniquement nom projet dans `title`
  * `engine/archivage_watcher.py` ligne 260-262 : garde orphelin déjà présente, renforcer log
- Impact : lecture restreinte aux propriétaires, pas de fuite de chemin

### COMPOSANT 4 : Watcher et file d'attente
- Agents impliqués : Async/Concurrence, Perf Algorithmique, Arch Debt
- Modifications requises :
  * `engine/archivage_watcher.py` ligne 248-262 : vérification PPID déjà implémentée, ajouter écriture PID dans fichier `watcher.pid`
  * `engine/archivage_watcher.py` ligne 146-148 : `subprocess.Popen` avec `stdout=None` hérité, conserver
  * `engine/archivage_workflow.py` ligne 276-286 : verrou fcntl, conserver code 75 pour file d'attente
- Impact : évite watchers orphelins, traitement normal mais app entend la ligne SUCCÈS

### COMPOSANT 5 : Gestion erreurs et logging centralisé
- Agents impliqués : Gestion des Erreurs, Logging
- Modifications requises :
  * `engine/archivage_workflow.py` ligne 467-479 : en cas d'échec ocrmypdf, logger cause détaillée et poursuivre avec repli
  * `Sources/ScanToPDF/Engine.swift` : centraliser les logs vers `FileLog.append`, éviter duplication
- Impact : meilleure observabilité post-engagement

### COMPOSANT 6 : Typage et contrats
- Agents impliqués : Typage & Contrats, Arch Design Patterns
- Modifications requises :
  * `engine/archivage_workflow.py` : typer `detect_and_group` retour `dict[str, list[tuple[int,Path]]]`
  * `Sources/ScanToPDF/Config.swift` : valider `config.json` via Codable avec valeurs par défaut
- Impact : réduction bugs silencieux

### COMPOSANT 7 : Versionnage
- Agents impliqués : DevOps CI/CD
- Respect mémoire : micro-version uniquement x.y.Z sauf demande explicite
- Modification : `build_app.sh` doit incrémenter patch uniquement

## [VÉRIFICATIONS ET SÉCURITÉS POST-ENGAGEMENT]
1. Commandes de test à lancer :
   - `swift build -c release` dans `/Users/antonin/Projet AI/Archives/ScanToPDF`
   - `python3 engine/archivage_workflow.py --dry-run` avec `SCAN_DIR` de test
   - `semgrep --config=auto Sources/` et `bandit -r engine/`
2. Éléments de log/métriques à surveiller :
   - `/Users/Shared/ScanToPDF/logs/watcher_*.log` : présence ligne `SUCCÈS` et absence `orphelin`
   - `/Users/Shared/ScanToPDF/update.log` : pas de `REFUS — identifiant de bundle inattendu` intempestif
   - `archivage_*.log` : permissions dossiers `drwxr-x` 750, fichiers `rw-r-----` 640
3. Critères d'acceptation stricts :
   - Aucune connexion TLS-PSK établie avec secret hardcodé par défaut après premier lancement
   - `updateTarget` capturé atomiquement, pas de race condition reproduite sous charge
   - Hôte ISAD non local rejeté, PDF produit sans fiche ISAD, log explicite
   - Notifications macOS n'affichent plus de chemins absolus
   - Watcher s'arrête si PPID change, pas de processus orphelin après redémarrage app
   - Tests existants verts, pas de régression sur regroupement TIFF/PDF
