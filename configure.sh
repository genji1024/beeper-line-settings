#!/bin/sh
# Ask for the bridge's settings and write them to .env. setup.sh runs this
# when .env is missing or incomplete; run it yourself to change them. The
# current values (or what can be found out from a running Synapse) are
# offered as defaults: press Enter to keep one.
#
#   ./configure.sh
set -eu
cd "$(dirname "$0")"
. ./lib.sh

[ -t 0 ] || { echo "error: configure.sh asks questions; run it in a terminal (or write .env from .env.example)" >&2; exit 1; }
[ -f .env ] && load_env .env

# ask VAR "question" default: read a value, Enter keeps the default.
ask() {
  printf '%s' "$2" >&2
  [ -n "$3" ] && printf ' [%s]' "$3" >&2
  printf ': ' >&2
  IFS= read -r answer || exit 1
  [ -n "$answer" ] || answer="$3"
  eval "$1=\$answer"
}

# ---------------------------------------------------------------------------
# What a running Synapse container tells us: its network, its name there,
# the host directory mounted at /data, and the server name in its config.
# ---------------------------------------------------------------------------
found_network= found_url= found_data= found_server_name= found_koto=
if command -v docker >/dev/null 2>&1; then
  for id in $(docker ps -q 2>/dev/null); do
    image=$(docker inspect -f '{{.Config.Image}}' "$id")
    case "$image" in *synapse*) ;; *) continue ;; esac
    nets=$(docker inspect -f '{{range $k, $v := .NetworkSettings.Networks}}{{println $k}}{{end}}' "$id")
    found_network=$(printf '%s\n' "$nets" | grep '_default$' | head -n1)
    [ -n "$found_network" ] || found_network=$(printf '%s\n' "$nets" | sed -n '/./{p;q;}')
    name=$(docker inspect -f '{{index .Config.Labels "com.docker.compose.service"}}' "$id")
    [ -n "$name" ] || name=$(docker inspect -f '{{.Name}}' "$id" | sed 's|^/||')
    found_url="http://$name:8008"
    found_data=$(docker inspect -f '{{range .Mounts}}{{if eq .Destination "/data"}}{{.Source}}{{end}}{{end}}' "$id")
    if [ -n "$found_data" ] && [ -r "$found_data/homeserver.yaml" ]; then
      found_server_name=$(sed -n 's/^server_name: *["'\'']\{0,1\}\([^"'\'']*\)["'\'']\{0,1\} *$/\1/p' "$found_data/homeserver.yaml" | head -n1)
    fi
    # koto lists every file in data/synapse/appservices/ (its scripts/init.sh).
    dir=$(docker inspect -f '{{index .Config.Labels "com.docker.compose.project.working_dir"}}' "$id")
    [ -n "$dir" ] && [ -f "$dir/scripts/init.sh" ] && grep -q appservices "$dir/scripts/init.sh" && found_koto="$dir"
    echo "==> found Synapse: $image, on network $found_network as $name" >&2
    break
  done
fi

echo "Matrix homeserver" >&2
d="${SERVER_NAME:-$found_server_name}"
while :; do
  ask SERVER_NAME "  Server name (the part after ':' in user IDs)" "$d"
  [ -n "$SERVER_NAME" ] && break
  echo "  required" >&2
done
d="${HOMESERVER_NETWORK:-$found_network}"
while :; do
  ask HOMESERVER_NETWORK "  Docker network the homeserver is on" "$d"
  if [ -z "$HOMESERVER_NETWORK" ]; then
    echo "  required; the networks here:" >&2
    docker network ls --format '    {{.Name}}' >&2 2>/dev/null || true
  elif command -v docker >/dev/null 2>&1 && ! docker network inspect "$HOMESERVER_NETWORK" >/dev/null 2>&1; then
    echo "  no such network; the networks here:" >&2
    docker network ls --format '    {{.Name}}' >&2 2>/dev/null || true
  else
    break
  fi
done
ask HOMESERVER_URL "  Homeserver URL on that network" "${HOMESERVER_URL:-${found_url:-http://synapse:8008}}"

echo "Who may use the bridge" >&2
ask BRIDGE_USERS "  A server name (all its users) or one user ID" "${BRIDGE_USERS:-$SERVER_NAME}"
d="${BRIDGE_ADMIN:-}"
while :; do
  ask BRIDGE_ADMIN "  Bridge admin (a user ID, e.g. @you:$SERVER_NAME)" "$d"
  case "$BRIDGE_ADMIN" in @?*:?*) break ;; esac
  echo "  a user ID looks like @name:$SERVER_NAME" >&2
