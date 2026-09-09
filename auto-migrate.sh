#!/bin/bash
# ==========================================================================
# auto-migrate.sh — run this on the OLD server.
# Backs up LEMP + Stalwart mail, transfers everything to a new server, and
# triggers the matching auto-migrate-restore.sh there.
#
# Usage:
#   ./auto-migrate.sh                # interactive
#   ./auto-migrate.sh --yes          # skip confirmation prompts
#
# Requires auto-migrate-restore.sh and lib/common.sh in the SAME folder
# as this script (that's how it ships in the repo — don't move just one file).
# ==========================================================================

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib/common.sh
source "$SCRIPT_DIR/lib/common.sh"

LOG_FILE="/var/log/auto-migrate.log"
touch "$LOG_FILE" 2>/dev/null || LOG_FILE=/dev/null

AUTO_YES=0
for arg in "$@"; do
    [[ "$arg" == "--yes" ]] && AUTO_YES=1
done

require_root
check_for_update "auto-migrate.sh" "$@"

RESTORE_SCRIPT="$SCRIPT_DIR/auto-migrate-restore.sh"
[[ -f "$RESTORE_SCRIPT" ]] || log_error "auto-migrate-restore.sh not found next to this script in $SCRIPT_DIR. Both files must ship together."

# ---------- Get new server details ----------
read -r -p "Enter new VPS IP address: " NEW_IP
read -rsp "Enter new VPS root password: " NEW_PASS
echo
read -r -p "Enter new VPS SSH port [22]: " NEW_PORT
NEW_PORT=${NEW_PORT:-22}

[[ -z "$NEW_IP" ]] && log_error "IP address is required."
[[ -z "$NEW_PASS" ]] && log_error "Password is required."
if ! [[ "$NEW_IP" =~ ^([0-9]{1,3}\.){3}[0-9]{1,3}$ ]] && ! [[ "$NEW_IP" =~ ^[a-zA-Z0-9.-]+$ ]]; then
    log_error "That doesn't look like a valid IP address or hostname."
fi
if ! [[ "$NEW_PORT" =~ ^[0-9]+$ ]]; then
    log_error "SSH port must be a number."
fi

# ---------- Prerequisites ----------
log_info "Installing required packages (rsync, sshpass)..."
apt-get update -qq
apt-get install -y -qq rsync sshpass >/dev/null

export SSHPASS="$NEW_PASS"
SSH_OPTS=(-p "$NEW_PORT" -o StrictHostKeyChecking=accept-new -o ConnectTimeout=10)

# ---------- Test connectivity BEFORE doing any backup work ----------
log_info "Testing SSH connection to $NEW_IP ..."
if ! sshpass -e ssh "${SSH_OPTS[@]}" "root@$NEW_IP" "echo ok" &>/dev/null; then
    unset SSHPASS
    log_error "Could not SSH into root@$NEW_IP:$NEW_PORT with the given password. Check IP/port/password and that root login is allowed, then try again."
fi
log_info "Connection OK."

confirm "This will back up this server and OVERWRITE data on $NEW_IP. Continue?" || { unset SSHPASS; log_error "Cancelled by user."; }

# ---------- 1. Create backup on old server ----------
BACKUP_DIR="/root/migration-backup"
require_free_space_mb /root 2048
rm -rf "$BACKUP_DIR"
mkdir -p "$BACKUP_DIR"
cd "$BACKUP_DIR"

log_info "Creating backups..."

archive() {
    # archive <output.tar.gz> <path...> — logs a clear warning (not a
    # silent swallow) if a path is missing, and verifies the archive isn't
    # corrupt once written.
    local out="$1"; shift
    if tar -czf "$out" "$@" 2>/tmp/tar-err.log; then
        tar -tzf "$out" &>/dev/null || log_warn "$out was created but failed integrity check — it may be incomplete."
    else
        log_warn "Could not fully archive $* into $out (see /tmp/tar-err.log). Continuing anyway."
    fi
}

# 1.1 Websites
archive website.tar.gz /var/www

