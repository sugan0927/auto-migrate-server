# auto-migrate

One-command migration for a LEMP + Stalwart mail server from an old VPS to a
new one: websites, MariaDB, mail data, nginx/PHP/firewall configs, and SSL
certificates.

## What it does

1. `auto-migrate.sh` (run on the **old** server) backs up:
   - `/var/www` (websites)
   - full MariaDB dump (`--single-transaction --routines --triggers --events`)
   - Stalwart mail data + config
   - nginx, PHP, ufw, fail2ban configs
   - Let's Encrypt certificates
   - hostname/hosts, the `ee` CLI (if present), and the MariaDB root password file
2. Transfers everything to the new server over SSH (password-based, using `sshpass`).
3. Automatically runs `auto-migrate-restore.sh` on the new server, which
   installs matching packages (detecting the right PHP version instead of
   assuming one), restores everything, and re-enables services.

## Requirements

- Both servers: Debian/Ubuntu with `bash`, run as **root**.
- Old server: outbound SSH access to the new server.
- New server: a fresh VPS is safest — this will overwrite `/etc/nginx`,
  `/etc/php`, `/var/www`, and MariaDB's data with the old server's data.

## Usage

```bash
git clone https://github.com/<you>/auto-migrate.git
cd auto-migrate
chmod +x auto-migrate.sh auto-migrate-restore.sh
sudo ./auto-migrate.sh
```

You'll be asked for the new server's IP, root password, and SSH port. Add
`--yes` to skip the confirmation prompt (useful for scripted runs).

**Important:** `auto-migrate.sh`, `auto-migrate-restore.sh`, and the `lib/`
folder must stay together in the same directory — the main script looks for
the restore script and shared library right next to itself.

## After migration

- Update your domain's DNS (A/AAAA) to the new IP.
- Update the mail server's reverse DNS (PTR) with your VPS provider.
- Test the site and mail on the new IP before fully cutting over DNS.
- Once DNS has propagated, run `certbot renew` on the new server if needed.
- If `mysql -u root` (no password) stops working after restore, use
  `mysql -u root -p` with the password now saved at
  `/root/.mysql_root_password` — restoring the database can replace the new
  server's fresh MariaDB auth with the old server's.

## Self-updating

Both scripts check `VERSION` against the same file in this repo's `main`
branch on every run and update themselves automatically if you're behind
(silently skipped if offline). To enable this after you fork/publish this
repo, set `REPO_RAW_BASE` at the top of `lib/common.sh` to your repo's raw
URL, e.g.:

```bash
REPO_RAW_BASE="https://raw.githubusercontent.com/<you>/auto-migrate/main"
```

Bump the `VERSION` file and push whenever you change something — every
server that has ever run this script will pick up the fix on its next run.

## Honest limitations

No script can realistically guarantee "zero errors for 10 years" — Debian/
Ubuntu package names, PHP's release cycle, and cloud-provider conventions
will keep changing. What this project does instead:

- Detects the PHP version to install rather than hardcoding one, so it
  keeps working after PHP 8.3 is retired.
- Fails fast with a clear message on missing SSH access, low disk space, or
  a missing restore script, instead of silently limping on.
- Self-updates from GitHub so a fix only has to be made once.

Re-test occasionally against current Debian/Ubuntu releases and keep the
repo's `VERSION` bumped when you do.
