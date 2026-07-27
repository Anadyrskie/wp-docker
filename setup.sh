#!/usr/bin/env bash
set -Eeuo pipefail

SCRIPT_DIR=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
cd "$SCRIPT_DIR"

START_STACK=1
PULL_IMAGES=1
INIT_ENV=0
REQUIRE_ENV=0

usage() {
  cat <<'USAGE'
Usage: ./setup.sh MODE [OPTIONS]

MODE:
  container   Initialize MariaDB in the same Compose project
  host        Create the database/user in host MariaDB through its Unix socket

OPTIONS:
  --init-env      Interactively create the mode-specific .env file, then exit
  --require-env   Fail instead of prompting when the .env file is missing
  --no-start      Provision secrets/database but do not start Compose
  --no-pull       Do not pull container images before starting
  -h, --help      Show this help

First-run behavior:
  - In an interactive terminal, a missing .env file triggers an offer to create it.
  - In a noninteractive shell, a missing .env file is an error.
  - A newly created .env file is never deployed immediately; review it and rerun.
USAGE
}

die() {
  printf 'Error: %s\n' "$*" >&2
  exit 1
}

[[ $# -ge 1 ]] || { usage >&2; exit 2; }
MODE=$1
shift

while (($#)); do
  case "$1" in
    --init-env) INIT_ENV=1 ;;
    --require-env) REQUIRE_ENV=1 ;;
    --no-start) START_STACK=0 ;;
    --no-pull) PULL_IMAGES=0 ;;
    -h|--help) usage; exit 0 ;;
    *) printf 'Unknown option: %s\n' "$1" >&2; usage >&2; exit 2 ;;
  esac
  shift
done

(( INIT_ENV == 0 || REQUIRE_ENV == 0 )) || \
  die "--init-env and --require-env cannot be used together."

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
  *) printf 'Unknown mode: %s\n' "$MODE" >&2; usage >&2; exit 2 ;;
esac

is_interactive() {
  [[ -t 0 && -t 1 ]]
}

