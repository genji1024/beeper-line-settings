#!/bin/sh
# Build the bridge, write data/config.yaml from .env, generate the
# appservice registration and start the bridge. Safe to re-run: the
# settings below are applied again, everything else in config.yaml is kept.
#
#   cp .env.example .env && $EDITOR .env
#   ./setup.sh
#
# Run as the user that runs `docker compose`; no sudo.
set -eu
cd "$(dirname "$0")"

# KEY=VALUE lines without shell evaluation, as docker compose reads them.
load_env() {
  [ -f "$1" ] || { echo "error: $1 not found (cp .env.example .env)" >&2; exit 1; }
  while IFS= read -r line || [ -n "$line" ]; do
    case "$line" in ''|'#'*) continue ;; esac
    key="${line%%=*}"; val="${line#*=}"
    case "$key" in *[!A-Za-z0-9_]*) continue ;; esac
    case "$val" in
      \"*\") val="${val#\"}"; val="${val%\"}" ;;
      \'*\') val="${val#\'}"; val="${val%\'}" ;;
    esac
    export "$key=$val"
  done < "$1"
}
set_env() {
  if grep -q "^$1=" .env; then
    sed -i "s|^$1=.*|$1=$2|" .env
  else
    printf '%s=%s\n' "$1" "$2" >> .env
  fi
}
load_env .env

: "${SERVER_NAME:?SERVER_NAME must be set in .env}"
: "${HOMESERVER_NETWORK:?HOMESERVER_NETWORK must be set in .env}"
: "${BRIDGE_ADMIN:?BRIDGE_ADMIN must be set in .env}"
HOMESERVER_URL="${HOMESERVER_URL:-http://synapse:8008}"
BRIDGE_USERS="${BRIDGE_USERS:-$SERVER_NAME}"
DATABASE_URI="${DATABASE_URI:-}"

docker network inspect "$HOMESERVER_NETWORK" >/dev/null 2>&1 || {
  echo "error: Docker network $HOMESERVER_NETWORK does not exist (HOMESERVER_NETWORK in .env)" >&2
  exit 1
}

# The bridge must write data/, and you must be able to read what it writes
# (the registration, to hand it to the homeserver):
#   rootful docker : your own uid/gid
#   rootless docker: container root (0), which is you on the host
if [ -z "${BRIDGE_UID:-}" ] || [ -z "${BRIDGE_GID:-}" ]; then
  if docker info -f '{{.SecurityOptions}}' 2>/dev/null | grep -q rootless; then
    BRIDGE_UID=0; BRIDGE_GID=0
  else
    BRIDGE_UID="$(id -u)"; BRIDGE_GID="$(id -g)"
  fi
  set_env BRIDGE_UID "$BRIDGE_UID"
  set_env BRIDGE_GID "$BRIDGE_GID"
  echo "==> running the bridge as $BRIDGE_UID:$BRIDGE_GID (saved to .env)"
fi
mkdir -p data

echo "==> building the bridge"
docker compose build

# Run the bridge binary, or yq (both in the image), as the bridge's user.
run() {
  entry="$1"; shift
  docker compose run --rm --no-deps --user "$BRIDGE_UID:$BRIDGE_GID" --entrypoint "$entry" "$@"
}

if [ ! -f data/config.yaml ]; then
  echo "==> writing the example config to data/config.yaml"
  run /usr/bin/matrix-line beeper-line -c /data/config.yaml -e
fi

if [ -n "$DATABASE_URI" ]; then
  DATABASE_TYPE=postgres
else
  DATABASE_TYPE=sqlite3-fk-wal DATABASE_URI="file:/data/beeper-line.db?_txlock=immediate"
fi

echo "==> applying .env to data/config.yaml"
# Values go in through the environment, so they need no quoting here.
run yq \
  -e HOMESERVER_URL="$HOMESERVER_URL" -e SERVER_NAME="$SERVER_NAME" \
  -e BRIDGE_USERS="$BRIDGE_USERS" -e BRIDGE_ADMIN="$BRIDGE_ADMIN" \
  -e DATABASE_TYPE="$DATABASE_TYPE" -e DATABASE_URI="$DATABASE_URI" \
  beeper-line -i '
    .homeserver.address = strenv(HOMESERVER_URL) |
    .homeserver.domain = strenv(SERVER_NAME) |
    .appservice.address = "http://beeper-line:29322" |
    .appservice.hostname = "0.0.0.0" |
    .appservice.port = 29322 |
    .bridge.permissions = {} |
    .bridge.permissions[strenv(BRIDGE_USERS)] = "user" |
    .bridge.permissions[strenv(BRIDGE_ADMIN)] = "admin" |
    .database.type = strenv(DATABASE_TYPE) |
    .database.uri = strenv(DATABASE_URI)
  ' /data/config.yaml

# The registration carries the tokens the homeserver and the bridge share;
# generating it again would change them.
if [ ! -f data/registration.yaml ]; then
  echo "==> generating data/registration.yaml"
  run /usr/bin/matrix-line beeper-line -g -c /data/config.yaml -r /data/registration.yaml
fi

if [ -n "${REGISTRATION_DIR:-}" ]; then
  mkdir -p "$REGISTRATION_DIR"
  cp data/registration.yaml "$REGISTRATION_DIR/beeper-line.yaml"
  echo "==> copied the registration to $REGISTRATION_DIR/beeper-line.yaml"
fi

echo "==> starting the bridge"
docker compose up -d

echo "==> done. If the homeserver does not know the registration yet, register it"
echo "    (README.md) and restart the homeserver; then message @linebot:$SERVER_NAME"
