#!/bin/bash
# =============================================
# Nova Setup Script - Voer dit 1x uit als root
# =============================================

echo "==> Nova setup gestart..."

# 1. Benodigde pakketten installeren
echo "==> Pakketten installeren..."
apt-get update -qq
apt-get install -y fuse3 curl

# 2. FUSE inschakelen (nodig voor rclone mount)
echo "==> FUSE configureren..."
sed -i 's/#user_allow_other/user_allow_other/' /etc/fuse.conf

# 3. Mount mappen aanmaken
echo "==> Mappen aanmaken..."
mkdir -p /mnt/zurg
mkdir -p /mnt/library/movies
mkdir -p /mnt/library/shows

# 4. Rechten instellen (PUID/PGID 1000)
chown -R 1000:1000 /mnt/zurg
chown -R 1000:1000 /mnt/library

# 5. Rclone remote configureren voor Zurg (WebDAV)
echo "==> Rclone remote aanmaken voor Zurg..."
mkdir -p ./config/rclone
cat > ./config/rclone/rclone.conf << 'EOF'
[zurg]
type = webdav
url = http://zurg:9999/dav
vendor = other
pacer_min_sleep = 0
EOF

echo ""
echo "==> Setup klaar!"
echo ""
echo "Volgende stap: Vul je Real-Debrid token in het .env bestand in."
echo "  nano .env"
echo ""
echo "Daarna start je de stack met:"
echo "  docker compose up -d"
echo ""
echo "Interfaces beschikbaar op:"
echo "  Jellyfin  -> http://localhost:8096"
echo "  Riven     -> http://localhost:3000"
echo "  Prowlarr  -> http://localhost:9696"
