#!/usr/bin/env bash
set -Eeuo pipefail

SCRIPT_DIR=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
cd "$SCRIPT_DIR"

START_STACK=1
PULL_IMAGES=1

usage() {
  cat <<'USAGE'
Usage: ./setup.sh MODE [--no-start] [--no-pull]

MODE:
  container   Initialize a MariaDB container in the same Compose project
  host        Create the database/user in host MariaDB through its Unix socket
USAGE
}

[[ $# -ge 1 ]] || { usage >&2; exit 2; }
MODE=$1
shift

while (($#)); do
  case "$1" in
    --no-start) START_STACK=0 ;;
    --no-pull) PULL_IMAGES=0 ;;
    -h|--help) usage; exit 0 ;;
    *) echo "Unknown option: $1" >&2; usage >&2; exit 2 ;;
  esac
  shift
done

case "$MODE" in
  container)
    ENV_FILE=.env.container
    ENV_EXAMPLE=.env.container.example
    COMPOSE_FILE=compose.container-db.yaml
    ;;
  host)
    ENV_FILE=.env.host
    ENV_EXAMPLE=.env.host.example
    COMPOSE_FILE=compose.host-db.yaml
    ;;
  *) echo "Unknown mode: $MODE" >&2; usage >&2; exit 2 ;;
esac

if [[ ! -f $ENV_FILE ]]; then
  cp "$ENV_EXAMPLE" "$ENV_FILE"
  echo "Created $ENV_FILE from $ENV_EXAMPLE. Review it before production use."
fi

# These templates are intentionally shell-compatible. Do not source an
# untrusted environment file.
set -a
# shellcheck disable=SC1090
source "./$ENV_FILE"
set +a

DB_NAME=${DB_NAME:-wordpress}
DB_USER=${DB_USER:-wordpress}
HTTP_PORT=${HTTP_PORT:-8080}

for name in DB_NAME DB_USER; do
  value=${!name}
  [[ $value =~ ^[A-Za-z0-9_]+$ ]] || {
    echo "$name must contain only letters, numbers, and underscores." >&2
    exit 1
  }
done

mkdir -p secrets backups
chmod 700 secrets backups

create_secret() {
  local path=$1
  if [[ ! -s $path ]]; then
    umask 077
    openssl rand -base64 36 | tr -d '\n' > "$path"
    printf '\n' >> "$path"
    echo "Generated $path"
  fi
  chmod 600 "$path"
}

create_secret secrets/db_password.txt

if [[ $MODE == container ]]; then
  create_secret secrets/db_root_password.txt
else
  MARIADB_SOCKET_DIR=${MARIADB_SOCKET_DIR:-/run/mysqld}
  MARIADB_SOCKET=${MARIADB_SOCKET:-${MARIADB_SOCKET_DIR%/}/mysqld.sock}

  [[ -S $MARIADB_SOCKET ]] || {
    echo "MariaDB socket not found: $MARIADB_SOCKET" >&2
    exit 1
  }

  if command -v mariadb >/dev/null 2>&1; then
    MARIADB_CLIENT=mariadb
  elif command -v mysql >/dev/null 2>&1; then
    MARIADB_CLIENT=mysql
  else
    echo "Install the MariaDB client before running host mode." >&2
    exit 1
  fi

  if [[ -n ${MARIADB_ADMIN_DEFAULTS_FILE:-} ]]; then
    [[ -r $MARIADB_ADMIN_DEFAULTS_FILE ]] || {
      echo "Cannot read MARIADB_ADMIN_DEFAULTS_FILE=$MARIADB_ADMIN_DEFAULTS_FILE" >&2
      exit 1
    }
    ADMIN_CMD=("$MARIADB_CLIENT" "--defaults-extra-file=$MARIADB_ADMIN_DEFAULTS_FILE" \
      --protocol=socket "--socket=$MARIADB_SOCKET")
  elif [[ $EUID -eq 0 ]]; then
    ADMIN_CMD=("$MARIADB_CLIENT" --protocol=socket "--socket=$MARIADB_SOCKET")
  else
    ADMIN_CMD=(sudo "$MARIADB_CLIENT" --protocol=socket "--socket=$MARIADB_SOCKET")
  fi

  DB_PASSWORD=$(tr -d '\r\n' < secrets/db_password.txt)
  SQL=$(cat <<SQL
CREATE DATABASE IF NOT EXISTS \`$DB_NAME\`
  CHARACTER SET utf8mb4 COLLATE utf8mb4_unicode_ci;
CREATE USER IF NOT EXISTS '$DB_USER'@'localhost' IDENTIFIED BY '$DB_PASSWORD';
ALTER USER '$DB_USER'@'localhost' IDENTIFIED BY '$DB_PASSWORD';
GRANT ALL PRIVILEGES ON \`$DB_NAME\`.* TO '$DB_USER'@'localhost';
FLUSH PRIVILEGES;
SQL
)
  printf '%s\n' "$SQL" | "${ADMIN_CMD[@]}"
  echo "Host MariaDB database '$DB_NAME' and user '$DB_USER' are ready."
fi

if ((START_STACK)); then
  command -v docker >/dev/null 2>&1 || {
    echo "Docker is not installed or not in PATH." >&2
    exit 1
  }
  docker info >/dev/null 2>&1 || {
    echo "Cannot access the Docker daemon." >&2
    exit 1
  }

  COMPOSE=(docker compose --env-file "$ENV_FILE" -f "$COMPOSE_FILE")
  if ((PULL_IMAGES)); then
    "${COMPOSE[@]}" pull
  fi
  "${COMPOSE[@]}" up -d
  "${COMPOSE[@]}" ps
  echo "Local upstream: http://127.0.0.1:$HTTP_PORT"
fi
