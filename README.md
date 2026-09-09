# auto-migrate-server

**Repo:** https://github.com/sugan0927/auto-migrate-server

One-command migration for a LEMP + Stalwart mail server from an old VPS to a
new one: websites, MariaDB, mail data, nginx/PHP/firewall configs, and SSL
certificates — plus a matching restore script that runs automatically on the
new server.

## What it does

1. **`auto-migrate.sh`** (run on the **old** server) backs up:
   - `/var/www` (websites)
   - a full MariaDB dump (`--single-transaction --routines --triggers --events`)
   - Stalwart mail data + config
   - nginx, PHP, ufw, fail2ban configs
   - Let's Encrypt certificates
   - hostname/hosts, the `ee` CLI (if present), and the MariaDB root
     password file (needed to log back in after DB restore)
2. Transfers everything to the new server over SSH (password-based, using `sshpass`).
3. Automatically runs **`auto-migrate-restore.sh`** on the new server, which
   detects and installs the matching PHP version, restores everything, and
   re-enables all services.

## Requirements

- Both servers: Debian/Ubuntu, run as **root**.
- Old server: outbound SSH access to the new server.
- New server: a **fresh** VPS is safest — this overwrites `/etc/nginx`,
  `/etc/php`, `/var/www`, and MariaDB's data with the old server's data.

## Usage

```bash
git clone https://github.com/sugan0927/auto-migrate-server.git
cd auto-migrate-server
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
  `mysql -u root -p` with the password saved at
  `/root/.mysql_root_password` — restoring the database can replace the
  new server's fresh MariaDB auth with the old server's.

## Self-updating

Every run checks `VERSION` in this repo's `main` branch and updates itself
automatically if a newer one is published (silently skipped if offline).
`lib/common.sh` already points at:

```
https://raw.githubusercontent.com/sugan0927/auto-migrate-server/main
```

To ship a fix to every server that has ever run this script: commit the
change, **bump the `VERSION` file**, and push to `main`. The next time
`auto-migrate.sh` or `auto-migrate-restore.sh` runs anywhere, it pulls the
update before doing anything else.

If you ever fork this to a different account/repo, update `REPO_RAW_BASE`
at the top of `lib/common.sh` to match.

## Honest limitations

No script can realistically guarantee "zero errors for 10 years" — Debian/
Ubuntu package names, PHP's release cycle, and cloud-provider conventions
will keep changing. What this project does instead:

- Detects the PHP version to install rather than hardcoding one, so it
  keeps working after PHP 8.3 is retired.
- Fails fast with a clear message on missing SSH access, low disk space, or
  a missing restore script, instead of silently limping on.
- Self-updates from this repo so a fix only has to be made once.

Re-test occasionally against current Debian/Ubuntu releases and keep
`VERSION` bumped when you do.
