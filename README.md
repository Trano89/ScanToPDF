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
- **OCR** — Powered by Tesseract via [ocrmypdf](https://github.com/ocrmypdf/Ocrmypdf) for text recognition and PDF/A compliance
- **Image Corrections** — Automatic deskew and rotation to correct misfed scans
- **Compression** — Reduces output file size without noticeable quality loss
- **PDF/A** — Exports in the archival PDF/A format for long-term preservation
- **Watermarking** (optional) — Applies a diagonal or custom watermark to pages
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
  "keepOriginals": true,
  "clean": true,
  "watermarkEnabled": false,
  "watermarkText": "",
  "watermarkOpacity": 20,
  "watermarkPosition": "diagonal",
  "watermarkHard": true,
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
| `keepOriginals` | Keep source images after processing | `true` |
| `clean` | Clean temporary files after processing | `true` |
| `watermarkEnabled` | Apply a watermark to each page | `false` |
| `watermarkText` | Watermark text to display | `""` |
| `watermarkOpacity` | Watermark opacity (0–100) | `20` |
| `watermarkPosition` | Watermark position (`diagonal`, etc.) | `"diagonal"` |
| `watermarkHard` | Render watermark directly into the page (vs overlay) | `true` |
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

Finished PDFs are saved alongside the original scan images (controlled by `keepOriginals`). If network export is enabled, copies are also sent to your NAS/share.

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

## Dependencies

All dependencies are bundled inside `ScanToPDF.app/Contents/Resources/`:

- **Python 3** — workflow engine
- **Tesseract OCR** — text recognition (`share/tessdata`)
- **ocrmypdf** — OCR + PDF/A conversion
- **Ghostscript** — PDF compression and PDF/A rendering (`bin/gs`, `gs-lib`)
- **Pillow / Pillow-SIMD** — image processing

No external dependencies are needed. The app is fully self-contained.

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
