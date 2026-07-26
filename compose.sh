#!/usr/bin/env bash
set -Eeuo pipefail

usage() {
  cat <<'USAGE'
Usage: ./compose.sh MODE [docker compose arguments...]

MODE:
  container   Use compose.container-db.yaml and .env.container
  host        Use compose.host-db.yaml and .env.host

Examples:
  ./compose.sh container up -d
  ./compose.sh host logs -f wordpress
  ./compose.sh host config
USAGE
}

[[ $# -ge 2 ]] || { usage >&2; exit 2; }
MODE=$1
shift

case "$MODE" in
  container)
    COMPOSE_FILE=compose.container-db.yaml
    ENV_FILE=.env.container
    ;;
  host)
    COMPOSE_FILE=compose.host-db.yaml
    ENV_FILE=.env.host
    ;;
  *)
    echo "Unknown mode: $MODE" >&2
    usage >&2
    exit 2
    ;;
esac

[[ -f $ENV_FILE ]] || {
  echo "Missing $ENV_FILE. Copy .env.$MODE.example first." >&2
  exit 1
}

exec docker compose --env-file "$ENV_FILE" -f "$COMPOSE_FILE" "$@"
