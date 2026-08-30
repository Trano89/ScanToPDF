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
import time
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

# Filigrane apposé sur chaque page : TEXTE ou IMAGE (PNG…) au choix, avec placement, opacité et
# « en dur » (fusionné, non supprimable) vs calque OCG (masquable/supprimable dans un lecteur PDF).
OPT_WM       = bool(_CFG.get("watermarkEnabled", False))
WM_TYPE      = str(_CFG.get("watermarkType", "text")).strip().lower()
if WM_TYPE not in ("text", "image"):
    WM_TYPE = "text"
WM_TEXT      = str(_CFG.get("watermarkText", "")).strip()
WM_IMAGE     = Path(str(_CFG.get("watermarkImagePath", "")).strip()).expanduser()
WM_POS       = str(_CFG.get("watermarkPosition", "diagonal")).strip()
if WM_POS not in ("diagonal", "center", "top", "bottom", "tile"):
    WM_POS = "diagonal"
try:
    WM_OPACITY = max(0, min(100, int(_CFG.get("watermarkOpacity", 20))))
except (TypeError, ValueError):
    WM_OPACITY = 20
WM_HARD      = bool(_CFG.get("watermarkHard", True))
# Rien à apposer (texte vide / image absente) → filigrane désactivé plutôt qu'un passage gs inutile.
if WM_TYPE == "image":
    if not (str(WM_IMAGE) and WM_IMAGE.is_absolute() and WM_IMAGE.is_file()):
        OPT_WM = False
elif not WM_TEXT:
    OPT_WM = False

# Publication du résultat sur un LECTEUR RÉSEAU SMB monté — et rien d'autre. Sans lecteur monté, on
# ne publie pas : déposer un résultat ailleurs qu'à sa place définitive serait pire qu'un export différé.
OPT_EXPORT   = bool(_CFG.get("exportEnabled", False))
NAS_VOLUME   = str(_CFG.get("nasVolumePath", "")).strip().rstrip("/")
NAS_SUBPATH  = str(_CFG.get("nasSubpath", "")).strip().strip("/")

# Fiche archivistique ISAD(G) : après le PDF final, un LLM local (Ollama) résume le texte OCR en
# champs ISAD et écrit un « <nom>.txt » à côté du PDF. Opt-in, OFF par défaut. Ollama tourne hors de
# l'app : aucun binaire n'est bundlé, on n'appelle que l'API HTTP locale via la bibliothèque standard.
OPT_ISAD   = bool(_CFG.get("isadEnabled", False))
# Contexte du fonds transmis au modèle, ÉDITABLE dans les préférences (le défaut ci-dessous doit rester
# identique à celui de Config.swift). Sans lui, le modèle invente le sens des sigles : « FVJC » a déjà
# été développé en « Front des Veilleurs Juifs et Chrétiens ». Vide = aucun contexte transmis.
ISAD_CONTEXT_DEFAULT = """CONTEXTE DU FONDS

Les documents décrits proviennent des archives de la FVJC — Fédération vaudoise des jeunesses \
campagnardes. Dans ce fonds, le sigle « FVJC » désigne toujours cette fédération et jamais autre chose.

Fondée le 24 mai 1919 à Lausanne par 27 sociétés de jeunesse, la FVJC fédère les sociétés de jeunesse \
des villages du canton de Vaud, en Suisse romande, et compte aujourd'hui environ 190 sociétés membres. \
Sauf indication contraire explicite dans le document, les personnes, lieux et événements mentionnés se \
rapportent au canton de Vaud et à la Suisse romande, et la langue des documents est le français.

ORGANISATION DE LA FÉDÉRATION

- Bureau central : président, vice-présidents, caissier, secrétaire.
- Comité central : représentants de la fédération et des girons.
- Commissions spécialisées : ski, rallye, archives, jury, tir, entre autres.
- Girons, groupements régionaux réunissant les sociétés d'une région : giron du Nord, giron du Centre, \
giron du Pied du Jura, giron de la Broye.

MANIFESTATIONS RÉCURRENTES

- Assemblée générale annuelle, en janvier.
- Camp à ski, en février ; rallye, au week-end de Pentecôte ; tir cantonal, en septembre.
- Girons : quatre fêtes régionales réparties de juin à août.
- Cantonale : grande fête de la fédération, tous les cinq ans (centenaire à Savigny en 2019).
- Disciplines pratiquées : lutte, tir à la corde, athlétisme, cross, football, volley-ball, ski, \
snowboard, concours théâtral, rallye motorisé.

NATURE DES DOCUMENTS

Le fonds réunit des pièces produites ou reçues par la fédération, par ses girons et par les sociétés de \
jeunesse des villages : procès-verbaux d'assemblées et de comités, rapports d'activité, correspondance, \
statuts et règlements, programmes et brochures de manifestations, affiches, comptes et budgets, listes \
de membres, coupures de presse, photographies légendées. Les documents sont le plus souvent \
dactylographiés ou imprimés, parfois manuscrits.

VOCABULAIRE DU FONDS

- « jeunesse » ou « société de jeunesse » : association des jeunes d'un village.
- « giron » : groupement régional de sociétés de jeunesse, et par extension la fête qu'il organise.
- « cantonale » : grande manifestation réunissant l'ensemble de la fédération.
- « camping » : terrain d'hébergement des participants pendant une manifestation.
- « pense-bête » ou « annuaire » : brochure annuelle récapitulant l'organisation de la saison — mot du \
président, composition des organes, calendrier des manifestations, coordonnées des sociétés membres. \
Un document de ce type est une BROCHURE ANNUELLE, jamais un dossier de classement ni de la correspondance.
- « cortège », « bal », « cantine », « joutes », « comité », « caissier », « syndic », « commune » : \
termes d'organisation associative ou d'administration communale vaudoise, à conserver dans ce sens.

CONSIGNES DE DESCRIPTION

- Décris uniquement ce qui figure dans le texte fourni ; n'ajoute aucune connaissance extérieure.
- Ne développe JAMAIS un sigle qui ne t'est pas connu : recopie-le tel quel.
- Les noms de communes, de sociétés de jeunesse et de personnes sont des points d'accès précieux pour \
le catalogue : relève-les systématiquement, y compris lorsqu'ils figurent dans une liste ou un tableau.
- Le texte provient d'une reconnaissance optique et peut contenir des erreurs, des mots coupés ou des \
accents manquants : ignore les coquilles évidentes sans en altérer le sens.
- Ces notices alimentent un catalogue d'archives : reste factuel, neutre et concis, sans jugement de \
valeur ni tournure promotionnelle."""
ISAD_CONTEXT = str(_CFG.get("isadContext", ISAD_CONTEXT_DEFAULT)).strip()
ISAD_MODEL = str(_CFG.get("isadModel", "qwen3.5:9b")).strip() or "qwen3.5:9b"
# Contrôle de l'hôte Ollama. Le TEXTE INTÉGRAL du document lui est transmis : une adresse publique
# saisie par erreur ferait sortir le contenu des archives de la maison. On n'accepte donc que la
# machine elle-même ou le réseau privé (un Ollama hébergé sur un autre Mac du réseau reste possible).
_ISAD_LOCAL_HOSTS = {"localhost", "127.0.0.1", "::1", "[::1]"}


def _validate_isad_host(url: str) -> str:
    """Renvoie l'URL si son hôte est local ou privé, sinon une chaîne vide."""
    from urllib.parse import urlparse
    try:
        parsed = urlparse(url)
    except ValueError:
        return ""
    host = (parsed.hostname or "").lower()
    if parsed.scheme not in ("http", "https") or not host:
        return ""
    if host in _ISAD_LOCAL_HOSTS or host.startswith("127.") or host.endswith((".local", ".lan")):
        return url
    m = re.match(r"^(\d{1,3})\.(\d{1,3})\.", host)      # plages privées RFC 1918
    if m:
        a, b = int(m.group(1)), int(m.group(2))
        if a == 10 or (a == 192 and b == 168) or (a == 172 and 16 <= b <= 31):
            return url
    return ""


