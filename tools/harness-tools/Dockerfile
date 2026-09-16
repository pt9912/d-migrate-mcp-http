# Werkzeug-Images fuer die Test-Skripte (Smoke, Typ-Matrix), zwei Stages:
#
#   sqlite (Default-Ziel, letzte Stage)  -> dmigrate-harness-tools:local
#       sqlite3 + libsqlite3-mod-spatialite fuer die SQLite-/SpatiaLite-Legs
#   py (--target py)                     -> dmigrate-harness-python:local
#       python3 fuer scripts/lib/silent-loss-check.py (Typ-Matrix)
#
# Hintergrund: der Host hat kein mod_spatialite und kein python3, das
# d-migrate-Runtime-Image hat keinen sqlite3-CLI (und soll auch keinen
# bekommen — das Image ist die Anwendung, nicht ein Admin-Werkzeugkasten).
# Beide Stages werden einmal gebaut und gecacht; `make harness-tools` baut
# beide. Der Python-Check laeuft bewusst NICHT im sqlite-Image: so bleibt
# dessen Zweck eindeutig und das Interpreter-Basisimage liefert python3.

# --- Stage "py": Interpreter fuer den Typcheck (python:3-slim ist Debian-basiert)
FROM python:3-slim AS py
WORKDIR /work

# --- Stage "sqlite" (Default): SQLite/SpatiaLite-Werkzeuge
FROM debian:stable-slim AS sqlite

RUN apt-get update \
 && apt-get install -y --no-install-recommends \
      sqlite3 \
      libsqlite3-mod-spatialite \
 && rm -rf /var/lib/apt/lists/*

# Aufruf in den Skripten bewusst pfadlos (`SELECT load_extension('mod_spatialite')`):
# SQLite ergaenzt die Plattform-Endung, der Rest laeuft ueber den System-Cache —
# damit ist es nicht an x86_64-Linux gebunden (arm64/macOS-Docker laufen mit).
WORKDIR /work
