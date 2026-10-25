#!/bin/sh
# Install or update the bridge from a release of beeper-line-settings, then
# run its setup:
#
#   curl -fsSL https://forgejo.genji1024.com/genji1024/beeper-line-settings/raw/branch/stable/install.sh | sh
#   curl -fsSL .../install.sh | sh -s -- --version v0.1.0 --dir ~/beeper-line
#
# Without --version it takes the latest release. Running it again updates a
# checkout it made to that release; .env and data/ are kept.
set -eu

REPO_URL=https://forgejo.genji1024.com/genji1024/beeper-line-settings.git
API_URL=https://forgejo.genji1024.com/api/v1/repos/genji1024/beeper-line-settings

# Everything is in functions, called on the last line: a download cut short
# runs nothing.
die() { echo "error: $*" >&2; exit 1; }

usage() {
  echo "usage: install.sh [--version vX.Y.Z] [--dir DIR]" >&2
  exit 2
}

latest_release() {
  json=$(curl -fsSL "$API_URL/releases/latest") ||
    die "could not find the latest release (is there one yet?); pass --version"
  printf '%s' "$json" | sed -n 's/.*"tag_name": *"\([^"]*\)".*/\1/p'
}

main() {
  version= dir="$HOME/beeper-line"
  while [ $# -gt 0 ]; do
    case "$1" in
      --version) [ $# -ge 2 ] || usage; version="$2"; shift 2 ;;
      --dir) [ $# -ge 2 ] || usage; dir="$2"; shift 2 ;;
      *) usage ;;
    esac
  done

  for tool in git curl docker; do
    command -v "$tool" >/dev/null 2>&1 || die "$tool is missing; install it first"
  done
  docker compose version >/dev/null 2>&1 || die "Docker Compose v2 is missing (docker compose version)"

  [ -n "$version" ] || version=$(latest_release)
  [ -n "$version" ] || die "could not read the latest release's tag; pass --version"

  if [ -e "$dir/.git" ]; then
    git -C "$dir" remote get-url origin | grep -q 'beeper-line-settings' ||
      die "$dir is a git checkout of something else; choose another --dir"
    # .env and data/ are ignored by git; anything else changed would be lost.
    [ -z "$(git -C "$dir" status --porcelain --untracked-files=no)" ] ||
      die "$dir has local changes; commit or undo them first (git -C $dir status)"
    echo "==> updating $dir to $version"
    git -C "$dir" fetch --quiet --tags origin
  elif [ -e "$dir" ]; then
    die "$dir exists and is not a checkout of beeper-line-settings; choose another --dir"
  else
    echo "==> installing $version into $dir"
    git clone --quiet "$REPO_URL" "$dir"
  fi
  git -C "$dir" -c advice.detachedHead=false checkout --quiet "refs/tags/$version" ||
    die "there is no release $version"

  # Piped into sh, this script's input is the script itself: give setup.sh
  # (and the questions it asks) the terminal instead, when there is one.
  cd "$dir"
  if (exec < /dev/tty) 2>/dev/null; then
    ./setup.sh < /dev/tty
  else
    ./setup.sh
  fi
}

main "$@"
