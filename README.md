# ScanToPDF

A macOS application that automatically watches a folder for scanned images, groups pages by project, and assembles them into searchable PDFs with OCR.

## Purpose

ScanToPDF streamlines the workflow of scanning large batches of documents. Instead of manually assembling each scanned page into a PDF, it monitors a designated **watch folder** — where your scanner or copier outputs files — and automatically:

1. Detects new images dropped into the watch folder
2. Groups pages belonging to the same document batch (by filename pattern)
3. Assembles them in order into a single multi-page PDF
4. Runs OCR (Optical Character Recognition) to make the text searchable
5. Applies image corrections and optimizations

## Features

- **Watch Folder** — Monitors a directory for new scanned images and processes them automatically
- **Batch Grouping** — Groups pages belonging to the same document by their shared filename prefix (e.g., `Eg.w.O0.1901_29` → project `Eg.w.O0.1901`)
- **OCR** — Powered by Tesseract via [ocrmypdf](https://github.com/ocrmypdf/Ocrmypdf) for text recognition and PDF/A compliance
- **Image Corrections** — Automatic deskew and rotation to correct misfed scans
- **Compression** — Reduces output file size without noticeable quality loss
- **PDF/A** — Exports in the archival PDF/A format for long-term preservation
- **Watermarking** (optional) — Applies a diagonal or custom watermark to pages
- **Network Export** (optional) — Can copy finished PDFs to a NAS or shared network drive

## Installation

### Quick Install

1. Download the latest `.dmg` or `.tar.gz` from [Releases](https://github.com/Trano89/ScanToPDF/releases)
2. Open the dmg or extract the archive
3. Drag `ScanToPDF.app` into your `/Applications` folder
4. Launch the app — it will start in the menu bar

All dependencies (Python 3, Tesseract OCR, ocrmypdf, Ghostscript, Pillow) are bundled inside the `.app`. No external installation is needed.

### From Source (Development)

```bash
git clone https://github.com/Trano89/ScanToPDF.git
cd ScanToPDF

# Build the app bundle (bundles Python, Tesseract, Ghostscript, etc.)
./build_app.sh

# Install to /Applications
sudo mv build/ScanToPDF.app /Applications/
```

The app requires **macOS 13+** and an Apple Silicon Mac. The `build_app.sh` script builds the Xcode project and bundles all native dependencies (Python, Tesseract, Ghostscript, ocrmypdf) inside `Contents/Resources/`.

## Configuration

The app is configured through a `config.json` file in the application directory:

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

All processing activity is logged in the `logs/` directory:
- `watcher_*.log` — Detection and grouping events
- `archivage_*.log` — PDF assembly and OCR results

## Dependencies

All dependencies are **bundled inside the `.app`** — no external installation is needed:

- **Python 3** (bundled) — workflow engine
- **Tesseract OCR** — text recognition (`Contents/Resources/share/tessdata/`)
- **ocrmypdf** — OCR + PDF/A conversion (`Contents/Resources/python/`)
- **Ghostscript** — PDF compression and PDF/A rendering (`Contents/Resources/bin/gs`)
- **Pillow / Pillow-SIMD** — image processing (`Contents/Resources/python/lib/`)

The app requires **macOS 13+** and an Apple Silicon Mac.

## License

Private use.
