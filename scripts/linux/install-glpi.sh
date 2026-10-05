#!/usr/bin/env bash
# Installs GLPI (open-source IT service management / ticketing) on Ubuntu 24.04 with Apache,
# PHP 8.3 and MariaDB. Run as root. Expects these variables (sent over SSH stdin, never on a
# command line): GLPI_VERSION, GLPI_DB_PW, GLPI_ADMIN_PW.
#
# Steps:
#   1. Install Apache, MariaDB and the PHP extensions GLPI needs.
#   2. Create the glpi database and a database user that can only touch that database.
#   3. Download GLPI from its official GitHub release and check it against the published SHA-256.
#   4. Point Apache at GLPI's public/ folder (GLPI 11 only exposes that folder to the web).
#   5. Run GLPI's own command-line installer to create the tables.
#   6. Replace the well-known default passwords: give "glpi" a strong one, disable the other demo accounts.
set -euo pipefail
: "${GLPI_VERSION:?}" "${GLPI_DB_PW:?}" "${GLPI_ADMIN_PW:?}"
export DEBIAN_FRONTEND=noninteractive

echo "[1/6] Packages"
apt-get update -qq
apt-get install -y -qq apache2 mariadb-server libapache2-mod-php \
  php-mysql php-curl php-gd php-intl php-xml php-mbstring php-zip php-bz2 php-ldap php-bcmath php-cli curl > /dev/null

echo "[2/6] Database"
mysql <<SQL
CREATE DATABASE IF NOT EXISTS glpi CHARACTER SET utf8mb4 COLLATE utf8mb4_unicode_ci;
CREATE USER IF NOT EXISTS 'glpi'@'localhost' IDENTIFIED BY '${GLPI_DB_PW}';
ALTER USER 'glpi'@'localhost' IDENTIFIED BY '${GLPI_DB_PW}';
GRANT ALL PRIVILEGES ON glpi.* TO 'glpi'@'localhost';
FLUSH PRIVILEGES;
SQL

echo "[3/6] Download GLPI ${GLPI_VERSION}"
cd /tmp
url="https://github.com/glpi-project/glpi/releases/download/${GLPI_VERSION}/glpi-${GLPI_VERSION}.tgz"
curl -fsSL -o glpi.tgz "$url"
# GitHub publishes a SHA-256 digest for each release asset; compare against it when available.
expected=$(curl -fsSL "https://api.github.com/repos/glpi-project/glpi/releases/tags/${GLPI_VERSION}" \
  | grep -A30 "\"name\": \"glpi-${GLPI_VERSION}.tgz\"" | grep -o '"digest": *"sha256:[0-9a-f]*"' | grep -o '[0-9a-f]\{64\}' || true)
actual=$(sha256sum glpi.tgz | cut -d' ' -f1)
if [ -n "$expected" ]; then
  [ "$expected" = "$actual" ] || { echo "Checksum mismatch: $actual vs $expected"; exit 1; }
  echo "  sha256 verified: $actual"
else
  echo "  (no published digest found; sha256 = $actual)"
fi
rm -rf /var/www/glpi
tar -xzf glpi.tgz -C /var/www
rm glpi.tgz
chown -R www-data:www-data /var/www/glpi

echo "[4/6] Apache"
cat > /etc/apache2/sites-available/glpi.conf <<'APACHE'
<VirtualHost *:80>
    ServerName tkt01.corp.roscoe.internal
    DocumentRoot /var/www/glpi/public
    <Directory /var/www/glpi/public>
        Require all granted
        RewriteEngine On
        # Pass Authorization headers through to GLPI's API
        RewriteCond %{HTTP:Authorization} ^(.+)$
        RewriteRule .* - [E=HTTP_AUTHORIZATION:%{HTTP:Authorization}]
        # Send every request that isn't a real file to GLPI's front controller
        RewriteCond %{REQUEST_FILENAME} !-f
        RewriteRule ^(.*)$ index.php [QSA,L]
    </Directory>
</VirtualHost>
APACHE
# GLPI's recommended PHP setting: session cookies can't be read by JavaScript
phpver=$(php -r 'echo PHP_MAJOR_VERSION.".".PHP_MINOR_VERSION;')
echo "session.cookie_httponly = On" > "/etc/php/${phpver}/apache2/conf.d/99-glpi.ini"
a2enmod -q rewrite
a2dissite -q 000-default
a2ensite -q glpi
systemctl reload apache2

echo "[5/6] GLPI database install"
cd /var/www/glpi
sudo -u www-data php bin/console database:install \
  --db-host=localhost --db-name=glpi --db-user=glpi --db-password="${GLPI_DB_PW}" \
  --default-language=en_US --no-interaction --force > /dev/null
rm -f /var/www/glpi/install/install.php   # GLPI warns until the web installer is removed

echo "[6/6] Default accounts"
hash=$(GLPI_ADMIN_PW="$GLPI_ADMIN_PW" php -r 'echo password_hash(getenv("GLPI_ADMIN_PW"), PASSWORD_DEFAULT);')
mysql glpi <<SQL
UPDATE glpi_users SET password = '${hash}', password_last_update = NOW() WHERE name = 'glpi';
UPDATE glpi_users SET is_active = 0 WHERE name IN ('tech', 'normal', 'post-only');
SQL

echo "GLPI ${GLPI_VERSION} installed: http://tkt01.corp.roscoe.internal/ (user: glpi)"
