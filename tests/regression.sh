#!/bin/bash
# Non-régression du MOTEUR de traitement (engine/archivage_workflow.py).
#
# Chaque cas construit un dossier surveillé isolé, une configuration dédiée, lance UN passage du
# workflow avec le Python EMBARQUÉ dans l'application installée, puis vérifie le résultat sur le
# disque. Rien n'est écrit hors du dossier temporaire du test : ni la configuration réelle, ni le
# dossier surveillé de l'utilisateur ne sont touchés.
#
# La fiche ISAD et l'export réseau sont désactivés dans tous les cas : ils dépendent de services
# externes (Ollama, un partage monté) et n'ont pas leur place dans une suite qui doit rester
# reproductible hors ligne.
#
# Usage : bash tests/regression.sh
set -uo pipefail

APP="${SCANTOPDF_APP:-/Applications/ScanToPDF.app}"
RES="$APP/Contents/Resources"
PYBIN="$RES/python/bin/python3"
WORKFLOW="$RES/engine/archivage_workflow.py"

[ -x "$PYBIN" ]      || { echo "❌ Python embarqué introuvable : $PYBIN"; exit 1; }
[ -f "$WORKFLOW" ]   || { echo "❌ Moteur introuvable : $WORKFLOW"; exit 1; }

RACINE="$(mktemp -d)"
trap 'rm -rf "$RACINE"' EXIT
REUSSIS=0; ECHOUES=0

# ── outils ───────────────────────────────────────────────────────────────────

# Fabrique un TIFF de N pixels de côté, avec une bande noire pour donner prise à l'OCR.
fabrique_tiff() {  # $1=chemin  $2=texte
  "$PYBIN" - "$1" "$2" <<'PY'
import sys
from PIL import Image, ImageDraw
img = Image.new("RGB", (1240, 1754), "white")     # A4 à 150 ppp
d = ImageDraw.Draw(img)
d.rectangle([100, 100, 1140, 300], fill="black")
d.text((120, 400), sys.argv[2], fill="black")
img.save(sys.argv[1], dpi=(150, 150))
PY
}

fabrique_pdf() {   # $1=chemin  $2=texte
  "$PYBIN" - "$1" "$2" <<'PY'
import sys
from PIL import Image, ImageDraw
img = Image.new("RGB", (1240, 1754), "white")
ImageDraw.Draw(img).text((120, 400), sys.argv[2], fill="black")
img.save(sys.argv[1], "PDF", resolution=150)
PY
}

fabrique_png_transparent() {  # $1=chemin — un rond rouge sur fond transparent
  "$PYBIN" - "$1" <<'PY'
import sys
from PIL import Image, ImageDraw
img = Image.new("RGBA", (400, 400), (0, 0, 0, 0))
ImageDraw.Draw(img).ellipse([20, 20, 380, 380], fill=(220, 30, 30, 255))
img.save(sys.argv[1])
PY
}

pages_pdf() {      # $1=pdf → nombre de pages
  "$PYBIN" -c "import pikepdf,sys; print(len(pikepdf.open(sys.argv[1]).pages))" "$1" 2>/dev/null || echo 0
}

# Compte les pixels d'une couleur donnée dans la première page rendue du PDF.
encre_pdf() {      # $1=pdf  $2=r  $3=v  $4=b  $5=tolérance
  "$PYBIN" - "$1" "$2" "$3" "$4" "$5" <<'PY' 2>/dev/null || echo 0
import sys, subprocess, os, tempfile
from PIL import Image
gs = os.environ.get("SCANTOPDF_GS", "gs")
with tempfile.TemporaryDirectory() as d:
    png = os.path.join(d, "p.png")
    subprocess.run([gs, "-q", "-dNOPAUSE", "-dBATCH", "-sDEVICE=png16m", "-r40",
                    "-dFirstPage=1", "-dLastPage=1", f"-sOutputFile={png}", sys.argv[1]],
                   capture_output=True)
    if not os.path.exists(png):
        print(0); raise SystemExit
    r, v, b, tol = (int(x) for x in sys.argv[2:6])
    n = sum(1 for px in Image.open(png).convert("RGB").getdata()
            if abs(px[0]-r) <= tol and abs(px[1]-v) <= tol and abs(px[2]-b) <= tol)
    print(n)
PY
}

