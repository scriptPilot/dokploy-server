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

# Stop all Dokploy services
echo "[INFO] Stopping Dokploy services..."
sshpass -p "$BACKUP_SERVER_PW" ssh -o StrictHostKeyChecking=no root@"$BACKUP_SERVER_IP" 'docker service rm dokploy dokploy-postgres dokploy-redis > /dev/null 2>&1 || true'
echo "[INFO] Dokploy services stopped."

# Stop all running containers
echo "[INFO] Stopping all running containers..."
sshpass -p "$BACKUP_SERVER_PW" ssh -o StrictHostKeyChecking=no root@"$BACKUP_SERVER_IP" 'docker ps -q | xargs -r docker stop > /dev/null 2>&1'
echo "[INFO] All running containers stopped."

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

# Restart all Dokploy services
# Use --quiet to suppress noisy logs
echo "[INFO] Restarting Dokploy services..."
for service_cmd in \
  "docker service create --name dokploy-postgres --constraint 'node.role==manager' --network dokploy-network --env POSTGRES_USER=dokploy --env POSTGRES_DB=dokploy --env POSTGRES_PASSWORD=amukds4wi9001583845717ad2 --mount type=volume,source=dokploy-postgres-database,target=/var/lib/postgresql/data postgres:16" \
  "docker service create --name dokploy-redis --constraint 'node.role==manager' --network dokploy-network --mount type=volume,source=redis-data-volume,target=/data redis:7" \
  "docker service create --name dokploy --replicas 1 --network dokploy-network --mount type=bind,source=/var/run/docker.sock,target=/var/run/docker.sock --mount type=bind,source=/etc/dokploy,target=/etc/dokploy --mount type=volume,source=dokploy-docker-config,target=/root/.docker --publish published=3000,target=3000,mode=host --update-parallelism 1 --update-order stop-first --constraint 'node.role == manager' -e ADVERTISE_ADDR=$BACKUP_SERVER_IP dokploy/dokploy:latest"
do
  sshpass -p "$BACKUP_SERVER_PW" ssh -o StrictHostKeyChecking=no root@"$BACKUP_SERVER_IP" "$service_cmd > /dev/null 2>&1"
done
echo "[INFO] Dokploy services restarted."

echo "[INFO] Restarting all containers..."
stopped_containers=$(sshpass -p "$BACKUP_SERVER_PW" ssh -o StrictHostKeyChecking=no root@"$BACKUP_SERVER_IP" "docker ps -a -q -f status=exited -f status=created")
if [ -n "$stopped_containers" ]; then
  sshpass -p "$BACKUP_SERVER_PW" ssh -o StrictHostKeyChecking=no root@"$BACKUP_SERVER_IP" "docker start $stopped_containers" > /dev/null 2>&1
fi
echo "[INFO] All containers restarted."

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
