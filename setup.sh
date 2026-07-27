#!/usr/bin/env bash
set -Eeuo pipefail

SCRIPT_DIR=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
cd "$SCRIPT_DIR"

START_STACK=1
PULL_IMAGES=0
INIT_ENV=0
REQUIRE_ENV=0
ADOPT_EXISTING_DB=0
REUSE_PROJECT=0
ALLOW_CUSTOM_IMAGES=0

usage() {
  cat <<'USAGE'
Usage: ./setup.sh MODE [OPTIONS]

MODE:
  container   Initialize MariaDB in the same Compose project
  host        Create the database/user in host MariaDB through its Unix socket

OPTIONS:
  --init-env      Interactively create the mode-specific .env file, then exit
  --require-env   Fail instead of prompting when the .env file is missing
  --no-start          Provision secrets/database but do not start Compose
  --pull              Explicitly refresh configured image tags before starting
  --no-pull           Do not refresh existing image tags (the default)
  --adopt-existing-db Allow host mode to claim an existing database/user once
  --reuse-project     Allow adoption of existing Compose resources when ownership
                      cannot be proven from this deployment directory
  --allow-custom-images
                      Permit image repositories other than the official
                      wordpress, nginx, and mariadb images
  -h, --help          Show this help

First-run behavior:
  - In an interactive terminal, a missing .env file triggers an offer to create it.
  - In a noninteractive shell, a missing .env file is an error.
  - A newly created .env file is never deployed immediately; review it and rerun.
  - Existing image tags are not refreshed unless --pull is supplied.
  - Existing host database resources are never silently adopted.
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
    --pull) PULL_IMAGES=1 ;;
    --no-pull) PULL_IMAGES=0 ;;
    --adopt-existing-db) ADOPT_EXISTING_DB=1 ;;
    --reuse-project) REUSE_PROJECT=1 ;;
    --allow-custom-images) ALLOW_CUSTOM_IMAGES=1 ;;
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

if [[ $MODE != host && $ADOPT_EXISTING_DB -eq 1 ]]; then
  die "--adopt-existing-db is valid only in host mode."
fi

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

