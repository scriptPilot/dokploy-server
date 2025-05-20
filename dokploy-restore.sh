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

# Stop all running containers on the server (suppress container IDs)
echo "[INFO] Stopping all running Docker containers on the server..."
running_containers=$(sshpass -p "$RESTORE_SERVER_PW" ssh -o StrictHostKeyChecking=no root@"$RESTORE_SERVER_IP" 'docker ps -q')
sshpass -p "$RESTORE_SERVER_PW" ssh -o StrictHostKeyChecking=no root@"$RESTORE_SERVER_IP" 'docker update --restart=no $(docker ps -q)' >/dev/null 2>&1
sshpass -p "$RESTORE_SERVER_PW" ssh -o StrictHostKeyChecking=no root@"$RESTORE_SERVER_IP" 'docker ps -q | xargs -r docker stop' >/dev/null 2>&1
echo "[INFO] All running Docker containers stopped and restart policies disabled."

# Remove all Docker Swarm stacks before restore to prevent automatic container restarts and duplicates
echo "[INFO] Removing all Docker Swarm stacks before restore..."
sshpass -p "$RESTORE_SERVER_PW" ssh -o StrictHostKeyChecking=no root@"$RESTORE_SERVER_IP" 'docker stack ls --format "{{.Name}}"' | while read -r stack; do
  if [ -n "$stack" ]; then
    sshpass -p "$RESTORE_SERVER_PW" ssh -o StrictHostKeyChecking=no root@"$RESTORE_SERVER_IP" "docker stack rm $stack"
    echo "[INFO] Docker stack $stack removed before restore."
  fi
done

# Wait for all containers to stop after stack removal
echo "[INFO] Waiting for all containers to stop after stack removal..."
while true; do
  running=$(sshpass -p "$RESTORE_SERVER_PW" ssh -o StrictHostKeyChecking=no root@"$RESTORE_SERVER_IP" 'docker ps -q')
  if [ -z "$running" ]; then
    break
  fi
  echo "[INFO] Waiting for containers to stop after stack removal..."
  sleep 2
done

# Restore /etc/dokploy folder
echo "[INFO] Restoring /etc/dokploy folder from backup..."
sshpass -p "$RESTORE_SERVER_PW" scp -o StrictHostKeyChecking=no -q "$LATEST_BACKUP_DIR/etc-dokploy-folder.tar.gz" root@"$RESTORE_SERVER_IP":/tmp/
sshpass -p "$RESTORE_SERVER_PW" ssh -o StrictHostKeyChecking=no root@"$RESTORE_SERVER_IP" 'rm -rf /etc/dokploy && mkdir -p /etc/dokploy && cd /etc && tar xzf /tmp/etc-dokploy-folder.tar.gz'
echo "[INFO] /etc/dokploy restored from backup."

# Restore Docker volumes
for archive in "$LATEST_BACKUP_DIR/volumes/"*.tar.gz; do
  volume_name=$(basename "$archive" .tar.gz)
  echo "[INFO] Restoring volume $volume_name from backup..."
  sshpass -p "$RESTORE_SERVER_PW" scp -o StrictHostKeyChecking=no -q "$archive" root@"$RESTORE_SERVER_IP":/tmp/
  sshpass -p "$RESTORE_SERVER_PW" ssh -o StrictHostKeyChecking=no root@"$RESTORE_SERVER_IP" "docker volume create $volume_name >/dev/null 2>&1; docker run --rm -v $volume_name:/volume -v /tmp:/backup alpine sh -c 'rm -rf /volume/* && tar xzf /backup/$volume_name.tar.gz -C /volume'"
  echo "[INFO] Volume $volume_name restored from backup."
done

# Redeploy all stacks after restore if compose file exists
for compose_file in /etc/dokploy/*.yml; do
  stack=$(basename "$compose_file" .yml)
  echo "[INFO] Redeploying stack $stack after restore..."
  if sshpass -p "$RESTORE_SERVER_PW" ssh -o StrictHostKeyChecking=no root@"$RESTORE_SERVER_IP" "[ -f $compose_file ]"; then
    sshpass -p "$RESTORE_SERVER_PW" ssh -o StrictHostKeyChecking=no root@"$RESTORE_SERVER_IP" "docker stack deploy -c $compose_file $stack"
    echo "[INFO] Docker stack $stack redeployed after restore."
  fi
done

# Restore restart policies for all previously running containers (if needed)
if [ -n "$running_containers" ]; then
  for cid in $running_containers; do
    sshpass -p "$RESTORE_SERVER_PW" ssh -o StrictHostKeyChecking=no root@"$RESTORE_SERVER_IP" "docker update --restart=unless-stopped $cid" >/dev/null 2>&1
  done
  echo "[INFO] Restart policies restored for previously running containers."
fi

# Clean up (remove only if file exists)
if [ -f /tmp/dokploy_stacks.txt ]; then
  rm /tmp/dokploy_stacks.txt
fi

# Do not restart containers automatically after restore. User should redeploy stacks or containers manually.
echo "[INFO] Dokploy restore script completed at $(date)"
