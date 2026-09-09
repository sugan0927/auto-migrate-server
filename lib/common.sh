#!/bin/bash
# ==========================================================================
# lib/common.sh — shared functions for auto-migrate.sh / auto-migrate-restore.sh
# Sourced by both scripts. Not meant to be run directly.
# ==========================================================================

# ---------- EDIT THIS after you publish the repo on GitHub ----------
# Example: https://raw.githubusercontent.com/yourname/auto-migrate/main
REPO_RAW_BASE="${REPO_RAW_BASE:-}"

RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[0;33m'; NC='\033[0m'

log_info()  { echo -e "${GREEN}[INFO]${NC} $*" | tee -a "${LOG_FILE:-/dev/null}"; }
log_warn()  { echo -e "${YELLOW}[WARN]${NC} $*" | tee -a "${LOG_FILE:-/dev/null}"; }
log_error() { echo -e "${RED}[ERROR]${NC} $*" | tee -a "${LOG_FILE:-/dev/null}" >&2; exit 1; }

require_root() {
    [[ $EUID -eq 0 ]] || log_error "This script must be run as root."
}

# Ask a yes/no question. Auto-accepts if AUTO_YES=1 (set via --yes flag).
confirm() {
    local prompt="$1"
    if [[ "${AUTO_YES:-0}" == "1" ]]; then
        return 0
    fi
    read -r -p "$prompt [y/N]: " reply
    [[ "$reply" =~ ^[Yy]$ ]]
}

# ---------- Self-update ----------
# Checks REPO_RAW_BASE/VERSION against the local VERSION file. If different,
# re-downloads this script + common.sh + VERSION and re-executes itself with
# the same arguments. Fails silently (keeps running current version) if
# offline or REPO_RAW_BASE isn't configured — never blocks a migration.
check_for_update() {
    local script_name="$1"     # e.g. auto-migrate.sh
    shift
    local orig_args=("$@")

    [[ -z "$REPO_RAW_BASE" ]] && return 0
    [[ -f "$SCRIPT_DIR/VERSION" ]] || return 0

    local local_version remote_version
    local_version=$(cat "$SCRIPT_DIR/VERSION" 2>/dev/null || echo "0")
    remote_version=$(curl -fsSL --max-time 5 "$REPO_RAW_BASE/VERSION" 2>/dev/null) || {
        log_warn "Could not check for updates (offline or repo unreachable). Continuing with v$local_version."
        return 0
    }
    remote_version="$(echo "$remote_version" | tr -d '[:space:]')"

    if [[ -n "$remote_version" && "$remote_version" != "$local_version" ]]; then
        log_info "New version found: $remote_version (you have $local_version). Updating..."
        local tmp_script tmp_common tmp_version
        tmp_script=$(mktemp); tmp_common=$(mktemp); tmp_version=$(mktemp)

        if curl -fsSL --max-time 20 "$REPO_RAW_BASE/$script_name" -o "$tmp_script" \
           && curl -fsSL --max-time 20 "$REPO_RAW_BASE/lib/common.sh" -o "$tmp_common" \
           && curl -fsSL --max-time 20 "$REPO_RAW_BASE/VERSION" -o "$tmp_version"; then
            chmod +x "$tmp_script"
            mv "$tmp_script" "$SCRIPT_DIR/$script_name"
            mkdir -p "$SCRIPT_DIR/lib"
            mv "$tmp_common" "$SCRIPT_DIR/lib/common.sh"
            mv "$tmp_version" "$SCRIPT_DIR/VERSION"
            # Best-effort: also refresh the sibling script so both stay in sync.
            local sibling="auto-migrate.sh"
            [[ "$script_name" == "auto-migrate.sh" ]] && sibling="auto-migrate-restore.sh"
            curl -fsSL --max-time 20 "$REPO_RAW_BASE/$sibling" -o "$SCRIPT_DIR/$sibling.new" 2>/dev/null \
                && mv "$SCRIPT_DIR/$sibling.new" "$SCRIPT_DIR/$sibling" && chmod +x "$SCRIPT_DIR/$sibling"

            log_info "Updated to v$remote_version. Restarting..."
            exec "$SCRIPT_DIR/$script_name" "${orig_args[@]}"
        else
            log_warn "Update download failed. Continuing with v$local_version."
            rm -f "$tmp_script" "$tmp_common" "$tmp_version"
        fi
    fi
}

# ---------- Environment detection (avoids hardcoding versions) ----------

# Prints the PHP version (e.g. "8.3") that php-fpm is actually running as on
# THIS machine, or empty string if none is installed.
detect_php_fpm_version() {
    local v
    # Prefer whichever php-fpm systemd service is currently active.
    for f in /etc/php/*/fpm; do
        [[ -d "$f" ]] || continue
        v="$(basename "$(dirname "$f")")"
        if systemctl is-active --quiet "php${v}-fpm" 2>/dev/null; then
            echo "$v"
            return 0
        fi
    done
    # None active (or systemctl unavailable) — fall back to the newest
    # installed version folder under /etc/php/.
    ls /etc/php/ 2>/dev/null | grep -E '^[0-9]+\.[0-9]+$' | sort -V | tail -1
}

# Given a version like "8.3" (or empty), prints the best PHP version to
# install: the requested one if still available in apt, otherwise the
# newest php-fpm package apt currently offers. This is what keeps the
# script working years from now even after PHP 8.3 is retired upstream.
resolve_php_version_to_install() {
    local wanted="$1"
    if [[ -n "$wanted" ]] && apt-cache show "php${wanted}-fpm" &>/dev/null; then
        echo "$wanted"
        return 0
    fi
    # NOTE: apt-cache search output is "packagename - description", so the
    # match must NOT anchor with $ right after "-fpm" or it will never hit.
    apt-cache search '^php[0-9]+\.[0-9]+-fpm' 2>/dev/null \
        | grep -oP '^php\K[0-9]+\.[0-9]+(?=-fpm\b)' \
        | sort -V | tail -1
}

# ---------- Disk space guard ----------
require_free_space_mb() {
    local path="$1" needed_mb="$2"
    local avail_mb
    avail_mb=$(df -Pm "$path" | awk 'NR==2 {print $4}')
    if [[ -z "$avail_mb" || "$avail_mb" -lt "$needed_mb" ]]; then
        log_error "Not enough free space at $path (need ~${needed_mb}MB, have ${avail_mb:-0}MB)."
    fi
}
