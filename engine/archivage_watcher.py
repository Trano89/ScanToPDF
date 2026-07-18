#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""
Watcher ScanToPDF — FILE D'ATTENTE non visuelle.

Principe : UN SEUL worker traite à la fois. Chaque dépôt de .tif/.tiff (à la racine du dossier
surveillé) « arme » le worker. Un dépôt survenu PENDANT un traitement est mémorisé et déclenche un
nouveau tour à la fin du traitement en cours → aucune série n'est perdue, tout est traité à la suite.

Le workflow (archivage_workflow.py) traite déjà, dans un même passage, tous les projets présents,
un par un (le premier, puis le suivant…). La file garantit en plus que les fichiers ajoutés
pendant un traitement sont bien repris ensuite.

Lancé et supervisé par l'application. Aucun chemin en dur (SCAN_DIR / SCANTOPDF_APPSUPPORT / sys.executable).
"""

import os
import sys
import time
import signal
import logging
import threading
import subprocess
import datetime
from pathlib import Path

from watchdog.observers import Observer
from watchdog.events import FileSystemEventHandler

from _logsetup import init_logging   # module voisin (copié dans Resources/engine/)


SCAN_DIR        = Path(os.environ.get("SCAN_DIR", "/Users/Shared/FVJC_SCAN"))
APPSUPPORT      = Path(os.environ.get("SCANTOPDF_APPSUPPORT", "/Users/Shared/ScanToPDF"))
LOG_DIR         = APPSUPPORT / "logs"
WORKFLOW_SCRIPT = Path(__file__).resolve().parent / "archivage_workflow.py"
PYTHON_BIN      = sys.executable
DEBOUNCE        = 3.0     # s de calme après le DERNIER dépôt avant de lancer (évite de traiter en plein copier)
STABILITY_SECS  = 1.0     # les TIFF racine doivent avoir une taille/mtime STABLE sur cet intervalle (copie réseau lente)
BUSY_RETRY      = 5.0     # s avant de réessayer si une autre instance tient le verrou
BUSY_EXIT_CODE  = 75      # code renvoyé par le workflow quand le verrou est déjà pris (occupé)
MAX_FAIL_RETRY  = 5       # tentatives max sur échec non récupérable avant d'attendre un nouveau dépôt


# (init_logging est fourni par le module partagé _logsetup.py)


class Worker(threading.Thread):
    """Thread unique : sérialise les traitements et absorbe les dépôts concurrents (file d'attente)."""

    def __init__(self, logger: logging.Logger):
        super().__init__(daemon=True)
        self._logger = logger
        self._cv = threading.Condition()
        self._pending = False          # du travail est en attente
        self._last_event = 0.0         # date (monotone) du dernier dépôt, pour le débounce
        self._stop = False
        self._current = None           # Popen du workflow en cours (pour l'arrêt propre)
        self._fail_streak = 0          # échecs consécutifs (back-off + plafond)

    def notify(self, filename: str | None = None):
        """Signale un nouveau dépôt. Ne bloque jamais (appelé depuis le thread de surveillance)."""
        with self._cv:
            self._last_event = time.monotonic()
            self._pending = True
            self._fail_streak = 0      # un nouveau dépôt relance le compteur d'échecs
            self._cv.notify()
        if filename:
            self._logger.info(f"'{filename}' détecté — ajouté à la file d'attente.")

    def stop(self):
        with self._cv:
            self._stop = True
            self._cv.notify()
        self._kill_current(signal.SIGTERM)   # ne pas laisser un workflow (OCR) orphelin

    def _kill_current(self, sig):
        cur = self._current
        if cur is not None and cur.poll() is None:
            # Le workflow est lancé en session isolée → on tue TOUT le sous-arbre (gs/tesseract inclus).
            try:
                os.killpg(os.getpgid(cur.pid), sig)
            except Exception:
                try:
                    cur.terminate()
                except Exception:
                    pass

    def _root_stable(self) -> bool:
        """Les TIFF à la racine ont-ils une taille+mtime STABLES sur STABILITY_SECS ? (anti-copie-en-cours)"""
        def snap():
            d = {}
            try:
                for p in SCAN_DIR.iterdir():
                    if p.is_file() and p.suffix.lower() in (".tif", ".tiff"):
                        try:
                            st = p.stat(); d[p.name] = (st.st_size, int(st.st_mtime))
                        except FileNotFoundError:
                            pass
            except Exception:
                pass
            return d
        a = snap()
        if not a:
            return True   # rien à la racine : le workflow ne trouvera rien, inutile d'attendre
        time.sleep(STABILITY_SECS)
        return a == snap()

    def run(self):
        while True:
            # 1) Attendre qu'il y ait du travail.
            with self._cv:
                while not self._pending and not self._stop:
                    self._cv.wait()
                if self._stop:
                    return
            # 2) Débounce + contrôle de STABILITÉ (fichiers plus en cours d'écriture).
            while True:
                with self._cv:
                    if self._stop:
                        return
                    quiet = time.monotonic() - self._last_event
                if quiet < DEBOUNCE:
                    time.sleep(0.3); continue
                if not self._root_stable():
                    self._logger.info("Fichiers encore en cours d'écriture — on patiente…")
                    continue
                break
            # 3) Prendre le travail : on efface `pending` AVANT de lancer → tout dépôt survenu PENDANT
            #    le traitement re-arme `pending` et sera traité au tour suivant.
            with self._cv:
                self._pending = False
            self._process()

    def _process(self):
        self._logger.info("File d'attente : démarrage d'un traitement…")
        rc, err = None, ""
        try:
            with self._cv:
                if self._stop:
                    return
                # start_new_session=True : le workflow devient chef de groupe → arrêt propre du sous-arbre.
                self._current = subprocess.Popen(
                    [PYTHON_BIN, str(WORKFLOW_SCRIPT)],
                    stdout=subprocess.DEVNULL, stderr=subprocess.PIPE, text=True, start_new_session=True)
            proc = self._current
            try:
                _, err = proc.communicate(timeout=7200)
                rc = proc.returncode
            except subprocess.TimeoutExpired:
                self._kill_current(signal.SIGKILL)
                proc.communicate()
                self._logger.error("Workflow : délai dépassé (sous-arbre tué).")
                rc = -1
        except Exception as exc:
            self._logger.error(f"Erreur de lancement du workflow : {exc}")
            rc = -1
        finally:
            with self._cv:
                self._current = None

        if self._stop:
            return
        if rc == 0:
            self._logger.info("File d'attente : traitement terminé.")
            self._fail_streak = 0
        elif rc == BUSY_EXIT_CODE:
            # Une autre instance (ex. « Traiter maintenant ») tenait le verrou → on réessaie.
            # On NE touche PAS _last_event : un dépôt arrivé entre-temps garde son débounce.
            self._logger.info(f"Occupé (autre instance) — nouvelle tentative dans {int(BUSY_RETRY)}s.")
            time.sleep(BUSY_RETRY)
            with self._cv:
                self._pending = True
                self._cv.notify()
        else:
            # Échec non récupéré (OOM/kill/erreur) : des TIFF peuvent rester à la racine, non isolés.
            # On réessaie avec back-off exponentiel, dans la limite de MAX_FAIL_RETRY (sinon on attend un dépôt).
            self._fail_streak += 1
            snippet = (err or "").strip()[:500]
            if self._fail_streak <= MAX_FAIL_RETRY:
                backoff = min(120, 2 ** self._fail_streak)
                self._logger.error(f"Workflow échoué (code {rc}) — tentative {self._fail_streak}/{MAX_FAIL_RETRY} dans {backoff}s.\n{snippet}")
                time.sleep(backoff)
                with self._cv:
                    self._pending = True
                    self._cv.notify()
            else:
                self._logger.error(f"Workflow échoué (code {rc}) — abandon jusqu'au prochain dépôt.\n{snippet}")


class TiffHandler(FileSystemEventHandler):
    def __init__(self, worker: Worker):
        self._worker = worker

    def _is_tiff_at_root(self, path: str) -> bool:
        p = Path(path)
        try:
            same_dir = p.parent.resolve() == SCAN_DIR.resolve()
        except Exception:
            same_dir = False
        return same_dir and p.suffix.lower() in (".tif", ".tiff")

    def on_created(self, event):
        if not event.is_directory and self._is_tiff_at_root(event.src_path):
            self._worker.notify(Path(event.src_path).name)

    def on_moved(self, event):
        if not event.is_directory and self._is_tiff_at_root(event.dest_path):
            self._worker.notify(Path(event.dest_path).name)


def _has_pending_tiffs() -> bool:
    try:
        return any(p.is_file() and p.suffix.lower() in (".tif", ".tiff") for p in SCAN_DIR.iterdir())
    except Exception:
        return False


def main():
    logger = init_logging("scantopdf.watcher", "watcher", LOG_DIR)
    SCAN_DIR.mkdir(parents=True, exist_ok=True)

    worker = Worker(logger)
    worker.start()

    # Rattrapage initial : des TIFF sont peut-être déjà présents (déposés app fermée) → on les met en file.
    if _has_pending_tiffs():
        logger.info("Fichiers déjà présents au démarrage — mis en file d'attente.")
        worker.notify()

    handler  = TiffHandler(worker)
    observer = Observer()
    observer.schedule(handler, str(SCAN_DIR), recursive=False)
    observer.start()
    logger.info(f"Surveillance active (file d'attente) : {SCAN_DIR}")

    # Arrêt propre : l'app envoie SIGTERM (Engine.stop) ; on ne se contente plus de SIGINT.
    stop_evt = threading.Event()
    def _on_signal(signum, frame):
        logger.info(f"Signal {signum} reçu — arrêt du watcher.")
        stop_evt.set()
    signal.signal(signal.SIGTERM, _on_signal)
    signal.signal(signal.SIGINT, _on_signal)

    try:
        while not stop_evt.wait(0.5):
            pass
    finally:
        worker.stop()          # tue le workflow en cours (sous-arbre OCR) s'il y en a un
        observer.stop()
        observer.join()


if __name__ == "__main__":
    main()
