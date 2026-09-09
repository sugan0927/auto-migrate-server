#!/bin/bash
# ==========================================================================
# auto-migrate-restore.sh — runs on the NEW VPS.
# Normally invoked automatically by auto-migrate.sh over SSH; can also be
# run manually on the new server if you already copied /root/migration-backup
# there yourself.
# ==========================================================================

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib/common.sh
source "$SCRIPT_DIR/lib/common.sh"

LOG_FILE="/var/log/auto-migrate-restore.log"
touch "$LOG_FILE" 2>/dev/null || LOG_FILE=/dev/null

AUTO_YES=0
for arg in "$@"; do
    [[ "$arg" == "--yes" ]] && AUTO_YES=1
done

require_root
check_for_update "auto-migrate-restore.sh" "$@"

BACKUP_DIR="/root/migration-backup"
cd "$BACKUP_DIR" || log_error "Backup directory ($BACKUP_DIR) not found. Did the transfer step complete?"

require_free_space_mb / 2048

# ---------- Figure out which PHP version to install ----------
# Uses whatever version the OLD server was actually running (saved during
# backup), falling back to the newest one apt currently offers. This is
# what keeps the script working correctly even after PHP 8.3 is retired.
WANTED_PHP=""
[[ -f php_version.txt ]] && WANTED_PHP="$(tr -d '[:space:]' < php_version.txt)"

apt-get update -qq

PHP_VERSION="$(resolve_php_version_to_install "$WANTED_PHP")"
if [[ -z "$PHP_VERSION" ]]; then
    log_error "Could not find any php-fpm package via apt. Check your apt sources."
fi
if [[ -n "$WANTED_PHP" && "$PHP_VERSION" != "$WANTED_PHP" ]]; then
    log_warn "PHP $WANTED_PHP (used by the old server) is no longer available; installing PHP $PHP_VERSION instead. You may need to review PHP-FPM pool configs after restore."
fi
log_info "Installing PHP $PHP_VERSION ..."

log_info "Installing required packages (nginx, mariadb, php, certbot, ufw, fail2ban)..."
apt-get install -y -qq nginx mariadb-server \
    "php${PHP_VERSION}-fpm" "php${PHP_VERSION}-common" "php${PHP_VERSION}-mysql" \
    "php${PHP_VERSION}-curl" "php${PHP_VERSION}-gd" "php${PHP_VERSION}-mbstring" \
    "php${PHP_VERSION}-xml" "php${PHP_VERSION}-zip" "php${PHP_VERSION}-bcmath" \
    "php${PHP_VERSION}-soap" "php${PHP_VERSION}-intl" "php${PHP_VERSION}-opcache" \
    redis-server certbot python3-certbot-nginx ufw fail2ban rsync curl wget git >/dev/null

# ---------- Install Stalwart mail server (if not already present) ----------
if ! command -v stalwart &>/dev/null; then
    log_info "Installing Stalwart mail server..."
    if curl -fsSL --max-time 30 https://get.stalw.art/install.sh -o /tmp/stalwart-install.sh; then
        bash /tmp/stalwart-install.sh
        rm -f /tmp/stalwart-install.sh
    else
        log_warn "Could not download the Stalwart installer — skipping. Mail restore below may not start correctly until it's installed manually."
    fi
fi

log_info "Restoring backups..."

extract() {
    # extract <archive.tar.gz> — logs a clear warning instead of silently
    # continuing if an archive is missing or corrupt.
    local archive_file="$1"
    if [[ ! -f "$archive_file" ]]; then
        log_warn "$archive_file not found in backup — skipping."
        return 0
    fi
    if ! tar -tzf "$archive_file" &>/dev/null; then
        log_warn "$archive_file looks corrupted — skipping restore of it."
        return 0
    fi
    tar -xzf "$archive_file" -C / || log_warn "Some files from $archive_file failed to restore."
}

extract website.tar.gz

if [[ -f db.sql ]]; then
    systemctl start mariadb
    mysql -u root < db.sql || log_warn "DB restore failed — you may need to import db.sql manually (mysql -u root -p < /root/migration-backup/db.sql)."
    systemctl restart mariadb
else
    log_warn "No db.sql in backup — skipping database restore."
fi

# Restoring db.sql above replaces the `mysql` system database, which can
# switch root auth from the new server's fresh unix_socket login to
# whatever the OLD server used. Put back the matching password reference
# so you're not locked out.
if [[ -f mysql_root_password.txt ]]; then
    cp mysql_root_password.txt /root/.mysql_root_password
    chmod 600 /root/.mysql_root_password
    log_info "MariaDB root password restored to /root/.mysql_root_password — use 'mysql -u root -p' with it if 'mysql -u root' (no password) stops working after this restore."
fi

systemctl stop stalwart 2>/dev/null || true
extract stalwart.tar.gz
systemctl start stalwart 2>/dev/null || log_warn "Stalwart did not start — check 'journalctl -u stalwart'."

extract configs.tar.gz
systemctl restart "php${PHP_VERSION}-fpm" 2>/dev/null || log_warn "Could not restart php${PHP_VERSION}-fpm — check its config."
nginx -t 2>/tmp/nginx-test.log && systemctl restart nginx || log_warn "nginx config test failed after restore, nginx NOT restarted. See /tmp/nginx-test.log and fix before it will serve traffic."

extract ssl.tar.gz

extract system.tar.gz
# Apply whatever hostname the OLD server actually had — never hardcoded,
# so this script works for any domain/server, not just one specific site.
if [[ -f /etc/hostname ]]; then
    hostnamectl set-hostname "$(cat /etc/hostname)" 2>/dev/null || true
fi

if [[ -f ee ]]; then
    cp ee /usr/local/bin/ee
    chmod +x /usr/local/bin/ee
fi

# ---------- Firewall ----------
# Looped individually (rather than one comma-separated rule) for maximum
# compatibility across ufw versions over the years.
log_info "Configuring firewall..."
for port in 22 80 443 25 587 465 143 993 110 995; do
    ufw allow "${port}/tcp" >/dev/null
done
ufw --force enable >/dev/null

log_info "Restoration complete."

# ---------- Renew SSL, using whatever authenticator each cert was
# actually issued with (nginx plugin, in the normal case) — NOT forced
# standalone, and without stopping nginx, which would break the nginx
# plugin's renewal.
log_info "Attempting to renew SSL certificates (works once DNS points here)..."
certbot renew --quiet --non-interactive || log_warn "certbot renew reported issues — this is expected until DNS points to this server. Re-run 'certbot renew' after updating DNS."

log_info "✅ All services restored. Review any [WARN] lines above before switching DNS."
log_info "Full log saved to $LOG_FILE"