trim() {
  local value=$1
  value=${value#"${value%%[![:space:]]*}"}
  value=${value%"${value##*[![:space:]]}"}
  printf '%s' "$value"
}

port_in_use() {
  local port=$1
  command -v ss >/dev/null 2>&1 || return 1
  ss -H -ltn "sport = :$port" 2>/dev/null | grep -q .
}

valid_project_name() {
  [[ $1 =~ ^[a-z0-9][a-z0-9_-]*$ ]]
}

valid_port() {
  [[ $1 =~ ^[0-9]+$ ]] && ((10#$1 >= 1 && 10#$1 <= 65535))
}

valid_sql_identifier() {
  [[ $1 =~ ^[A-Za-z0-9_]+$ ]]
}

valid_table_prefix() {
  [[ $1 =~ ^[A-Za-z0-9_]+$ ]]
}

valid_socket_dir() {
  [[ $1 == /* && $1 != *$'\n'* ]]
}

prompt_value() {
  local output_var=$1
  local label=$2
  local default_value=$3
  local validator=$4
  local input

  while true; do
    read -r -p "$label [$default_value]: " input
    input=${input:-$default_value}

    if "$validator" "$input"; then
      printf -v "$output_var" '%s' "$input"
      return 0
    fi

    printf 'Invalid value: %s\n' "$input" >&2
  done
}

next_free_port() {
  local port=8081
  while ((port <= 8999)); do
    if ! port_in_use "$port"; then
      printf '%s' "$port"
      return 0
    fi
    ((port++))
  done
  printf '8081'
}

create_env_interactively() {
  is_interactive || die "Interactive environment creation requires a terminal. Create $ENV_FILE manually from $ENV_EXAMPLE."
  [[ ! -e $ENV_FILE ]] || die "$ENV_FILE already exists. Edit it directly or remove it before recreating it."

  local directory_name project_default db_default port_default
  local project_name http_port db_name db_user table_prefix socket_dir
  local temp_file answer

  directory_name=$(basename "$SCRIPT_DIR")
  project_default=$(printf '%s' "$directory_name" |
    tr '[:upper:]' '[:lower:]' |
    sed -E 's/[^a-z0-9_-]+/-/g; s/^-+//; s/-+$//')
  [[ -n $project_default ]] || project_default=wordpress-site

  db_default=$(printf '%s_wp' "$project_default" |
    sed -E 's/[^A-Za-z0-9_]+/_/g; s/^_+//; s/_+$//')
  [[ -n $db_default ]] || db_default=wordpress_site_wp

  port_default=$(next_free_port)

  printf '\nCreate %s for the %s database mode.\n' "$ENV_FILE" "$MODE"
  printf 'No containers or databases will be created during this step.\n\n'

  prompt_value project_name 'Compose project name' "$project_default" valid_project_name

  while true; do
    prompt_value http_port 'Loopback HTTP port' "$port_default" valid_port
    if port_in_use "$http_port"; then
      printf 'Port %s is already listening. Choose another port.\n' "$http_port" >&2
      port_default=$((10#$http_port + 1))
      continue
    fi
    break
  done

  prompt_value db_name 'MariaDB database name' "$db_default" valid_sql_identifier
  prompt_value db_user 'MariaDB application user' "$db_default" valid_sql_identifier
  prompt_value table_prefix 'WordPress table prefix' 'wp_' valid_table_prefix

  if [[ $MODE == host ]]; then
    prompt_value socket_dir 'Host MariaDB socket directory' '/run/mysqld' valid_socket_dir
  fi

  printf '\nConfiguration summary:\n'
  printf '  Project:      %s\n' "$project_name"
  printf '  HTTP port:    127.0.0.1:%s\n' "$http_port"
  printf '  Database:     %s\n' "$db_name"
  printf '  DB user:      %s@localhost\n' "$db_user"
  printf '  Table prefix: %s\n' "$table_prefix"
  [[ $MODE == host ]] && printf '  Socket dir:   %s\n' "$socket_dir"

  read -r -p 'Write this environment file? [y/N]: ' answer
  [[ $answer =~ ^[Yy]$ ]] || die "Environment creation cancelled."

  umask 077
  temp_file=$(mktemp "./.${ENV_FILE}.tmp.XXXXXX")

  if [[ $MODE == host ]]; then
    cat > "$temp_file" <<ENV
COMPOSE_PROJECT_NAME=$project_name
HTTP_PORT=$http_port

DB_NAME=$db_name
DB_USER=$db_user
WP_TABLE_PREFIX=$table_prefix

MARIADB_SOCKET_DIR=$socket_dir
DB_HOST=localhost:${socket_dir%/}/mysqld.sock

WORDPRESS_IMAGE=wordpress:7.0-php8.3-fpm-alpine
NGINX_IMAGE=nginx:1.30-alpine

WP_MEM_LIMIT=512m
NGINX_MEM_LIMIT=64m
ENV
  else
    cat > "$temp_file" <<ENV
COMPOSE_PROJECT_NAME=$project_name
HTTP_PORT=$http_port

DB_NAME=$db_name
DB_USER=$db_user
WP_TABLE_PREFIX=$table_prefix

WORDPRESS_IMAGE=wordpress:7.0-php8.3-fpm-alpine
NGINX_IMAGE=nginx:1.30-alpine
MARIADB_IMAGE=mariadb:11.8

WP_MEM_LIMIT=512m
NGINX_MEM_LIMIT=64m
DB_MEM_LIMIT=384m
ENV
  fi

  chmod 600 "$temp_file"
  mv -- "$temp_file" "$ENV_FILE"

  printf '\nCreated %s with mode 600.\n' "$ENV_FILE"
  printf 'Review it, then provision the site with:\n'
  printf '  ./setup.sh %s\n' "$MODE"
}

if ((INIT_ENV)); then
  create_env_interactively
  exit 0
fi

if [[ ! -f $ENV_FILE ]]; then
  if ((REQUIRE_ENV)); then
    die "$ENV_FILE is required. Copy $ENV_EXAMPLE and edit it, or run ./setup.sh $MODE --init-env."
  fi

  if is_interactive; then
    printf '%s does not exist.\n' "$ENV_FILE"
    read -r -p 'Create it interactively now? [y/N]: ' answer
    if [[ $answer =~ ^[Yy]$ ]]; then
      create_env_interactively
      exit 0
    fi
  fi

  die "$ENV_FILE is required. Copy $ENV_EXAMPLE and edit it, or run ./setup.sh $MODE --init-env."
fi

# Parse only KEY=VALUE records. The environment file is data and is never
# sourced or executed as shell code.
declare -A ALLOWED_KEYS=()
declare -A ENV_VALUES=()
declare -A SEEN_KEYS=()

for key in \
  COMPOSE_PROJECT_NAME HTTP_PORT DB_NAME DB_USER WP_TABLE_PREFIX \
  WORDPRESS_IMAGE NGINX_IMAGE WP_MEM_LIMIT NGINX_MEM_LIMIT; do
  ALLOWED_KEYS[$key]=1
done

if [[ $MODE == host ]]; then
  for key in MARIADB_SOCKET_DIR MARIADB_SOCKET DB_HOST; do
    ALLOWED_KEYS[$key]=1
  done
else
  for key in MARIADB_IMAGE DB_MEM_LIMIT; do
    ALLOWED_KEYS[$key]=1
  done
fi

parse_env_file() {
  local line key value line_number=0

  while IFS= read -r line || [[ -n $line ]]; do
    ((line_number+=1))
    line=${line%$'\r'}
    line=$(trim "$line")

    [[ -z $line || $line == \#* ]] && continue

    if [[ ! $line =~ ^([A-Za-z_][A-Za-z0-9_]*)[[:space:]]*=(.*)$ ]]; then
      die "$ENV_FILE:$line_number is not a valid KEY=VALUE record."
    fi

    key=${BASH_REMATCH[1]}
    value=$(trim "${BASH_REMATCH[2]}")

    [[ -n ${ALLOWED_KEYS[$key]+x} ]] || \
      die "$ENV_FILE:$line_number contains unknown key '$key'."
    [[ -z ${SEEN_KEYS[$key]+x} ]] || \
      die "$ENV_FILE:$line_number duplicates key '$key'."

    if [[ ${#value} -ge 2 ]]; then
      if [[ ${value:0:1} == '"' && ${value: -1} == '"' ]] || \
         [[ ${value:0:1} == "'" && ${value: -1} == "'" ]]; then
        value=${value:1:${#value}-2}
      fi
    fi

    ENV_VALUES[$key]=$value
    SEEN_KEYS[$key]=1
  done < "$ENV_FILE"
}

require_env_value() {
  local key=$1
  [[ -n ${ENV_VALUES[$key]:-} ]] || die "$ENV_FILE must define a nonempty $key."
}

parse_env_file

for key in COMPOSE_PROJECT_NAME HTTP_PORT DB_NAME DB_USER WP_TABLE_PREFIX; do
  require_env_value "$key"
done

COMPOSE_PROJECT_NAME=${ENV_VALUES[COMPOSE_PROJECT_NAME]}
HTTP_PORT=${ENV_VALUES[HTTP_PORT]}
DB_NAME=${ENV_VALUES[DB_NAME]}
DB_USER=${ENV_VALUES[DB_USER]}
WP_TABLE_PREFIX=${ENV_VALUES[WP_TABLE_PREFIX]}

valid_project_name "$COMPOSE_PROJECT_NAME" || \
  die "COMPOSE_PROJECT_NAME must match [a-z0-9][a-z0-9_-]*."
valid_port "$HTTP_PORT" || die "HTTP_PORT must be an integer from 1 through 65535."
valid_sql_identifier "$DB_NAME" || \
  die "DB_NAME must contain only letters, numbers, and underscores."
valid_sql_identifier "$DB_USER" || \
  die "DB_USER must contain only letters, numbers, and underscores."
valid_table_prefix "$WP_TABLE_PREFIX" || \
  die "WP_TABLE_PREFIX must contain only letters, numbers, and underscores."

mkdir -p secrets backups
chmod 700 secrets backups

create_secret() {
  local path=$1

  [[ ! -L $path ]] || die "$path must not be a symbolic link."

  if [[ ! -s $path ]]; then
    local temp_file
    umask 077
    temp_file=$(mktemp "${path}.tmp.XXXXXX")
    openssl rand -hex 32 > "$temp_file"
    chmod 600 "$temp_file"
    mv -- "$temp_file" "$path"
    printf 'Generated %s\n' "$path"
  fi

  chmod 600 "$path"
}

validate_secret() {
  local path=$1 value
  value=$(tr -d '\r\n' < "$path")
  [[ -n $value ]] || die "$path is empty."
  [[ $value =~ ^[A-Za-z0-9._+/=-]+$ ]] || \
    die "$path contains characters that are unsafe for this setup script."
}

create_secret secrets/db_password.txt
validate_secret secrets/db_password.txt

if [[ $MODE == container ]]; then
  create_secret secrets/db_root_password.txt
  validate_secret secrets/db_root_password.txt
else
  MARIADB_SOCKET_DIR=${ENV_VALUES[MARIADB_SOCKET_DIR]:-/run/mysqld}
  MARIADB_SOCKET=${ENV_VALUES[MARIADB_SOCKET]:-${MARIADB_SOCKET_DIR%/}/mysqld.sock}

  valid_socket_dir "$MARIADB_SOCKET_DIR" || \
    die "MARIADB_SOCKET_DIR must be an absolute path."
  [[ -S $MARIADB_SOCKET ]] || die "MariaDB socket not found: $MARIADB_SOCKET"

  if command -v mariadb >/dev/null 2>&1; then
    MARIADB_CLIENT=mariadb
  elif command -v mysql >/dev/null 2>&1; then
    MARIADB_CLIENT=mysql
  else
    die "Install the MariaDB client before running host mode."
  fi

  if [[ -n ${MARIADB_ADMIN_DEFAULTS_FILE:-} ]]; then
    [[ -r $MARIADB_ADMIN_DEFAULTS_FILE ]] || \
      die "Cannot read MARIADB_ADMIN_DEFAULTS_FILE=$MARIADB_ADMIN_DEFAULTS_FILE"
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
  printf "Host MariaDB database '%s' and user '%s' are ready.\n" "$DB_NAME" "$DB_USER"
fi

if ((START_STACK)); then
  command -v docker >/dev/null 2>&1 || die "Docker is not installed or not in PATH."
  docker info >/dev/null 2>&1 || die "Cannot access the Docker daemon."

  COMPOSE=(docker compose --env-file "$ENV_FILE" -f "$COMPOSE_FILE")
  "${COMPOSE[@]}" config >/dev/null

  if ((PULL_IMAGES)); then
    "${COMPOSE[@]}" pull
  fi

  "${COMPOSE[@]}" up -d
  "${COMPOSE[@]}" ps
  printf 'Local upstream: http://127.0.0.1:%s\n' "$HTTP_PORT"
fi