# Prépare un cas : dossier surveillé + configuration. Les options passées en $2… écrasent les défauts.
prepare() {        # $1=nom du cas, puis des paires clé=valeur JSON
  CAS="$RACINE/$1"; SCAN="$CAS/scan"; SUPPORT="$CAS/support"
  # Ghostscript écrit ses fichiers intermédiaires dans TMPDIR : sans ce dossier il refuse de
  # démarrer, et le moteur retombe alors sur une copie brute — le filigrane ne s'applique pas.
  mkdir -p "$SCAN" "$SUPPORT/logs" "$SUPPORT/tmp"
  shift
  "$PYBIN" - "$SUPPORT/config.json" "$@" <<'PY'
import json, sys
cfg = {"ocr": False, "pdfa": False, "compress": False, "clean": False, "deskew": False,
       "rotate": False, "notify": False, "isadEnabled": False, "exportEnabled": False,
       "atomEnabled": False, "deleteOriginals": False, "watermarkEnabled": False,
       "pageDelimiter": "-", "dpi": 150}
for arg in sys.argv[2:]:
    k, _, v = arg.partition("=")
    cfg[k] = json.loads(v)
json.dump(cfg, open(sys.argv[1], "w"), ensure_ascii=False)
PY
}

lance() {          # exécute un passage du workflow sur le cas préparé
  SCANTOPDF_CONFIG="$SUPPORT/config.json" \
  SCANTOPDF_APPSUPPORT="$SUPPORT" \
  SCAN_DIR="$SCAN" \
  PATH="$RES/bin:$PATH" \
  TESSDATA_PREFIX="$RES/share/tessdata" \
  GS_LIB="$RES/gs-lib/Resource/Init:$RES/gs-lib/lib:$RES/gs-lib" \
  SCANTOPDF_GS="${GS_FORCE:-$RES/bin/gs}" \
  SCANTOPDF_GSLIB="$RES/gs-lib" \
  TMPDIR="$SUPPORT/tmp" \
  PYTHONDONTWRITEBYTECODE=1 \
  "$PYBIN" "$WORKFLOW" > "$CAS/sortie.log" 2>&1
}

verdict() {        # $1=libellé  $2=condition déjà évaluée (0 = vrai)
  if [ "$2" -eq 0 ]; then echo "  ✅ $1"; REUSSIS=$((REUSSIS+1))
  else echo "  ❌ $1"; ECHOUES=$((ECHOUES+1)); sed -n '1,12p' "$CAS/sortie.log" | sed 's/^/       /'; fi
}

# ── 1. TIFF : les originaux sont CONSERVÉS ───────────────────────────────────
echo "═ 1. TIFF : originaux conservés ═"
prepare tiff_garde
fabrique_tiff "$SCAN/Aa.b.C1.1990_1-1.tif" "page un"
fabrique_tiff "$SCAN/Aa.b.C1.1990_1-2.tif" "page deux"
lance
P="$SCAN/Aa.b.C1.1990_1/Aa.b.C1.1990_1.pdf"
[ -f "$P" ] && [ "$(pages_pdf "$P")" = "2" ] \
  && [ -f "$SCAN/Aa.b.C1.1990_1/Aa.b.C1.1990_1-1.tif" ]
verdict "2 TIFF → PDF de 2 pages, originaux gardés" $?

# ── 2. PDF homonyme du résultat : renommé, jamais écrasé ─────────────────────
echo "═ 2. PDF homonyme → _original.pdf ═"
prepare pdf_homonyme
fabrique_pdf "$SCAN/Bb.c.D2.1991_1.pdf" "source"
lance
D="$SCAN/Bb.c.D2.1991_1"
[ -f "$D/Bb.c.D2.1991_1.pdf" ] && ls "$D" | grep -q "_original"
verdict "original renommé, résultat intact" $?

# ── 3. PDF paginés : fusionnés dans l'ordre ──────────────────────────────────
echo "═ 3. PDF paginés fusionnés ═"
prepare pdf_pagines
fabrique_pdf "$SCAN/Cc.d.E3.1992_1-1.pdf" "un"
fabrique_pdf "$SCAN/Cc.d.E3.1992_1-2.pdf" "deux"
lance
[ "$(pages_pdf "$SCAN/Cc.d.E3.1992_1/Cc.d.E3.1992_1.pdf")" = "2" ]
verdict "2 PDF → 1 document de 2 pages" $?

# ── 4. Suppression des originaux : opt-in, et JAMAIS le résultat ─────────────
echo "═ 4. Suppression opt-in ═"
prepare suppression deleteOriginals=true
fabrique_tiff "$SCAN/Dd.e.F4.1993_1-1.tif" "un"
lance
D="$SCAN/Dd.e.F4.1993_1"
[ -f "$D/Dd.e.F4.1993_1.pdf" ] && [ ! -f "$D/Dd.e.F4.1993_1-1.tif" ]
verdict "originaux supprimés, résultat conservé" $?

