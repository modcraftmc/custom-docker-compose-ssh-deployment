#!/usb/bin/env bash
set -e

log() {
  echo ">> [local]" "$@"
}

cleanup() {
  set +e
  log "Killing ssh agent."
  ssh-agent -k
  log "Removing workspace archive."
  rm -f /tmp/workspace.tar.bz2
}
trap cleanup EXIT

log 'Exporting environment variables...';
echo "$EXPORTS" | tr ";" "\n" > .env;

log "Packing workspace into archive to transfer onto remote machine."
tar cjvf /tmp/workspace.tar.bz2 $TAR_PACKAGE_OPERATION_MODIFIERS .

rm .env

if ! $LOCAL_MODE
then
  log "Launching ssh agent."
  eval `ssh-agent -s`

  ssh-add <(echo "$SSH_PRIVATE_KEY")
fi

remote_command="set -e;

workdir=\"\$HOME/$DIRECTORY\";

log() {
    echo '>> [remote]' \$@ ;
};

log \"\$(env)\";

if [ -d \$workdir ]
then
  log 'Deleting workspace directory...';
  rm -rf \$workdir;
fi

log 'Creating workspace directory...';
mkdir \$workdir;

log 'Unpacking workspace...';
tar -C \$workdir -xjv;

cd \$workdir;

log 'Launching docker compose...';
if $ZERO_DOWN_TIME
then
  log 'Launching scaling containers.';
  docker compose -f \"$DOCKER_COMPOSE_FILENAME\" up -d --scale $DOCKER_CONTAINER_NAME=2
else
  log 'Executing docker compose down...';
  docker compose -f \"$DOCKER_COMPOSE_FILENAME\" -p \"$DOCKER_COMPOSE_PREFIX\" down
fi

if [ -n \"$DOCKERHUB_USERNAME\" ] && [ -n \"$DOCKERHUB_PASSWORD\" ]
then
  log 'Executing docker login...';
  docker login -u \"$DOCKERHUB_USERNAME\" -p \"$DOCKERHUB_PASSWORD\"
fi

log 'Executing docker compose pull...';
docker compose -f \"$DOCKER_COMPOSE_FILENAME\" -p \"$DOCKER_COMPOSE_PREFIX\" pull

if $NO_CACHE
then
  docker compose -f \"$DOCKER_COMPOSE_FILENAME\" -p \"$DOCKER_COMPOSE_PREFIX\" build --no-cache;
  if $ZERO_DOWN_TIME
  then
    docker compose -f \"$DOCKER_COMPOSE_FILENAME\" -p \"$DOCKER_COMPOSE_PREFIX\" up -d --remove-orphans --force-recreate --scale $DOCKER_CONTAINER_NAME=1 --no-recreate $DOCKER_CONTAINER_NAME;
  else
    docker compose -f \"$DOCKER_COMPOSE_FILENAME\" -p \"$DOCKER_COMPOSE_PREFIX\" up -d --remove-orphans --force-recreate;
  fi
else
  if $ZERO_DOWN_TIME
  then
    docker compose -f \"$DOCKER_COMPOSE_FILENAME\" -p \"$DOCKER_COMPOSE_PREFIX\" up -d --remove-orphans --build --scale $DOCKER_CONTAINER_NAME=1 --no-recreate $DOCKER_CONTAINER_NAME;
  else
    docker compose -f \"$DOCKER_COMPOSE_FILENAME\" -p \"$DOCKER_COMPOSE_PREFIX\" up -d --remove-orphans --build;
  fi
fi"

if $LOCAL_MODE
then
  log "Running in local mode."
  bzcat /tmp/workspace.tar.bz2 | bash -s -- "$remote_command"
else
  log "Connecting to remote host."
  ssh -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o ServerAliveInterval=100 \
    "$SSH_USER@$SSH_HOST" -p "$SSH_PORT" \
    "$remote_command" \
    < /tmp/workspace.tar.bz2
fi