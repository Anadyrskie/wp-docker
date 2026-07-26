#!/usr/bin/env bash
set -Eeuo pipefail

SCRIPT_DIR=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
cd "$SCRIPT_DIR"

usage() {
  cat <<'USAGE'
Usage: ./backup.sh MODE

MODE is either "container" or "host".
Creates a logical SQL dump and a complete WordPress volume archive.
USAGE
}

[[ $# -eq 1 ]] || { usage >&2; exit 2; }
MODE=$1

case "$MODE" in
  container)
    ENV_FILE=.env.container
    COMPOSE_FILE=compose.container-db.yaml
    ;;
  host)
    ENV_FILE=.env.host
    COMPOSE_FILE=compose.host-db.yaml
    ;;
  *) echo "Unknown mode: $MODE" >&2; usage >&2; exit 2 ;;
esac

[[ -f $ENV_FILE ]] || { echo "Missing $ENV_FILE" >&2; exit 1; }
set -a
# shellcheck disable=SC1090
source "./$ENV_FILE"
set +a

DB_NAME=${DB_NAME:-wordpress}
DB_USER=${DB_USER:-wordpress}
BACKUP_DIR=${BACKUP_DIR:-$SCRIPT_DIR/backups}
STAMP=$(date +%Y-%m-%d_%H%M%S)
COMPOSE=(docker compose --env-file "$ENV_FILE" -f "$COMPOSE_FILE")

mkdir -p "$BACKUP_DIR"
chmod 700 "$BACKUP_DIR"

DB_OUT="$BACKUP_DIR/database-$STAMP.sql.gz"
WP_OUT="$BACKUP_DIR/wordpress-$STAMP.tar.gz"

if [[ $MODE == container ]]; then
  "${COMPOSE[@]}" exec -T db sh -ec '
    exec mariadb-dump --single-transaction --quick --triggers --routines --events \
      --no-tablespaces -u"$MARIADB_USER" \
      -p"$(cat /run/secrets/db_password)" "$MARIADB_DATABASE"
  ' | gzip -9 > "$DB_OUT"
else
  MARIADB_SOCKET_DIR=${MARIADB_SOCKET_DIR:-/run/mysqld}
  MARIADB_SOCKET=${MARIADB_SOCKET:-${MARIADB_SOCKET_DIR%/}/mysqld.sock}
  SECRET_FILE="$SCRIPT_DIR/secrets/db_password.txt"

  if command -v mariadb-dump >/dev/null 2>&1; then
    DUMP=mariadb-dump
  elif command -v mysqldump >/dev/null 2>&1; then
    DUMP=mysqldump
  else
    echo "mariadb-dump or mysqldump is required." >&2
    exit 1
  fi

  DB_PASSWORD=$(tr -d '\r\n' < "$SECRET_FILE")
  CLIENT_CNF=$(mktemp)
  trap 'rm -f "$CLIENT_CNF"' EXIT
  chmod 600 "$CLIENT_CNF"
  cat > "$CLIENT_CNF" <<EOF
[client]
user=$DB_USER
password=$DB_PASSWORD
protocol=socket
socket=$MARIADB_SOCKET
EOF

  "$DUMP" --defaults-extra-file="$CLIENT_CNF" \
    --single-transaction --quick --triggers --routines --events \
    --no-tablespaces "$DB_NAME" | gzip -9 > "$DB_OUT"
fi

gzip -t "$DB_OUT"

"${COMPOSE[@]}" run --rm --no-deps -T --entrypoint sh wordpress -ec \
  'tar czf - -C /var/www/html .' > "$WP_OUT"

tar tzf "$WP_OUT" >/dev/null
printf 'Created:\n  %s\n  %s\n' "$DB_OUT" "$WP_OUT"