# ── 5. Filigrane TEXTE ───────────────────────────────────────────────────────
echo "═ 5. Filigrane TEXTE ═"
prepare filigrane_texte watermarkEnabled=true watermarkType='"text"' \
        watermarkText='"ARCHIVES FVJC"' watermarkOpacity=60 watermarkPosition='"diagonal"'
fabrique_tiff "$SCAN/Ee.f.G5.1994_1-1.tif" "fond"
lance
ENCRE=$(encre_pdf "$SCAN/Ee.f.G5.1994_1/Ee.f.G5.1994_1.pdf" 128 128 128 90)
[ "${ENCRE:-0}" -gt 200 ]
verdict "texte visible sur le résultat (encre=$ENCRE)" $?

# ── 6. Filigrane IMAGE avec transparence ─────────────────────────────────────
echo "═ 6. Filigrane IMAGE (PNG transparent) ═"
prepare filigrane_image
fabrique_png_transparent "$CAS/tampon.png"
prepare filigrane_image watermarkEnabled=true watermarkType='"image"' \
        watermarkImagePath="\"$CAS/tampon.png\"" watermarkOpacity=100 watermarkPosition='"center"'
fabrique_png_transparent "$CAS/tampon.png"
fabrique_tiff "$SCAN/Ff.g.H6.1995_1-1.tif" "fond"
lance
ROUGE=$(encre_pdf "$SCAN/Ff.g.H6.1995_1/Ff.g.H6.1995_1.pdf" 220 30 30 70)
[ "${ROUGE:-0}" -gt 100 ]
verdict "image couleur appliquée, transparence respectée (rouge=$ROUGE)" $?

# ── 7. Séparateur de pagination configurable ─────────────────────────────────
echo "═ 7. Séparateur de pagination ═"
prepare separateur pageDelimiter='"."'
fabrique_tiff "$SCAN/Gg.h.I7.1996_1.1.tif" "un"
fabrique_tiff "$SCAN/Gg.h.I7.1996_1.2.tif" "deux"
lance
[ "$(pages_pdf "$SCAN/Gg.h.I7.1996_1/Gg.h.I7.1996_1.pdf")" = "2" ]
verdict "séparateur « . » respecté" $?

# ── 8. Groupe MIXTE TIFF + PDF ───────────────────────────────────────────────
echo "═ 8. Groupe mixte TIFF+PDF ═"
prepare mixte
fabrique_tiff "$SCAN/Hh.i.J8.1997_1-1.tif" "un"
fabrique_pdf  "$SCAN/Hh.i.J8.1997_1-2.pdf" "deux"
lance
[ "$(pages_pdf "$SCAN/Hh.i.J8.1997_1/Hh.i.J8.1997_1.pdf")" = "2" ]
verdict "TIFF et PDF fusionnés (2 pages)" $?

# ── 9. Ghostscript en panne : le document est produit, mais l'annonce le DIT ──
echo "═ 9. Repli sans filigrane ni PDF/A : annoncé, pas tu ═"
prepare gs_en_panne pdfa=true watermarkEnabled=true watermarkType='"text"' \
        watermarkText='"ARCHIVES"' watermarkOpacity=60
fabrique_tiff "$SCAN/Ii.j.K9.1998_1-1.tif" "fond"
# Un chemin INEXISTANT ne suffit pas : le moteur retombe alors sur le gs du PATH. Il faut un
# exécutable qui existe et qui échoue — c'est la seule façon d'exercer réellement le repli.
printf '#!/bin/sh\nexit 1\n' > "$CAS/gs-en-panne"; chmod +x "$CAS/gs-en-panne"
GS_FORCE="$CAS/gs-en-panne" lance
LIGNE=$(grep "SUCCÈS" "$CAS/sortie.log" | tail -1)
CHEMIN=$(printf '%s' "$LIGNE" | sed 's/.*→ *//')
[ -f "$SCAN/Ii.j.K9.1998_1/Ii.j.K9.1998_1.pdf" ] \
  && printf '%s' "$LIGNE" | grep -q "SANS" \
  && printf '%s' "$LIGNE" | grep -q "PDF/A" \
  && printf '%s' "$LIGNE" | grep -q "filigrane" \
  && [ -f "$CHEMIN" ]
verdict "document conservé, manques annoncés, chemin toujours lisible par l'app" $?

echo
echo "  RÉUSSIS : $REUSSIS   ÉCHOUÉS : $ECHOUES"
[ "$ECHOUES" -eq 0 ]
