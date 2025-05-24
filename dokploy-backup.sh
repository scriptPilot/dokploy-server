#!/bin/zsh

# Log the script start
START_TIME=$(date +%s)
echo "[INFO] Dokploy backup script started"

# Load the Dokploy server ip and password from the .env file
if [ -f .env ]; then
  export $(grep -v '^#' .env | xargs)
fi
if [ -z "$BACKUP_SERVER_IP" ]; then
  echo "[ERROR] BACKUP_SERVER_IP is not set. Please set it in your .env file."
  exit 1
fi

if [ -z "$BACKUP_SERVER_PW" ]; then
  echo "[ERROR] BACKUP_SERVER_PW is not set. Please set it in your .env file."
  exit 1
fi

if [ -z "$LOCAL_BACKUP_DIR" ]; then
  echo "[ERROR] LOCAL_BACKUP_DIR is not set. Please set it in your .env file."
  exit 1
fi
echo "[INFO] Server address loaded as $BACKUP_SERVER_IP"

# Check if /etc/dokploy folder exists on the remote server
echo "[INFO] Checking if /etc/dokploy folder exists on the remote server..."
if ! sshpass -p "$BACKUP_SERVER_PW" ssh -o StrictHostKeyChecking=no root@"$BACKUP_SERVER_IP" 'test -d /etc/dokploy'; then
  echo "[ERROR] /etc/dokploy folder not found on the remote server. Aborting backup."
  exit 1
fi
echo "[INFO] /etc/dokploy folder found on the remote server."

# Ensure the local file structure
echo "[INFO] Create the local backup folder..."
if [[ "$LOCAL_BACKUP_DIR" = /* ]]; then
  BACKUP_DIR="$LOCAL_BACKUP_DIR/$(date +"%Y-%m-%d")"
else
  BACKUP_DIR="$(pwd)/$LOCAL_BACKUP_DIR/$(date +"%Y-%m-%d")"
fi
if [ -d "$BACKUP_DIR" ]; then
  rm -rf "$BACKUP_DIR"
fi
mkdir -p "$BACKUP_DIR"
mkdir "$BACKUP_DIR/volumes"
echo "[INFO] Backup folder created at $BACKUP_DIR"

# Backup /etc/dokploy folder
BACKUP_DATE=$(date +"%Y-%m-%d")
BACKUP_DIR="$LOCAL_BACKUP_DIR/$BACKUP_DATE"
mkdir -p "$BACKUP_DIR/volumes"
echo "[INFO] Backing up /etc/dokploy folder on remote server..."
sshpass -p "$BACKUP_SERVER_PW" ssh -o StrictHostKeyChecking=no root@"$BACKUP_SERVER_IP" 'cd /etc && tar czf - dokploy' > "$BACKUP_DIR/etc-dokploy-folder.tar.gz"
echo "[INFO] /etc/dokploy folder archived and downloaded."

# Backup all Dokploy volumes
# excluding those starting with redis-data-volume, dokploy-docker-config, or buildx_buildkit
volumes=$(sshpass -p "$BACKUP_SERVER_PW" ssh -o StrictHostKeyChecking=no root@"$BACKUP_SERVER_IP" \
  "docker volume ls -q | grep -Ev '^(redis-data-volume|dokploy-docker-config|buildx_buildkit)'")
for volume in $volumes; do
  echo "[INFO] Backing up volume $volume on remote server..."
  sshpass -p "$BACKUP_SERVER_PW" ssh -o StrictHostKeyChecking=no root@"$BACKUP_SERVER_IP" \
    "docker run --rm -v $volume:/volume -v /tmp:/backup alpine tar czf /backup/$volume.tar.gz -C /volume ."
  sshpass -p "$BACKUP_SERVER_PW" scp -o StrictHostKeyChecking=no -q root@"$BACKUP_SERVER_IP":/tmp/$volume.tar.gz "$BACKUP_DIR/volumes/"
  echo "[INFO] Volume $volume archived and downloaded."
done

# Log completion
END_TIME=$(date +%s)
DURATION=$((END_TIME - START_TIME))
MINUTES=$((DURATION / 60))
SECONDS=$((DURATION % 60))
if [ "$MINUTES" -eq 1 ]; then
  unit="minute"
else
  unit="minutes"
fi
echo "[INFO] Dokploy backup script completed after $MINUTES:$(printf '%02d' $SECONDS) $unit"
