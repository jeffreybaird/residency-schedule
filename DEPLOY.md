# Production Deployment Guide

This guide covers deploying the Residency Schedule app to a Digital Ocean Ubuntu droplet using GitHub Actions CI/CD.

---

## Overview

| Component | Choice |
|---|---|
| Server | Digital Ocean Droplet — Ubuntu 24.04 LTS, 2 GB RAM |
| Process manager | systemd |
| Reverse proxy | Nginx |
| SSL | Let's Encrypt (Certbot) |
| Database | PostgreSQL (self-hosted on the same droplet) |
| Deploys | GitHub Actions — push to `main` triggers build → deploy |

Deployments are fully automated after initial server setup. Pushing to `main` builds the release, runs tests, runs migrations, swaps the binary, and restarts the service. If the health check fails, the old release is automatically restored.

---

## Part 1: One-time server setup (do this once)

### 1.1 Create the droplet

- **Image:** Ubuntu 24.04 LTS x64
- **Size:** 2 GB RAM / 1 vCPU (minimum), 2 vCPU recommended
- **Region:** Choose nearest to your users
- **Authentication:** SSH key (add your local public key during creation)
- **Hostname:** e.g. `residency-schedule`

SSH in as root:
```bash
ssh root@<your-droplet-ip>
```

### 1.2 Install system dependencies

```bash
apt-get update && apt-get upgrade -y
apt-get install -y \
  erlang elixir \
  postgresql postgresql-contrib \
  nginx certbot python3-certbot-nginx \
  git curl
```

Verify versions:
```bash
elixir --version   # should be 1.15+
psql --version     # should be 14+
nginx -v
```

### 1.3 Create the deploy user

```bash
useradd -m -s /bin/bash deploy
mkdir -p /home/deploy/.ssh
# Paste the PUBLIC key that matches your GitHub deploy SSH key
echo "ssh-ed25519 AAAA... deploy@github-actions" >> /home/deploy/.ssh/authorized_keys
chmod 700 /home/deploy/.ssh
chmod 600 /home/deploy/.ssh/authorized_keys
chown -R deploy:deploy /home/deploy/.ssh
```

### 1.4 Grant deploy user permission to restart the service

```bash
cat > /etc/sudoers.d/deploy << 'EOF'
deploy ALL=(ALL) NOPASSWD: /usr/bin/systemctl restart residency_schedule, /usr/bin/systemctl start residency_schedule, /usr/bin/systemctl stop residency_schedule
EOF
chmod 440 /etc/sudoers.d/deploy
visudo -c   # verify the file is valid
```

### 1.5 Set up PostgreSQL

```bash
# Set a password for the postgres superuser
sudo -u postgres psql -c "ALTER USER postgres PASSWORD 'your-db-password';"

# Create the production database
sudo -u postgres createdb residency_schedule_prod

# Verify the connection
PGPASSWORD=your-db-password psql -U postgres -h localhost -d residency_schedule_prod -c "\conninfo"
```

> **Security note:** For a shared or managed database (Digital Ocean Managed PostgreSQL), skip this step and use the connection string provided in the dashboard instead. Set `DB_SSL=true` in your `.env` if using a managed database over SSL.

### 1.6 Create the deployment directory

```bash
mkdir -p /home/deploy/residency_schedule
chown deploy:deploy /home/deploy/residency_schedule
```

### 1.7 Create the environment file

This file holds all secrets. It is **never** committed to source control.

```bash
cat > /home/deploy/residency_schedule/.env << 'EOF'
DATABASE_URL=ecto://postgres:your-db-password@localhost:5432/residency_schedule_prod
SECRET_KEY_BASE=<generate with: mix phx.gen.secret>
PHX_HOST=yourdomain.com
ACCESS_PASSWORD=<choose a strong password>
POOL_SIZE=10
EOF

chmod 600 /home/deploy/residency_schedule/.env
chown deploy:deploy /home/deploy/residency_schedule/.env
```

Generate a `SECRET_KEY_BASE` on your local machine:
```bash
mix phx.gen.secret
```

