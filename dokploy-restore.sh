#!/bin/zsh

# Log the script start
echo "[INFO] Dokploy restore script started at $(date)"

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

# Preview files to be restored
LATEST_BACKUP_DIR_CLEAN=${LATEST_BACKUP_DIR%/}
echo ""
echo "[PREVIEW] The following items will be restored:"  # simplified wording
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

# Check if Dokploy is installed on the server, if not, run install script
echo "[INFO] Checking if Dokploy is installed on the server..."
if ! sshpass -p "$RESTORE_SERVER_PW" ssh -o StrictHostKeyChecking=no root@"$RESTORE_SERVER_IP" '[ -d /etc/dokploy ]'; then
  echo "[INFO] Dokploy is not installed. Running Dokploy install script on server..."
  sshpass -p "$RESTORE_SERVER_PW" ssh -o StrictHostKeyChecking=no root@"$RESTORE_SERVER_IP" 'curl -sSL https://dokploy.com/install.sh | sh'
  echo "[INFO] Dokploy install script completed on the server."
else
  echo "[INFO] Dokploy already installed on the server."
fi

# Stop all Docker swarm services and all containers
echo "[INFO] Stopping all Docker swarm services and containers..."
sshpass -p "$RESTORE_SERVER_PW" ssh -o StrictHostKeyChecking=no root@"$RESTORE_SERVER_IP" 'docker service ls -q | xargs -r docker service rm; docker ps -q | xargs -r docker stop > /dev/null'
echo "[INFO] All Docker swarm services and containers stopped."

# Restore /etc/dokploy folder
echo "[INFO] Restoring /etc/dokploy folder from backup..."
sshpass -p "$RESTORE_SERVER_PW" ssh -o StrictHostKeyChecking=no root@"$RESTORE_SERVER_IP" 'rm -rf /etc/dokploy'
sshpass -p "$RESTORE_SERVER_PW" scp -o StrictHostKeyChecking=no -q "$LATEST_BACKUP_DIR/etc-dokploy-folder.tar.gz" root@"$RESTORE_SERVER_IP":/tmp/
sshpass -p "$RESTORE_SERVER_PW" ssh -o StrictHostKeyChecking=no root@"$RESTORE_SERVER_IP" 'mkdir -p /etc/dokploy && cd /etc && tar xzf /tmp/etc-dokploy-folder.tar.gz'
echo "[INFO] /etc/dokploy restored from backup."

# Restore Docker volumes
for archive in "$LATEST_BACKUP_DIR/volumes/"*.tar.gz; do
  volume_name=$(basename "$archive" .tar.gz)
  echo "[INFO] Removing existing volume $volume_name before restore..."
  sshpass -p "$RESTORE_SERVER_PW" ssh -o StrictHostKeyChecking=no root@"$RESTORE_SERVER_IP" "docker volume rm -f $volume_name >/dev/null 2>&1 || true"
  echo "[INFO] Restoring volume $volume_name from backup..."
  sshpass -p "$RESTORE_SERVER_PW" scp -o StrictHostKeyChecking=no -q "$archive" root@"$RESTORE_SERVER_IP":/tmp/
  sshpass -p "$RESTORE_SERVER_PW" ssh -o StrictHostKeyChecking=no root@"$RESTORE_SERVER_IP" "docker volume create $volume_name >/dev/null 2>&1; docker run --rm -v $volume_name:/volume -v /tmp:/backup alpine sh -c 'rm -rf /volume/* && tar xzf /backup/$volume_name.tar.gz -C /volume'"
  echo "[INFO] Volume $volume_name restored from backup."
done

# Run Dokploy install script on server after restore
echo "[INFO] Running Dokploy install script on server after restore..."
sshpass -p "$RESTORE_SERVER_PW" ssh -o StrictHostKeyChecking=no root@"$RESTORE_SERVER_IP" 'curl -sSL https://dokploy.com/install.sh | sh'
echo "[INFO] Dokploy install script completed on server after restore."

# Do not restart containers automatically after restore. User should redeploy stacks or containers manually.
echo "[INFO] Dokploy restore script completed at $(date)"
