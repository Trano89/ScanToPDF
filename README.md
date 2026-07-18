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
  "startAtLogin": false
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

The app requires:
- **macOS** — native integration for file watching and notifications
- **Tesseract OCR** — for text recognition (installed via ocrmypdf)
- **ocrmypdf** — handles OCR, PDF/A conversion, and optimization
- **ImageMagick / PIL** — image corrections and assembly

## License

Private use.