> **Important:** `DATABASE_URL` and `ACCESS_PASSWORD` live **only** on the server. They are never sent through GitHub. `SECRET_KEY_BASE` and `PHX_HOST` are also in GitHub Secrets (needed at build time for asset digests).

### 1.8 Create the systemd service

```bash
cat > /etc/systemd/system/residency_schedule.service << 'EOF'
[Unit]
Description=Residency Schedule Phoenix App
After=network.target

[Service]
Type=simple
User=deploy
WorkingDirectory=/home/deploy/residency_schedule
EnvironmentFile=/home/deploy/residency_schedule/.env
ExecStart=/home/deploy/residency_schedule/bin/residency_schedule start
ExecStop=/home/deploy/residency_schedule/bin/residency_schedule stop
Restart=on-failure
RestartSec=5
StandardOutput=journal
StandardError=journal

[Install]
WantedBy=multi-user.target
EOF

systemctl daemon-reload
systemctl enable residency_schedule
```

### 1.9 Configure Nginx

```bash
cat > /etc/nginx/sites-available/residency_schedule << 'EOF'
server {
    listen 80;
    server_name yourdomain.com;
    return 301 https://$host$request_uri;
}

server {
    listen 443 ssl;
    server_name yourdomain.com;

    ssl_certificate     /etc/letsencrypt/live/yourdomain.com/fullchain.pem;
    ssl_certificate_key /etc/letsencrypt/live/yourdomain.com/privkey.pem;

    location / {
        proxy_pass         http://localhost:4000;
        proxy_http_version 1.1;
        proxy_set_header   Upgrade $http_upgrade;
        proxy_set_header   Connection "upgrade";
        proxy_set_header   Host $host;
        proxy_set_header   X-Real-IP $remote_addr;
        proxy_set_header   X-Forwarded-For $proxy_add_x_forwarded_for;
        proxy_set_header   X-Forwarded-Proto $scheme;
    }
}
EOF

ln -s /etc/nginx/sites-available/residency_schedule /etc/nginx/sites-enabled/
nginx -t   # verify config is valid
systemctl reload nginx
```

### 1.10 Issue an SSL certificate

Your domain's DNS A record must already point to the droplet IP before running this.

```bash
certbot --nginx -d yourdomain.com
```

Follow the prompts. Certbot will auto-renew the certificate via a cron job.

---

## Part 2: GitHub Secrets setup (do this once)

In your GitHub repository go to **Settings → Secrets and variables → Actions** and add:

| Secret | Value | Notes |
|---|---|---|
| `DEPLOY_HOST` | Droplet IP or domain | e.g. `143.198.12.34` |
| `DEPLOY_SSH_KEY` | Full private key PEM | Generate with `ssh-keygen -t ed25519 -C "deploy@github-actions" -f ~/.ssh/residency_deploy -N ""`, use the private key file |
| `SECRET_KEY_BASE` | Output of `mix phx.gen.secret` | Must match the value in your server `.env` |
| `PHX_HOST` | Your domain | e.g. `residency-schedule.example.com` |

**`DATABASE_URL` and `ACCESS_PASSWORD` are NOT GitHub Secrets** — they live only in `/home/deploy/residency_schedule/.env` on the server.

### Generating and installing the deploy SSH key

On your local machine:
```bash
ssh-keygen -t ed25519 -C "deploy@github-actions" -f ~/.ssh/residency_deploy -N ""
```

Add the **public** key to the server:
```bash
cat ~/.ssh/residency_deploy.pub
# Copy the output, then on the server:
echo "ssh-ed25519 AAAA..." >> /home/deploy/.ssh/authorized_keys
```

Test it works:
```bash
ssh -i ~/.ssh/residency_deploy deploy@your-droplet "echo ok"
```

Add the **private** key to GitHub:
```bash
cat ~/.ssh/residency_deploy
# Copy the entire output including -----BEGIN/END lines
# Paste into GitHub Secret: DEPLOY_SSH_KEY
```

---

## Part 3: First deployment