valid_wp_url() {
  local value=$1 authority

  [[ $value == http://* || $value == https://* ]] || return 1
  [[ $value != *[[:space:]]* ]] || return 1
  [[ $value != *'?'* && $value != *'#'* && $value != */ ]] || return 1

  authority=${value#*://}
  authority=${authority%%/*}
  [[ -n $authority ]] || return 1

  [[ $authority =~ ^([A-Za-z0-9-]+\.)*[A-Za-z0-9-]+(:[0-9]+)?$ ]] || \
    [[ $authority =~ ^\[[0-9A-Fa-f:]+\](:[0-9]+)?$ ]]
}

valid_official_image() {
  local kind=$1 image=$2

  case "$kind:$image" in
    wordpress:wordpress:*|wordpress:wordpress@sha256:*) return 0 ;;
    nginx:nginx:*|nginx:nginx@sha256:*) return 0 ;;
    mariadb:mariadb:*|mariadb:mariadb@sha256:*) return 0 ;;
    *) return 1 ;;
  esac
}

read_identity_value() {
  local file=$1 wanted=$2 line key value

  [[ -f $file && ! -L $file ]] || return 1
  while IFS= read -r line || [[ -n $line ]]; do
    [[ $line =~ ^([A-Za-z_][A-Za-z0-9_]*)=(.*)$ ]] || continue
    key=${BASH_REMATCH[1]}
    value=${BASH_REMATCH[2]}
    if [[ $key == "$wanted" ]]; then
      printf '%s' "$value"
      return 0
    fi
  done < "$file"
  return 1
}

write_identity_file() {
  local file=$1
  shift
  local temp_file line

  [[ ! -L $file ]] || die "$file must not be a symbolic link."
  umask 077
  temp_file=$(mktemp "${file}.tmp.XXXXXX")
  for line in "$@"; do
    printf '%s\n' "$line" >> "$temp_file"
  done
  chmod 600 "$temp_file"
  mv -- "$temp_file" "$file"
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
  local project_name http_port wp_home wp_siteurl db_name db_user table_prefix socket_dir
  local temp_file answer url_default

  directory_name=$(basename "$SCRIPT_DIR")
  project_default=$(printf '%s' "$directory_name" |
    tr '[:upper:]' '[:lower:]' |
    sed -E 's/[^a-z0-9_-]+/-/g; s/^-+//; s/-+$//')
  [[ -n $project_default ]] || project_default=wordpress-site

  db_default=$(printf '%s_wp' "$project_default" |
    sed -E 's/[^A-Za-z0-9_]+/_/g; s/^_+//; s/_+$//')
  [[ -n $db_default ]] || db_default=wordpress_site_wp

  port_default=$(next_free_port)
  url_default=https://$directory_name
  valid_wp_url "$url_default" || url_default=https://example.com

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

  prompt_value wp_home 'Public WordPress URL (WP_HOME)' "$url_default" valid_wp_url
  prompt_value wp_siteurl 'WordPress core URL (WP_SITEURL)' "$wp_home" valid_wp_url

  prompt_value db_name 'MariaDB database name' "$db_default" valid_sql_identifier
  prompt_value db_user 'MariaDB application user' "$db_default" valid_sql_identifier
  prompt_value table_prefix 'WordPress table prefix' 'wp_' valid_table_prefix

  if [[ $MODE == host ]]; then
    prompt_value socket_dir 'Host MariaDB socket directory' '/run/mysqld' valid_socket_dir
  fi

  printf '\nConfiguration summary:\n'
  printf '  Project:      %s\n' "$project_name"
  printf '  HTTP port:    127.0.0.1:%s\n' "$http_port"
  printf '  WP_HOME:      %s\n' "$wp_home"
  printf '  WP_SITEURL:   %s\n' "$wp_siteurl"
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

WP_HOME=$wp_home
WP_SITEURL=$wp_siteurl

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

WP_HOME=$wp_home
WP_SITEURL=$wp_siteurl

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
  COMPOSE_PROJECT_NAME HTTP_PORT WP_HOME WP_SITEURL DB_NAME DB_USER WP_TABLE_PREFIX \
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

for key in COMPOSE_PROJECT_NAME HTTP_PORT WP_HOME WP_SITEURL DB_NAME DB_USER WP_TABLE_PREFIX; do
  require_env_value "$key"
done

COMPOSE_PROJECT_NAME=${ENV_VALUES[COMPOSE_PROJECT_NAME]}
HTTP_PORT=${ENV_VALUES[HTTP_PORT]}
WP_HOME=${ENV_VALUES[WP_HOME]}
WP_SITEURL=${ENV_VALUES[WP_SITEURL]}
DB_NAME=${ENV_VALUES[DB_NAME]}
DB_USER=${ENV_VALUES[DB_USER]}
WP_TABLE_PREFIX=${ENV_VALUES[WP_TABLE_PREFIX]}

valid_project_name "$COMPOSE_PROJECT_NAME" || \
  die "COMPOSE_PROJECT_NAME must match [a-z0-9][a-z0-9_-]*."
valid_port "$HTTP_PORT" || die "HTTP_PORT must be an integer from 1 through 65535."
valid_wp_url "$WP_HOME" || \
  die "WP_HOME must be an absolute http:// or https:// URL without a trailing slash, query, or fragment."
valid_wp_url "$WP_SITEURL" || \
  die "WP_SITEURL must be an absolute http:// or https:// URL without a trailing slash, query, or fragment."
valid_sql_identifier "$DB_NAME" || \
  die "DB_NAME must contain only letters, numbers, and underscores."
valid_sql_identifier "$DB_USER" || \
  die "DB_USER must contain only letters, numbers, and underscores."
valid_table_prefix "$WP_TABLE_PREFIX" || \
  die "WP_TABLE_PREFIX must contain only letters, numbers, and underscores."

WORDPRESS_IMAGE=${ENV_VALUES[WORDPRESS_IMAGE]:-wordpress:7.0-php8.3-fpm-alpine}
NGINX_IMAGE=${ENV_VALUES[NGINX_IMAGE]:-nginx:1.30-alpine}
if [[ $MODE == container ]]; then
  MARIADB_IMAGE=${ENV_VALUES[MARIADB_IMAGE]:-mariadb:11.8}
fi

if (( ! ALLOW_CUSTOM_IMAGES )); then
  valid_official_image wordpress "$WORDPRESS_IMAGE" || \
    die "WORDPRESS_IMAGE must use the official wordpress repository, or pass --allow-custom-images."
  valid_official_image nginx "$NGINX_IMAGE" || \
    die "NGINX_IMAGE must use the official nginx repository, or pass --allow-custom-images."
  if [[ $MODE == container ]]; then
    valid_official_image mariadb "$MARIADB_IMAGE" || \
      die "MARIADB_IMAGE must use the official mariadb repository, or pass --allow-custom-images."
  fi
fi

mkdir -p secrets backups
chmod 700 secrets backups

create_secret() {
  local path=$1 mode=$2

  [[ ! -L $path ]] || die "$path must not be a symbolic link."

  if [[ ! -s $path ]]; then
    local temp_file
    umask 077
    temp_file=$(mktemp "${path}.tmp.XXXXXX")
    openssl rand -hex 32 > "$temp_file"
    chmod "$mode" "$temp_file"
    mv -- "$temp_file" "$path"
    printf 'Generated %s\n' "$path"
  fi

  chmod "$mode" "$path"
}

validate_secret() {
  local path=$1 value
  value=$(tr -d '\r\n' < "$path")
  [[ -n $value ]] || die "$path is empty."
  [[ $value =~ ^[A-Za-z0-9._+/=-]+$ ]] || \
    die "$path contains characters that are unsafe for this setup script."
}

create_secret secrets/db_password.txt 0644
validate_secret secrets/db_password.txt

if [[ $MODE == container ]]; then
  create_secret secrets/db_root_password.txt 0600
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
    [[ -f $MARIADB_ADMIN_DEFAULTS_FILE && ! -L $MARIADB_ADMIN_DEFAULTS_FILE ]] || \
      die "MARIADB_ADMIN_DEFAULTS_FILE must be a regular, non-symlink file."
    [[ -r $MARIADB_ADMIN_DEFAULTS_FILE ]] || \
      die "Cannot read MARIADB_ADMIN_DEFAULTS_FILE=$MARIADB_ADMIN_DEFAULTS_FILE"

    defaults_mode=$(stat -c '%a' "$MARIADB_ADMIN_DEFAULTS_FILE")
    defaults_owner=$(stat -c '%u' "$MARIADB_ADMIN_DEFAULTS_FILE")
    (( (8#$defaults_mode & 077) == 0 )) || \
      die "MARIADB_ADMIN_DEFAULTS_FILE must not be group- or world-readable."
    [[ $defaults_owner -eq $EUID || $defaults_owner -eq 0 ]] || \
      die "MARIADB_ADMIN_DEFAULTS_FILE must be owned by the current user or root."

    ADMIN_CMD=("$MARIADB_CLIENT" "--defaults-extra-file=$MARIADB_ADMIN_DEFAULTS_FILE" \
      --protocol=socket "--socket=$MARIADB_SOCKET")
  elif [[ $EUID -eq 0 ]]; then
    ADMIN_CMD=("$MARIADB_CLIENT" --protocol=socket "--socket=$MARIADB_SOCKET")
  else
    ADMIN_CMD=(sudo "$MARIADB_CLIENT" --protocol=socket "--socket=$MARIADB_SOCKET")
  fi

  DB_PASSWORD=$(tr -d '\r\n' < secrets/db_password.txt)
  DB_IDENTITY_FILE=secrets/host-db.identity

  db_exists=$("${ADMIN_CMD[@]}" --batch --skip-column-names -e \
    "SELECT COUNT(*) FROM information_schema.SCHEMATA WHERE SCHEMA_NAME='$DB_NAME';")
  user_exists=$("${ADMIN_CMD[@]}" --batch --skip-column-names -e \
    "SELECT COUNT(*) FROM mysql.user WHERE User='$DB_USER' AND Host='localhost';")
  other_grants=$("${ADMIN_CMD[@]}" --batch --skip-column-names -e \
    "SELECT COALESCE(GROUP_CONCAT(DISTINCT TABLE_SCHEMA ORDER BY TABLE_SCHEMA), '')
       FROM information_schema.SCHEMA_PRIVILEGES
      WHERE GRANTEE=CONCAT(QUOTE('$DB_USER'), '@', QUOTE('localhost'))
        AND TABLE_SCHEMA <> '$DB_NAME';")

  if [[ -f $DB_IDENTITY_FILE ]]; then
    identity_db=$(read_identity_value "$DB_IDENTITY_FILE" database || true)
    identity_user=$(read_identity_value "$DB_IDENTITY_FILE" user || true)
    [[ $identity_db == "$DB_NAME" && $identity_user == "$DB_USER" ]] || \
      die "$DB_IDENTITY_FILE does not match DB_NAME/DB_USER in $ENV_FILE."
  elif (( db_exists > 0 || user_exists > 0 )); then
    (( ADOPT_EXISTING_DB )) || die \
      "Database '$DB_NAME' or user '$DB_USER' already exists. Review it, then rerun once with --adopt-existing-db."
  fi

  if [[ -n $other_grants && $other_grants != NULL ]]; then
    (( ADOPT_EXISTING_DB )) || die \
      "MariaDB user '$DB_USER' already has grants on other databases: $other_grants"
    printf 'Warning: adopting a MariaDB user with grants on: %s\n' "$other_grants" >&2
  fi

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

  write_identity_file "$DB_IDENTITY_FILE" \
    "database=$DB_NAME" \
    "user=$DB_USER" \
    "socket=$MARIADB_SOCKET"

  printf "Host MariaDB database '%s' and user '%s' are ready.\n" "$DB_NAME" "$DB_USER"
fi

if ((START_STACK)); then
  command -v docker >/dev/null 2>&1 || die "Docker is not installed or not in PATH."
  docker info >/dev/null 2>&1 || die "Cannot access the Docker daemon."

  COMPOSE=(docker compose --env-file "$ENV_FILE" -f "$COMPOSE_FILE")
  "${COMPOSE[@]}" config >/dev/null

  PROJECT_IDENTITY_FILE=secrets/compose-project.identity
  current_dir=$(realpath "$SCRIPT_DIR")
  project_resource_count=0
  project_dirs=()

  mapfile -t project_containers < <(
    docker ps -aq --filter "label=com.docker.compose.project=$COMPOSE_PROJECT_NAME"
  )
  if ((${#project_containers[@]})); then
    project_resource_count=$((project_resource_count + ${#project_containers[@]}))
    mapfile -t project_dirs < <(
      docker inspect --format '{{ index .Config.Labels "com.docker.compose.project.working_dir" }}' \
        "${project_containers[@]}" | sed '/^$/d' | sort -u
    )
  fi

  mapfile -t project_volumes < <(
    docker volume ls -q --filter "label=com.docker.compose.project=$COMPOSE_PROJECT_NAME"
  )
  project_resource_count=$((project_resource_count + ${#project_volumes[@]}))

  if [[ -f $PROJECT_IDENTITY_FILE ]]; then
    identity_project=$(read_identity_value "$PROJECT_IDENTITY_FILE" project || true)
    identity_dir=$(read_identity_value "$PROJECT_IDENTITY_FILE" working_dir || true)
    [[ $identity_project == "$COMPOSE_PROJECT_NAME" && $identity_dir == "$current_dir" ]] || \
      die "$PROJECT_IDENTITY_FILE does not match this project name and directory."
  else
    foreign_dir=0
    for known_dir in "${project_dirs[@]}"; do
      if [[ $(realpath -m "$known_dir") != "$current_dir" ]]; then
        foreign_dir=1
      fi
    done

    if ((foreign_dir)); then
      (( REUSE_PROJECT )) || die \
        "Compose project '$COMPOSE_PROJECT_NAME' is already associated with another working directory."
    elif ((project_resource_count > 0 && ${#project_dirs[@]} == 0)); then
      (( REUSE_PROJECT )) || die \
        "Compose resources already exist for '$COMPOSE_PROJECT_NAME', but ownership cannot be proven. Rerun once with --reuse-project after review."
    fi
  fi

  if ((PULL_IMAGES)); then
    "${COMPOSE[@]}" pull
    up_pull_policy=never
  else
    up_pull_policy=missing
  fi

  "${COMPOSE[@]}" up -d --pull "$up_pull_policy"
  "${COMPOSE[@]}" ps

  write_identity_file "$PROJECT_IDENTITY_FILE" \
    "project=$COMPOSE_PROJECT_NAME" \
    "working_dir=$current_dir"

  printf 'Local upstream: http://127.0.0.1:%s\n' "$HTTP_PORT"
fi
