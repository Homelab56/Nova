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

echo "Git pull..."
git pull origin main

echo "Docker containers herstarten..."
docker compose restart backend frontend 2>/dev/null || docker-compose restart backend frontend 2>/dev/null

echo "Klaar! De wijzigingen zijn actief."
echo "Frontend: http://192.168.1.75:8004"
echo "Backend API: http://192.168.1.75:8005/docs"
