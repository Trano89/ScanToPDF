#!/usr/bin/env bash
# ─────────────────────────────────────────────────────────────────────────────
# Construit ScanToPDF.app — application macOS AUTONOME (Apple Silicon).
# Embarque : CPython relocalisable + ocrmypdf/pikepdf/pillow/watchdog,
#            binaires arm64 (tesseract, gs, unpaper, pngquant, jbig2) + leurs dylibs,
#            ressources Ghostscript (gs_init.ps, fonts, ICC) + tessdata (fra/eng/osd),
#            les scripts moteur (engine/).
# Aucune dépendance système requise sur le Mac cible (hors macOS 14+).
# ─────────────────────────────────────────────────────────────────────────────
set -euo pipefail
cd "$(dirname "$0")"
PROJ="$(pwd)"

APP_NAME="ScanToPDF"
BUNDLE_ID="com.antonin.scantopdf"
VERSION="1.0.18"
# Numéro de build COURT et monotone : minutes écoulées depuis 2026-01-01 UTC (≈ 6 chiffres, ex. 266401).
# Croissant dans le temps → comparable entre Mac pour la mise à jour réseau. (1767225600 = 2026-01-01 00:00 UTC)
BUILD=$(( ( $(date +%s) - 1767225600 ) / 60 ))
[ "$BUILD" -ge 1 ] 2>/dev/null || BUILD=1     # garde-fou si l'horloge est antérieure à l'époque

# Révision git (commit count + sha court) → clé SCGitRevision de l'Info.plist, lue par AppVersion.
# (Elle passait par « -D NOM=valeur », inopérant en Swift : un flag y est présent ou absent, jamais valué.)
GIT_REV=$(git rev-parse --short HEAD 2>/dev/null || echo "none")
GIT_COUNT=$(git rev-list --count HEAD 2>/dev/null || echo "0")
OUT_DIR="${1:-/Applications}"
APP="$OUT_DIR/$APP_NAME.app"
RES="$APP/Contents/MacOS/../Resources"      # = Contents/Resources
BREW="$(brew --prefix)"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

echo "════════════════════════════════════════════════════"
echo "  ScanToPDF — build $BUILD"
echo "════════════════════════════════════════════════════"

# ── Prérequis outils de build ────────────────────────────────────────────────
need() { command -v "$1" >/dev/null 2>&1 || { echo "❌ Outil requis manquant : $1 (brew install $2)"; exit 1; }; }
need dylibbundler dylibbundler
[ -x "$BREW/bin/gs" ]        || { echo "❌ ghostscript arm64 requis (brew install ghostscript)"; exit 1; }
[ -x "$BREW/bin/tesseract" ] || { echo "❌ tesseract arm64 requis (brew install tesseract)"; exit 1; }
[ -x "$BREW/bin/unpaper" ]   || { echo "❌ unpaper arm64 requis (brew install unpaper)"; exit 1; }
# Un binaire Homebrew peut être PRÉSENT mais incapable de démarrer : une dépendance mise à jour change
# de numéro (libx265.215 → .216) sans que la formule qui l'utilise soit reliée. On le détecte ICI, en
# une seconde, plutôt que de le découvrir bien plus loin (dylibbundler cherche alors une bibliothèque
# fantôme et attend une saisie au clavier — build figé).
for t in gs tesseract unpaper; do
  if ! probe=$("$BREW/bin/$t" --version 2>&1); then
    echo "❌ $t est installé mais ne démarre pas — dépendance Homebrew cassée :"
    printf '%s\n' "$probe" | grep -m1 -E "Library not loaded" | sed 's/^/   /'
    echo "   Remède : brew upgrade (ou brew reinstall) la formule qui fournit cette bibliothèque"
    echo "            — pour unpaper c'est généralement ffmpeg."
    exit 1
  fi
done

# ── 1) Compilation Swift ─────────────────────────────────────────────────────
echo "→ [1/9] Compilation Swift (release, arm64)…"
swift build -c release --arch arm64
BIN="$(swift build -c release --arch arm64 --show-bin-path)/$APP_NAME"
[ -f "$BIN" ] || { echo "❌ Binaire introuvable : $BIN"; exit 1; }

# ── 2) Squelette du bundle ───────────────────────────────────────────────────
echo "→ [2/9] Assemblage du bundle…"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$RES/bin" "$RES/lib" "$RES/share" "$RES/gs-lib" "$RES/engine"
cp "$BIN" "$APP/Contents/MacOS/$APP_NAME"
cp "$PROJ/engine/"*.py "$RES/engine/"

