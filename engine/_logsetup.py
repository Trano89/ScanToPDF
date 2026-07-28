#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""Configuration de logging partagée entre le watcher et le workflow ScanToPDF."""

import sys
import logging
import datetime
from pathlib import Path


KEEP_LOGS = 60   # nombre de journaux conservés PAR type (watcher/archivage) — au-delà, purge du plus ancien


def _prune(log_dir: Path, prefix: str, keep: int = KEEP_LOGS):
    """Un journal est créé à CHAQUE traitement : sans purge, le dossier grossit indéfiniment."""
    try:
        old = sorted(log_dir.glob(f"{prefix}_*.log"), key=lambda p: p.name)[:-keep]
        for f in old:
            try:
                f.unlink()
            except OSError:
                pass
    except OSError:
        pass


def init_logging(name: str, prefix: str, log_dir: Path) -> logging.Logger:
    log_dir.mkdir(parents=True, exist_ok=True)
    _prune(log_dir, prefix)
    ts = datetime.datetime.now().strftime("%Y%m%d_%H%M%S")
    logger = logging.getLogger(name)
    logger.setLevel(logging.DEBUG)
    logger.handlers.clear()
    fmt = logging.Formatter("%(asctime)s [%(levelname)s] %(message)s", datefmt="%Y-%m-%d %H:%M:%S")
    fh = logging.FileHandler(log_dir / f"{prefix}_{ts}.log", encoding="utf-8")
    fh.setLevel(logging.DEBUG); fh.setFormatter(fmt)
    ch = logging.StreamHandler(sys.stdout)
    ch.setLevel(logging.INFO); ch.setFormatter(fmt)
    logger.addHandler(fh); logger.addHandler(ch)
    return logger
