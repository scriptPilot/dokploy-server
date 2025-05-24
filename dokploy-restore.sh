#!/bin/zsh

# Log the script start
START_TIME=$(date +%s)
echo "[INFO] Dokploy restore script started"

# Load the Dokploy server ip and password from the .env file
if [ -f .env ]; then
  export $(grep -v '^#' .env | xargs)
fi
if [ -z "$RESTORE_SERVER_IP" ]; then
  echo "[ERROR] RESTORE_SERVER_IP is not set. Please set it in your .env file."
  exit 1
fi
if [ -z "$RESTORE_SERVER_PW" ]; then
  echo "[ERROR] RESTORE_SERVER_PW is not set. Please set it in your .env file."
  exit 1
fi

# Check if LOCAL_BACKUP_DIR is set
if [ -z "$LOCAL_BACKUP_DIR" ]; then
  echo "[ERROR] LOCAL_BACKUP_DIR is not set. Please set it in your .env file."
  exit 1
fi

echo "[INFO] Server address loaded as $RESTORE_SERVER_IP"

# Find the latest backup directory
if [[ "$LOCAL_BACKUP_DIR" = /* ]]; then
  BACKUP_PARENT_DIR="$LOCAL_BACKUP_DIR"
else
  BACKUP_PARENT_DIR="$(pwd)/$LOCAL_BACKUP_DIR"
fi

if [ ! -d "$BACKUP_PARENT_DIR" ]; then
  echo "[ERROR] No backup folder $BACKUP_PARENT_DIR found. Aborting restore."
  BACKUP_ERROR=1
else
  # Find the latest backup directory (suppress error if none found)
  LATEST_BACKUP_DIR=$(ls -td "$BACKUP_PARENT_DIR"/*/ 2>/dev/null | head -1)
  if [ -z "$LATEST_BACKUP_DIR" ]; then
    echo "[ERROR] No backup subdirectory found in $BACKUP_PARENT_DIR. Aborting restore."
    BACKUP_ERROR=1
  else
    echo "[INFO] Using latest backup directory: $LATEST_BACKUP_DIR"
  fi
fi

if [ "$BACKUP_ERROR" = "1" ]; then
  return 0 2>/dev/null || exit 0
fi

# Check that required backup files exist before preview
if [ ! -f "$LATEST_BACKUP_DIR/etc-dokploy-folder.tar.gz" ]; then
  echo "[ERROR] Required backup file etc-dokploy-folder.tar.gz not found in $LATEST_BACKUP_DIR. Aborting restore."
  exit 1
fi
if [ ! -f "$LATEST_BACKUP_DIR/volumes/dokploy-postgres-database.tar.gz" ]; then
  echo "[ERROR] Required backup file volumes/dokploy-postgres-database.tar.gz not found in $LATEST_BACKUP_DIR. Aborting restore."
  exit 1
fi

# Check ssh access to the remote server
echo "[INFO] Checking SSH access to the remote server..."
if ! sshpass -p "$RESTORE_SERVER_PW" ssh -o StrictHostKeyChecking=no root@"$RESTORE_SERVER_IP" 'exit'; then
  echo "[ERROR] SSH access to the remote server failed. Please check your credentials."
  exit 1
fi
echo "[INFO] SSH access to the remote server successful."

# Preview files to be restored
LATEST_BACKUP_DIR_CLEAN=${LATEST_BACKUP_DIR%/}
echo ""
echo "[PREVIEW] The following items will be restored and overwrite existing data:"
# Show only the item names, not full paths
etc_item=$(basename "$LATEST_BACKUP_DIR_CLEAN")/etc-dokploy-folder.tar.gz
echo "- $etc_item"
for archive in "$LATEST_BACKUP_DIR_CLEAN/volumes/"*.tar.gz; do
  volume_item=$(basename "$LATEST_BACKUP_DIR_CLEAN")/volumes/$(basename "$archive")
  echo "- $volume_item"
done
echo ""
echo "[PREVIEW] Proceed with restoration? (y/n) "
read -r CONFIRM
if [[ ! "$CONFIRM" =~ ^[Yy]$ ]]; then
  echo "[INFO] Restoration cancelled by user."
  exit 0
fi

# Stop all Docker swarm services and all containers
echo "[INFO] Stopping all Docker swarm services and containers on the remote server..."
sshpass -p "$RESTORE_SERVER_PW" ssh -o StrictHostKeyChecking=no root@"$RESTORE_SERVER_IP" '
  if command -v docker > /dev/null 2>&1; then
    docker service ls -q | xargs -r docker service rm > /dev/null 2>&1
    docker ps -q | xargs -r docker stop > /dev/null 2>&1
    echo "[INFO] All Docker swarm services and containers stopped (if Docker was present)."
  else
    echo "[INFO] Docker not found on remote server, skipping stop commands."
  fi
'

# Wait until all Docker services and containers are fully stopped
echo "[INFO] Waiting for all Docker services and containers to fully stop..."
if sshpass -p "$RESTORE_SERVER_PW" ssh -o StrictHostKeyChecking=no root@"$RESTORE_SERVER_IP" 'command -v docker > /dev/null 2>&1'; then
  echo "[INFO] Waiting for all Docker services and containers to fully stop..."
  while true; do
    services=$(sshpass -p "$RESTORE_SERVER_PW" ssh -o StrictHostKeyChecking=no root@"$RESTORE_SERVER_IP" 'docker service ls -q')
    containers=$(sshpass -p "$RESTORE_SERVER_PW" ssh -o StrictHostKeyChecking=no root@"$RESTORE_SERVER_IP" 'docker ps -q')
    if [ -z "$services" ] && [ -z "$containers" ]; then
      echo "[INFO] All Docker services and containers are fully stopped."
      break
    else
      echo "[INFO] Waiting... (services: $(echo $services | wc -w), containers: $(echo $containers | wc -w))"
      sleep 2
    fi
  done
fi

# Restore /etc/dokploy folder (remove existing folder first)
echo "[INFO] Restoring /etc/dokploy folder on remote server..."
# Upload tar file to /tmp on server
sshpass -p "$RESTORE_SERVER_PW" scp "$LATEST_BACKUP_DIR/etc-dokploy-folder.tar.gz" root@"$RESTORE_SERVER_IP":/tmp/
# Remove existing folder, unpack, move, and cleanup
sshpass -p "$RESTORE_SERVER_PW" ssh -o StrictHostKeyChecking=no root@"$RESTORE_SERVER_IP" '
  rm -rf /etc/dokploy && \
  mkdir -p /etc/dokploy && \
  tar xzf /tmp/etc-dokploy-folder.tar.gz -C /tmp && \
  mv /tmp/dokploy /etc/ && \
  rm -f /tmp/etc-dokploy-folder.tar.gz && \
  rm -rf /tmp/dokploy
'
echo "[INFO] /etc/dokploy folder restored."

# Restore Docker volumes from local backup (remove existing volumes first)
echo "[INFO] Restoring Docker volumes on remote server..."
for archive in "$LATEST_BACKUP_DIR/volumes/"*.tar.gz; do
  volume_name=$(basename "${archive%.tar.gz}")
  echo "[INFO] Restoring volume $volume_name on remote server..."
  # Upload tar file to /tmp on server
  sshpass -p "$RESTORE_SERVER_PW" scp "$archive" root@"$RESTORE_SERVER_IP":/tmp/${volume_name}.tar.gz
  # Unpack on server and cleanup
  sshpass -p "$RESTORE_SERVER_PW" ssh -o StrictHostKeyChecking=no root@"$RESTORE_SERVER_IP" "
    mkdir -p /var/lib/docker/volumes/$volume_name/_data && \
    tar xzf /tmp/${volume_name}.tar.gz -C /var/lib/docker/volumes/$volume_name/_data && \
    rm -f /tmp/${volume_name}.tar.gz
  "
  echo "[INFO] Volume $volume_name restored."
done

# Run Dokploy installation script
echo "[INFO] Running Dokploy installation script on remote server..."
sshpass -p "$RESTORE_SERVER_PW" ssh -tt root@"$RESTORE_SERVER_IP" 'curl -L https://dokploy.com/install.sh | sh'
echo "[INFO] Dokploy installation script executed."

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
echo "[INFO] Dokploy restore script completed after $MINUTES:$(printf '%02d' $SECONDS) $unit"