done

echo "Registration" >&2
default_dir="${REGISTRATION_DIR:-}"
if [ -z "$default_dir" ] && [ -n "$found_data" ]; then default_dir="$found_data/appservices"; fi
ask REGISTRATION_DIR "  Directory to copy the registration to (empty: copy it yourself)" "$default_dir"

echo "Database" >&2
d="${DATABASE_URI:-}"
while :; do
  ask DATABASE_URI "  PostgreSQL URI (empty: SQLite in data/)" "$d"
  case "$DATABASE_URI" in ''|postgres://*|postgresql://*) break ;; esac
  echo "  postgres://user:password@host/database?sslmode=disable, or empty" >&2
done

echo "Bridge image" >&2
release_ref=$(sed -n 's/^BEEPER_LINE_REF=//p' .env.example)
BEEPER_LINE_REF="${BEEPER_LINE_REF:-$release_ref}"
d=n; [ "${BEEPER_LINE_BUILD:-}" = source ] && d=y
while :; do
  ask build "  Build it here instead of downloading it? Needs over 10 GB of memory (y/n)" "$d"
  case "$build" in
    y|Y|yes) BEEPER_LINE_BUILD=source; break ;;
    n|N|no) BEEPER_LINE_BUILD=; break ;;
  esac
done

image="${BEEPER_LINE_IMAGE:-ghcr.io/genji1024/beeper-line}:$BEEPER_LINE_REF"
[ "${BEEPER_LINE_BUILD:-}" = source ] && image="built here from source"
cat >&2 <<EOF

  SERVER_NAME        $SERVER_NAME
  HOMESERVER_NETWORK $HOMESERVER_NETWORK
  HOMESERVER_URL     $HOMESERVER_URL
  BRIDGE_USERS       $BRIDGE_USERS
  BRIDGE_ADMIN       $BRIDGE_ADMIN
  REGISTRATION_DIR   ${REGISTRATION_DIR:-(none)}
  DATABASE_URI       ${DATABASE_URI:-(SQLite)}
  BEEPER_LINE_REF    $BEEPER_LINE_REF
  image              $image

EOF
ask ok "Write these to .env? (y/n)" y
case "$ok" in y|Y|yes) ;; *) echo "nothing written" >&2; exit 1 ;; esac

umask 077
{
  echo "# Written by configure.sh; run it again to change these (see .env.example)."
  for k in SERVER_NAME HOMESERVER_NETWORK HOMESERVER_URL BRIDGE_USERS BRIDGE_ADMIN \
           REGISTRATION_DIR DATABASE_URI BEEPER_LINE_REF BEEPER_LINE_IMAGE BEEPER_LINE_BUILD \
           BRIDGE_UID BRIDGE_GID; do
    eval "v=\${$k:-}"
    # The release's own commit stays out of .env, so that updating to a
    # newer release moves the bridge too.
    [ "$k" = BEEPER_LINE_REF ] && [ "$v" = "$release_ref" ] && v=
    if [ -n "$v" ]; then printf '%s=%s\n' "$k" "$v"; fi
  done
} > .env.new
mv .env.new .env
echo "==> wrote .env" >&2

if [ -n "$found_koto" ] && [ -n "$REGISTRATION_DIR" ]; then
  echo "==> koto at $found_koto: after setup.sh, run there: ./scripts/init.sh && docker compose restart synapse" >&2
fi
