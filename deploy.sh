#!/bin/bash
# Deploy script - run this on the server: bash deploy.sh
# Or from Windows: ssh glenn@192.168.1.75 "bash -s" < deploy.sh

set -e

# Zoek de project directory
PROJECT_DIR=""
for dir in /docker/nova-kopie /docker/nova /home/glenn/nova /opt/nova; do
  if [ -f "$dir/docker-compose.yml" ]; then
    PROJECT_DIR="$dir"
    break
  fi
done

if [ -z "$PROJECT_DIR" ]; then
  echo "Project directory niet gevonden. Zoeken..."
  PROJECT_DIR=$(find /docker /home /opt -name docker-compose.yml 2>/dev/null | grep -i nova | head -1 | xargs dirname)
fi

if [ -z "$PROJECT_DIR" ]; then
  echo "FOUT: Kan project directory niet vinden"
  exit 1
fi

echo "Project gevonden op: $PROJECT_DIR"
cd "$PROJECT_DIR"

echo "Git pull (lokale wijzigingen worden weggegooid)..."
git fetch origin main
git reset --hard origin/main

echo "Docker containers herbouwen en herstarten..."
# --build (niet enkel restart): een plain restart hergebruikt de bestaande image en pakt dus
# geen nieuwe/gewijzigde dependencies op (requirements.txt, package.json) - dat gaf eerder
# precies het "staat in de code maar werkt niet op de server" probleem dat dit script juist
# moet voorkomen.
docker compose up -d --build backend frontend 2>/dev/null || docker-compose up -d --build backend frontend 2>/dev/null

echo "Klaar! De wijzigingen zijn actief."
echo "Frontend: http://192.168.1.75:8004"
echo "Backend API: http://192.168.1.75:8005/docs"