_ISAD_HOST_RAW = str(_CFG.get("isadHost", "http://localhost:11434")).strip().rstrip("/")
ISAD_HOST  = _validate_isad_host(_ISAD_HOST_RAW) or "http://localhost:11434"
# Le journal n'existe pas encore ici : on mémorise le rejet pour le signaler au démarrage du workflow.
_ISAD_HOST_REJECTED = _ISAD_HOST_RAW if (_ISAD_HOST_RAW and ISAD_HOST != _ISAD_HOST_RAW) else ""
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
# Plafond de la réponse. À 1500, les huit champs se disputaient le budget et la PORTÉE — le champ
# qui porte la description réelle — était la première rabotée. Valeur volontairement large : elle
# borne les dérives sans brider un document riche, et reste très en deçà de la fenêtre de contexte.
# Ce n'est PAS un dimensionnement tiré d'un échantillon de documents : c'est un garde-fou haut, que
# seuls les documents les plus fournis approcheront.
ISAD_MAX_TOKENS  = 8000
ISAD_START_WAIT  = 45       # secondes laissées à Ollama pour répondre après un démarrage automatique
ISAD_MIN_TEXT    = 400      # en deçà, l'OCR n'a rien rendu d'exploitable → la fiche est signalée comme fragile

# Ghostscript : binaire bundlé fourni par l'app (SCANTOPDF_GS), repli Homebrew.
if os.environ.get("SCANTOPDF_GS") and Path(os.environ["SCANTOPDF_GS"]).exists():
    GHOSTSCRIPT_BIN = os.environ["SCANTOPDF_GS"]
elif Path("/opt/homebrew/bin/gs").exists():
    GHOSTSCRIPT_BIN = "/opt/homebrew/bin/gs"
elif Path("/usr/local/bin/gs").exists():
    GHOSTSCRIPT_BIN = "/usr/local/bin/gs"
else:
    GHOSTSCRIPT_BIN = "gs"

# Règle de regroupement, IDENTIQUE pour les TIFF et les PDF : seul le DÉLIMITEUR marque une page.
# « Be.a.S1.1989_1-1.tiff », « -2 », « -3 » → projet « Be.a.S1.1989_1 », pages 1, 2, 3.
# « Be.a.S1.1989_1.tiff » (sans délimiteur) → projet « Be.a.S1.1989_1 », document d'une seule pièce.
# Tout ce qui précède le dernier délimiteur est la COTE et doit être conservé tel quel dans le nom du
# dossier et du PDF produit — le « _1 » y désigne le n° de document, pas un n° de page.
PAGE_DELIMITER    = re.escape(os.environ.get("SCANTOPDF_PAGE_DELIMITER", _CFG.get("pageDelimiter", "-")))
PAGE_PATTERN      = re.compile(
    rf"^(.+){PAGE_DELIMITER}(\d{{1,3}})\.(tif|tiff)$", re.IGNORECASE)
# PDF : pagination INDÉPENDANTE (le regroupement TIFF reste inchangé). Seul le DÉLIMITEUR marque une
# page (« Dz.a.Y2.2017_2-1.pdf » → projet « Dz.a.Y2.2017_2 », page 1) : le séparateur appartient à la
# COTE (« _2 » = 2ᵉ document de la cote), il ne doit donc PAS être pris pour un numéro de page — sinon
# « Dz.a.Y2.2017_2.pdf » devient à tort la page 2 de « Dz.a.Y2.2017 » et le « _2 » disparaît du résultat.
# Sans délimiteur (ex. « Rapport.pdf », « Dz.a.Y2.2017_2.pdf ») → PDF autonome, cote conservée telle quelle.
PDF_PAGE_PATTERN = re.compile(
    rf"^(.+){PAGE_DELIMITER}(\d{{1,3}})\.pdf$", re.IGNORECASE)


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
        if entry.suffix.lower() not in (".tif", ".tiff"):
            continue
        # Même règle que pour les PDF : délimiteur = page, sinon document d'une seule pièce. Un TIFF
        # sans numéro n'est plus IGNORÉ en silence (il l'était : il ne ressortait jamais du dossier).
        page_match = PAGE_PATTERN.match(entry.name)
        if page_match:
            project_name = page_match.group(1).strip()
            page_num     = int(page_match.group(2))
        else:
            project_name = entry.stem.strip()
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
    # Le dossier de travail n'était créé que par les fonctions de FUSION. Sur le chemin « un seul PDF »
    # il n'y a pas de fusion : sur une installation neuve, ocrmypdf échouait donc à écrire sa sortie
    # (« Output file location is not a writable file ») et le repli livrait un PDF SANS couche texte.
    TEMP_DIR.mkdir(parents=True, exist_ok=True)
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
            # Repli utile (mieux vaut un PDF qu'aucun résultat), mais il doit être VISIBLE : sans
            # couche texte, le document n'est pas cherchable et aucune fiche ISAD ne pourra être écrite.
            logger.warning("Repli : PDF finalisé SANS couche texte — document non cherchable et "
                           "fiche ISAD impossible. Corrigez la cause ci-dessus puis retraitez.")
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


def _wm_endpage(prelude: str, body: str, hard: bool) -> str:
    """Assemble le PostScript du filigrane : préambule + calque OCG éventuel + hook EndPage (exécuté
    sur CHAQUE page). Commun aux filigranes TEXTE et IMAGE.
    hard=False → le filigrane est placé dans un calque OCG « Filigrane » (masquable/supprimable)."""
    ocg_reg = oc_begin = oc_end = ""
    if not hard:
        ocg_reg = ("[ /_objdef {oc_wm} /type /dict /OBJ pdfmark "
                   "[ {oc_wm} << /Type /OCG /Name (Filigrane) >> /PUT pdfmark "
                   "[ {Catalog} << /OCProperties << /OCGs [ {oc_wm} ] /D << /ON [ {oc_wm} ] >> >> >> /PUT pdfmark ")
        oc_begin = "[ /OC {oc_wm} /BDC pdfmark "
        oc_end = "[ /EMC pdfmark "
    endpage = ("<< /EndPage { exch pop 0 eq { gsave "
               "currentpagedevice /PageSize get aload pop /ph exch def /pw exch def "
               + oc_begin + body + oc_end +
               "grestore true }{ false } ifelse } bind >> setpagedevice ")
    return prelude + ocg_reg + endpage


def _watermark_text_ps(text: str, position: str, opacity: int, hard: bool):
    """Filigrane TEXTE : Helvetica ISOLatin1 auto-dimensionnée ; l'opacité est rendue par le niveau de
    gris (PostScript n'expose pas d'alpha réel dans ce contexte)."""
    txt = _ps_escape(text or "")
    if not txt.strip():
        return None
    gray = max(0.0, min(1.0, 1.0 - float(opacity) / 100.0))   # opacité 20 → gris 0.80 (léger)

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
    return _wm_endpage(fontdef, ("%.3f setgray " % gray) + body, hard)


def _wm_image_data(path: Path, opacity: int):
    """Prépare l'image du filigrane → (largeur, hauteur, pixels RGB, masque 1 bit).
    Transparence : masque 1 bit — les pixels transparents ne sont PAS peints (le document reste lisible).
    Opacité : fondu vers le blanc (comme le filigrane texte module son gris).
    Réduction : borne le volume de données embarqué dans le PostScript."""
    with Image.open(path) as src:
        im = src.convert("RGBA")
        maxdim = 1400
        if max(im.size) > maxdim:
            r = maxdim / float(max(im.size))
            im = im.resize((max(1, int(im.width * r)), max(1, int(im.height * r))), Image.LANCZOS)
        alpha = im.getchannel("A")
        blend = alpha.point(lambda v: int(v * opacity / 100.0))
        rgb = Image.composite(im.convert("RGB"), Image.new("RGB", im.size, "white"), blend)
        # Bit à 1 = pixel NON peint (transparent) — convention ImageType 3 avec /Decode [0 1].
        mask = alpha.point(lambda v: 255 if v <= 8 else 0).convert("1", dither=Image.Dither.NONE)
        return im.width, im.height, rgb.tobytes(), mask.tobytes()


def _wm_a85(data: bytes) -> str:
    """Compresse (Flate) puis encode en ASCII85 pour intégration dans le PostScript. Le préfixe « <~ »
    d'Adobe est retiré : l'ASCII85Decode de PostScript ne l'attend pas."""
    import zlib
    import base64
    s = base64.a85encode(zlib.compress(data, 9), adobe=True, wrapcol=120).decode("ascii")
    return s[2:] if s.startswith("<~") else s


