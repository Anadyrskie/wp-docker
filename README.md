# WordPress Compose: containerized or host MariaDB

This repository tracks two complete deployment modes for the same independently portable WordPress site:

- `compose.container-db.yaml`: WordPress, Nginx, and MariaDB are all containerized.
- `compose.host-db.yaml`: WordPress and Nginx are containerized; WordPress reaches host MariaDB through `/run/mysqld/mysqld.sock`.

Both modes use the same WordPress volume layout, Nginx configuration, PHP configuration, database name/user variables, and backup format. Secrets and live environment files are intentionally excluded from Git.

## Layout

```text
.
├── compose.container-db.yaml
├── compose.host-db.yaml
├── .env.container.example
├── .env.host.example
├── compose.sh
├── setup.sh
├── backup.sh
├── nginx/default.conf
├── php/
├── mariadb/low-memory.cnf
├── secrets/                 # ignored except .gitkeep
└── backups/                 # ignored except .gitkeep
```

## Which mode to use?

### Containerized MariaDB

Use this when you want the site to be a nearly self-contained Compose deployment. It is easiest to move between Docker hosts and gives the site an independent MariaDB lifecycle, but it consumes more RAM.

### Host MariaDB

Use this on a small VPS when RAM efficiency matters. Multiple WordPress projects can use separate databases and users in one host MariaDB instance. The setup remains portable through a logical SQL dump, but `docker compose up` alone does not create the host database server.

Do not run both modes against the same live WordPress volume at the same time.

## Initial setup: containerized MariaDB

Create the environment interactively:

```bash
./setup.sh container --init-env
# Review .env.container, then:
./setup.sh container
```

Or create it manually and require it to exist:

```bash
cp .env.container.example .env.container
nano .env.container
./setup.sh container --require-env
```

A normal interactive `./setup.sh container` also offers to create a missing environment file. Noninteractive runs fail when the file is missing. A newly generated environment file is never deployed immediately; the script exits so you can review it first.

The first initialization creates the database and user from the secret files. Changing `DB_NAME`, `DB_USER`, or the secret after the `db_data` volume has already initialized does not rewrite existing MariaDB accounts automatically.

Useful commands:

```bash
./compose.sh container ps
./compose.sh container logs -f
./compose.sh container pull
./compose.sh container up -d
./compose.sh container down
```

## Initial setup: host MariaDB

Install MariaDB Server and its client first. Then create the environment interactively:

```bash
./setup.sh host --init-env
# Review .env.host, then:
./setup.sh host
```

Or create it manually and require it to exist:

```bash
cp .env.host.example .env.host
nano .env.host
./setup.sh host --require-env
```

A normal interactive `./setup.sh host` also offers to create a missing environment file. Noninteractive runs fail when the file is missing. The setup script parses the environment as `KEY=VALUE` data and does not source or execute it as Bash.

On Debian/Ubuntu, the script normally administers MariaDB using `sudo mariadb` over the Unix socket. For password-authenticated database administration, set `MARIADB_ADMIN_DEFAULTS_FILE` before running the script.

Example root client file:

```ini
[client]
user=root
password=replace-me
socket=/run/mysqld/mysqld.sock
```

```bash
sudo chmod 600 /root/.my.cnf
export MARIADB_ADMIN_DEFAULTS_FILE=/root/.my.cnf
./setup.sh host
```

Useful commands:

```bash
./compose.sh host ps
./compose.sh host logs -f
./compose.sh host pull
./compose.sh host up -d
./compose.sh host down
```

If PHP-FPM cannot open the MariaDB socket, inspect the host socket permissions and AppArmor/SELinux policy. The host socket directory is mounted read-only into the WordPress container.


## Environment-file safety

The setup script never silently copies and deploys example defaults. Its behavior is:

- `--init-env`: prompt for site-specific values, write the mode-specific environment file with permission `0600`, and exit.
- `--require-env`: fail immediately if the environment file is absent.
- No environment option: offer interactive creation only when attached to a terminal; fail in automation or other noninteractive shells.

The required site-specific values are the Compose project name, localhost HTTP port, `WP_HOME`, `WP_SITEURL`, database name, database user, and WordPress table prefix. Each deployment must use a unique Compose project name, port, database, and database user.

## Canonical WordPress URLs

Each site environment file must define the public URL constants used by WordPress:

```dotenv
WP_HOME=https://association.org
WP_SITEURL=https://association.org
```

For this root-directory image layout, the two values are normally identical. `WP_HOME` is the visitor-facing site address; `WP_SITEURL` is the address where the WordPress core files are served. Use a different `WP_SITEURL` only when deliberately serving core from a subdirectory. Include `http://` or `https://` and omit the trailing slash.