# 1.2 MariaDB (includes routines/triggers/events, and a consistent
# snapshot even while the DB is live).
if command -v mysqldump &>/dev/null && systemctl is-active --quiet mariadb 2>/dev/null; then
    mysqldump --all-databases --single-transaction --routines --triggers --events -u root > db.sql \
        || log_warn "MariaDB dump failed — check root DB auth (see /root/.mysql_root_password if this server used ee.sh)."
else
    log_warn "MariaDB not running/installed — skipping database dump."
fi

# 1.3 Stalwart (stop briefly to avoid dumping mid-write data)
if systemctl is-active --quiet stalwart 2>/dev/null; then
    systemctl stop stalwart
    archive stalwart.tar.gz /var/lib/stalwart /etc/stalwart
    systemctl start stalwart
else
    archive stalwart.tar.gz /var/lib/stalwart /etc/stalwart
fi

# 1.4 Configs (nginx, php, ufw, fail2ban)
archive configs.tar.gz /etc/nginx /etc/php /etc/ufw /etc/fail2ban

# 1.5 SSL
archive ssl.tar.gz /etc/letsencrypt

# 1.6 System hostname/hosts (restore.sh re-applies the ACTUAL hostname
# from this backup — nothing is hardcoded to any particular domain).
archive system.tar.gz /etc/hostname /etc/hosts

# 1.7 EE script (if exists)
[[ -f /usr/local/bin/ee ]] && cp /usr/local/bin/ee .

# 1.7b MariaDB root password reference (servers set up with ee.sh keep it
# here). Restoring db.sql below overwrites the `mysql` system database,
# which can replace the NEW server's fresh root auth with the OLD
# server's — so this file is what lets you log back in afterwards.
[[ -f /root/.mysql_root_password ]] && cp /root/.mysql_root_password mysql_root_password.txt

# 1.8 Record this server's PHP version, so the new server installs the
# SAME version instead of a hardcoded one that may not exist in 8-10 years.
detect_php_fpm_version > php_version.txt 2>/dev/null || echo "" > php_version.txt

# 1.9 List all files
ls -lh "$BACKUP_DIR"

# ---------- 2. Transfer to new server ----------
log_info "Transferring backups to $NEW_IP ..."
sshpass -e ssh "${SSH_OPTS[@]}" "root@$NEW_IP" "mkdir -p /root/migration-backup"
rsync -avz --partial -e "sshpass -e ssh ${SSH_OPTS[*]}" \
    "$BACKUP_DIR/" "root@$NEW_IP:/root/migration-backup/"

# Send the ACTUAL restore script + shared lib (fixes the old bug where
# this migrate script's own content ($0) was sent instead).
rsync -avz -e "sshpass -e ssh ${SSH_OPTS[*]}" \
    "$RESTORE_SCRIPT" "$SCRIPT_DIR/VERSION" "root@$NEW_IP:/root/"
sshpass -e ssh "${SSH_OPTS[@]}" "root@$NEW_IP" "mkdir -p /root/lib"
rsync -avz -e "sshpass -e ssh ${SSH_OPTS[*]}" \
    "$SCRIPT_DIR/lib/common.sh" "root@$NEW_IP:/root/lib/"

log_info "Transfer complete."

# ---------- 3. Run restore script on new server ----------
log_info "Running restoration on new server (this can take a while)..."
sshpass -e ssh "${SSH_OPTS[@]}" "root@$NEW_IP" \
    "REPO_RAW_BASE='$REPO_RAW_BASE' bash /root/auto-migrate-restore.sh ${AUTO_YES:+--yes}"

unset SSHPASS

log_info "✅ Migration completed."
log_info "Next steps:"
log_info "1. Update your DNS records (A/AAAA) to the new IP: $NEW_IP"
log_info "2. Update Reverse DNS (PTR) for your mail hostname with your VPS provider."
log_info "3. Verify the website and mail server on the new IP before switching DNS fully."
log_info "4. Once DNS has propagated, run 'certbot renew' on the new server to refresh SSL if needed."
log_info "Full log saved to $LOG_FILE"