def _watermark_image_ps(path: Path, position: str, opacity: int, hard: bool):
    """Filigrane IMAGE (PNG…) : image + masque de transparence (ImageType 3) dessinés sur chaque page.
    Les données sont incluses en UN seul flux (image et masque concaténés) puis découpées par
    getinterval — un seul flux inline = aucun problème de positionnement dans le fichier PostScript."""
    try:
        w, h, rgb, mask = _wm_image_data(path, opacity)
    except Exception:
        return None
    if w < 1 or h < 1:
        return None
    prelude = (
        "/wmW %d def /wmH %d def /wmAR %.6f def /wmRGBLen %d def /wmMskLen %d def "
        % (w, h, w / float(h), len(rgb), len(mask))
        + "/wmAll wmRGBLen wmMskLen add string def\n"
        "{ currentfile /ASCII85Decode filter /FlateDecode filter wmAll readstring pop pop } exec\n"
        + _wm_a85(rgb + mask) + "\n"
        "/wmData wmAll 0 wmRGBLen getinterval def "
        "/wmMask wmAll wmRGBLen wmMskLen getinterval def "
        "/wmDraw { /DeviceRGB setcolorspace << /ImageType 3 /InterleaveType 3 "
        "/DataDict << /ImageType 1 /Width wmW /Height wmH /BitsPerComponent 8 /Decode [0 1 0 1 0 1] "
        "/ImageMatrix [wmW 0 0 wmH neg 0 wmH] /DataSource wmData >> "
        "/MaskDict << /ImageType 1 /Width wmW /Height wmH /BitsPerComponent 1 /Decode [0 1] "
        "/ImageMatrix [wmW 0 0 wmH neg 0 wmH] /DataSource wmMask >> >> image } bind def "
    )
    # Taille cible : largeur en fraction de page, hauteur plafonnée — rapport d'aspect conservé.
    frac_w, frac_h = {"diagonal": (0.90, 0.60), "center": (0.85, 0.60), "top": (0.85, 0.12),
                      "bottom": (0.85, 0.12), "tile": (0.28, 0.20)}.get(position, (0.90, 0.60))
    size = ("/tw pw %.3f mul def /th tw wmAR div def "
            "th ph %.3f mul gt { /th ph %.3f mul def /tw th wmAR mul def } if "
            % (frac_w, frac_h, frac_h))
    if position == "center":
        body = size + "pw 2 div tw 2 div sub ph 2 div th 2 div sub translate tw th scale wmDraw "
    elif position == "top":
        body = size + "pw 2 div tw 2 div sub ph 0.93 mul th 2 div sub translate tw th scale wmDraw "
    elif position == "bottom":
        body = size + "pw 2 div tw 2 div sub ph 0.07 mul th 2 div sub translate tw th scale wmDraw "
    elif position == "tile":
        body = size + ("0 1 3 { /iy exch def 0 1 2 { /ix exch def gsave "
                       "pw ix mul 3 div pw 6 div add ph iy mul 4 div ph 8 div add translate 30 rotate "
                       "tw 2 div neg th 2 div neg translate tw th scale wmDraw grestore } for } for ")
    else:  # diagonal
        body = size + ("pw 2 div ph 2 div translate 45 rotate "
                       "tw 2 div neg th 2 div neg translate tw th scale wmDraw ")
    return _wm_endpage(prelude, body, hard)


def _watermark_ps():
    """PostScript du filigrane selon la configuration (texte OU image), None si rien à apposer."""
    if not OPT_WM:
        return None
    if WM_TYPE == "image":
        return _watermark_image_ps(WM_IMAGE, WM_POS, WM_OPACITY, WM_HARD)
    return _watermark_text_ps(WM_TEXT, WM_POS, WM_OPACITY, WM_HARD)


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
    cmd += [f"-sOutputFile={out_pdf}", "-f"]     # -f : ce qui suit sont des fichiers
    TEMP_DIR.mkdir(parents=True, exist_ok=True)  # requis même sans fusion (PDF seul) pour les .ps générés
    if pdfa:
        icc = _srgb_icc()
        if not icc:
            raise RuntimeError("Profil ICC sRGB introuvable (PDF/A impossible).")
        cmd.append(str(_write_pdfa_def(icc)))   # doit précéder le PDF source
    # Filigrane : PostScript exécuté AVANT le PDF source (installe le hook EndPage). Écrit dans un
    # FICHIER plutôt que passé en « -c » : un filigrane image dépasse la taille maximale d'un argument.
    if watermark_ps:
        wm_file = TEMP_DIR / "watermark.ps"
        wm_file.write_text(watermark_ps, encoding="latin-1")
        cmd.append(str(wm_file))
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
    wm = _watermark_ps()

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
    """Vide le dossier de travail. Les SOUS-DOSSIERS étaient ignorés (unlink échoue sur un dossier,
    l'erreur était avalée) : un répertoire laissé par un outil interrompu s'accumulait indéfiniment."""
    if not TEMP_DIR.exists():
        return
    for item in TEMP_DIR.iterdir():
        try:
            if item.is_dir() and not item.is_symlink():
                shutil.rmtree(item, ignore_errors=True)
            else:
                item.unlink()
        except Exception as exc:
            logger.debug(f"Nettoyage : « {item.name} » non supprimé ({exc}).")


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
    # Une notification s'affiche à l'écran, visible de quiconque passe : on n'y laisse aucun chemin
    # absolu. Le message de succès ne porte déjà que le nom du fichier, mais un message d'ERREUR peut
    # charrier le chemin complet du dossier de travail — on le réduit à son dernier segment.
    message = re.sub(r"(?:/[^\s'\"]+)+/([^/\s'\"]+)", r"\1", message)
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
        # Le groupe « staff » (tous les comptes locaux) garde la LECTURE, comme prévu par le partage ;
        # on retire en revanche l'écriture au groupe et tout accès aux autres — des archives n'ont pas
        # à être lisibles au-delà des comptes de la machine, notamment si le dossier part sur un partage.
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
    """Copie le dossier projet sur le lecteur réseau, classé selon son nom (« Eg.w.O0.… » → Eg/w/O0/)."""
    if not OPT_EXPORT:
        return
    # Destination : le lecteur réseau retenu, obligatoirement MONTÉ. Aucun repli local.
    if not NAS_VOLUME:
        logger.warning("Publication : aucun lecteur réseau choisi — copie ignorée.")
        return
    volume = Path(NAS_VOLUME)
    if not volume.is_dir():
        logger.warning(f"Publication : lecteur « {NAS_VOLUME} » non monté — copie ignorée. "
                       f"Le résultat reste dans le dossier surveillé.")
        return
    base = volume / NAS_SUBPATH if NAS_SUBPATH else volume
    if not base.is_dir():
        logger.warning(f"Publication : sous-dossier « {NAS_SUBPATH} » absent du lecteur — copie ignorée.")
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
# FICHE ISAD(G) — extraction du texte OCR + résumé par LLM local (Ollama)
# ─────────────────────────────────────────────────────────────
def _normalize_text(text: str) -> str:
    """Compacte le texte extrait. Le rendu texte d'un PDF numérisé est massivement fait d'espaces de
    positionnement : jusqu'à 97,5 % du volume sur ce fonds (1 807 213 caractères pour 64 994 utiles).
    Sans compactage, le budget envoyé au modèle part en blancs — environ mille caractères de texte réel
    sur quarante mille — et la fiche se retrouve sans matière à décrire."""
    text = text.replace("\r", "\n")
    text = re.sub(r"[ \t   ]+", " ", text)   # suites d'espaces → un seul
    text = re.sub(r" *\n *", "\n", text)                     # espaces en bord de ligne
    text = re.sub(r"\n{3,}", "\n\n", text)                   # lignes vides en série
    return text.strip()


def _text_is_usable(text: str) -> bool:
    """Le texte extrait est-il RÉELLEMENT lisible ? Quand la police embarquée n'expose pas de table
    ToUnicode, un extracteur peut rendre « (cid:83)(cid:111)… » là où il y a « Sommaire » : du charabia,
    illisible pour un humain comme pour un modèle — qui se rabat alors sur le contexte et décrit
    n'importe quoi. On mesure donc la lisibilité avant de transmettre quoi que ce soit."""
    if not text or len(text.strip()) < 200:
        return False
    if text.count("(cid:") > 20:                       # codes de glyphes non résolus
        return False
    if sum(1 for c in text if c.isalpha() or c.isspace()) / len(text) < 0.6:
        return False
    words = text.split()
    return not words or sum(len(w) for w in words) / len(words) <= 25