The Compose files pass these values into the official image and define `WP_HOME` and `WP_SITEURL` through `WORDPRESS_CONFIG_EXTRA`. This makes the canonical URL explicit instead of deriving it from an untrusted `Host` header. The constants override the corresponding `home` and `siteurl` database options while the stack is running; they do not rewrite those stored database values.

After changing either URL, recreate the application containers:

```bash
./compose.sh host up -d --force-recreate wordpress nginx
# or: ./compose.sh container up -d --force-recreate wordpress nginx
```

An existing `wp-config.php` generated by the official image will continue to evaluate `WORDPRESS_CONFIG_EXTRA`. A manually replaced or hard-coded `wp-config.php` must be updated or regenerated before these environment values can take effect.

## Host Apache reverse proxy

Each stack binds its inner Nginx only to localhost:

```text
association.org -> Apache :443 -> 127.0.0.1:8081 -> container Nginx -> WordPress FPM
```

The repository now includes complete Apache examples and installation instructions:

- `apache2/wordpress-site-http.conf.example`: initial HTTP vhost for certificate issuance
- `apache2/wordpress-site-https.conf.example`: final HTTPS proxy and HTTP redirect
- `apache2/README.md`: module setup, Certbot, testing, additional sites, and troubleshooting

Keep the Compose port bound to `127.0.0.1`; do not expose the inner Nginx publicly unless that is intentional.

The inner Nginx configuration denies PHP execution in writable upload/cache/upgrade directories **before** the general PHP regex handler. Keep that ordering intact.

## Backups

Create a database dump plus a complete WordPress volume archive:

```bash
./backup.sh container
# or
./backup.sh host
```

Outputs:

```text
backups/database-YYYY-MM-DD_HHMMSS.sql.gz
backups/wordpress-YYYY-MM-DD_HHMMSS.tar.gz
```

The SQL dump is the portable database artifact. The WordPress archive contains the entire `/var/www/html` volume, including `wp-content`.

For a quiet migration snapshot:

```bash
./compose.sh host stop nginx wordpress
./backup.sh host
./compose.sh host start wordpress nginx
```

Use `container` in place of `host` for the containerized database mode.

## Switching database modes

Do not simply start the other Compose file against an unrelated empty database. Migrate logically:

1. Stop or quiesce WordPress writes.
2. Run `./backup.sh MODE`.
3. Initialize the destination mode with `./setup.sh OTHER_MODE --no-start`.
4. Import the SQL dump into the destination database.
5. Start the destination stack.
6. Verify the site before removing the old database.

The WordPress volume can remain the same because both Compose files use the same project-scoped volume name, provided `COMPOSE_PROJECT_NAME` is unchanged. Never run both WordPress services concurrently against that same volume.

## Git workflow

Track:

- Both Compose YAML files
- Both `.env.*.example` templates
- Nginx, PHP, and MariaDB configuration
- Setup and backup scripts

Do not track:

- `.env.host` or `.env.container`
- Database passwords
- Database dumps
- WordPress archives
- Live WordPress volume contents

Suggested first commit:

```bash
git init
git add .
git commit -m "Add dual-mode WordPress Compose deployment"
```

Validate rendered configuration before deploying:

```bash
./compose.sh container config >/dev/null
./compose.sh host config >/dev/null
```

## Resource notes for a 2 GB VPS

The host-MariaDB mode is normally the better fit when several small sites share one VPS. The containerized mode reserves an additional MariaDB process, buffer pool, caches, and container overhead. The included MariaDB configuration starts with a 128 MB InnoDB buffer pool and conservative connection/cache limits.

Add swap, rotate logs, and keep backups off-host. Container memory limits are safety ceilings, not reservations or substitutes for tuning.

## Hardened setup behavior

`setup.sh` treats the selected `.env` file strictly as data; it does not source or execute it. First-run environment creation remains explicit and exits before provisioning.

Additional safeguards:

- Existing image tags are reused by default. Use `--pull` when you intentionally want to refresh the configured tags.
- Host mode refuses to silently claim an existing database or MariaDB user. After reviewing an older deployment, run once with `--adopt-existing-db` to create a local identity marker.
- Compose resources are tied to the deployment working directory. After reviewing legacy stopped volumes with no identity marker, run once with `--reuse-project`.
- Official `wordpress`, `nginx`, and `mariadb` image repositories are required by default. Use `--allow-custom-images` only for a reviewed custom build.
- A MariaDB administrative defaults file must be a regular non-symlink file, privately permissioned, and owned by the current user or root.

Normal first deployment:

```bash
./setup.sh host --init-env
editor .env.host
./setup.sh host
```

Explicit image refresh:

```bash
./setup.sh host --pull
```

One-time adoption after upgrading an existing host-database deployment:

```bash
./setup.sh host --adopt-existing-db
```

One-time adoption of existing Compose resources whose original working directory cannot be proven:

```bash
./setup.sh host --reuse-project
```

Review the database name, user, grants, Compose project name, and Docker volumes before using either adoption option.