# ── 3) Python relocalisable (python-build-standalone) ────────────────────────
# Version de CPython embarquée : on la CALE sur celle du venv source pour pouvoir réutiliser ses
# paquets déjà installés (wheels auto-contenues) sans dépendre de PyPI au moment du build.
VENV_SRC="${SCANTOPDF_VENV:-/Users/Shared/code/venv}"
PYMINOR="3.13"
if [ -d "$VENV_SRC/lib" ]; then
  PYMINOR="$(ls -d "$VENV_SRC/lib/python3."* 2>/dev/null | head -1 | grep -oE 'python3\.[0-9]+' | sed 's/python//' || echo 3.13)"
fi
VENV_SP="$VENV_SRC/lib/python${PYMINOR}/site-packages"

echo "→ [3/9] Téléchargement de CPython relocalisable ($PYMINOR)…"
REL_JSON="$(curl -fsSL https://api.github.com/repos/astral-sh/python-build-standalone/releases/latest)"
# NB : dans le JSON de l'API, le « + » de la version est encodé « %2B » → on accepte les deux.
PY_URL="$(printf '%s' "$REL_JSON" | grep -oE "https://[^\"]*cpython-${PYMINOR}\.[0-9]+(%2B|\+)[0-9]+-aarch64-apple-darwin-install_only\.tar\.gz" | head -1 || true)"
[ -n "$PY_URL" ] || { echo "❌ URL python-build-standalone introuvable pour $PYMINOR"; exit 1; }
echo "   $PY_URL"
curl -fL "$PY_URL" -o "$TMP/python.tar.gz"
tar -xzf "$TMP/python.tar.gz" -C "$TMP"     # → $TMP/python/
cp -R "$TMP/python/." "$RES/python/"
PYBIN="$RES/python/bin/python3"
DEST_SP="$RES/python/lib/python${PYMINOR}/site-packages"

echo "→ [4/9] Paquets Python (ocrmypdf, pikepdf, pillow, watchdog)…"
if [ -f "$VENV_SP/ocrmypdf/__init__.py" ]; then
  # Chemin HORS-LIGNE fiable : on réutilise les paquets déjà installés du venv (wheels auto-contenues,
  # dylibs dans PIL/.dylibs et pikepdf/.dylibs → aucune dépendance Homebrew). ABI cp${PYMINOR/./} compatible.
  echo "   (hors-ligne) copie des paquets depuis $VENV_SP"
  cp -R "$VENV_SP"/. "$DEST_SP"/
else
  # Repli : installation depuis PyPI (nécessite le réseau).
  echo "   (réseau) pip install depuis PyPI"
  "$PYBIN" -m ensurepip --upgrade >/dev/null 2>&1 || true
  "$PYBIN" -m pip install --upgrade pip --no-warn-script-location >/dev/null
  "$PYBIN" -m pip install --no-warn-script-location "ocrmypdf==17.4.1" pikepdf pillow watchdog
fi
# Allège le bundle (suites de tests). On CONSERVE le bytecode et on le régénère juste après :
# les .pyc doivent exister AVANT la signature (aucune écriture au runtime → cf. PYTHONDONTWRITEBYTECODE).
find "$RES/python" -depth -type d -name "test" -prune -exec rm -rf {} + 2>/dev/null || true
find "$RES/python" -depth -type d -name "tests" -prune -exec rm -rf {} + 2>/dev/null || true

# ── 5) Binaires natifs arm64 + ressources ────────────────────────────────────
echo "→ [5/9] Copie des binaires natifs (arm64) + ressources…"
for t in tesseract gs unpaper pngquant jbig2; do
  cp -L "$BREW/bin/$t" "$RES/bin/$t"
done
# tessdata : langues (fra/eng/osd) + fichiers de config des renderers (hocr, pdf, txt, alto…).
# IMPORTANT : cp -L / -RL DÉRÉFÉRENCE les symlinks Homebrew — sinon on embarque des liens morts
# (vers .../Cellar/...) et tesseract échoue (« read_params_file: Can't open hocr ») → OCR KO.
mkdir -p "$RES/share/tessdata"
TDIR="$BREW/share/tessdata"
for lang in fra eng osd; do
  [ -f "$TDIR/$lang.traineddata" ] && cp -L "$TDIR/$lang.traineddata" "$RES/share/tessdata/"