def _extract_with_ghostscript(pdf_path: Path, logger: logging.Logger) -> str:
    """Ghostscript txtwrite : toujours bundlé, et fiable sur les PDF que l'application produit."""
    try:
        TEMP_DIR.mkdir(parents=True, exist_ok=True)
        out_txt = TEMP_DIR / f"{pdf_path.stem}_ocrtext.txt"
        r = subprocess.run(
            [GHOSTSCRIPT_BIN, "-dBATCH", "-dNOPAUSE", "-dQUIET",
             "-sDEVICE=txtwrite", f"-sOutputFile={out_txt}", str(pdf_path)],
            capture_output=True, text=True, timeout=300)
        if r.returncode == 0 and out_txt.exists():
            return out_txt.read_text(encoding="utf-8", errors="replace")
        logger.debug(f"Ghostscript txtwrite rc={r.returncode} : {r.stderr.strip()[:200]}")
    except Exception as exc:
        logger.debug(f"Extraction texte (Ghostscript) échouée : {exc}")
    return ""


def _extract_with_pdfminer(pdf_path: Path, logger: logging.Logger) -> str:
    """pdfminer.six, s'il est présent. Utilisé en REPLI seulement : sur les PDF de ce pipeline il rend
    fréquemment les codes de glyphes bruts au lieu du texte."""
    try:
        from pdfminer.high_level import extract_text  # type: ignore
        return extract_text(str(pdf_path)) or ""
    except Exception as exc:
        logger.debug(f"pdfminer indisponible ou échec : {exc}")
        return ""


def extract_pdf_text(pdf_path: Path, logger: logging.Logger) -> str:
    """Texte de la couche OCR du PDF final, avec contrôle de LISIBILITÉ. Retourne '' si rien
    d'exploitable (PDF purement image sans OCR) — l'appelant ne produira alors pas de fiche."""
    candidates = [("Ghostscript", _normalize_text(_extract_with_ghostscript(pdf_path, logger)))]
    if _text_is_usable(candidates[0][1]):
        logger.info(f"Texte du document extrait par Ghostscript ({len(candidates[0][1])} caractères utiles).")
        return candidates[0][1]
    logger.info("Extraction Ghostscript inexploitable — essai de pdfminer.")
    candidates.append(("pdfminer", _normalize_text(_extract_with_pdfminer(pdf_path, logger))))
    for name, txt in candidates:
        if _text_is_usable(txt):
            logger.info(f"Texte du document extrait par {name} ({len(txt)} caractères).")
            return txt
    # Aucun extracteur lisible : on renvoie le plus long, l'appelant jugera (peut rester vide).
    best = max((t for _, t in candidates), key=len, default="")
    if best.strip():
        logger.warning("Texte extrait peu lisible (police sans table ToUnicode ?) — "
                       "la fiche ISAD risque d'être imprécise.")
    return best


def _pdf_creation_date(pdf_path: Path, logger: logging.Logger) -> str:
    """Date de création inscrite dans les métadonnées du PDF (« D:20170315… » → « 2017-03-15 »).
    RÉSERVÉE aux documents dont la source est déjà un PDF : pour un TIFF, cette date serait celle de
    la NUMÉRISATION, pas celle du document — elle induirait l'archiviste en erreur."""
    raw = ""
    try:
        import pikepdf
        with pikepdf.Pdf.open(str(pdf_path)) as pdf:
            raw = str(pdf.docinfo.get("/CreationDate", "") or "") if pdf.docinfo else ""
            if not raw:
                # Beaucoup de PDF récents ne portent leur date que dans les métadonnées XMP.
                try:
                    with pdf.open_metadata() as meta:
                        raw = str(meta.get("xmp:CreateDate", "") or "")
                except Exception:
                    raw = ""
    except Exception as exc:
        logger.debug(f"Métadonnées PDF illisibles ({pdf_path.name}) : {exc}")
        return ""
    # « D:20170710080542+02'00' » comme « 2017-07-10T08:05:42+02:00 »
    m = re.match(r"^D?:?\s*(\d{4})-?(\d{2})-?(\d{2})", raw)
    if not m:
        return ""
    year, month, day = (int(g) for g in m.groups())
    if not (1500 <= year <= 2200 and 1 <= month <= 12 and 1 <= day <= 31):
        return ""
    return f"{year:04d}-{month:02d}-{day:02d}"


def _ollama_alive(timeout: float = 2.0) -> bool:
    import urllib.request
    try:
        with urllib.request.urlopen(f"{ISAD_HOST}/api/tags", timeout=timeout) as resp:
            return resp.status == 200
    except Exception:
        return False


def ensure_ollama(logger: logging.Logger) -> bool:
    """S'assure qu'Ollama tourne, et le DÉMARRE sinon (app Ollama du Mac, sinon binaire « ollama serve »).
    Uniquement pour un serveur LOCAL : une adresse distante appartient à une autre machine, on ne tente
    jamais d'y lancer quoi que ce soit. Best-effort : un échec n'empêche pas la production du PDF."""
    if _ollama_alive():
        return True
    if not any(h in ISAD_HOST for h in ("localhost", "127.0.0.1", "[::1]")):
        logger.warning(f"Ollama distant injoignable ({ISAD_HOST}) — fiche ISAD ignorée.")
        return False

    launched = False
    app = Path("/Applications/Ollama.app")
    if app.is_dir():
        try:
            subprocess.run(["/usr/bin/open", "-a", str(app)], capture_output=True, timeout=30)
            launched = True
        except Exception as exc:
            logger.debug(f"Lancement de Ollama.app échoué : {exc}")
    if not launched:
        for cand in ("/usr/local/bin/ollama", "/opt/homebrew/bin/ollama",
                     "/Applications/Ollama.app/Contents/Resources/ollama"):
            if os.access(cand, os.X_OK):
                try:
                    # start_new_session : le serveur survit à la fin du workflow (il sert aux suivants).
                    subprocess.Popen([cand, "serve"], stdout=subprocess.DEVNULL,
                                     stderr=subprocess.DEVNULL, start_new_session=True)
                    launched = True
                    break
                except Exception as exc:
                    logger.debug(f"Lancement de « {cand} serve » échoué : {exc}")
    if not launched:
        logger.warning("Ollama introuvable sur ce Mac (ni app ni binaire) — fiche ISAD ignorée.")
        return False

    logger.info("Ollama n'était pas démarré — lancement automatique…")
    deadline = time.monotonic() + ISAD_START_WAIT
    while time.monotonic() < deadline:
        if _ollama_alive(1.5):
            logger.info("Ollama est prêt.")
            return True
        time.sleep(1.0)
    logger.warning(f"Ollama n'a pas répondu dans les {ISAD_START_WAIT} s — fiche ISAD ignorée.")
    return False


PAPER_FORMATS = (("A3", 29.7, 42.0), ("A4", 21.0, 29.7), ("A5", 14.8, 21.0),
                 ("Letter", 21.6, 27.9), ("Legal", 21.6, 35.6))


def _pdf_extent(pdf_path: Path, from_pdf: bool) -> tuple:
    """(nombre de pages, dimensions) du PDF final. Le nombre de pages est toujours sûr.
    Les DIMENSIONS ne le sont pas : les images de ce fonds sont photographiées et ne portent aucune
    résolution, si bien que la page du PDF mesure « 29,3 × 43,9 cm » — un format qui n'existe pas.
    On ne transmet donc une dimension que si elle est CRÉDIBLE : source déjà en PDF, ou correspondance
    avec un format papier courant. Mieux vaut une notice muette qu'une notice fausse."""
    try:
        import pikepdf
        with pikepdf.Pdf.open(str(pdf_path)) as pdf:
            pages = len(pdf.pages)
            box = pdf.pages[0].mediabox
            w = (float(box[2]) - float(box[0])) / 72 * 2.54
            h = (float(box[3]) - float(box[1])) / 72 * 2.54
    except Exception:
        return 0, ""
    fmt = next((n for n, a, b in PAPER_FORMATS if abs(w - a) < 1.0 and abs(h - b) < 1.0), "")
    if not (from_pdf or fmt):
        return pages, ""
    size = f"{w:.1f} × {h:.1f} cm".replace(".", ",")
    return pages, f"{size} ({fmt})" if fmt else size


