# Kleines Werkzeug-Image fuer den SQLite-/SpatiaLite-Leg des Smoke-Tests.
#
# Hintergrund: der Host hat kein mod_spatialite, das d-migrate-Runtime-Image
# hat keinen sqlite3-CLI (und soll auch keinen bekommen — das Image ist die
# Anwendung, nicht ein Admin-Werkzeugkasten). Dieses Image bringt beides
# zusammen und wird einmal gebaut, statt pro Smoke-Lauf apt-get zu fahren.
FROM debian:stable-slim

RUN apt-get update \
 && apt-get install -y --no-install-recommends \
      sqlite3 \
      libsqlite3-mod-spatialite \
 && rm -rf /var/lib/apt/lists/*

# Aufruf in den Skripten bewusst pfadlos (`SELECT load_extension('mod_spatialite')`):
# SQLite ergaenzt die Plattform-Endung, der Rest laeuft ueber den System-Cache —
# damit ist es nicht an x86_64-Linux gebunden (arm64/macOS-Docker laufen mit).
WORKDIR /work
