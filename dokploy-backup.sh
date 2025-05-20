#!/bin/zsh

# Log the scripr start
echo "[INFO] Dokploy backup script started at $(date)"

# Load the Dokploy server ip and password from the .env file
if [ -f .env ]; then
  export $(grep -v '^#' .env | xargs)
fi
if [ -z "$DOKPLOY_SERVER_IP" ]; then
  echo "[ERROR] DOKPLOY_SERVER_IP is not set. Please set it in your .env file."
  exit 1
fi

if [ -z "$DOKPLOY_SERVER_PW" ]; then
  echo "[ERROR] DOKPLOY_SERVER_PW is not set. Please set it in your .env file."
  exit 1
fi

if [ -z "$DOKPLOY_BACKUP_DIR" ]; then
  echo "[ERROR] DOKPLOY_BACKUP_DIR is not set. Please set it in your .env file."
  exit 1
fi
echo "[INFO] Server address loaded as $DOKPLOY_SERVER_IP"

# Ensure the local file structure
if [[ "$DOKPLOY_BACKUP_DIR" = /* ]]; then
  BACKUP_DIR="$DOKPLOY_BACKUP_DIR/$(date +"%Y-%m-%d")"
else
  BACKUP_DIR="$(pwd)/$DOKPLOY_BACKUP_DIR/$(date +"%Y-%m-%d")"
fi
if [ -d "$BACKUP_DIR" ]; then
  rm -rf "$BACKUP_DIR"
fi
mkdir -p "$BACKUP_DIR"
mkdir "$BACKUP_DIR/volumes"
echo "[INFO] Backup folder created"

# Archive and download the /etc/dokploy folder
echo "[INFO] Archiving and downloading the /etc/dokploy folder..."
sshpass -p "$DOKPLOY_SERVER_PW" ssh -o StrictHostKeyChecking=no root@"$DOKPLOY_SERVER_IP" 'cd /etc && tar czf - dokploy' > "$BACKUP_DIR/etc-dokploy-folder.tar.gz"
echo "[INFO] Folder /etc/dokploy archived and downloaded as etc-dokploy-folder.tar.gz"

# Archive and download all Docker volumes
for volume in $(sshpass -p "$DOKPLOY_SERVER_PW" ssh -o StrictHostKeyChecking=no root@"$DOKPLOY_SERVER_IP" 'docker volume ls -q'); do
  if [[ "$volume" == redis-data-volume ]] || [[ "$volume" == buildx_buildkit* ]]; then
    echo "[INFO] Skipping volume $volume as requested."
    continue
  fi
  echo "[INFO] Archiving and downloading volume $volume..."
  sshpass -p "$DOKPLOY_SERVER_PW" ssh -o StrictHostKeyChecking=no root@"$DOKPLOY_SERVER_IP" "docker run --rm -v $volume:/volume -v /tmp:/backup alpine tar czf /backup/$volume.tar.gz -C /volume ." && \
  sshpass -p "$DOKPLOY_SERVER_PW" scp -o StrictHostKeyChecking=no -q root@"$DOKPLOY_SERVER_IP":/tmp/"$volume".tar.gz "$BACKUP_DIR/volumes/"
  echo "[INFO] Volume $volume archived and downloaded as $volume.tar.gz"
done

# Log completion
echo "[INFO] Dokploy backup script completed at $(date)"
