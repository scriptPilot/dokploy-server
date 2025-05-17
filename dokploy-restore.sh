#!/bin/zsh

# Log the script start
echo "[INFO] Dokploy restore script started at $(date)"

# Load the Dokploy server ip from the .env file
if [ -f .env ]; then
  export $(grep -v '^#' .env | xargs)
fi
if [ -z "$DOKPLOY_SERVER" ]; then
  echo "[ERROR] DOKPLOY_SERVER is not set. Please set it in your .env file."
  exit 1
fi
echo "[INFO] Server address loaded as $DOKPLOY_SERVER"

# Find the latest backup directory
BACKUP_PARENT_DIR="$(pwd)/dokploy-backup-files"
LATEST_BACKUP_DIR=$(ls -td "$BACKUP_PARENT_DIR"/*/ | head -1)
echo "[INFO] Using latest backup directory: $LATEST_BACKUP_DIR"

# Stop all running containers on the server (suppress container IDs)
running_containers=$(ssh root@"$DOKPLOY_SERVER" 'docker ps -q')
ssh root@"$DOKPLOY_SERVER" 'docker update --restart=no $(docker ps -q)' >/dev/null 2>&1
ssh root@"$DOKPLOY_SERVER" 'docker ps -q | xargs -r docker stop' >/dev/null 2>&1
echo "[INFO] All running Docker containers stopped and restart policies disabled."

# Remove all Docker Swarm stacks before restore to prevent automatic container restarts and duplicates
ssh root@"$DOKPLOY_SERVER" 'docker stack ls --format "{{.Name}}"' | while read -r stack; do
  if [ -n "$stack" ]; then
    ssh root@"$DOKPLOY_SERVER" "docker stack rm $stack"
    echo "[INFO] Docker stack $stack removed before restore."
  fi
done

# Wait for all containers to stop after stack removal
while true; do
  running=$(ssh root@"$DOKPLOY_SERVER" 'docker ps -q')
  if [ -z "$running" ]; then
    break
  fi
  echo "[INFO] Waiting for containers to stop after stack removal..."
  sleep 2
done

# Restore /etc/dokploy folder
scp -q "$LATEST_BACKUP_DIR/etc-dokploy-folder.tar.gz" root@"$DOKPLOY_SERVER":/tmp/
ssh root@"$DOKPLOY_SERVER" 'rm -rf /etc/dokploy && mkdir -p /etc/dokploy && cd /etc && tar xzf /tmp/etc-dokploy-folder.tar.gz'
echo "[INFO] /etc/dokploy restored from backup."

# Restore Docker volumes
for archive in "$LATEST_BACKUP_DIR/volumes/"*.tar.gz; do
  volume_name=$(basename "$archive" .tar.gz)
  scp -q "$archive" root@"$DOKPLOY_SERVER":/tmp/
  ssh root@"$DOKPLOY_SERVER" "docker volume create $volume_name >/dev/null 2>&1; docker run --rm -v $volume_name:/volume -v /tmp:/backup alpine sh -c 'rm -rf /volume/* && tar xzf /backup/$volume_name.tar.gz -C /volume'"
  echo "[INFO] Volume $volume_name restored from backup."
done

# Redeploy all stacks after restore if compose file exists
for compose_file in /etc/dokploy/*.yml; do
  stack=$(basename "$compose_file" .yml)
  if ssh root@"$DOKPLOY_SERVER" "[ -f $compose_file ]"; then
    ssh root@"$DOKPLOY_SERVER" "docker stack deploy -c $compose_file $stack"
    echo "[INFO] Docker stack $stack redeployed after restore."
  fi
done

# Restore restart policies for all previously running containers (if needed)
if [ -n "$running_containers" ]; then
  for cid in $running_containers; do
    ssh root@"$DOKPLOY_SERVER" "docker update --restart=unless-stopped $cid" >/dev/null 2>&1
  done
  echo "[INFO] Restart policies restored for previously running containers."
fi

# Clean up (remove only if file exists)
if [ -f /tmp/dokploy_stacks.txt ]; then
  rm /tmp/dokploy_stacks.txt
fi

# Do not restart containers automatically after restore. User should redeploy stacks or containers manually.
echo "[INFO] Dokploy restore script completed at $(date)"
