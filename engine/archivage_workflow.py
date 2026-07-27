#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""
Moteur ScanToPDF — Workflow TIFF -> PDF (OCR + redressement + compression + PDF/A-2b).
Version généralisée du workflow FVJC : toutes les étapes sont pilotées par la config de l'app
(config.json, chemin dans SCANTOPDF_CONFIG) et par des variables d'environnement posées par l'app Swift.
Aucun chemin en dur : le dossier surveillé, les binaires et les dossiers de travail viennent de l'app.
Plateforme : macOS Apple Silicon.
"""

import os
import re
import sys
import grp
import json
import fcntl
import shutil
import logging
import subprocess
import datetime
from pathlib import Path

from PIL import Image, ImageSequence
from _logsetup import init_logging   # module voisin (copié dans Resources/engine/)

# umask permissif : fichiers 664, dossiers 775 (accès groupe staff = tous les comptes locaux).
os.umask(0o002)

try:
    STAFF_GID = grp.getgrnam("staff").gr_gid
except KeyError:
    STAFF_GID = 20


# ─────────────────────────────────────────────────────────────
# CONFIGURATION — issue de config.json + variables d'environnement
# ─────────────────────────────────────────────────────────────
def _load_config() -> dict:
    path = os.environ.get("SCANTOPDF_CONFIG", "")
    if path and os.path.exists(path):
        try:
            with open(path, "r", encoding="utf-8") as f:
                return json.load(f)
        except Exception:
            return {}
    return {}


_CFG = _load_config()

APPSUPPORT     = Path(os.environ.get("SCANTOPDF_APPSUPPORT", "/Users/Shared/ScanToPDF"))

def _safe_watch_dir() -> Path:
    # watchFolder provient d'un config.json potentiellement modifiable par un autre compte :
    # on n'accepte qu'un chemin ABSOLU, sinon on retombe sur le dossier par défaut (anti-détournement).
    raw = os.environ.get("SCAN_DIR") or _CFG.get("watchFolder", "/Users/Shared/FVJC_SCAN")
    p = Path(str(raw)).expanduser()
    return p if p.is_absolute() else Path("/Users/Shared/FVJC_SCAN")

SCAN_DIR       = _safe_watch_dir()
TEMP_DIR       = APPSUPPORT / "temp_processing"
LOG_DIR        = APPSUPPORT / "logs"
LOCK_FILE_PATH = APPSUPPORT / "archivage.lock"

# Cases à cocher (défaut = tout activé, comme le script d'origine).
OPT_OCR      = bool(_CFG.get("ocr", True))
# Segmentation de page (détection des colonnes) : 3=auto (colonnes), 4=colonne unique, 6=bloc, 1=auto+OSD.
try:
    TESS_PSM = int(_CFG.get("tesseractPSM", 3))
except (TypeError, ValueError):
    TESS_PSM = 3
if TESS_PSM not in (1, 3, 4, 6):
    TESS_PSM = 3
# Binarisation Tesseract : adaptive-otsu/sauvola nettoient mieux les scans anciens → colonnes mieux séparées.
OCR_THRESHOLD = str(_CFG.get("ocrThreshold", "adaptive-otsu")).strip()
if OCR_THRESHOLD not in ("auto", "otsu", "adaptive-otsu", "sauvola"):
    OCR_THRESHOLD = "adaptive-otsu"
OPT_DESKEW   = bool(_CFG.get("deskew", True))
OPT_CLEAN    = bool(_CFG.get("clean", True))
OPT_ROTATE   = bool(_CFG.get("rotate", True))
try:
    # Seuil de confiance OSD pour la rotation auto. Élevé = ne pivote QUE si Tesseract est sûr
    # (moins de rotations erronées) ; bas = pivote plus agressivement (plus d'erreurs). Défaut ocrmypdf : 15.
    OPT_ROTATE_THRESHOLD = max(2, min(60, int(_CFG.get("rotateThreshold", 15))))
except (TypeError, ValueError):
    OPT_ROTATE_THRESHOLD = 15
OPT_COMPRESS = bool(_CFG.get("compress", True))
try:
    OPT_DPI  = max(72, min(600, int(_CFG.get("dpi", 150))))   # borné : un config.json trafiqué ne casse pas gs
except (TypeError, ValueError):
    OPT_DPI  = 150
OPT_PDFA     = bool(_CFG.get("pdfa", True))
OPT_NOTIFY   = bool(_CFG.get("notify", True))
# Suppression des originaux : opt-in EXPLICITE, désactivé par défaut (aucune perte de données par
# défaut). Quand activé, supprime les originaux TIFF *et* PDF de façon IDENTIQUE (jamais le résultat).
OPT_DELETE   = bool(_CFG.get("deleteOriginals", False))

# Filigrane (texte apposé sur chaque page) : contenu, placement, opacité, et « en dur » (fusionné,
# non supprimable) vs calque OCG (masquable/supprimable dans un lecteur PDF).
OPT_WM       = bool(_CFG.get("watermarkEnabled", False))
WM_TEXT      = str(_CFG.get("watermarkText", "")).strip()
WM_POS       = str(_CFG.get("watermarkPosition", "diagonal")).strip()
if WM_POS not in ("diagonal", "center", "top", "bottom", "tile"):
    WM_POS = "diagonal"
try:
    WM_OPACITY = max(0, min(100, int(_CFG.get("watermarkOpacity", 20))))
except (TypeError, ValueError):
    WM_OPACITY = 20
WM_HARD      = bool(_CFG.get("watermarkHard", True))
if not WM_TEXT:
    OPT_WM = False   # pas de texte → pas de filigrane

# Export du résultat vers le NAS (priorité) ou le dossier Synology Drive (repli).
OPT_EXPORT   = bool(_CFG.get("exportEnabled", False))
NAS_SHARE    = str(_CFG.get("nasShare", "")).strip()
NAS_SUBPATH  = str(_CFG.get("nasSubpath", "")).strip().strip("/")
DRIVE_FOLDER = str(_CFG.get("driveFolder", "")).strip()

# Ghostscript : binaire bundlé fourni par l'app (SCANTOPDF_GS), repli Homebrew.
if os.environ.get("SCANTOPDF_GS") and Path(os.environ["SCANTOPDF_GS"]).exists():
    GHOSTSCRIPT_BIN = os.environ["SCANTOPDF_GS"]
elif Path("/opt/homebrew/bin/gs").exists():
    GHOSTSCRIPT_BIN = "/opt/homebrew/bin/gs"
elif Path("/usr/local/bin/gs").exists():
    GHOSTSCRIPT_BIN = "/usr/local/bin/gs"
else:
    GHOSTSCRIPT_BIN = "gs"

# Règle de regroupement : « <identifiant><pageSep><pageNum>(<pageDelim><n>) .tif(f) »
# Les deux séparateurs sont configurables via les variables d'environnement posées par l'app Swift.
PAGE_SEPARATOR    = re.escape(os.environ.get("SCANTOPDF_PAGE_SEPARATOR", _CFG.get("pageSeparator", "_")))
PAGE_DELIMITER    = re.escape(os.environ.get("SCANTOPDF_PAGE_DELIMITER",   _CFG.get("pageDelimiter",   "-")))
# Regex : tout ce qui précède le dernier « sep » est l'identifiant du document, suivi du n° de pagination.
# Les pages d'une même série sont séparées par le delimeter (ex. Doc_29-1, Doc_29-2).
PAGE_PATTERN      = re.compile(
    rf"^(.+){PAGE_SEPARATOR}(\d{{1,3}}){PAGE_DELIMITER}\d{{1,3}}\.(tif|tiff)$", re.IGNORECASE)
# Regex : identifiant + n° de pagination (sans sous-page) → un seul TIFF par projet.
SINGLE_FILE_PATTERN = re.compile(
    rf"^(.+){PAGE_SEPARATOR}(\d{{1,3}})\.(tif|tiff)$", re.IGNORECASE)
# PDF : pagination INDÉPENDANTE (le regroupement TIFF reste inchangé). Le marqueur de page peut être
# le séparateur OU le délimiteur (« Doc-1.pdf », « Doc_1.pdf » → projet « Doc », page N). Les pages d'un
# même document sont fusionnées en un seul PDF. Sans marqueur (ex. « Rapport.pdf ») → PDF autonome.
PDF_PAGE_PATTERN = re.compile(
    rf"^(.+)[{PAGE_SEPARATOR}{PAGE_DELIMITER}](\d{{1,3}})\.pdf$", re.IGNORECASE)


# (init_logging est fourni par le module partagé _logsetup.py)


# ─────────────────────────────────────────────────────────────
# VERROUILLAGE — une seule instance à la fois
# ─────────────────────────────────────────────────────────────
def acquire_lock(logger: logging.Logger):
    LOCK_FILE_PATH.parent.mkdir(parents=True, exist_ok=True)
    lock_fd = open(LOCK_FILE_PATH, "w")
    try:
        fcntl.flock(lock_fd, fcntl.LOCK_EX | fcntl.LOCK_NB)
        return lock_fd
    except BlockingIOError:
        # Occupé : une autre instance traite déjà. Code 75 (≈ EX_TEMPFAIL) → la file d'attente du
        # watcher sait que c'est temporaire et réessaiera (au lieu de considérer le travail « fait »).
        logger.info("Une autre instance tourne déjà — abandon (la file réessaiera).")
        sys.exit(75)


def release_lock(lock_fd, logger: logging.Logger):
    fcntl.flock(lock_fd, fcntl.LOCK_UN)
    lock_fd.close()


# ─────────────────────────────────────────────────────────────
# DÉTECTION ET REGROUPEMENT
# ─────────────────────────────────────────────────────────────
def detect_and_group(logger: logging.Logger) -> dict:
    groups: dict = {}
    if not SCAN_DIR.exists():
        return groups
    for entry in SCAN_DIR.iterdir():
        if not entry.is_file():
            continue
        if entry.suffix.lower() == ".pdf":
            # PDF : pagination indépendante (« Doc-1.pdf » → projet « Doc », page 1). Sans marqueur → autonome.
            m = PDF_PAGE_PATTERN.match(entry.name)
            if m:
                groups.setdefault(m.group(1).strip(), []).append((int(m.group(2)), entry))
            else:
                groups.setdefault(entry.stem.strip(), []).append((0, entry))
            continue
        page_match = PAGE_PATTERN.match(entry.name)
        if page_match:
            project_name = page_match.group(1).strip()
            page_num     = int(page_match.group(2))
        else:
            single_match = SINGLE_FILE_PATTERN.match(entry.name)
            if not single_match:
                continue
            project_name = single_match.group(1).strip()
            page_num     = 0
        groups.setdefault(project_name, []).append((page_num, entry))
    for project_name in groups:
        groups[project_name].sort(key=lambda x: x[0])
        pages_str = ", ".join(str(p[0]) for p in groups[project_name])
        logger.info(f"Projet détecté : '{project_name}' — pages : [{pages_str}]")
    return groups


# ─────────────────────────────────────────────────────────────
# ISOLATION — déplacement des originaux vers le sous-dossier projet
# ─────────────────────────────────────────────────────────────
def isolate_originals(project_name: str, source_files: list, logger: logging.Logger) -> tuple:
    """Déplace les originaux (TIFF **ou** PDF, traités à l'identique) vers le sous-dossier projet.
    SEULE différence PDF : si un original porte déjà le nom du résultat final (« <projet>.pdf »),
    il est renommé « <projet>_original.pdf » pour ne pas entrer en concurrence avec la sortie.
    Ne JAMAIS écraser un original déjà archivé (versionné horodaté). Retourne (project_dir, [chemins isolés])."""
    project_dir = SCAN_DIR / project_name
    project_dir.mkdir(parents=True, exist_ok=True)
    result_name = f"{project_name}.pdf"
    moved = []
    for _, src_path in sorted(source_files, key=lambda x: x[0]):
        if src_path.suffix.lower() == ".pdf" and src_path.name == result_name:
            # Différence PDF : l'original entrerait en concurrence avec le résultat → « _original.pdf ».
            dst_path = _unique_path(project_dir / f"{project_name}_original.pdf")
            logger.info(f"PDF original homonyme du résultat — conservé sous « {dst_path.name} ».")
        else:
            dst_path = project_dir / src_path.name
            if dst_path.exists():
                dst_path = _unique_path(dst_path)
                logger.warning(f"Original homonyme existant — conservé sous « {dst_path.name} » (pas d'écrasement).")
        shutil.move(str(src_path), str(dst_path))
        moved.append(dst_path)
    logger.info(f"{len(moved)} original(aux) isolé(s) dans : {project_dir}")
    return project_dir, moved


# ─────────────────────────────────────────────────────────────
# FUSION — TIFF multipage dans temp_processing
# ─────────────────────────────────────────────────────────────
def merge_tiffs(project_name: str, page_paths: list, logger: logging.Logger) -> Path:
    TEMP_DIR.mkdir(parents=True, exist_ok=True)
    merged_path = TEMP_DIR / f"{project_name}_merged.tiff"
    all_frames = []
    for page_path in page_paths:
        with Image.open(page_path) as src:          # ferme le handle (pas de fuite de descripteur)
            for frame in ImageSequence.Iterator(src):
                frame_copy = frame.copy()
                if frame_copy.mode not in ("RGB", "L", "CMYK"):
                    frame_copy = frame_copy.convert("RGB")
                all_frames.append(frame_copy)
    total = len(all_frames)
    if total == 0:
        raise ValueError("Aucune frame extraite des fichiers TIFF.")
    if total == 1:
        all_frames[0].save(str(merged_path), format="TIFF", compression="tiff_lzw")
    else:
        all_frames[0].save(str(merged_path), format="TIFF", save_all=True,
                           append_images=all_frames[1:], compression="tiff_lzw")
    logger.info(f"TIFF fusionné ({total} page(s)) : {merged_path.name}")
    return merged_path


# ─────────────────────────────────────────────────────────────
# FUSION — plusieurs PDF paginés en un seul document (pikepdf)
# ─────────────────────────────────────────────────────────────
def merge_pdfs(project_name: str, pdf_paths: list, logger: logging.Logger) -> Path:
    """Concatène (dans l'ordre reçu) plusieurs PDF en un seul document, sans perte."""
    import pikepdf
    TEMP_DIR.mkdir(parents=True, exist_ok=True)
    merged_path = TEMP_DIR / f"{project_name}_merged.pdf"
    dst = pikepdf.Pdf.new()
    try:
        for p in pdf_paths:
            with pikepdf.Pdf.open(str(p)) as src:
                dst.pages.extend(src.pages)
        dst.save(str(merged_path))
    finally:
        dst.close()
    logger.info(f"PDF fusionné ({len(pdf_paths)} fichier(s)) : {merged_path.name}")
    return merged_path


# ─────────────────────────────────────────────────────────────
# CONVERSION DIRECTE (repli sans OCR ni traitement image) — Pillow
# ─────────────────────────────────────────────────────────────
def tiff_to_pdf_direct(tiff_path: Path, out_pdf: Path, logger: logging.Logger):
    with Image.open(tiff_path) as src:
        frames = [f.copy().convert("RGB") for f in ImageSequence.Iterator(src)]
    if not frames:
        raise ValueError("Aucune page dans le TIFF fusionné.")
    frames[0].save(str(out_pdf), "PDF", save_all=True, append_images=frames[1:], resolution=float(OPT_DPI))
    logger.info(f"PDF (conversion directe) généré : {out_pdf.name}")


# ─────────────────────────────────────────────────────────────
# OCR / traitement image — OCRmyPDF (conditionnel selon les cases)
# ─────────────────────────────────────────────────────────────
def run_ocr(tiff_path: Path, project_name: str, logger: logging.Logger) -> Path:
    out_pdf = TEMP_DIR / f"{project_name}_ocr.pdf"
    image_steps = OPT_DESKEW or OPT_CLEAN or OPT_ROTATE
    is_pdf_in = tiff_path.suffix.lower() == ".pdf"   # ocrmypdf accepte aussi un PDF en entrée

    # Ni OCR ni traitement image → rien à faire ici (finalize_pdf compressera/normalisera).
    if not OPT_OCR and not image_steps:
        if is_pdf_in:
            return tiff_path                     # déjà un PDF
        tiff_to_pdf_direct(tiff_path, out_pdf, logger)
        return out_pdf

    cmd = [sys.executable, "-m", "ocrmypdf"]
    if OPT_OCR:
        cmd += ["--language", "fra+eng", "--skip-text",
                "--tesseract-pagesegmode", str(TESS_PSM),      # 3 = détection auto des colonnes
                "--tesseract-thresholding", OCR_THRESHOLD]     # binarisation adaptée aux scans
    else:
        cmd += ["--tesseract-timeout", "0"]   # pas d'OCR, mais traitement image conservé
    if OPT_ROTATE:
        # Seuil élevé (défaut 15) → on ne pivote que si l'OSD est CONFIANT, ce qui évite de retourner
        # à tort des pages correctes (fréquent sur documents anciens/manuscrits à faible texte).
        cmd += ["--rotate-pages", "--rotate-pages-threshold", str(OPT_ROTATE_THRESHOLD)]
    if OPT_DESKEW:
        cmd += ["--deskew"]
    if OPT_CLEAN:
        cmd += ["--clean"]
    cmd += [
        "--output-type", "pdf",
        "--image-dpi", "300",
        "--jobs", str(max(2, (os.cpu_count() or 8) // 2)),
        "--optimize", "1",
        str(tiff_path), str(out_pdf),
    ]

    env = os.environ.copy()          # PATH pointe déjà sur les binaires bundlés (posé par l'app)
    env["TMPDIR"] = str(TEMP_DIR)
    env["OMP_THREAD_LIMIT"] = "1"
    env["OMP_NUM_THREADS"]  = "1"

    logger.info("OCRmyPDF : " + " ".join(cmd[2:]))
    result = subprocess.run(cmd, capture_output=True, text=True, timeout=1800, env=env)
    if result.returncode != 0:
        logger.error(f"OCRmyPDF échoué (code {result.returncode}) : {result.stderr.strip()}")
        # Repli tolérant : PDF en entrée → on finalise l'original sans couche OCR ;
        # TIFF sans OCR requis → conversion directe. Sinon on lève.
        if is_pdf_in:
            logger.info("Repli : le PDF original sera finalisé sans couche OCR.")
            return tiff_path
        if not OPT_OCR:
            tiff_to_pdf_direct(tiff_path, out_pdf, logger)
            return out_pdf
        raise RuntimeError(f"OCRmyPDF a retourné le code {result.returncode}")
    logger.info(f"PDF généré : {out_pdf.name}")
    return out_pdf


# ─────────────────────────────────────────────────────────────
# COMPRESSION — Ghostscript
# ─────────────────────────────────────────────────────────────
def _unique_path(p: Path) -> Path:
    """Chemin non existant : si p existe déjà, retourne une variante horodatée (anti-écrasement)."""
    if not p.exists():
        return p
    stamp = datetime.datetime.now().strftime("%Y%m%d_%H%M%S")
    return p.with_name(f"{p.stem}_{stamp}{p.suffix}")


def _ps_string(s: str) -> str:
    """Échappe une chaîne pour un littéral PostScript (…)."""
    return s.replace("\\", "\\\\").replace("(", "\\(").replace(")", "\\)")


def _srgb_icc() -> str:
    """Chemin absolu du profil ICC sRGB embarqué (requis pour l'OutputIntent PDF/A)."""
    base = os.environ.get("SCANTOPDF_GSLIB", "")
    if base:
        cand = Path(base) / "iccprofiles" / "srgb.icc"
        if cand.exists():
            return str(cand)
    for p in ("/opt/homebrew/opt/ghostscript/share/ghostscript/iccprofiles/srgb.icc",):
        if Path(p).exists():
            return p
    return ""


def _write_pdfa_def(icc_path: str) -> Path:
    """Génère le PDFA_def.ps minimal (OutputIntent sRGB, N=3) référençant l'ICC en chemin absolu."""
    content = f"""%!
[ /Title (ScanToPDF) /DOCINFO pdfmark
/ICCProfile ({_ps_string(icc_path)}) def
[/_objdef {{icc_PDFA}} /type /stream /OBJ pdfmark
[{{icc_PDFA}} << /N 3 >> /PUT pdfmark
[{{icc_PDFA}} ICCProfile (r) file /PUT pdfmark
[/_objdef {{OutputIntent_PDFA}} /type /dict /OBJ pdfmark
[{{OutputIntent_PDFA}} <<
  /Type /OutputIntent /S /GTS_PDFA1
  /DestOutputProfile {{icc_PDFA}}
  /OutputConditionIdentifier (sRGB)
>> /PUT pdfmark
[{{Catalog}} << /OutputIntents [ {{OutputIntent_PDFA}} ] >> /PUT pdfmark
"""
    p = TEMP_DIR / "PDFA_def.ps"
    p.write_text(content, encoding="utf-8")
    return p


def _ps_escape(s: str) -> str:
    """Échappe une chaîne pour un littéral PostScript (…), en Latin-1 (octal pour les accents)."""
    out = []
    for ch in s:
        o = ord(ch)
        if ch in "()\\":
            out.append("\\" + ch)
        elif 32 <= o < 127:
            out.append(ch)
        elif o <= 255:
            out.append("\\%03o" % o)     # é, è… via ISOLatin1Encoding
        else:
            out.append(" ")
    return "".join(out)


def _watermark_ps(text: str, position: str, opacity: int, hard: bool):
    """Construit le PostScript (-c) qui dessine le filigrane sur CHAQUE page (hook EndPage).
    hard=False → le filigrane est placé dans un calque OCG « Filigrane » (masquable/supprimable)."""
    txt = _ps_escape(text or "")
    if not txt.strip():
        return None
    gray = max(0.0, min(1.0, 1.0 - float(opacity) / 100.0))   # opacité 20 → gris 0.80 (léger)

    ocg_reg = oc_begin = oc_end = ""
    if not hard:
        ocg_reg = ("[ /_objdef {oc_wm} /type /dict /OBJ pdfmark "
                   "[ {oc_wm} << /Type /OCG /Name (Filigrane) >> /PUT pdfmark "
                   "[ {Catalog} << /OCProperties << /OCGs [ {oc_wm} ] /D << /ON [ {oc_wm} ] >> >> >> /PUT pdfmark ")
        oc_begin = "[ /OC {oc_wm} /BDC pdfmark "
        oc_end = "[ /EMC pdfmark "

    # Auto-dimensionne la police pour une largeur cible /TW, puis affiche centré horizontalement.
    autosize = ("/HelvISO findfont 1 scalefont setfont (%s) stringwidth pop /w1 exch def "
                "w1 0 le { /w1 1 def } if /sz TW w1 div def sz 140 gt { /sz 140 def } if "
                "/HelvISO findfont sz scalefont setfont /yoff sz -0.33 mul def " % txt)
    show1 = "(%s) dup stringwidth pop 2 div neg yoff moveto show " % txt

    if position == "center":
        body = "/TW pw 0.85 mul def " + autosize + "pw 2 div ph 2 div translate " + show1
    elif position == "top":
        body = "/TW pw 0.85 mul def " + autosize + "pw 2 div ph 0.93 mul translate " + show1
    elif position == "bottom":
        body = "/TW pw 0.85 mul def " + autosize + "pw 2 div ph 0.06 mul translate " + show1
    elif position == "tile":
        body = ("/TW pw 0.28 mul def " + autosize +
                "0 1 3 { /iy exch def 0 1 2 { /ix exch def gsave "
                "pw ix mul 3 div pw 6 div add  ph iy mul 4 div ph 8 div add  translate 30 rotate " +
                show1 + "grestore } for } for ")
    else:  # diagonal
        body = "/TW pw 0.90 mul def " + autosize + "pw 2 div ph 2 div translate 45 rotate " + show1

    fontdef = ("/HelvISO /Helvetica findfont dup length dict copy begin "
               "/Encoding ISOLatin1Encoding def currentdict end definefont pop ")
    endpage = ("<< /EndPage { exch pop 0 eq { gsave "
               "currentpagedevice /PageSize get aload pop /ph exch def /pw exch def "
               + oc_begin + ("%.3f setgray " % gray) + body + oc_end +
               "grestore true }{ false } ifelse } bind >> setpagedevice ")
    return fontdef + ocg_reg + endpage


def run_ghostscript(src_pdf: Path, out_pdf: Path, pdfa: bool, downsample: bool, logger: logging.Logger,
                    watermark_ps: str = None):
    """Un seul passage Ghostscript : PDF/A-2b conforme (OutputIntent sRGB) et/ou compression @ OPT_DPI."""
    cmd = [GHOSTSCRIPT_BIN, "-dBATCH", "-dNOPAUSE", "-dQUIET",
           f"-dNumRenderingThreads={os.cpu_count() or 8}", "-sDEVICE=pdfwrite"]
    if pdfa:
        # Vrai PDF/A-2 : conversion colorimétrique RGB + OutputIntent (via PDFA_def.ps) → veraPDF OK.
        cmd += ["-dPDFA=2", "-dPDFACompatibilityPolicy=1",
                "-sColorConversionStrategy=RGB", "-sProcessColorModel=DeviceRGB",
                "-dCompatibilityLevel=1.7"]
    else:
        cmd += ["-dCompatibilityLevel=1.6", "-dPDFSETTINGS=/ebook"]
    if downsample:
        dpi = str(OPT_DPI)
        cmd += [f"-dColorImageResolution={dpi}", f"-dGrayImageResolution={dpi}", f"-dMonoImageResolution={dpi}",
                "-dDownsampleColorImages=true", "-dDownsampleGrayImages=true", "-dDownsampleMonoImages=true",
                "-dColorImageDownsampleType=/Bicubic", "-dGrayImageDownsampleType=/Bicubic",
                "-dColorImageFilter=/DCTEncode", "-dGrayImageFilter=/DCTEncode",
                "-dAutoFilterColorImages=false", "-dAutoFilterGrayImages=false",
                "-dColorACSImageDict=/QFactor 0.22 /Blend 1 /ColorTransform 1 /HSamples [1 1 1 1] /VSamples [1 1 1 1]",
                "-dGrayACSImageDict=/QFactor 0.22 /Blend 1 /HSamples [1 1 1 1] /VSamples [1 1 1 1]"]
    cmd += [f"-sOutputFile={out_pdf}"]
    # Filigrane : code PostScript exécuté AVANT les fichiers d'entrée (installe le hook EndPage).
    if watermark_ps:
        cmd += ["-c", watermark_ps]
    cmd.append("-f")                             # fin du -c → ce qui suit sont des fichiers
    if pdfa:
        icc = _srgb_icc()
        if not icc:
            raise RuntimeError("Profil ICC sRGB introuvable (PDF/A impossible).")
        cmd.append(str(_write_pdfa_def(icc)))   # doit précéder le PDF source
    cmd.append(str(src_pdf))
    result = subprocess.run(cmd, capture_output=True, text=True, timeout=600)
    if result.returncode != 0:
        raise RuntimeError(f"Ghostscript code {result.returncode} : {result.stderr.strip()[:300]}")


# ─────────────────────────────────────────────────────────────
# FINALISATION — vrai PDF/A-2b (Ghostscript + OutputIntent) ou compression / copie simple
# ─────────────────────────────────────────────────────────────
def finalize_pdf(src_pdf: Path, project_name: str, project_dir: Path, logger: logging.Logger) -> Path:
    # Sortie VERSIONNÉE : on n'écrase jamais un PDF déjà archivé (anti-perte de données, #4).
    final = _unique_path(project_dir / f"{project_name}.pdf")
    wm = _watermark_ps(WM_TEXT, WM_POS, WM_OPACITY, WM_HARD) if OPT_WM else None

    if OPT_PDFA:
        try:
            run_ghostscript(src_pdf, final, pdfa=True, downsample=OPT_COMPRESS, logger=logger, watermark_ps=wm)
            logger.info(f"PDF/A-2b final{' + filigrane' if wm else ''} : {final}")
            return final
        except Exception as exc:
            # On NE revendique PAS PDF/A si on n'a pas pu le produire (pas d'annonce trompeuse).
            logger.error(f"PDF/A non produit ({exc}) — repli sur PDF simple non certifié.")

    # gs nécessaire aussi si un filigrane est demandé (même sans compression).
    if OPT_COMPRESS or wm:
        try:
            run_ghostscript(src_pdf, final, pdfa=False, downsample=OPT_COMPRESS, logger=logger, watermark_ps=wm)
            logger.info(f"PDF final{' compressé' if OPT_COMPRESS else ''}{' + filigrane' if wm else ''} : {final}")
            return final
        except Exception as exc:
            logger.error(f"Ghostscript échoué ({exc}) — copie brute.")

    shutil.copy(str(src_pdf), str(final))
    logger.info(f"PDF final : {final}")
    return final


# ─────────────────────────────────────────────────────────────
# NETTOYAGE TEMP
# ─────────────────────────────────────────────────────────────
def cleanup_temp(logger: logging.Logger):
    if TEMP_DIR.exists():
        for item in TEMP_DIR.iterdir():
            try:
                item.unlink()
            except Exception:
                pass


# ─────────────────────────────────────────────────────────────
# NOTIFICATION macOS
# ─────────────────────────────────────────────────────────────
def send_notification(title: str, message: str, success: bool, logger: logging.Logger):
    if not OPT_NOTIFY:
        return
    try:
        result = subprocess.run(["stat", "-f", "%Su", "/dev/console"],
                                capture_output=True, text=True, timeout=5)
        console_user = result.stdout.strip()
    except Exception:
        console_user = ""
    if not console_user or console_user == "root":
        return
    message_short = (message[:200] + "…") if len(message) > 200 else message
    icon = "✅" if success else "❌"
    body = f"{icon} {message_short}"
    # SÉCURITÉ : le message ET le titre (qui contient le nom de projet = nom de fichier, non maîtrisé)
    # sont passés en ARGUMENTS à osascript via `on run argv`, JAMAIS interpolés dans le source AppleScript.
    # Un nom de fichier contenant guillemets/« & »/« do shell script » ne peut donc pas injecter de code.
    osa = ('on run argv\n'
           'display notification (item 1 of argv) with title "ScanToPDF" subtitle (item 2 of argv)\n'
           'end run')
    try:
        uid = subprocess.run(["id", "-u", console_user], capture_output=True, text=True, timeout=5).stdout.strip()
        r = subprocess.run(["launchctl", "asuser", uid, "osascript", "-e", osa, body, title],
                           capture_output=True, text=True, timeout=10)
        if r.returncode != 0:
            logger.debug(f"Notification non émise (osascript rc={r.returncode}) : {r.stderr.strip()}")
    except Exception as exc:
        logger.debug(f"Notification échouée : {exc}")


# ─────────────────────────────────────────────────────────────
# PERMISSIONS — accès groupe staff
# ─────────────────────────────────────────────────────────────
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


# ─────────────────────────────────────────────────────────────
# EXPORT vers le NAS (priorité) ou le dossier Synology Drive (repli)
# ─────────────────────────────────────────────────────────────
def resolve_dir(base: Path, code: str, logger: logging.Logger) -> Path:
    """Sous-dossier de `base` correspondant au CODE : nom == code, ou code suivi d'un caractère NON
    alphanumérique (le suffixe textuel « Eg - Égypte » est ignoré, sans confondre « Eg » avec « Egypte »).
    Créé (nommé exactement `code`) s'il n'existe pas."""
    try:
        for child in sorted(base.iterdir()):
            if not child.is_dir():
                continue
            n = child.name
            if n == code or (n.startswith(code) and not n[len(code):len(code) + 1].isalnum()):
                return child
    except FileNotFoundError:
        pass
    d = base / code
    d.mkdir(parents=True, exist_ok=True)
    return d


def export_result(project_dir: Path, project_name: str, logger: logging.Logger):
    """Copie le dossier projet vers la destination, classé selon son nom (« Eg.w.O0.… » → Eg/w/O0/)."""
    if not OPT_EXPORT:
        return
    # Base : NAS SMB monté (/Volumes/<share>[/<subpath>]) en PRIORITÉ, sinon dossier Synology Drive.
    base = None
    if NAS_SHARE:
        nas = Path("/Volumes") / NAS_SHARE
        if NAS_SUBPATH:
            nas = nas / NAS_SUBPATH
        if nas.exists():
            base = nas
    if base is None and DRIVE_FOLDER and Path(DRIVE_FOLDER).exists():
        base = Path(DRIVE_FOLDER)
    if base is None:
        logger.warning("Export : destination indisponible (NAS non monté et dossier Synology Drive absent) — copie ignorée.")
        return
    # Arborescence : tous les segments SAUF le dernier sont des dossiers (Eg / w / O0), le reste déposé dedans.
    parts = project_name.split(".")
    codes = parts[:-1] if len(parts) >= 2 else []
    dest = base
    for code in codes:
        code = code.strip()
        if code:
            dest = resolve_dir(dest, code, logger)
    # Copie du dossier projet COMPLET. Anti-écrasement : versionne si déjà présent.
    target = dest / project_dir.name
    if target.exists():
        stamp = datetime.datetime.now().strftime("%Y%m%d_%H%M%S")
        target = dest / f"{project_dir.name}_{stamp}"
    r = subprocess.run(["/usr/bin/ditto", str(project_dir), str(target)],
                       capture_output=True, text=True, timeout=1800)
    if r.returncode == 0:
        logger.info(f"Export réussi → {target}")
    else:
        logger.error(f"Export échoué (ditto code {r.returncode}) vers {target} : {r.stderr.strip()[:200]}")


# ─────────────────────────────────────────────────────────────
# TRAITEMENT D'UN PROJET
# ─────────────────────────────────────────────────────────────
def process_project(project_name: str, source_files: list, logger: logging.Logger):
    logger.info(f"===== DÉBUT : {project_name} =====")
    project_dir = SCAN_DIR / project_name
    try:
        # VOIE UNIQUE — TIFF et PDF traités À L'IDENTIQUE : isolation des originaux → fusion → OCR →
        # finalisation PDF/A. Les originaux sont TOUJOURS conservés (sauf option « Supprimer les originaux »
        # activée, opt-in ci-dessous). Seule différence PDF : un original homonyme du résultat est renommé
        # « <projet>_original.pdf » (géré dans isolate_originals).
        project_dir, moved = isolate_originals(project_name, source_files, logger)
        is_pdf = all(p.suffix.lower() == ".pdf" for p in moved)
        if is_pdf:
            # PDF paginés d'un même document → fusionnés en un seul ; PDF autonome → tel quel.
            source = moved[0] if len(moved) == 1 else merge_pdfs(project_name, moved, logger)
        else:
            source = merge_tiffs(project_name, moved, logger)
        staged = run_ocr(source, project_name, logger)
        # finalize_pdf gère en un seul passage Ghostscript : compression @ DPI et/ou vrai PDF/A-2b.
        final_pdf = finalize_pdf(staged, project_name, project_dir, logger)

        # Suppression optionnelle des ORIGINAUX (opt-in EXPLICITE, OFF par défaut → aucune perte par
        # défaut). Supprime uniquement les originaux isolés (TIFF *et* PDF, à l'identique), JAMAIS le résultat.
        if OPT_DELETE:
            removed = 0
            for f in moved:
                try:
                    if f.exists() and f != final_pdf:
                        f.unlink(); removed += 1
                except Exception:
                    pass
            logger.info(f"{removed} original(aux) supprimé(s) (option « Supprimer les originaux » activée).")

        logger.info(f"✅ SUCCÈS : {project_name} → {final_pdf}")
        send_notification(project_name, f"PDF généré : {final_pdf.name}", True, logger)
        # Export vers le NAS / Synology Drive — best-effort : n'échoue JAMAIS le traitement local.
        try:
            export_result(project_dir, project_name, logger)
        except Exception as exc:
            logger.error(f"Export vers le NAS échoué : {exc}")
    except Exception as exc:
        logger.error(f"❌ ÉCHEC pour '{project_name}' : {exc}", exc_info=True)
        send_notification(project_name, str(exc), False, logger)
    finally:
        cleanup_temp(logger)
        if project_dir.exists():
            fix_permissions(project_dir, logger)
    logger.info(f"===== FIN : {project_name} =====")


# ─────────────────────────────────────────────────────────────
# POINT D'ENTRÉE
# ─────────────────────────────────────────────────────────────
def main():
    logger  = init_logging("scantopdf", "archivage", LOG_DIR)
    lock_fd = acquire_lock(logger)
    try:
        logger.info(f"ScanToPDF — surveillance : {SCAN_DIR}")
        groups = detect_and_group(logger)
        if not groups:
            logger.info("Aucun fichier TIFF/PDF à traiter.")
            return
        logger.info(f"{len(groups)} projet(s) à traiter.")
        for project_name, tiff_files in groups.items():
            process_project(project_name, tiff_files, logger)
        logger.info("Workflow terminé.")
    finally:
        release_lock(lock_fd, logger)


if __name__ == "__main__":
    main()
