# Host Apache 2 reverse proxy

The Compose stacks publish their inner Nginx service only on loopback:

```text
association.org -> Apache :443 -> 127.0.0.1:8081 -> container Nginx -> PHP-FPM
```

MariaDB and PHP-FPM are not published to the host network.

## 1. Assign a unique loopback port

For `association.org`, set the chosen mode's environment file:

```dotenv
COMPOSE_PROJECT_NAME=association-org
HTTP_PORT=8081
```

For additional sites, use a different project name and port, for example:

```text
association.org -> 8081
person.com      -> 8082
domain.us       -> 8083
```

Start the selected stack and confirm the loopback backend responds:

```bash
./compose.sh host up -d
# or: ./compose.sh container up -d

curl -I -H 'Host: association.org' http://127.0.0.1:8081/
```

Do not change the Compose binding from `127.0.0.1:${HTTP_PORT}:80` to a public bind unless bypassing Apache is intentional.

## 2. Enable Apache modules

Debian/Ubuntu:

```bash
sudo a2enmod proxy proxy_http headers ssl alias
sudo apache2ctl configtest
sudo systemctl reload apache2
```

`ProxyRequests Off` must remain set; this deployment is a reverse proxy, not an open forward proxy.

## 3. Install the initial HTTP vhost

Copy and edit the included template:

```bash
sudo cp apache2/wordpress-site-http.conf.example \
  /etc/apache2/sites-available/association.org.conf
sudo editor /etc/apache2/sites-available/association.org.conf
```

Change at least:

- `ServerName`
- `ServerAlias`
- `127.0.0.1:8081`
- log filenames if desired

Then enable it:

```bash
sudo a2ensite association.org.conf
sudo apache2ctl configtest
sudo systemctl reload apache2
```

Test Apache before changing DNS:

```bash
curl -I -H 'Host: association.org' http://127.0.0.1/
```

## 4. Obtain TLS with Certbot

After the public DNS records resolve to this VPS:

```bash
sudo certbot --apache \
  -d association.org \
  -d www.association.org \
  --redirect
```

Certbot can install and renew the certificate using Apache. Inspect the resulting vhost and confirm the HTTPS proxy still targets `http://127.0.0.1:8081/` and sets:

```apache
RequestHeader set X-Forwarded-Proto "https"
RequestHeader set X-Forwarded-Port "443"
```

Alternatively, after obtaining the certificate, install `wordpress-site-https.conf.example`, adjust its values, and disable the HTTP-only configuration if it is replaced by a differently named file.

## 5. Validate the final path

```bash
sudo apache2ctl configtest
sudo systemctl reload apache2

curl -I https://association.org/
curl -I https://association.org/wp-admin/
```

The first WordPress installation should use the final canonical URL:

```text
https://association.org
```

The Compose configuration enables `FORCE_SSL_ADMIN`. The official WordPress Docker configuration recognizes `X-Forwarded-Proto: https`, preventing the usual TLS-termination redirect loop.

## 6. Add another site

Copy the repository into a separate deployment directory, set a unique `COMPOSE_PROJECT_NAME` and `HTTP_PORT`, and create another Apache vhost pointing to that port.

Example mapping:

```apache
# person.com
ProxyPass        / http://127.0.0.1:8082/ connectiontimeout=5 timeout=120
ProxyPassReverse / http://127.0.0.1:8082/
```

## Troubleshooting

### 502 Bad Gateway

Check the loopback backend and containers:

```bash
curl -I http://127.0.0.1:8081/
./compose.sh host ps
./compose.sh host logs --tail=100 nginx wordpress
```

Use `container` instead of `host` for the containerized-database mode.

### HTTPS redirect loop

Confirm the port 443 vhost sets `X-Forwarded-Proto` to `https`, and that no other proxy layer overwrites it.

### Wrong domain in redirects

Confirm `ProxyPreserveHost On` and check WordPress `home` and `siteurl` values. Do not set those values to `127.0.0.1:8081`.

### Upload rejected

The request-size limit is 64 MiB in Apache, inner Nginx, and PHP. Change all three layers together if a larger limit is required.
