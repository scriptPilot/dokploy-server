#!/bin/zsh

# Log the scripr start
echo "[INFO] Dokploy backup script started at $(date)"

# Load the Dokploy server ip from the .env file
if [ -f .env ]; then
  export $(grep -v '^#' .env | xargs)
fi
if [ -z "$DOKPLOY_SERVER" ]; then
  echo "[ERROR] DOKPLOY_SERVER is not set. Please set it in your .env file."
  exit 1
fi
echo "[INFO] Server address loaded as $DOKPLOY_SERVER"

# Ensure the local file structure
BACKUP_DIR="$(pwd)/dokploy-backup-files/$(date +"%Y-%m-%d")"
if [ -d "$BACKUP_DIR" ]; then
  rm -rf "$BACKUP_DIR"
fi
mkdir -p "$BACKUP_DIR"
mkdir "$BACKUP_DIR/volumes"
echo "[INFO] Backup folder created"

# Archive and download the /etc/dokploy folder
echo "[INFO] Archiving and downloading the /etc/dokploy folder..."
ssh root@"$DOKPLOY_SERVER" 'cd /etc && tar czf - dokploy' > "$BACKUP_DIR/etc-dokploy-folder.tar.gz"
echo "[INFO] Folder /etc/dokploy archived and downloaded as etc-dokploy-folder.tar.gz"

# Archive and download all Docker volumes
for volume in $(ssh root@"$DOKPLOY_SERVER" 'docker volume ls -q'); do
  if [[ "$volume" == redis-data-volume ]] || [[ "$volume" == buildx_buildkit* ]]; then
    echo "[INFO] Skipping volume $volume as requested."
    continue
  fi
  echo "[INFO] Archiving and downloading volume $volume..."
  ssh root@"$DOKPLOY_SERVER" "docker run --rm -v $volume:/volume -v /tmp:/backup alpine tar czf /backup/$volume.tar.gz -C /volume ." && \
  scp -q root@"$DOKPLOY_SERVER":/tmp/"$volume".tar.gz "$BACKUP_DIR/volumes/"
  echo "[INFO] Volume $volume archived and downloaded as $volume.tar.gz"
done

# Log completion
echo "[INFO] Dokploy backup script completed at $(date)"
