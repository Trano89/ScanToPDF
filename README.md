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
- **Batch Grouping** — Groups pages belonging to the same document by their shared filename prefix (e.g., `Eg.w.O0.1901_29` → project `Eg.w.O0.1901`)
- **PDF Input** — PDFs are processed **exactly like TIFF scans** (same pipeline: isolate → merge → OCR → PDF/A). Paginated PDFs sharing a document name (e.g. `Doc-1.pdf`, `Doc-2.pdf`, …) are merged into one multi-page document. The only PDF-specific rule: if a source PDF's name would collide with the final result (`<project>.pdf`), the original is preserved as `<project>_original.pdf`
- **OCR** — Powered by Tesseract via [ocrmypdf](https://github.com/ocrmypdf/Ocrmypdf) for text recognition and PDF/A compliance
- **Image Corrections** — Automatic deskew and rotation to correct misfed scans
- **Compression** — Reduces output file size without noticeable quality loss
- **PDF/A** — Exports in the archival PDF/A format for long-term preservation
- **Watermarking** (optional) — Stamps every page with either **text** or an **image** (PNG with transparency, JPEG, TIFF). Choose placement (diagonal, centred, top, bottom, tiled), opacity, and whether it is burned in or added as a removable "Filigrane" layer
- **ISAD(G) Finding Aid** (optional) — After each PDF, a **local LLM** (Ollama, running on your own Mac) reads the OCR layer and writes an archival description next to the PDF as `<name>.txt`. Pick any installed model from a drop-down in Preferences. Nothing leaves your machine
- **Network Export** (optional) — Can copy finished PDFs to a NAS or shared network drive
- **Multi-Mac Sync** — Optional over-the-air app updates across Macs on the same local network

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
  "nasHost": "",
  "nasShare": "",
  "nasSubpath": "",
  "nasUser": "",
  "exportEnabled": false,
  "notify": true,
  "startAtLogin": false,
  "pageSeparator": "_",
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
| `networkEnabled` | Enable network/NAS export | `false` |
| `nasHost` | NAS/SMB server hostname or IP | `""` |
| `nasShare` | Network share path | `""` |
| `nasSubpath` | Subfolder on the share | `""` |
| `nasUser` | Username for authentication | `""` |
| `exportEnabled` | Copy finished PDFs to the network location | `false` |
| `notify` | Show macOS notifications for progress/events | `true` |
| `startAtLogin` | Launch the app when macOS starts | `false` |
| `pageSeparator` | Character separating project ID from pagination number (e.g., `_` in `Doc_29-1.tif`) | `"_"` |
| `pageDelimiter` | Character separating page number within a batch (e.g., `-` in `Doc_29-1.tif`) | `"-"` |

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

You can configure how files are grouped into document batches using the **Preferences** pane → **Regroupement des fichiers** section, or directly via `config.json`:

- **Separateur identifiant-projet** (`pageSeparator`): the character between the project identifier and the pagination number (default: `_`). For `Eg.w.O0.1901_29`, this is `_`. Use `-` if your identifiers already contain underscores.
- **Séparateur pagination** (`pageDelimiter`): the character between the document number and individual page numbers within a batch (default: `-`). For `Eg.w.O0.1901_29-1`, this is `-`.

Example — renaming your files to use dots instead of underscores:
```
Doc.1.1.tif   → project "Doc", pagination "1", page 1
Doc.1.2.tif   → project "Doc", pagination "1", page 2
```
Set `pageSeparator` = `.` and `pageDelimiter` = `.` (or a different character for each role).

## ISAD(G) Finding Aids (local AI)

When **Fiche archivistique (ISAD)** is enabled, ScanToPDF reads the OCR layer of the PDF it just
produced, asks a **local language model** to describe it, and writes the result next to the PDF —
`Eg.w.O0.1901.pdf` gets `Eg.w.O0.1901.txt`. The model runs on your own Mac through
[Ollama](https://ollama.com); no document text is ever sent to a third party.

### Requirements

Ollama is **not bundled** with ScanToPDF — the app only talks to it over `http://localhost:11434`.
Install it and pull a model that can generate text:

```bash
ollama pull qwen3.5:9b
```

### Setting it up

1. Open **Preferences → Fiche archivistique (ISAD)** and tick *Générer une fiche texte ISAD à côté du PDF*.
2. Choose your model in the **Modèle installé** drop-down. It lists the models actually installed on
   this Mac (embedding-only models are filtered out, since they cannot generate text). Use
   **Actualiser la liste** after pulling a new model. If Ollama is not running, the field falls back to
   free text so you can prepare the setting offline.
3. Leave **Adresse Ollama** on `http://localhost:11434` unless Ollama listens elsewhere.

### What the finding aid contains

Eight fields, in this order, designed to be short enough to paste into AtoM:

| Field | ISAD(G) | Content |
|---|---|---|
| `DATE` | 3.1.3 | `YYYY-MM-DD`, a range, or just the year — `Inconnu` if undated |
| `ETENDUE` | 3.1.5 | Extent and medium, e.g. *1 brochure de 18 pages* |
| `HISTOIRE` | 3.2.3 | Archival history: origin, creator, context |
| `PORTEE` | 3.3.1 | Scope and content |
| `SUJETS` | — | Subject keywords |
| `LIEUX` | — | Place names cited |
| `GENRE` | — | Document type (minutes, correspondence, photograph…) |
| `MATIERES` | — | Named entities used as subject access points |

The model is told never to invent anything: missing or unreadable information comes back as `Inconnu`.
Temperature is kept low so the same document yields a stable description.

### Guarantees and limits

- **Never blocking.** If Ollama is stopped, the model is missing, or the request times out, the PDF is
  produced exactly as usual and the reason is written to the log — only the `.txt` is skipped.
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