done
[ -d "$TDIR/configs" ]     && cp -RL "$TDIR/configs"     "$RES/share/tessdata/configs"
[ -d "$TDIR/tessconfigs" ] && cp -RL "$TDIR/tessconfigs" "$RES/share/tessdata/tessconfigs"
[ -f "$TDIR/pdf.ttf" ]     && cp -L  "$TDIR/pdf.ttf"     "$RES/share/tessdata/pdf.ttf"
# Ressources Ghostscript COMPLÈTES (Resource/gs_init.ps + lib/ + iccprofiles/ + fonts/) — indispensables
# au fonctionnement de gs SANS Homebrew (autonomie) et au PDF/A (profil ICC sRGB pour l'OutputIntent).
# Layout possible : versionné (.../10.07.0/) OU plat (--without-versioned-path). On copie le dossier qui
# CONTIENT Resource/. cp -RL déréférence les symlinks (sinon liens morts sur un Mac vierge).
GS_PREFIX="$(brew --prefix ghostscript)"
GS_SHARE="$GS_PREFIX/share/ghostscript"
GS_SRC="$GS_SHARE"
for d in "$GS_SHARE"/*/; do
  if [ -d "${d}Resource" ]; then GS_SRC="${d%/}"; break; fi
done
[ -d "$GS_SRC/Resource" ] || { echo "❌ ressources Ghostscript (Resource/) introuvables sous $GS_SHARE"; exit 1; }
cp -RL "$GS_SRC"/. "$RES/gs-lib/"
[ -f "$RES/gs-lib/iccprofiles/srgb.icc" ] || echo "   ⚠︎ srgb.icc absent du bundle → PDF/A indisponible (repli PDF simple)"

# ── 6) Réécriture des install-names (dylibbundler) ───────────────────────────
echo "→ [6/9] Bundling des dylibs (dylibbundler)…"
# dylibbundler DEMANDE le chemin d'une bibliothèque qu'il ne trouve pas ; sans terminal la lecture
# échoue en boucle et il tourne indéfiniment à 100 % de CPU. On ferme donc son entrée standard, on lui
# donne les dossiers de recherche Homebrew, et on borne son temps d'exécution.
bundle_dylibs() {
  local t="$1" pid waited=0
  dylibbundler -of -b -x "$RES/bin/$t" -d "$RES/lib" -p "@executable_path/../lib" \
    -s "$BREW/lib" >/dev/null 2>&1 </dev/null &
  pid=$!
  while kill -0 "$pid" 2>/dev/null; do
    sleep 2; waited=$((waited + 2))
    if [ "$waited" -ge 180 ]; then
      kill -9 "$pid" 2>/dev/null || true
      echo "   ❌ dylibbundler bloqué sur $t (bibliothèque introuvable) — abandon après 180 s."
      return 1
    fi
  done
  wait "$pid" 2>/dev/null || return 1
}
DYLIB_WARN=0
for t in tesseract gs unpaper pngquant jbig2; do
  bundle_dylibs "$t" || { echo "   ⚠︎ dylibs incomplètes pour $t → autonomie non garantie."; DYLIB_WARN=1; }
done

# ── 7) Pré-compilation du bytecode Python ────────────────────────────────────
# Tous les .pyc sont générés MAINTENANT (avant la signature) : au runtime, PYTHONDONTWRITEBYTECODE
# empêche toute écriture → le bundle ne change plus jamais → sa signature reste valide (indispensable
# pour que la mise à jour réseau, qui vérifie codesign --deep --strict, accepte le bundle transféré).
echo "→ [7/9] Pré-compilation du bytecode Python…"
"$PYBIN" -m compileall -q -j 0 "$RES/python/lib" >/dev/null 2>&1 || true

# ── 8) Info.plist + test de fumée (AVANT signature) ──────────────────────────
echo "→ [8/9] Info.plist + vérification de l'autonomie…"
cat > "$APP/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleName</key><string>$APP_NAME</string>
  <key>CFBundleDisplayName</key><string>$APP_NAME</string>
  <key>CFBundleExecutable</key><string>$APP_NAME</string>
  <key>CFBundleIdentifier</key><string>$BUNDLE_ID</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleShortVersionString</key><string>$VERSION</string>
  <key>CFBundleVersion</key><string>$BUILD</string>
  <key>SCGitRevision</key><string>$GIT_COUNT:$GIT_REV</string>
  <key>LSMinimumSystemVersion</key><string>14.0</string>
  <key>LSUIElement</key><true/>
  <key>NSHighResolutionCapable</key><true/>
  <key>NSPrincipalClass</key><string>NSApplication</string>
  <key>LSApplicationCategoryType</key><string>public.app-category.productivity</string>
  <key>NSAppTransportSecurity</key>
  <dict><key>NSAllowsLocalNetworking</key><true/></dict>
  <key>NSBonjourServices</key>
  <array><string>_scantopdf._tcp</string></array>
  <key>NSLocalNetworkUsageDescription</key>
  <string>ScanToPDF découvre les autres Mac du réseau local pour proposer une mise à jour de l'application lorsqu'une version plus récente est disponible.</string>
</dict>
</plist>
PLIST
printf 'APPL????' > "$APP/Contents/PkgInfo"

# Test de fumée AVANT signature. PYTHONDONTWRITEBYTECODE=1 : aucun .pyc écrit ici non plus.
export PATH="$RES/bin:$PATH"
export TESSDATA_PREFIX="$RES/share/tessdata"
export PYTHONDONTWRITEBYTECODE=1
export GS_LIB="$RES/gs-lib/Resource/Init:$RES/gs-lib/lib:$RES/gs-lib/Resource/Font:$RES/gs-lib/Resource:$RES/gs-lib/iccprofiles:$RES/gs-lib"
OK=1
echo -n "   gs        : "; "$RES/bin/gs" --version 2>/dev/null && :   || { echo "ÉCHEC"; OK=0; }
echo -n "   tesseract : "; "$RES/bin/tesseract" --version 2>/dev/null | head -1 || { echo "ÉCHEC"; OK=0; }
echo -n "   unpaper   : "; "$RES/bin/unpaper" --version 2>/dev/null | head -1 || { echo "ÉCHEC"; OK=0; }
echo -n "   langues   : "; "$RES/bin/tesseract" --list-langs 2>&1 | grep -E "fra|eng" | tr '\n' ' '; echo
echo -n "   python    : "; "$PYBIN" --version 2>/dev/null || { echo "ÉCHEC"; OK=0; }
echo -n "   ocrmypdf  : "; "$PYBIN" -m ocrmypdf --version 2>/dev/null || { echo "ÉCHEC"; OK=0; }
# Vrai test OCR (exerce le renderer hocr → détecte l'absence des configs tesseract). Police TrueType
# lisible pour un OCR fiable (la police bitmap par défaut de Pillow est trop petite → faux négatif).
"$PYBIN" - >/dev/null 2>&1 <<PY || true
from PIL import Image, ImageDraw, ImageFont
f = None
for p in ("/System/Library/Fonts/Supplemental/Arial.ttf", "/System/Library/Fonts/Helvetica.ttc"):
    try: f = ImageFont.truetype(p, 52); break
    except Exception: pass
im = Image.new("RGB", (1000, 180), "white")
ImageDraw.Draw(im).text((24, 60), "scantopdf ocr test", font=f, fill="black")
im.save("$TMP/ocrtest.png")
PY
echo -n "   OCR réel  : "
if "$RES/bin/tesseract" "$TMP/ocrtest.png" - hocr 2>/dev/null | grep -qi "scantopdf"; then
  echo "OK"
else
  echo "ÉCHEC (renderer hocr / tessdata configs)"; OK=0
fi

# ── 9) Signature ad-hoc — EN DERNIER (après toute écriture) ──────────────────
# Inside-out : on signe d'abord les Mach-O DANS Resources (codesign --deep n'y descend pas seul),
# puis le bundle en --deep. Signer en dernier garantit qu'aucune écriture ultérieure (bytecode,
# ressources) n'invalide le sceau. Sur Apple Silicon, un Mach-O non/mal signé est refusé au chargement.
echo "→ [9/9] Signature ad-hoc (inside-out + bundle)…"
sign_macho() { file "$1" 2>/dev/null | grep -q "Mach-O" && codesign --force --sign - "$1" >/dev/null 2>&1 || true; }
export -f sign_macho
find "$RES/lib" "$RES/bin" -type f -print0 2>/dev/null | while IFS= read -r -d '' f; do sign_macho "$f"; done
find "$RES/python" -type f \( -name "*.so" -o -name "*.dylib" \) -print0 | while IFS= read -r -d '' f; do sign_macho "$f"; done
find "$RES/python/bin" -type f -perm -u+x -print0 | while IFS= read -r -d '' f; do sign_macho "$f"; done
codesign --force --deep --sign - "$APP" >/dev/null 2>&1 || echo "  (signature du bundle non bloquante)"
echo -n "   signature : "; codesign --verify --deep --strict "$APP" 2>/dev/null && echo "VALIDE" || { echo "INVALIDE"; OK=0; }

SIZE="$(du -sh "$APP" | cut -f1)"
echo "════════════════════════════════════════════════════"
if [ "$OK" -eq 1 ] && [ "$DYLIB_WARN" -eq 0 ]; then echo "✓ Terminé : $APP  (build $BUILD, $SIZE)"
else echo "⚠︎ Terminé AVEC des erreurs : $APP ($SIZE)"; fi
echo "════════════════════════════════════════════════════"