Once server setup and GitHub Secrets are configured, trigger the first deployment:

```bash
git push origin main
```

Monitor the deployment in the GitHub Actions tab. The workflow:

1. **Test job** — runs the full test suite against a Postgres service container
2. **Deploy job** (only if tests pass):
   - Builds a production release with `mix release`
   - SCPs the release to `/home/deploy/residency_schedule_new/` on the server
   - On the server:
     - Copies `.env` from the current release into the new release
     - Runs database migrations via `ResidencySchedule.Release.migrate()`
     - Atomically swaps the old and new release directories
     - Restarts the systemd service
     - Waits 3 seconds and checks `systemctl is-active`
     - If the health check fails, automatically rolls back to the old release

After a successful deploy, verify:
```bash
# On the server:
systemctl status residency_schedule
journalctl -u residency_schedule -n 50
```

Then visit `https://yourdomain.com` — you should see the login page.

---

## Part 4: Ongoing deployments

Every push to `main` automatically deploys. No manual steps required after initial setup.

To deploy manually without a code change:
```bash
git commit --allow-empty -m "trigger deploy"
git push
```

---

## Part 5: Loading data

After the first deploy, the database exists but has no schedule data. Upload a schedule via the UI:

1. Go to `https://yourdomain.com/admin/upload`
2. Select your CSV file
3. Click **Import Schedule**

The academic year is derived automatically from the dates in the CSV file. You can upload multiple academic years — each coexists in the database. To switch between years on the Gantt, Calendar, and Compare pages, use the year picker that appears when more than one schedule is loaded.

---

## Part 6: The public demo deployment

The demo is a **second instance of the same release** on the same droplet: its
own database, its own systemd unit, its own port, its own domain. It runs with
`DEMO_MODE=true`, which removes the login wall and refuses every write.

Its data is the synthetic fixture at `priv/demo/demo_schedule.csv` — invented
names on academic year 2030–2031. Nothing in it derives from real program data.
`Release.seed_demo/0` reloads it on every deploy, so the demo self-heals.

> **Why 2030:** `NameNormalizer` rewrites resident names to canonical forms for
> academic years 2023–2026. A demo fixture inside that range would have its
> invented names silently replaced with real ones. Regenerate the fixture with
> `python3 priv/demo/gen_demo_schedule.py` if you change it, and keep the year
> outside the mapped range.

The demo runs at **residency-schedule.jeffreybaird.com** on port 4002.

> **Port allocation on this droplet.** 4000 is production residency-schedule,
> 4001 is the Sudoku Race container (`docker-compose.yml` in that repo publishes
> `127.0.0.1:4001`), and 4002 is this demo. Check what is already listening
> before assigning a port to anything new: `ss -tlnp | grep 40`.

### 6.0 Run the provisioning script

`priv/demo/provision_demo.sh` performs steps 6.1 through 6.4 in one pass. It is
idempotent, and it never touches production's `.env`, systemd unit, nginx block,
or database — production keeps serving throughout.

```bash
# Copy it to the droplet, read it, then run as root
scp priv/demo/provision_demo.sh deploy@<droplet-ip>:/tmp/
ssh deploy@<droplet-ip>
less /tmp/provision_demo.sh
sudo bash /tmp/provision_demo.sh
```

It generates the demo's database password and `SECRET_KEY_BASE`, writes them to
`/home/deploy/residency_schedule_demo/.env` with mode 600, and **aborts** if the
demo role turns out to be able to reach the production database. It prints the remaining manual steps (DNS, certbot, the
`DEMO_DEPLOY_HOST` secret) when it finishes.

The rest of this section explains what the script does, and is the reference if
you would rather do it by hand.

### 6.1 Scoped database roles

The demo app must not be able to reach the production database. Give each
instance a non-superuser role that owns only its own database, so a mistyped
`DATABASE_URL` fails to connect instead of quietly writing to the wrong place.