def _isad_sample(text: str, budget: int) -> str:
    """Échantillon REPRÉSENTATIF du document. Tronquer au début fait manquer tout ce qui suit : dans
    une brochure, les listes de sociétés, de communes et de personnes se trouvent au milieu et à la fin
    (5 des 7 lieux attendus étaient au-delà de la limite). On prélève donc des extraits répartis."""
    text = text.strip()
    if len(text) <= budget:
        return text
    head = budget // 3                       # le début porte le titre et la nature du document
    chunks = 8
    size = (budget - head) // chunks
    step = max(1, (len(text) - head) // chunks)
    parts = [text[:head]]
    for i in range(chunks):
        start = head + i * step
        parts.append(text[start:start + size])
    return "\n[…]\n".join(parts)


def _isad_prompt(ocr_text: str, project_name: str, fallback_date: str = "",
                 facts: dict | None = None) -> str:
    """Prompt en français pour un modèle généraliste (Qwen). Consignes STRICTES : sortie en champs
    fixes, une seule date ou une plage AAAA-MM-JJ, pas d'invention (le bénévole doit pouvoir se fier
    à la fiche). On demande peu de champs pour ne pas surcharger la saisie ultérieure dans AtoM."""
    snippet = _isad_sample(ocr_text, ISAD_MAX_CHARS)
    # Données MESURÉES sur le fichier : le modèle ne doit pas les inventer, il doit les recopier.
    facts = facts or {}
    lines = [f"- Cote : {project_name}"]
    if facts.get("support"):
        lines.append(f"- Support : {facts['support']}")
    if facts.get("pages"):
        lines.append(f"- Nombre de pages : {facts['pages']}")
    if facts.get("size"):
        lines.append(f"- Format des pages : {facts['size']}")
    else:
        lines.append("- Format des pages : non mesurable (numérisation sans résolution fiable) — "
                     "n'indique AUCUNE dimension dans la fiche.")
    if fallback_date:
        lines.append(f"- Date de création du fichier d'origine : {fallback_date}")
    facts_block = ("DONNÉES FACTUELLES (mesurées sur le fichier — reprends-les telles quelles, "
                   "ne les contredis pas) :\n" + "\n".join(lines) + "\n\n")
    # Date de repli : proposée au modèle SEULEMENT si le document lui-même n'en porte aucune.
    date_fallback = (
        f"Si le TEXTE OCR ne porte AUCUNE date, et seulement dans ce cas, utilise la date de création "
        f"du fichier d'origine : {fallback_date}.\n" if fallback_date else "")
    # ORDRE DU PROMPT — il est déterminant. Le contexte du fonds, court et bien structuré, captait
    # l'attention du modèle au détriment du document : la fiche paraphrasait le contexte (« listes de
    # membres, coupures de presse… ») au lieu de décrire la pièce. On place donc le contexte en amont
    # comme simple aide, le DOCUMENT juste avant la tâche, et les consignes EN DERNIER — c'est ce que
    # le modèle a le plus « frais » au moment de rédiger.
    return (
        "Tu es archiviste. Tu dois décrire UN document précis, fourni plus bas.\n\n"
        + ("<<< CONTEXTE DU FONDS — aide à l'interprétation UNIQUEMENT >>>\n"
           "Ce contexte explique les sigles, l'organisation et le vocabulaire du fonds. Il ne décrit "
           "PAS le document à décrire et ne doit JAMAIS servir de source : n'y puise aucun élément de "
           "description, ne recopie pas ses exemples comme s'ils figuraient dans le document.\n\n"
           + ISAD_CONTEXT + "\n<<< FIN DU CONTEXTE >>>\n\n" if ISAD_CONTEXT else "")
        + facts_block
        + "<<< TEXTE DU DOCUMENT À DÉCRIRE (issu de la reconnaissance optique) >>>\n"
        + snippet
        + "\n<<< FIN DU DOCUMENT >>>\n\n"
        "TÂCHE : rédige la fiche descriptive de CE document selon la norme ISAD(G), en français, "
        "factuelle et concise.\n"
        "Règles impératives :\n"
        "- Tout ce que tu écris doit provenir du TEXTE DU DOCUMENT ci-dessus ou des DONNÉES FACTUELLES.\n"
        "- N'invente rien : si une information est absente ou illisible, écris « Inconnu ».\n"
        "- N'emploie un terme du contexte que s'il figure réellement dans le document.\n"
        "- Réponds UNIQUEMENT avec les champs ci-dessous, dans cet ordre exact, chacun sur sa ou ses "
        "lignes, sans commentaire ni Markdown.\n\n"
        "DATE: date de création du document. Cherche-la PARTOUT : page de titre, en-tête, pied de page, "
        "signature, mention d'achèvement, colophon — et en toutes lettres autant qu'en chiffres "
        "(« février 2015 », « le 12 mars 1989 »). Écris AAAA-MM-JJ si le jour est connu, AAAA-MM si "
        "seuls le mois et l'année le sont, AAAA si seule l'année l'est, ou une plage "
        "« AAAA-MM-JJ - AAAA-MM-JJ » si le document couvre plusieurs dates. N'INVENTE JAMAIS une "
        "composante absente : pas de jour pour un « février 2015 », pas de mois pour une simple année. "
        "Aucune date dans le document → « Inconnu ».\n"
        + date_fallback +
        "ETENDUE: étendue et support (ISAD 3.1.5). Reprends OBLIGATOIREMENT le nombre de pages des "
        "DONNÉES FACTUELLES, sous la forme « <nature du document> de N pages », suivi du format "
        "UNIQUEMENT s'il y est fourni (ex. « 1 brochure de 18 pages, 21,0 × 29,7 cm »). Si le format "
        "est annoncé non mesurable, n'invente aucune dimension.\n"
        "HISTOIRE: histoire archivistique (ISAD 3.2.3) : origine, producteur, contexte de création. "
        "2 à 4 phrases.\n"
        "PORTEE: portée et contenu (ISAD 3.3.1) : de quoi traite CE document. C'est le champ le plus "
        "important de la fiche — développe-le autant que le document le justifie, sans le résumer à "
        "l'excès. Décris les parties et rubriques, les thèmes traités, les types de pièces qu'il "
        "contient, les points saillants relevés dans son texte. Un document riche mérite plusieurs "
        "paragraphes, séparés par une ligne vide ; pour un document mince, quelques phrases suffisent. "
        "PROPORTIONNE la description à l'ampleur du document : un dossier de plusieurs dizaines de "
        "pages demande une description longue et structurée, partie par partie, qui permette de savoir "
        "ce qu'il contient sans l'ouvrir. N'abrège pas pour faire court.\n"
        "SUJETS: AU PLUS QUATRE mots-clés thématiques, séparés par des virgules, du plus important au "
        "moins important. Choisis ceux par lesquels un archiviste CHERCHERAIT ce document ; ce ne sont "
        "pas des étiquettes à accumuler. Un terme qui conviendrait à n'importe quel document du fonds "
        "n'apprend rien : écarte-le.\n"
        "LIEUX: AU PLUS TROIS lieux, séparés par des virgules — celui de l'ORGANISATION qui produit le "
        "document et, le cas échéant, celui où se déroule ce dont il traite. N'énumère PAS toutes les "
        "communes citées au fil du texte : une liste de villages ne sert pas à retrouver la pièce. "
        "N'indique QUE des noms LITTÉRALEMENT présents dans le texte du document : ne complète jamais "
        "par des communes plausibles ou connues par ailleurs. Aucun lieu pertinent → « Inconnu ».\n"
        "GENRE: AU PLUS QUATRE types documentaires, séparés par des virgules — la NATURE matérielle du "
        "document (ex. brochure, portfolio, procès-verbal, correspondance, photographie), pas son sujet.\n"
        "MATIERES: AU PLUS TROIS entités nommées, séparées par des virgules — organisations, "
        "manifestations ou institutions dont le document traite VRAIMENT, non celles simplement "
        "mentionnées en passant.\n"
    )


def _ollama_generate(prompt: str, logger: logging.Logger) -> str:
    """Appelle l'API Ollama locale (/api/generate, stream désactivé) via la bibliothèque standard.
    Aucune dépendance externe : l'app ne bundle pas Ollama, elle interroge un service local déjà lancé
    par l'utilisateur. Retourne le texte généré, ou '' en cas d'échec (best-effort)."""
    import urllib.request
    import urllib.error
    if not ensure_ollama(logger):     # démarre Ollama s'il est local et arrêté
        return ""
    url = f"{ISAD_HOST}/api/generate"

    def _post(body: dict) -> str:
        req = urllib.request.Request(url, data=json.dumps(body).encode("utf-8"),
                                     headers={"Content-Type": "application/json"}, method="POST")
        with urllib.request.urlopen(req, timeout=ISAD_TIMEOUT) as resp:
            data = json.loads(resp.read().decode("utf-8", errors="replace"))
        # Nombre RÉEL de jetons du prompt : seul moyen de savoir si la fenêtre a suffi (une troncature
        # côté Ollama est silencieuse et donne une fiche qui décrit un document vu en morceaux).
        used = int(data.get("prompt_eval_count", 0) or 0)
        ctx = int(body.get("options", {}).get("num_ctx", 0) or 0)
        if used and ctx and used >= ctx:
            logger.warning(f"Fiche ISAD : prompt de {used} jetons pour une fenêtre de {ctx} — "
                           f"le document a pu être tronqué.")
        elif used:
            logger.info(f"Fiche ISAD : {used} jetons de prompt (fenêtre {ctx}).")
        return str(data.get("response", "")).strip()

    num_ctx = ISAD_CTX
    body = {
        "model": ISAD_MODEL,
        "prompt": prompt,
        "stream": False,
        # Modèles à RÉFLEXION (Qwen 3.5…) : sans cette clé ils produisent des milliers de jetons de
        # raisonnement avant de répondre et dépassent le délai — inutile pour une fiche factuelle.
        "think": False,
        # Réglages d'EXTRACTION, pas de rédaction créative. On neutralise explicitement les pénalités
        # du modèle : certains Modelfile imposent presence_penalty 1.5, qui pousse à produire des mots
        # NOUVEAUX — exactement le contraire de ce qu'on veut (le modèle inventait des communes).
        "options": {"temperature": 0.1, "num_ctx": num_ctx, "top_p": 0.9, "top_k": 40,
                    "presence_penalty": 0, "frequency_penalty": 0, "repeat_penalty": 1.0,
                    "num_predict": ISAD_MAX_TOKENS},
    }
    logger.info(f"Fiche ISAD : {len(prompt)} caractères envoyés, fenêtre de contexte {num_ctx} jetons.")
    try:
        return _post(body)
    except urllib.error.HTTPError as exc:
        # 400 : un modèle sans mode « réflexion » peut refuser la clé « think » → réessai sans elle.
        if exc.code == 400:
            body.pop("think", None)
            try:
                return _post(body)
            except Exception as exc2:
                logger.warning(f"Appel Ollama échoué — fiche ISAD ignorée : {exc2}")
                return ""
        # Ollama répond mais rejette la demande (404 = modèle non installé, à « pull » au préalable).
        logger.warning(f"Ollama a refusé la requête (HTTP {exc.code}) — modèle « {ISAD_MODEL} » "
                       f"installé ? Fiche ISAD ignorée.")
    except urllib.error.URLError as exc:
        logger.warning(f"Ollama injoignable ({ISAD_HOST}) — fiche ISAD ignorée : {exc}")
    except Exception as exc:
        logger.warning(f"Appel Ollama échoué — fiche ISAD ignorée : {exc}")
    return ""


# Champs de la fiche : clé demandée au modèle, intitulé lisible, référence ISAD(G).
ISAD_FIELDS = (
    ("DATE",     "DATE DU DOCUMENT",        "ISAD 3.1.3"),
    ("ETENDUE",  "ÉTENDUE ET SUPPORT",      "ISAD 3.1.5"),
    ("HISTOIRE", "HISTOIRE ARCHIVISTIQUE",  "ISAD 3.2.3"),
    ("PORTEE",   "PORTÉE ET CONTENU",       "ISAD 3.3.1"),
    ("GENRE",    "TYPE DOCUMENTAIRE",       ""),
    ("SUJETS",   "MOTS-CLÉS — SUJETS",      ""),
    ("LIEUX",    "MOTS-CLÉS — LIEUX",       ""),
    ("MATIERES", "POINTS D'ACCÈS MATIÈRES", ""),
)
# Le GENRE devient une liste : c'est un type documentaire, souvent multiple (« brochure, portfolio »).
ISAD_LIST_FIELDS = {"SUJETS", "LIEUX", "MATIERES", "GENRE"}   # rendus en liste, un terme par ligne
# Un mot-clé n'a d'intérêt que s'il permet de RETROUVER le document. Une notice de 41 sujets et
# 23 lieux ne se cherche plus, elle se subit : au-delà de quelques termes bien choisis, chaque ajout
# dilue les précédents. Ces plafonds sont appliqués APRÈS le modèle, qui ne respecte pas
# systématiquement une consigne de nombre.
ISAD_MAX_TERMS = {"SUJETS": 4, "LIEUX": 3, "GENRE": 4, "MATIERES": 3}
ISAD_MIN_TERM_LEN = 3      # « A », « 12 », « de » ne sont pas des mots-clés
ISAD_WIDTH   = 78                                     # largeur de repli par défaut (lisible en Aperçu)
ISAD_WIDE    = 120                                    # HISTOIRE et PORTEE : plusieurs phrases, éviter les retours prématurés


def _isad_parse(body: str) -> dict:
    """Découpe la réponse du modèle en champs. Tolérant : « DATE: » comme « DATE : », casse variable,
    et texte débordant sur plusieurs lignes (rattaché au champ courant)."""
    keys = {f[0] for f in ISAD_FIELDS}
    fields, current, blank = {}, None, False
    for line in body.splitlines():
        m = re.match(r"^\s*([A-ZÀ-Ü]+)\s*:\s*(.*)$", line.strip())
        if m and m.group(1).upper() in keys:
            current = m.group(1).upper()
            fields[current] = m.group(2).strip()
            blank = False
        elif current and not line.strip():
            # Ligne vide DANS un champ : changement de paragraphe. Tout était auparavant recollé par
            # une espace, si bien qu'une portée en plusieurs paragraphes revenait en un seul bloc.
            blank = True
        elif current:
            fields[current] = (fields[current] + ("\n" if blank else " ") + line.strip()).strip()
            blank = False
    return fields


def _isad_trim_terms(key: str, value: str, logger: logging.Logger) -> str:
    """Ne garde que les termes exploitables, dans l'ordre donné par le modèle (le plus pertinent
    d'abord), et plafonne leur nombre. Écarte les fragments d'OCR — lettre isolée, nombre nu,
    ponctuation — qui n'ont aucune valeur de recherche."""
    limit = ISAD_MAX_TERMS.get(key)
    if not limit or not value or value.strip().lower().startswith("inconnu"):
        return value
    gardes, vus, ecartes = [], set(), []
    for brut in re.split(r"[,;]", value):
        t = brut.strip(" .;:-–—\t")
        if not t:
            continue
        # Un terme utile a de la longueur ET au moins une lettre.
        if len(t) < ISAD_MIN_TERM_LEN or not any(c.isalpha() for c in t):
            ecartes.append(t)
            continue
        cle = t.lower()
        if cle in vus:
            continue
        vus.add(cle)
        gardes.append(t)
    surplus = gardes[limit:]
    gardes = gardes[:limit]
    if ecartes:
        logger.info(f"Fiche ISAD : {key} — {len(ecartes)} terme(s) sans valeur de recherche écarté(s) : "
                    + ", ".join(ecartes[:6]))
    if surplus:
        logger.info(f"Fiche ISAD : {key} — {len(surplus)} terme(s) au-delà de {limit} écarté(s) : "
                    + ", ".join(surplus[:6]))
    return ", ".join(gardes) if gardes else "Inconnu"


def _isad_filter_places(value: str, ocr_text: str, logger: logging.Logger) -> str:
    """Ne conserve que les lieux LITTÉRALEMENT présents dans le texte. Un modèle peut aligner des
    communes parfaitement plausibles mais absentes du document (Bulle, Fribourg, Montreux…) : dans une
    notice d'archives, un lieu inventé est pire qu'un lieu manquant. Comparaison insensible à la casse,
    aux accents et à la ponctuation, pour absorber le bruit de l'OCR."""
    import unicodedata

    def norm(s: str) -> str:
        s = unicodedata.normalize("NFD", s.lower())
        s = "".join(c for c in s if unicodedata.category(c) != "Mn")
        return re.sub(r"[^a-z0-9]+", "", s)

    if value.strip().lower().startswith("inconnu"):
        return "Inconnu"          # absence déclarée : rien à filtrer
    hay = norm(ocr_text)
    kept, dropped, seen = [], [], set()
    for raw in re.split(r"[,;]", value):
        item = re.sub(r"\(.*?\)", "", raw).strip(" .;")
        key = norm(item)
        if not item or key in seen:      # un même lieu revient souvent deux fois dans la liste
            continue
        seen.add(key)
        (kept if key and key in hay else dropped).append(item)
    if dropped:
        logger.info(f"Fiche ISAD : {len(dropped)} lieu(x) écarté(s) car absents du texte — "
                    f"{', '.join(dropped[:6])}")
    return ", ".join(kept) if kept else "Inconnu"


MOIS_FR = {
    "janvier": 1, "fevrier": 2, "mars": 3, "avril": 4, "mai": 5, "juin": 6, "juillet": 7,
    "aout": 8, "septembre": 9, "octobre": 10, "novembre": 11, "decembre": 12,
    "janv": 1, "fev": 2, "avr": 4, "juil": 7, "sept": 9, "oct": 10, "nov": 11, "dec": 12,
}


def _sans_accents(s: str) -> str:
    import unicodedata
    return "".join(c for c in unicodedata.normalize("NFD", s) if unicodedata.category(c) != "Mn")


def _isad_scan_dates(text: str) -> list:
    """Relève les dates ÉCRITES DANS LE TEXTE, sans rien déduire ni compléter.

    Le modèle laisse échapper des dates rédigées en toutes lettres (« février 2015 ») parce qu'il
    cherche un format et non une formulation. Ce relevé déterministe les retrouve. Il ne rend que ce
    qui figure littéralement : jamais un jour pour un « février 2015 », jamais une année déduite.

    Rend une liste de (précision, date ISO, position), précision 3 = jour, 2 = mois, 1 = année.
    """
    t = _sans_accents(text.lower())
    vus = []

    def ajoute(prec, iso, pos):
        vus.append((prec, iso, pos))

    mois_alt = "|".join(sorted(MOIS_FR, key=len, reverse=True))
    # « 12 février 2015 », « 1er mars 1989 »
    for m in re.finditer(rf"\b(\d{{1,2}})\s*(?:er)?\s+({mois_alt})\.?\s+(\d{{4}})\b", t):
        j, mo, a = int(m.group(1)), MOIS_FR[m.group(2)], int(m.group(3))
        if 1 <= j <= 31 and 1800 <= a <= 2100:
            ajoute(3, f"{a:04d}-{mo:02d}-{j:02d}", m.start())
    # « février 2015 » (sans jour)
    for m in re.finditer(rf"\b({mois_alt})\.?\s+(\d{{4}})\b", t):
        mo, a = MOIS_FR[m.group(1)], int(m.group(2))
        if 1800 <= a <= 2100:
            ajoute(2, f"{a:04d}-{mo:02d}", m.start())
    # « 12.02.2015 », « 12/02/2015 », « 12-02-2015 »
    for m in re.finditer(r"\b(\d{1,2})[./-](\d{1,2})[./-](\d{4})\b", t):
        j, mo, a = int(m.group(1)), int(m.group(2)), int(m.group(3))
        if 1 <= j <= 31 and 1 <= mo <= 12 and 1800 <= a <= 2100:
            ajoute(3, f"{a:04d}-{mo:02d}-{j:02d}", m.start())
    # « 2015-02-12 »
    for m in re.finditer(r"\b(\d{4})-(\d{2})-(\d{2})\b", t):
        a, mo, j = int(m.group(1)), int(m.group(2)), int(m.group(3))
        if 1 <= j <= 31 and 1 <= mo <= 12 and 1800 <= a <= 2100:
            ajoute(3, f"{a:04d}-{mo:02d}-{j:02d}", m.start())
    return vus


def _isad_refine_date(valeur: str, ocr_text: str, logger: logging.Logger) -> str:
    """Complète la date du modèle par ce que le TEXTE porte réellement — et seulement par cela.

    Prudence délibérée : on n'ajoute une précision que si le texte est SANS AMBIGUÏTÉ. Plusieurs mois
    concurrents pour la même année, ou plusieurs dates isolées sans rapport, et l'on s'abstient : une
    date fausse dans une notice d'archives est pire qu'une date absente.
    """
    v = (valeur or "").strip()
    if re.match(r"^\d{4}-\d{2}-\d{2}", v) or re.match(r"^\d{4}-\d{2}$", v):
        return v                                   # déjà précis, on n'y touche pas
    releve = _isad_scan_dates(ocr_text)
    if not releve:
        return v
    annee = re.match(r"^(\d{4})$", v)
    if annee:
        a = annee.group(1)
        # Affiner AAAA → AAAA-MM seulement si le texte ne propose qu'UN mois pour cette année.
        mois = {iso[:7] for prec, iso, _ in releve if prec >= 2 and iso.startswith(a)}
        if len(mois) == 1:
            precise = _isad_plus_precise(releve, mois.pop())
            logger.info(f"Fiche ISAD : date « {v} » précisée en « {precise} » d'après le texte.")
            return precise
        if len(mois) > 1:
            logger.info(f"Fiche ISAD : {len(mois)} mois différents pour {a} dans le texte — "
                        f"année conservée sans précision.")
        return v
    if v.lower().startswith("inconnu") or not v:
        # Rien du modèle : n'accepter que si le texte désigne UN SEUL mois. « le 12 mars 1989 » est
        # relevé deux fois — au jour et au mois — ce qui n'est pas une concurrence mais la même date
        # à deux précisions : c'est le mois qui fait foi pour juger de l'ambiguïté.
        mois = {iso[:7] for prec, iso, _ in releve if prec >= 2}
        if len(mois) == 1:
            trouve = _isad_plus_precise(releve, mois.pop())
            logger.info(f"Fiche ISAD : aucune date du modèle — « {trouve} » relevée dans le texte.")
            return trouve
        logger.info(f"Fiche ISAD : aucune date du modèle et {len(mois)} mois différents dans le "
                    f"texte — laissée « Inconnu » plutôt que de choisir au hasard.")
    return v


def _isad_plus_precise(releve: list, mois: str) -> str:
    """Pour un mois donné, rend le jour s'il est unique dans le texte, sinon le mois seul."""
    jours = {iso for prec, iso, _ in releve if prec == 3 and iso.startswith(mois)}
    return jours.pop() if len(jours) == 1 else mois


def _isad_clean_date(value: str) -> str:
    """« 1989-04-XX » → « 1989-04 » : le modèle comble parfois par des X les composantes inconnues,
    ce qui n'est pas une date exploitable dans un catalogue."""
    return re.sub(r"[-/](?:[Xx]{1,2}|00)\b", "", value).strip()


def _isad_render(fields: dict, raw: str) -> str:
    """Met la fiche en page : une section par champ, titre souligné, texte replié en paragraphes et
    mots-clés en liste — pour être lisible d'un coup d'œil au lieu d'un pavé de huit lignes."""
    import textwrap
    out = []
    for key, title, ref in ISAD_FIELDS:
        value = (fields.get(key) or "").strip()
        if not value:
            value = "Inconnu"
        if key == "DATE":
            value = _isad_clean_date(value)
        heading = f"{title}  ({ref})" if ref else title
        out.append(heading)
        out.append("─" * ISAD_WIDTH)
        # HISTOIRE et PORTEE acceptent plusieurs phrases : on leur donne plus de largeur pour éviter
        # des retours à la ligne prématurés qui coupent les phrases en deux. Les autres champs sont courts
        # et ne bénéficient pas de cette largeur accrue — textwrap.wrap fait son travail sans coupure.
        wrap_w = ISAD_WIDE if key in ("HISTOIRE", "PORTEE") else ISAD_WIDTH
        if key in ISAD_LIST_FIELDS and value.lower() != "inconnu":
            for item in [t.strip(" .;") for t in re.split(r"[,;]", value) if t.strip(" .;")]:
                out.extend(textwrap.wrap(item, wrap_w - 2,
                                         initial_indent="• ", subsequent_indent="  ") or ["• " + item])
        else:
            # Les paragraphes se suivaient sans ligne vide : rien ne distinguait alors un repli de
            # mise en page d'un vrai changement de paragraphe, et l'application ne pouvait pas rendre
            # au texte son flux avant de le publier. La ligne vide est cette marque — elle aère aussi
            # la fiche à la lecture.
            paras = [p.strip() for p in value.split("\n") if p.strip()] or [value]
            for n, para in enumerate(paras):
                if n:
                    out.append("")
                out.extend(textwrap.wrap(para, wrap_w) or [para])
        out.append("")
    if not fields:      # réponse inattendue : on conserve le texte brut plutôt que de le perdre
        out += ["RÉPONSE BRUTE DU MODÈLE (format inattendu)", "─" * ISAD_WIDTH, raw.strip(), ""]
    return "\n".join(out)


def write_isad_sidecar(final_pdf: Path, ocr_text: str, project_name: str, logger: logging.Logger,
                       fallback_date: str = "", from_pdf: bool = False):
    """Écrit « <nom_du_pdf>.txt » à côté du PDF final avec la fiche ISAD produite par le LLM.
    Best-effort intégral : toute erreur est journalisée et avalée (ne doit jamais casser le PDF)."""
    if not ocr_text.strip():
        logger.info("Fiche ISAD : aucune couche texte exploitable dans le PDF — fiche non générée.")
        return
    pages, size = _pdf_extent(final_pdf, from_pdf)
    facts = {"pages": pages or None, "size": size or None,
             "support": "document PDF numérique" if from_pdf else "numérisation de documents papier"}
    # Signal d'honnêteté : sous ce seuil, l'OCR n'a presque rien rendu (page de titre seule, écriture
    # manuscrite, scan illisible) et la description ne peut pas être solide. On le DIT, plutôt que de
    # livrer une notice assurée bâtie sur trois lignes de texte.
    thin_note = ""
    if len(ocr_text.strip()) < ISAD_MIN_TEXT:
        thin_note = (f"Texte reconnu très limité ({len(ocr_text.strip())} caractères) — "
                     f"description peu fiable, à reprendre manuellement.\n")
        logger.warning(f"Fiche ISAD : seulement {len(ocr_text.strip())} caractères de texte exploitable "
                       f"pour « {project_name} » — description peu fiable.")
    prompt = _isad_prompt(ocr_text, project_name, fallback_date, facts)
    logger.info(f"Fiche ISAD : interrogation du modèle « {ISAD_MODEL} » via {ISAD_HOST}…")
    body = _ollama_generate(prompt, logger)
    if not body:
        return
    fields = _isad_parse(body)
    # Garantie : si le modèle laisse la date inconnue alors que le PDF d'origine en porte une, on la
    # renseigne nous-mêmes — et on le SIGNALE : l'archiviste doit savoir que la date ne vient pas du
    # texte mais des métadonnées du fichier.
    date_note = ""
    # Recherche approfondie DANS LE TEXTE avant tout repli : une date écrite dans le document prime
    # sur celle du fichier, qui n'est que la date de fabrication du PDF.
    if fields.get("DATE") is not None:
        fields["DATE"] = _isad_refine_date(fields.get("DATE", ""), ocr_text, logger)
    if fallback_date and fields.get("DATE", "").strip().lower().startswith("inconnu"):
        fields["DATE"] = fallback_date
        date_note = "Date reprise des métadonnées du PDF d'origine (aucune date dans le texte).\n"
        logger.info(f"Fiche ISAD : date absente du texte — reprise des métadonnées ({fallback_date}).")
    # Filet de sécurité déterministe contre les lieux inventés (cf. _isad_filter_places).
    if fields.get("LIEUX"):
        fields["LIEUX"] = _isad_filter_places(fields["LIEUX"], ocr_text, logger)
    # Puis pertinence et plafond, sur les quatre listes.
    for cle in ISAD_MAX_TERMS:
        if fields.get(cle):
            fields[cle] = _isad_trim_terms(cle, fields[cle], logger)
    sidecar = final_pdf.with_suffix(".txt")
    # En-tête : provenance de la fiche (auto-générée, par quel modèle, et d'où vient la date).
    stamp = datetime.datetime.now().strftime("%Y-%m-%d à %H:%M")
    header = ("═" * ISAD_WIDTH + "\n"
              "FICHE ARCHIVISTIQUE — ISAD(G)\n"
              f"{final_pdf.stem}\n"
              + "═" * ISAD_WIDTH + "\n"
              f"Document  : {final_pdf.name}\n"
              f"Générée   : automatiquement le {stamp}\n"
              f"Modèle    : {ISAD_MODEL}\n"
              + (f"Remarque  : {date_note}" if date_note else "")
              # Provenance de la date : on donne TOUJOURS la date inscrite dans le fichier d'origine
              # quand il y en a une. L'archiviste voit ainsi d'où peut venir la date de la fiche, sans
              # qu'on prétende savoir si le modèle l'a lue dans le texte ou reprise du fichier.
              + (f"Fichier   : date de création du PDF d'origine {fallback_date}\n" if fallback_date else "")
              + (f"⚠ Alerte  : {thin_note}" if thin_note else "")
              + "Relecture : description produite par une machine — à vérifier avant publication.\n"
              + "═" * ISAD_WIDTH + "\n\n")
    try:
        sidecar.write_text(header + _isad_render(fields, body), encoding="utf-8")
        logger.info(f"Fiche ISAD écrite : {sidecar}")
    except Exception as exc:
        logger.error(f"Écriture de la fiche ISAD échouée : {exc}")


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
        pdfs   = [p for p in moved if p.suffix.lower() == ".pdf"]
        images = [p for p in moved if p.suffix.lower() != ".pdf"]
        if not pdfs:
            source = merge_tiffs(project_name, images, logger)
        elif not images:
            # PDF paginés d'un même document → fusionnés en un seul ; PDF autonome → tel quel.
            source = pdfs[0] if len(pdfs) == 1 else merge_pdfs(project_name, pdfs, logger)
        else:
            # Groupe MIXTE (TIFF et PDF portant le même nom de projet) : on convertit les TIFF puis on
            # fusionne le tout, plutôt que d'échouer en ouvrant un PDF avec le lecteur d'images.
            logger.warning("Groupe mixte TIFF + PDF — les pages TIFF sont placées en tête du document.")
            tif_pdf = TEMP_DIR / f"{project_name}_tiffs.pdf"
            tiff_to_pdf_direct(merge_tiffs(project_name, images, logger), tif_pdf, logger)
            source = merge_pdfs(project_name, [tif_pdf] + pdfs, logger)
        # Date de repli pour la fiche ISAD : lue sur l'ORIGINAL, avant toute suppression, et UNIQUEMENT
        # si l'entrée est un PDF — pour un TIFF ce serait la date de numérisation, donc fausse.
        isad_date = _pdf_creation_date(pdfs[0], logger) if (OPT_ISAD and pdfs and not images) else ""
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

        # Fiche ISAD(G) : best-effort, n'échoue JAMAIS le traitement (comme l'export). Placée AVANT
        # l'export pour que le « .txt » parte aussi vers le NAS avec le dossier projet.
        if OPT_ISAD:
            try:
                ocr_text = extract_pdf_text(final_pdf, logger)
                write_isad_sidecar(final_pdf, ocr_text, project_name, logger, isad_date,
                                   from_pdf=bool(pdfs and not images))
            except Exception as exc:
                logger.error(f"Fiche ISAD échouée (ignorée) : {exc}")

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
    TEMP_DIR.mkdir(parents=True, exist_ok=True)   # dossier de travail garanti dès le départ
    if _ISAD_HOST_REJECTED:
        logger.warning(f"Adresse Ollama « {_ISAD_HOST_REJECTED} » refusée : seuls la machine locale et "
                       f"le réseau privé sont autorisés (le texte du document y serait envoyé). "
                       f"Repli sur {ISAD_HOST}.")
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
