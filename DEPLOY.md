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

## Part 6: Observability (Grafana Cloud via Alloy)

The app is instrumented with OpenTelemetry:

- **Traces** — every HTTP request, LiveView mount/`handle_params`/`handle_event`, and Ecto query becomes a span. Spans carry `session.id` (a UUID minted into the signed session cookie on first visit) and `enduser.id` (the logged-in user's id), so a single Tempo search lists everything one person did, in order.
- **Logs** — in prod the app logs JSON to journald with top-level `trace`/`span` fields, powering trace ↔ log correlation in Grafana.

The app exports OTLP to a local **Grafana Alloy** agent, which batches, retries, and forwards to Grafana Cloud. The app never talks to Grafana Cloud directly and holds no Grafana credentials. If Alloy is down or absent, exports fail quietly — the app itself is unaffected.

```
app ──OTLP/gRPC──▶ Alloy (localhost:4317) ──▶ Grafana Cloud Tempo (traces)
app ──JSON──▶ journald ──▶ Alloy ──▶ Grafana Cloud Loki (logs)
```

### 6.1 Create a Grafana Cloud stack (one time)

1. Sign up at https://grafana.com (free tier includes Tempo + Loki).
2. In your stack, note from **Connections → Add new connection → OpenTelemetry (OTLP)**:
   - the OTLP endpoint (e.g. `https://otlp-gateway-prod-us-east-0.grafana.net/otlp`)
   - your stack's instance ID and a generated API token
3. From the **Loki** data source details, note the Loki push URL, username (numeric), and reuse the same token (or generate a Loki-scoped one).

### 6.2 One-time server bootstrap (root, via the DigitalOcean web console)

Everything else in this part runs from GitHub Actions — this is the only
step that needs root on the droplet, and it can be done from the DigitalOcean
**web console** (Droplet → Access → Launch Droplet Console), no SSH client
required. It installs a root-owned provisioning script and a sudoers entry
that lets the `deploy` user run exactly that script and nothing else.

Paste the following as root. The script body must match
`deploy/setup_observability.sh` in the repo (canonical copy) — re-run this
block if that file ever changes:

```bash
install -m 0755 /dev/stdin /usr/local/sbin/setup-observability << 'SCRIPT'
#!/usr/bin/env bash
set -euo pipefail

STAGING_DIR=/home/deploy/observability
ENV_SRC="$STAGING_DIR/alloy.env"
CONFIG_SRC="$STAGING_DIR/config.alloy"

if [[ $EUID -ne 0 ]]; then
  echo "must run as root (via sudo)" >&2
  exit 1
fi

for f in "$ENV_SRC" "$CONFIG_SRC"; do
  if [[ ! -f "$f" ]]; then
    echo "missing $f — run the Provision Observability workflow, not this script directly" >&2
    exit 1
  fi
done

# Install Alloy from the Grafana apt repo (idempotent)
if ! command -v alloy > /dev/null; then
  mkdir -p /etc/apt/keyrings
  if [[ ! -f /etc/apt/keyrings/grafana.gpg ]]; then
    curl -fsSL https://apt.grafana.com/gpg.key | gpg --dearmor -o /etc/apt/keyrings/grafana.gpg
  fi
  echo "deb [signed-by=/etc/apt/keyrings/grafana.gpg] https://apt.grafana.com stable main" \
    > /etc/apt/sources.list.d/grafana.list
  apt-get update -qq
  DEBIAN_FRONTEND=noninteractive apt-get install -y -qq alloy
fi

# Move staged credentials + config into place, root-owned. The staged
# credential file is removed so secrets never linger in the deploy home.
install -o root -g root -m 600 "$ENV_SRC" /etc/default/alloy
install -o root -g root -m 644 "$CONFIG_SRC" /etc/alloy/config.alloy
rm -f "$ENV_SRC"

systemctl enable alloy
systemctl restart alloy

sleep 2
if ! systemctl is-active --quiet alloy; then
  echo "alloy failed to start:" >&2
  journalctl -u alloy -n 20 --no-pager >&2
  exit 1
fi

echo "Alloy provisioned and running."
SCRIPT

cat > /etc/sudoers.d/deploy-observability << 'EOF'
deploy ALL=(ALL) NOPASSWD: /usr/local/sbin/setup-observability
EOF
chmod 440 /etc/sudoers.d/deploy-observability
visudo -c
```

> **Why root-owned?** The workflow (holding only the `deploy` SSH key) stages
> *data* — credentials and the Alloy config — but the *code* that runs as root
> is fixed at bootstrap time. A compromised deploy key can re-run provisioning
> but cannot change what provisioning does.

### 6.3 Add the Grafana credentials to GitHub Secrets

In the repo: **Settings → Secrets and variables → Actions → New repository
secret**. Add the five values from step 6.1:

| Secret | Example |
|---|---|
| `GRAFANA_CLOUD_OTLP_ENDPOINT` | `https://otlp-gateway-prod-us-east-0.grafana.net/otlp` |
| `GRAFANA_CLOUD_INSTANCE_ID` | `123456` |
| `GRAFANA_CLOUD_API_TOKEN` | `glc_...` |
| `GRAFANA_CLOUD_LOKI_URL` | `https://logs-prod-006.grafana.net/loki/api/v1/push` |
| `GRAFANA_CLOUD_LOKI_USER` | `654321` |

(`DEPLOY_HOST` and `DEPLOY_SSH_KEY` already exist from Part 2.)

### 6.4 Run the Provision Observability workflow

**Actions → Provision Observability → Run workflow.** It stages
`deploy/alloy/config.alloy` and a credentials file onto the droplet, then
runs the root-owned script from 6.2, which installs Alloy (first run only),
moves the files into `/etc/`, and restarts the service.

Re-run the workflow whenever:

- a Grafana credential is rotated (update the GitHub Secret first), or
- `deploy/alloy/config.alloy` changes.

No app-side changes are needed: in prod the app already exports OTLP to
`http://localhost:4317` by default (`config/runtime.exs`), which is where
Alloy listens. `OTEL_EXPORTER_OTLP_ENDPOINT` in the app's `.env` is only
needed to override that default.

### 6.5 Verify

1. Load a few pages of the app in a browser.
2. In Grafana Cloud → **Explore** → the Tempo data source, run a TraceQL search: `{ resource.service.name = "residency_schedule" }`. You should see traces with nested Phoenix → LiveView → Ecto spans.
3. Follow one person's journey: `{ span.session.id = "<uuid>" }` or `{ span.enduser.id = "<user id>" }`.
4. In **Explore** → the Loki data source: `{unit="residency_schedule.service"} | json`. Log lines carry `trace`/`span` fields.
5. In the Tempo data source settings, enable **Trace to logs** (Loki, match on trace ID) so a span click jumps to its log lines, and enable **derived fields** on Loki (regex the `trace_id` from the JSON) for the reverse jump.

### 6.6 Following a user through the app

- **One user's full history:** Tempo search `{ span.enduser.id = "42" }` — ordered traces are their journey; each `handle_event#<name>` span is one click.
- **One anonymous visit (incl. pre-login):** `{ span.session.id = "<uuid>" }` — the session id is minted before login, so the login flow itself is included; after login the same session also carries `enduser.id`.
- **Their logs:** Loki `{unit="residency_schedule.service"} | json | metadata_user_id="42"`.

> **Privacy:** spans and logs carry only numeric user ids — never names or emails.

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