```bash
sudo -u postgres psql << 'EOF'
-- One role per instance, neither of them superuser.
CREATE ROLE rs_prod LOGIN PASSWORD 'prod-db-password';
CREATE ROLE rs_demo LOGIN PASSWORD 'demo-db-password';

CREATE DATABASE residency_schedule_demo OWNER rs_demo;
ALTER DATABASE residency_schedule_prod OWNER TO rs_prod;

-- Neither role may touch the other's database.
REVOKE ALL ON DATABASE residency_schedule_prod FROM rs_demo, PUBLIC;
REVOKE ALL ON DATABASE residency_schedule_demo FROM rs_prod, PUBLIC;
EOF
```

Then update the **production** `.env` to stop using the superuser:

```
DATABASE_URL=ecto://rs_prod:prod-db-password@localhost:5432/residency_schedule_prod
```

Verify the isolation holds before trusting it:

```bash
# Should succeed
PGPASSWORD=demo-db-password psql -U rs_demo -h localhost -d residency_schedule_demo -c '\conninfo'

# Should FAIL with "permission denied for database"
PGPASSWORD=demo-db-password psql -U rs_demo -h localhost -d residency_schedule_prod -c '\conninfo'
```

If that second command succeeds, stop and fix the grants — the demo is not isolated.

### 6.2 Demo deployment directory and environment

```bash
mkdir -p /home/deploy/residency_schedule_demo
chown deploy:deploy /home/deploy/residency_schedule_demo

cat > /home/deploy/residency_schedule_demo/.env << 'EOF'
DEMO_MODE=true
PORT=4002
DATABASE_URL=ecto://rs_demo:demo-db-password@localhost:5432/residency_schedule_demo
SECRET_KEY_BASE=<generate a SEPARATE one with: mix phx.gen.secret>
PHX_HOST=residency-schedule.jeffreybaird.com
POOL_SIZE=5
EOF

chmod 600 /home/deploy/residency_schedule_demo/.env
chown deploy:deploy /home/deploy/residency_schedule_demo/.env
```

Notes on these values:

- `SECRET_KEY_BASE` **must differ from production.** Sharing it would let a
  session cookie minted by the public demo be replayed against the real app.
- `ACCESS_PASSWORD` and `RESEND_API_KEY` are **not required** in demo mode —
  resident auth and magic-link email are both off.
- No admin password is configured. Admin access is a **user role**, and the demo
  database has no user accounts at all, so `/admin/*` is unreachable by
  construction. Never run `Release.promote_admin/1` against the demo database.
- `PORT=4002` keeps the demo off production's port 4000.

### 6.3 Demo systemd unit

```bash
cat > /etc/systemd/system/residency_schedule_demo.service << 'EOF'
[Unit]
Description=Residency Schedule Public Demo
After=network.target

[Service]
Type=simple
User=deploy
WorkingDirectory=/home/deploy/residency_schedule_demo
EnvironmentFile=/home/deploy/residency_schedule_demo/.env
ExecStart=/home/deploy/residency_schedule_demo/bin/residency_schedule start
ExecStop=/home/deploy/residency_schedule_demo/bin/residency_schedule stop
Restart=on-failure
RestartSec=5
StandardOutput=journal
StandardError=journal

[Install]
WantedBy=multi-user.target
EOF

systemctl daemon-reload
systemctl enable residency_schedule_demo
```

Grant the deploy user restart rights for the new unit the same way you did for
production in step 1.4.

### 6.4 Nginx vhost and certificate

Add a server block for `residency-schedule.jeffreybaird.com` proxying to `127.0.0.1:4002`,
mirroring the production block from step 1.9, then:

```bash
certbot --nginx -d residency-schedule.jeffreybaird.com
```

### 6.5 GitHub Secret

The deploy workflow builds one release and ships it to both targets. Add:

- `DEMO_DEPLOY_HOST` — the droplet IP or hostname (same box as production)

`DEPLOY_SSH_KEY` is shared between targets. The demo job has
`fail-fast: false`, so a broken demo deploy cannot abort the production one.

### 6.6 Resource headroom

Two BEAM releases plus PostgreSQL on a 2 GB droplet is tight. Check before and
after enabling the demo:

