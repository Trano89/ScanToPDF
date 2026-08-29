# ScanToPDF

A macOS app that automatically watches a folder for scanned images, groups pages by document batch, and assembles them into searchable PDFs with OCR.

## Purpose

ScanToPDF automates the processing of bulk document scans. Instead of manually assembling each scanned page into a PDF, it monitors a designated **watch folder** — where your scanner or copier outputs files — and automatically:

1. Detects new images dropped into the watch folder
2. Groups pages belonging to the same document batch (by filename pattern)
3. Assembles them in order into a single multi-page PDF
4. Runs OCR (Optical Character Recognition) to make the text searchable
5. Applies image corrections and compression

## Features

- **Watch Folder** — Monitors a directory for new scanned images and processes them automatically
- **Batch Grouping** — One rule, identical for TIFFs and PDFs: the **page delimiter** (`-` by default) introduces the page number, and everything before it is the reference code, kept verbatim for the folder and the resulting PDF. `Be.a.S1.1989_1-1.tif`, `-2`, `-3` → one document `Be.a.S1.1989_1`; `Be.a.S1.1989_1.tif` alone → a single-piece document under that same name
- **PDF Input** — PDFs go through **exactly the same pipeline** as TIFF scans (isolate → merge → OCR → PDF/A) and follow the same naming rule. The only PDF-specific behaviour: if a source PDF's name would collide with the final result (`<project>.pdf`), the original is preserved as `<project>_original.pdf`
- **OCR** — Powered by Tesseract via [ocrmypdf](https://github.com/ocrmypdf/Ocrmypdf) for text recognition and PDF/A compliance
- **Image Corrections** — Automatic deskew and rotation to correct misfed scans
- **Compression** — Reduces output file size without noticeable quality loss
- **PDF/A** — Exports in the archival PDF/A format for long-term preservation
- **Watermarking** (optional) — Stamps every page with either **text** or an **image** (PNG with transparency, JPEG, TIFF). Choose placement (diagonal, centred, top, bottom, tiled), opacity, and whether it is burned in or added as a removable "Filigrane" layer
- **ISAD(G) Finding Aid** (optional) — After each PDF, a **local LLM** (Ollama, running on your own Mac) reads the OCR layer and writes an archival description next to the PDF as `<name>.txt`. Pick any installed model from a drop-down in Preferences. Nothing leaves your machine
- **Network Publication** (optional) — Publishes finished folders to a **mounted SMB network drive**, picked from a drop-down of the drives actually mounted. The choice is remembered, the drive is remounted on its own when it has been ejected, and the setting can be locked behind the Mac administrator password. No local fallback: with no drive mounted nothing is published
- **Multi-Mac Sync** — Optional over-the-air app updates across Macs on the same local network

## Changelog

### v1.0.23 — No record is ever created

- ScanToPDF never creates a description: the catalogue stays in charge of its own hierarchy
- When a description cannot be found, the window offers exactly three ways out — **retry** the
  automatic lookup, **search manually** (paste the record URL, its slug, or another reference code —
  a button opens the AtoM search in the browser), or **cancel**
- The proposed values stay visible for reference while nothing is attached, and publishing is
  impossible until a record is

### v1.0.22 — AtoM publication with a review step

- After each result, a window shows what AtoM already holds and what ScanToPDF proposes, field by
  field, marked **added** / **modified** / **unchanged**. **Every value stays editable**, including
  those already in AtoM, and nothing is sent without confirmation
- A description is looked up by its reference code in **both spellings** (`_` and `/`) so no duplicate
  can be created; a description still using the old `/` form is migrated to `_`
- Credentials live in the macOS Keychain, HTTPS only, with a "test connection" button
- AtoM receives **only the final PDF/A**; the network drive keeps receiving the whole folder
- Audit fixes: the engine's output was cut into arbitrary chunks, so a line could never be matched
  reliably — it is now split into complete lines; and the workflow's output was discarded by both the
  watcher and the "Traiter maintenant" button, so the completion line never reached the app at all

### v1.0.21 — Preferences in tabs, AtoM groundwork

- Preferences are split into six **tabs** (Dossier, Traitement, Filigrane, Fiche ISAD, Publication,
  Application) instead of one long page
- Settings are edited in a **draft** and applied by an explicit **Enregistrer** button, with an
  "unsaved changes" indicator and a Cancel button
- Groundwork for publishing to AtoM: reading an existing description by its reference code and
  comparing it field by field with what ScanToPDF proposes (verified against archives.fvjc.ch)

### v1.0.20 — Network publication rebuilt around the drive

- The destination is now picked from a **drop-down of the SMB drives actually mounted**; internal
  mounts (Time Machine, `nobrowse`) are filtered out
- The chosen drive is remembered and **remounted on its own** when it has been ejected
- Changing the drive can be **locked behind the Mac administrator password**
- The Synology Drive fallback is removed: with no drive mounted, nothing is published

### v1.0.19 — ISAD(G) finding aid formatting fix
- Wider wrap width (120 vs 78 chars) for **Histoire Archivistique** and **Portée et Contenu** fields in the ISAD sidecar `.txt` file, so multi-sentence descriptions no longer break at arbitrary line lengths

### v1.0.18 — Security audit fixes
- Applied three sound findings from security audit, rejected two as false positives

## Releases

Pre-compiled releases are available on the [Releases page](https://github.com/Trano89/ScanToPDF/releases) :

- `.dmg` — Disk image for drag-and-drop installation
- `.zip` — Source code archive (for manual inspection or alternative builds)

### App Auto-Update

ScanToPDF includes two built-in update mechanisms:

1. **GitHub Release Check** — The app queries the GitHub API every 24 hours for newer release versions. A banner appears in Settings with a link to the latest release.
2. **Local Network Sync** — When enabled, Macs running ScanToPDF on the same local network can discover each other via mDNS/Bonjour and push updates between themselves using TLS-PSK encryption.

You can toggle both behaviors in the Preferences pane → Application section.

## Installation

### Prerequisites

The following dependencies are bundled inside the `.app` bundle. No external installation is needed:

- **Python 3** (bundled) — powers the workflow engine
- **Tesseract OCR** — text recognition
- **ocrmypdf** — OCR, PDF/A conversion, optimization
- **Ghostscript** — PDF compression and PDF/A rendering
- **ImageMagick / Pillow** — image corrections and assembly

### Quick Install

1. Download the latest `.dmg` or `.tar.gz` from [Releases](https://github.com/Trano89/ScanToPDF/releases)
2. Open the dmg or extract the archive
3. Drag `ScanToPDF.app` into your `/Applications` folder
4. Launch the app — it will start in the menu bar

### From Source (Development)

```bash
# Clone the repository
git clone https://github.com/Trano89/ScanToPDF.git
cd ScanToPDF

# Build and install directly to /Applications
./build_app.sh
```

The app requires **macOS 13+** and an Apple Silicon Mac. The `build_app.sh` script compiles the Swift source, bundles the Python runtime, and installs the final `ScanToPDF.app` directly into `/Applications/`. All native dependencies (Tesseract, Ghostscript, ocrmypdf) are included automatically.

## Configuration

The app is configured through a `config.json` file stored in `/Users/Shared/ScanToPDF/config.json` (accessible from the preferences pane):

```json
{
  "watchFolder": "/path/to/your/scans",
  "dpi": 150,
  "ocr": true,
  "ocrThreshold": "adaptive-otsu",
  "tesseractPSM": 3,
  "deskew": true,
  "rotate": true,
  "rotateThreshold": 15,
  "compress": true,
  "pdfa": true,
  "deleteOriginals": false,
  "clean": true,
  "watermarkEnabled": false,
  "watermarkType": "text",
  "watermarkText": "",
  "watermarkImagePath": "",
  "watermarkOpacity": 20,
  "watermarkPosition": "diagonal",
  "watermarkHard": true,
  "isadEnabled": false,
  "isadModel": "qwen3.5:9b",
  "isadHost": "http://localhost:11434",
  "networkEnabled": false,
  "nasVolumePath": "",
  "nasMountFrom": "",
  "nasSubpath": "",
  "nasLocked": false,
  "exportEnabled": false,
  "notify": true,
  "startAtLogin": false,
  "pageDelimiter": "-"
}
```

| Setting | Description | Default |
|---|---|---|
| `watchFolder` | Directory the app monitors for scanned images | — |
| `dpi` | Target DPI for output PDFs | `150` |
| `ocr` | Enable text recognition via Tesseract | `true` |
| `ocrThreshold` | Tesseract page segmentation mode (`adaptive-otsu`, `3`, etc.) | `"adaptive-otsu"` |
| `tesseractPSM` | Tesseract Page Segmentation Mode (0–11) | `3` |
| `deskew` | Automatically correct skewed/tilted scans | `true` |
| `rotate` | Auto-rotate pages that are upside down or sideways | `true` |
| `rotateThreshold` | Minimum rotation angle (degrees) to trigger correction | `15` |
| `compress` | Compress images in the output PDF | `true` |
| `pdfa` | Output PDF/A archival format | `true` |
| `deleteOriginals` | Delete source files (TIFF **and** PDF alike) after the result is produced. Off by default — originals are always kept | `false` |
| `clean` | Clean temporary files after processing | `true` |
| `watermarkEnabled` | Apply a watermark to each page | `false` |
| `watermarkType` | `"text"` or `"image"` | `"text"` |
| `watermarkText` | Watermark text (type `text`) | `""` |
| `watermarkImagePath` | Absolute path to the watermark image — PNG transparency is preserved (type `image`) | `""` |
| `watermarkOpacity` | Watermark opacity (0–100); lightens the text or image | `20` |
| `watermarkPosition` | `diagonal`, `center`, `top`, `bottom` or `tile` | `"diagonal"` |
| `watermarkHard` | Render watermark directly into the page (vs overlay) | `true` |
| `isadEnabled` | Write an ISAD(G) finding aid next to each PDF, using a local LLM | `false` |
| `isadModel` | Ollama model queried (pick it from the drop-down in Preferences) | `"qwen3.5:9b"` |
| `isadHost` | Base URL of the local Ollama API | `"http://localhost:11434"` |
| `isadContext` | Description of your fonds sent to the model before every request (editable in Preferences) | FVJC archives context |
| `networkEnabled` | Enable network/NAS export | `false` |
| `exportEnabled` | Publish finished folders to the network drive | `false` |
| `nasVolumePath` | Mount point of the chosen SMB drive, e.g. `/Volumes/Archives` | `""` |
| `nasMountFrom` | SMB origin of that drive, e.g. `//user@server/share` — used to remount it | `""` |
| `nasSubpath` | Subfolder on the drive | `""` |
| `nasLocked` | Changing the drive requires the Mac administrator password | `false` |
| `notify` | Show macOS notifications for progress/events | `true` |
| `startAtLogin` | Launch the app when macOS starts | `false` |
| `pageDelimiter` | Character introducing the page number; everything before it is the reference code | `"-"` |

## How It Works

### 1. Scan or copy files to the watch folder

Place your scanned images (PNG, JPG, TIFF, etc.) into the configured watch folder using your scanner or copier's output directory. Pages from the same document batch should share a filename prefix (e.g., `Eg.w.O0.1901_29-1.png`, `Eg.w.O0.1901_29-2.png`).

### 2. Automatic processing

The app detects the new files and:
- Groups pages by their shared project prefix
- Sorts them in order
- Assembles them into a single PDF
- Runs OCR to recognize text
- Applies corrections (deskew, rotation) and compression
- Outputs a searchable PDF

### 3. Output

Finished PDFs are saved alongside the original source files, which are always kept unless you explicitly enable `deleteOriginals`. If network export is enabled, copies are also sent to your NAS/share.

### Logs

All processing activity is logged in `/Users/Shared/ScanToPDF/logs/`:
- `watcher_*.log` — Detection and grouping events
- `archivage_*.log` — PDF assembly and OCR results

## Customizing File Grouping

A **single** character drives the grouping — **Séparateur de pagination** (`pageDelimiter`, default `-`),
set in **Preferences → Regroupement des fichiers** or in `config.json`. It introduces the page number;
everything before it is the reference code and is reproduced verbatim in the folder name and in the
resulting PDF. TIFFs and PDFs obey exactly the same rule.

| Files dropped in the watch folder | Folder | Result |
|---|---|---|
| `Be.a.S1.1989_1-1.tif`, `-2`, `-3` | `Be.a.S1.1989_1/` | `Be.a.S1.1989_1.pdf` (3 pages) |
| `Be.a.S1.1989_1.tif` | `Be.a.S1.1989_1/` | `Be.a.S1.1989_1.pdf` (1 page) |
| `Be.a.S1.1989_1.pdf` | `Be.a.S1.1989_1/` | `Be.a.S1.1989_1.pdf`, original kept as `Be.a.S1.1989_1_original.pdf` |

Note that `_1` belongs to the reference code: it is a document number, never a page number. If your
codes already contain `-`, pick another delimiter (`_`, `.`, `~`, `:` or a space) so that the split
happens where you intend.

## ISAD(G) Finding Aids (local AI)

When **Fiche archivistique (ISAD)** is enabled, ScanToPDF reads the OCR layer of the PDF it just
produced, asks a **local language model** to describe it, and writes the result next to the PDF —
`Eg.w.O0.1901.pdf` gets `Eg.w.O0.1901.txt`. The model runs on your own Mac through
[Ollama](https://ollama.com); no document text is ever sent to a third party.

### Requirements

Ollama is **not bundled** with ScanToPDF — it stays under your control. Install it and pull a model
that can generate text:

```bash
ollama pull qwen3.5:9b
```

You do **not** need to start Ollama yourself: when it is installed on this Mac but not running,
ScanToPDF launches it (the Ollama app, or `ollama serve`) and waits for it to answer. A **remote**
host is never started — it belongs to another machine.

### Setting it up

1. Open **Preferences → Fiche archivistique (ISAD)** and tick *Générer une fiche texte ISAD à côté du PDF*.
2. Choose your model in the **Modèle installé** drop-down. It lists the models actually installed on
   this Mac (embedding-only models are filtered out, since they cannot generate text). Use
   **Actualiser la liste** after pulling a new model. If Ollama is not running, the field falls back to
   free text so you can prepare the setting offline.
3. Leave **Adresse Ollama** on `http://localhost:11434` unless Ollama listens elsewhere.
4. Review the **Contexte transmis au modèle** box. This editable text describes your fonds — what the
   acronyms mean, the organisation behind them, the recurring events, the vocabulary to respect — and
   is sent before every description request. It ships with a context written for the FVJC archives;
   edit it freely for your own fonds, and use **Rétablir le contexte par défaut** to go back. This box
   is the single biggest lever on description quality: without it a model will invent an expansion for
   an unfamiliar acronym, and it will not recognise a house term (a *pense-bête* is an annual brochure,
   not a filing folder). After upgrading ScanToPDF, click **Rétablir le contexte par défaut** to pick
   up an improved shipped context — your own edits are never overwritten automatically.

### What the finding aid contains

Eight fields, in this order, designed to be short enough to paste into AtoM:

| Field | ISAD(G) | Content |
|---|---|---|
| `DATE` | 3.1.3 | `YYYY-MM-DD`, a range, or just the year — `Inconnu` if undated. When the text carries no date **and the source was already a PDF**, the file's creation date is used instead and the header says so. Never for TIFFs: their creation date is the scanning date, not the document's |
| `ETENDUE` | 3.1.5 | Extent and medium, e.g. *1 brochure de 18 pages* |
| `HISTOIRE` | 3.2.3 | Archival history: origin, creator, context |
| `PORTEE` | 3.3.1 | Scope and content |
| `SUJETS` | — | Subject keywords |
| `LIEUX` | — | Place names cited |
| `GENRE` | — | Document type (minutes, correspondence, photograph…) |
| `MATIERES` | — | Named entities used as subject access points |

The model is told never to invent anything: missing or unreadable information comes back as `Inconnu`,
and it must never expand an acronym on its own initiative. Everything it knows about your fonds comes
from the editable context box described above.

Several measures keep the description faithful to the document:

- **The text is compacted first.** A scanned PDF renders as mostly positioning whitespace — up to
  97.5% of the extracted volume on this fonds. Uncompacted, the budget sent to the model is spent on
  blanks (about a thousand real characters out of forty thousand) and the description has nothing to
  work from. Runs of spaces and blank lines are collapsed before anything else.
- **The whole document is read.** Up to 480 000 characters of *useful* text are sent; beyond that,
  excerpts are sampled across the entire file rather than truncating to the first pages — otherwise
  everything after the opening pages (lists of societies, places, people) would be invisible.
- **Only trustworthy measurements are asserted.** Page count always; page dimensions only when the
  source was already a PDF or the size matches a standard paper format. Photographed documents carry
  no resolution, so their PDF page claims impossible sizes such as 29,3 × 43,9 cm — the finding aid
  stays silent rather than recording a false measurement.
- **A thin result is flagged.** When OCR yields almost no text, the finding aid says so in its header
  instead of presenting a confident description built on nothing.
- **A fixed 128k-token context window.** Ollama caps it at 4096 tokens by default whatever the model
  supports, silently discarding part of a long prompt. ScanToPDF requests 131 072 tokens outright
  rather than deriving a size from the document at hand — the next document may be far larger than
  anything processed so far. Use a model whose context reaches that size.
- **Extraction settings, not creative ones.** Low temperature, and the penalties that push a model
  towards *new* words (`presence_penalty`, some model files ship it at 1.5) are explicitly neutralised.
- **Place names are verified.** Any place the model returns that does not literally appear in the OCR
  text is dropped from the finding aid, duplicates are removed, and the removal is logged. In archival
  description an invented place is worse than a missing one.

### Guarantees and limits

- **Never blocking.** If Ollama cannot be started, the model is missing, or the request times out, the
  PDF is produced exactly as usual and the reason is written to the log — only the `.txt` is skipped.
- **Needs a text layer.** The finding aid is built from the OCR layer, so keep **OCR** enabled. A
  PDF with no extractable text produces no finding aid.
- **Included in the NAS export.** The `.txt` is written before the export step, so it travels with the
  project folder.
- **Thinking models.** Reasoning models (Qwen 3.x…) are asked to skip their reasoning phase, which
  takes a description from several minutes down to a few seconds. Models without that mode are
  retried automatically without the option.
- **Review before use.** The description is machine-generated: it is a starting point for the
  archivist, not an authoritative record.

## Dependencies

All dependencies are bundled inside `ScanToPDF.app/Contents/Resources/`:

- **Python 3** — workflow engine
- **Tesseract OCR** — text recognition (`share/tessdata`)
- **ocrmypdf** — OCR + PDF/A conversion
- **Ghostscript** — PDF compression and PDF/A rendering (`bin/gs`, `gs-lib`)
- **Pillow / Pillow-SIMD** — image processing

No external dependencies are needed. The app is fully self-contained.

The only optional external component is **Ollama**, used solely by the ISAD(G) finding aid. It is
deliberately *not* bundled: it stays under your control, is shared with your other tools, and the
feature degrades silently when it is absent.

## Architecture

```
ScanToPDF.app/
├── Contents/MacOS/ScanToPDF          # Swift binary (AppKit/SwiftUI)
├── Contents/Resources/
│   ├── python/                        # Bundled Python 3 runtime
│   ├── bin/gs                         # Ghostscript binary
│   ├── gs-lib/                        # Ghostscript resources
│   ├── share/tessdata/                # Tesseract trained data
│   └── engine/
│       ├── archivage_watcher.py       # File watcher + queue (watchdog)
│       └── archivage_workflow.py      # TIFF → PDF pipeline
└── Info.plist
```

## License

Private use.