```bash
free -m
systemctl status residency_schedule residency_schedule_demo
```

If memory is short, lower `POOL_SIZE` in the demo `.env` before adding swap.

---

## Maintenance

### Viewing logs

```bash
ssh deploy@your-droplet
journalctl -u residency_schedule -f         # live tail
journalctl -u residency_schedule -n 200     # last 200 lines
```

### Restarting the service manually

```bash
ssh deploy@your-droplet
sudo systemctl restart residency_schedule
```

### Manual rollback

If a bad release makes it past the automated health check:

```bash
ssh deploy@your-droplet
mv /home/deploy/residency_schedule /home/deploy/residency_schedule_bad
mv /home/deploy/residency_schedule_old /home/deploy/residency_schedule
sudo systemctl restart residency_schedule
```

### Updating the .env file

Edit directly on the server, then restart:
```bash
ssh root@your-droplet
nano /home/deploy/residency_schedule/.env
sudo systemctl restart residency_schedule
```

> **Note:** The `.env` file is automatically copied into each new release during deployment (`cp .env residency_schedule_new/.env`), so you only ever need to maintain one copy. Edits take effect on the next service restart.

### Resetting the database (destructive)

```bash
ssh root@your-droplet
sudo -u postgres dropdb residency_schedule_prod
sudo -u postgres createdb residency_schedule_prod
# Then trigger a deploy to re-run migrations, or run them manually:
set -a; source /home/deploy/residency_schedule/.env; set +a
/home/deploy/residency_schedule/bin/residency_schedule eval "ResidencySchedule.Release.migrate()"
```

---

## Troubleshooting

### Service fails to start — check logs

```bash
journalctl -u residency_schedule -n 100 --no-pager
```

Common causes:
- **Missing `.env` file** — recreate it at `/home/deploy/residency_schedule/.env` (see section 1.7)
- **Database not reachable** — check PostgreSQL is running: `systemctl status postgresql`
- **Port 4000 already in use** — check for a zombie process: `lsof -ti:4000`
- **Wrong binary path** — verify `ls /home/deploy/residency_schedule/bin/residency_schedule`

### Deploy fails with "DATABASE_URL not set"

The `set -a; source .env; set +a` in the deploy script exports variables to child processes. If you see this error, the `.env` file is missing. Recreate it (section 1.7) then re-run the deploy.

### Deploy fails with "mv: cannot overwrite"

A stale `residency_schedule_old` directory from a previous failed deploy is blocking the swap. Remove it:
```bash
ssh deploy@your-droplet
rm -rf /home/deploy/residency_schedule_old
```
Then re-run the deploy.

### SSL certificate issues

```bash
certbot renew --dry-run   # test auto-renewal
certbot certificates       # view current certs
```

### Nginx not proxying correctly

```bash
nginx -t                    # test config
systemctl reload nginx      # reload after config changes
```

Verify the `Connection: upgrade` header is present — it is required for Phoenix LiveView WebSocket connections.

---

## Appendix: Endpoint bind address

The endpoint binds `127.0.0.1` by default. Nginx proxies from the same host, so
nothing needs to reach it directly.

It previously bound `0.0.0.0`, which published the app to the internet on its raw
port. That mattered because `config/prod.exs` excludes the hosts `localhost` and
`127.0.0.1` from `force_ssl`, and the `Host` header is supplied by the client — so
a request to `http://<droplet-ip>:4000/` carrying `Host: localhost` skipped the
HTTPS redirect and was served the real application over plaintext.

Before deploying this change, confirm nginx proxies over loopback:

```bash
nginx -T 2>/dev/null | grep proxy_pass
# expect http://localhost:4000 (or 127.0.0.1:4000), not the droplet's public IP
```

If a proxy ever runs on a different host, set `HTTP_IP=0.0.0.0` in that
instance's `.env` and restrict the port at the firewall instead.

Belt and braces — the raw ports should not be open regardless:

```bash
ufw allow 22,80,443/tcp
ufw deny 4000/tcp
ufw deny 4002/tcp
ufw enable
ufw status verbose
```
