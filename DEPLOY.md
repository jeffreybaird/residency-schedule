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

Runtime settings are managed in GitHub's `prod` and `demo` environments. Each
deployment generates protected, versioned configuration outside the release
directory and recovers the previous configuration with the previous code on
failure. The promotion script requires an existing installed release; the host
setup examples below do not constitute a tested empty-host bootstrap procedure.

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
elixir --version   # CI: Elixir 1.19.5 / OTP 28.5.0.7; OTP 29 requires 29.1.1+
psql --version     # should be 14+
nginx -v
```

The deployment tools also require a maintained Ruby 3.3 installation with its
bundled RubyGems archive libraries, plus `flock` and checksum/tar utilities.
Verify those on the target host; the OS default Ruby package may differ. Minitest
is needed only for development and CI.

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

> **Security note:** For a managed database, use its connection string as the target GitHub environment's `DATABASE_URL` secret and set the `DB_SSL` variable to `true`. Use a restricted database role rather than a superuser.

### 1.6 Create the deployment directory

```bash
mkdir -p /home/deploy/residency_schedule
chown deploy:deploy /home/deploy/residency_schedule
```

### 1.7 Establish GitHub as the configuration source

Configure the target environment as described in Part 2. For an existing
installation, privately import its current values, including `SECRET_KEY_BASE`
and its effective `RELEASE_COOKIE`. Preserve these values during the transition;
cookie rotation is a separate operation. New installation signing secrets can be
generated with `mix phx.gen.secret`.

The workflow validates a complete configuration before promotion. The host
creates versioned mode-600 files beneath a mode-700
`/home/deploy/residency_schedule.config` directory. A release's `.env` is then a
managed link to its configuration version, preserving the existing systemd
`EnvironmentFile` path. The JSON copy supplies release commands directly, without
executing configuration as shell code. Both copies contain secrets and stay
outside retained code archives.

The existing regular `.env` remains available for recovery during the first
transition. Later deployments use GitHub values, including explicit defaults for
optional settings; they do not merge hand-edited server state. See the
[runtime configuration runbook](.docs/phase0-release-artifacts.md) for validation,
cookie continuity, private recovery copies and retention requirements.

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

## Part 2: GitHub configuration setup

Under **Settings → Secrets and variables → Actions**, configure transport access:

| Secret | Value | Notes |
|---|---|---|
| `DEPLOY_HOST` | Droplet IP or domain | e.g. `143.198.12.34` |
| `DEMO_DEPLOY_HOST` | Demo droplet IP or domain | May share a host with production, but uses a separate installation and database |
| `DEPLOY_SSH_KEY` | Full private key PEM | Generate with `ssh-keygen -t ed25519 -C "deploy@github-actions" -f ~/.ssh/residency_deploy -N ""`, use the private key file |

Create **Settings → Environments → `prod` and `demo`**, with the desired branch
restrictions and deployment approvals. Each deployment job selects its target
environment. Configure runtime values there:

| Environment secret | Required for | Notes |
|---|---|---|
| `DATABASE_URL` | Both targets | Distinct database and restricted role for each target |
| `SECRET_KEY_BASE` | Both targets | Preserve the installation's signing secret; demo and production must differ |
| `RELEASE_COOKIE` | Both targets | Preserve the effective existing Erlang distribution cookie |
| `ACCESS_PASSWORD` | Production | App login password |
| `RESEND_API_KEY` | Production | Transactional email credential |
| `ANTHROPIC_API_KEY` | Production with chat enabled | Provider credential |
| `OTEL_HUB_TOKEN` | Production with telemetry enabled | Source-scoped ingest token |

Environment variables hold public configuration:

| Variable | Value | Notes |
|---|---|---|
| `CONFIG_ENVIRONMENT` | `prod` or `demo` | Required; must match the job's target |
| `EXPECTED_DATABASE_NAME` | e.g. `residency_schedule_prod` | Required; must match the database in `DATABASE_URL` |
| `PHX_HOST` | Target public hostname | Required |
| `POOL_SIZE` | Positive integer | Optional connection-pool override |
| `DB_SSL` | `true` or `false` | Enable for a managed database using SSL |
| `HTTP_IP` | IPv4 address | Defaults to loopback for the local Nginx proxy |
| `ROSTER_PATH` | Existing private roster-file path | Optional; the workflow does not provision that file |
| `CHAT_ENABLED` | `true` or `false` | Production only; defaults off |
| `OTEL_ENABLED` | `true` or `false` | Production only; defaults off |
| `OTEL_EXPORTER_OTLP_ENDPOINT` | `https://elixir-as-inf.diviningdad.com` | HTTPS base URL; the exporter appends each signal's `/v1/` path |
| `OTEL_RESOURCE_ATTRIBUTES` | Optional telemetry labels | Production only; never include resident data or credentials |

The workflow sets target-specific port and demo mode and keeps Erlang node
identities distinct. See the runbook for supported overrides and defaults.
Removing an optional setting restores its declared default; disabled integrations
do not retain their old provider credentials in the newly generated configuration.

`DATABASE_URL` must select the database in its path, without a query string or
fragment. Use the separate `DB_SSL` variable for TLS; query parameters that could
override the expected database are rejected.

Populate both environments explicitly. GitHub can fall back to repository-level
secrets when an environment value is absent; production database credentials must
not become demo defaults. Target and expected-database checks catch common
misconfiguration but do not prove database grants are isolated. Verify the demo
role cannot access production before permitting its automatic seed operation.

Before transition, privately inspect the systemd service and its drop-ins for
other `Environment` assignments, `EnvironmentFile` entries or wrapper scripts
that supply these settings. Resolve competing sources so the managed file governs
the service as well as release commands. Do not paste that inspection into logs
or a PR: existing unit configuration may contain credentials.

Runtime secrets are injected only into the deployment's rendering step. The
private payload travels separately from the shared code artifact and is cleaned
up after transfer/promotion; generated server configuration remains private for
restart and recovery. Build jobs and published artifacts receive no runtime
credentials. GitHub stores the managed source; the server stores the generated
runtime copies needed to run the application.

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

## Part 3: First managed deployment of an existing installation

After environment configuration, host prerequisites and staging rehearsals are
verified, an authorized push or merge to `main` triggers deployment:

```bash
git push origin main
```

Monitor the deployment in the GitHub Actions tab. The workflow:

1. **Test job** — runs the application and deployment-script tests.
2. **Build job** — creates one release archive identified by commit and SHA256,
   without server runtime credentials or a distribution cookie.
3. **Deploy jobs** — download the same archive for production and demo. Each
   destination has noncanceling workflow concurrency and a stable host lock.
   A separate private payload carries the validated GitHub configuration.
   The host verifies the artifact, retains the previous code archive, creates
   a protected configuration version, runs migrations before the swap/restart, and
   checks HTTP readiness. Swap, restart or startup-check failure attempts to
   restore the previous application and its configuration, and verifies recovery.

See [release artifact and locking operations](.docs/phase0-release-artifacts.md)
for retained paths, cookie handling, failure limits and pending recovery gates.
This upgrade path requires an existing installation with recoverable configuration
and a matching distribution cookie. It accepts the legacy regular `.env` for the
initial transition and managed configuration links thereafter. Initial provisioning
is a separate operation.

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
names on the current academic year. Nothing in it derives from real program data.
`Release.seed_demo/0` reloads it on every deploy, so the demo self-heals.

> **Why the names survive:** `NameNormalizer` rewrites resident names to
> canonical forms for academic years 2023–2026, and the fixture deliberately
> covers the current year so it renders on the calendar rather than sitting in
> an empty future. `normalize/3` therefore skips canonicalization entirely when
> `DEMO_MODE=true`. If a demo ever imports with `DEMO_MODE` unset, its invented
> names will be silently replaced with the real residents' names. Regenerate the
> fixture with `python3 priv/demo/gen_demo_schedule.py`.

The demo runs at **residency-schedule.jeffreybaird.com** on port 4002.

> **Port allocation on this droplet.** 4000 is production residency-schedule,
> 4001 is the Sudoku Race container (`docker-compose.yml` in that repo publishes
> `127.0.0.1:4001`), and 4002 is this demo. Check what is already listening
> before assigning a port to anything new: `ss -tlnp | grep 40`.

### 6.0 Run the provisioning script

This is the legacy one-time bootstrap helper. It creates a regular `.env`; it is
not the configuration management interface for subsequent deployments. Before the
first managed promotion, privately import its generated values into the GitHub
`demo` environment and satisfy the existing-release and cookie prerequisites.
Fresh-host bootstrap must be rehearsed separately from this upgrade workflow.

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

The remaining sections describe the required isolation and service layout.
Ongoing runtime configuration is managed through the GitHub environment.

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

Set the **`prod` GitHub environment's `DATABASE_URL` secret** to the restricted
role and deploy the change:

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
```

In the GitHub `demo` environment, set `CONFIG_ENVIRONMENT=demo`,
`EXPECTED_DATABASE_NAME=residency_schedule_demo`, the demo `PHX_HOST` and a
suitable `POOL_SIZE`. Store its restricted `DATABASE_URL`, distinct
`SECRET_KEY_BASE` and existing `RELEASE_COOKIE` as environment secrets. The
workflow supplies `DEMO_MODE=true` and port 4002 and generates the private runtime
files during promotion.

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

If memory is short, lower `POOL_SIZE` in the GitHub `demo` environment and deploy
the change before adding swap.

---

## Maintenance

### OTel Hub telemetry

Register a source named `residency-schedule` in OTel Hub and store its ingest token
in the `prod` environment's `OTEL_HUB_TOKEN` secret. Set the endpoint variable above and
`OTEL_ENABLED=true`, then deploy through the normal `main` workflow. The production
job generates protected runtime configuration from these settings; the demo target receives
none of these settings. Missing or invalid required settings fail startup when
telemetry is enabled. Development and test environments leave export disabled.

The integration reports service identity `residency-schedule`. It exports bounded
HTTP completion summaries and spans, plus aggregate request, database timing, and
VM metrics. Request method and response status are the only request attributes.
Spans summarize completed HTTP requests under the fixed name `HTTP request`;
they do not provide per-route breakdowns or a distributed call tree of database
queries and outbound HTTP calls.
It excludes URLs, query strings, headers, resident names, SQL text and parameters,
chat content, and arbitrary application log messages. Existing local application
logging remains available through the journal.

Exporter environment settings are administrator-controlled configuration. Do not
put credentials or personal data in `OTEL_RESOURCE_ATTRIBUTES`: the metric
reporter can include these additional resource attributes in exported data.

After deployment, make an ordinary request and verify that the source's logs,
metrics, and traces arrive in OTel Hub. A successful application health check alone
does not prove export delivery. Export is asynchronous, bounded, and best effort;
an unavailable collector must not prevent requests from being served.

To disable export, set `OTEL_ENABLED=false` or remove the variable and deploy
again. The default is off, and new configuration omits disabled integration
credentials. Rotate the source token by
updating the secret and deploying; do not paste tokens into command output or
commit them to the repository.

### Viewing logs

```bash
ssh deploy@your-droplet
journalctl -u residency_schedule -f         # live tail
journalctl -u residency_schedule -n 200     # last 200 lines
```

### Restarting the service manually

```bash
ssh deploy@your-droplet
flock -x --close /home/deploy/residency_schedule.deploy.lock bash
sudo systemctl restart residency_schedule
```

### Manual rollback

The deployment now retains checksummed code archives rather than a disposable
`_old` directory. Do not use an unguarded directory swap: every recovery operation
must hold `/home/deploy/residency_schedule.deploy.lock`. See the
[artifact runbook](.docs/phase0-release-artifacts.md). A checksum-verified,
schema-compatible manual rollback command and rehearsal remain Phase 0 Step 6
work; automatic startup recovery does not establish that capability.

### Updating runtime configuration

Change the setting in the GitHub `prod` or `demo` environment, then deploy through
the reviewed workflow. A restart alone uses the currently installed configuration
version; it does not fetch new GitHub settings.

The deployment validates required and conditional values, writes a new protected
version and links the candidate release to it. Recovery restores the previous
release's configuration. Avoid editing generated files or their `.env` link:
GitHub remains the source of truth and the next deployment regenerates the
configuration. Missing required values fail validation rather than falling back
to stale server values.

Private configuration versions and legacy recovery copies contain credentials.
Preserve the designated recovery configuration, restrict its access and agree a
retention window before pruning. These files must never enter build artifacts or
ordinary diagnostic logs. Distribution-cookie rotation requires a separate
reviewed procedure; normal deployment verifies continuity.

### Resetting the database (destructive)

```bash
ssh root@your-droplet
test -f /home/deploy/residency_schedule.deploy.lock || exit 1
flock -x --close /home/deploy/residency_schedule.deploy.lock bash
sudo -u postgres dropdb residency_schedule_prod
sudo -u postgres createdb residency_schedule_prod
# Exit the maintenance lock before triggering the reviewed deployment workflow
# to re-run migrations with the managed runtime configuration.
```

---

## Troubleshooting

### Service fails to start — check logs

```bash
journalctl -u residency_schedule -n 100 --no-pager
```

Common causes:
- **Missing runtime configuration** — inspect the managed link and protected configuration version without printing contents; recover the matching release/configuration or deploy valid GitHub settings under the shared lock
- **Database not reachable** — check PostgreSQL is running: `systemctl status postgresql`
- **Port 4000 already in use** — check for a zombie process: `lsof -ti:4000`
- **Wrong binary path** — verify `ls /home/deploy/residency_schedule/bin/residency_schedule`

### Deploy fails with "DATABASE_URL not set"

Check that `DATABASE_URL` is present in the selected GitHub environment, that
`CONFIG_ENVIRONMENT` matches the target and that `EXPECTED_DATABASE_NAME` matches
the URL's database. The renderer and host validate these before promotion. Release
commands receive the generated environment directly; they do not source the old
server `.env`. Correct the GitHub settings and retry the reviewed deployment.

### Deploy fails with "mv: cannot overwrite"

Do not delete a previous release or recovery directory to clear this error.
The new deployment uses run-specific private work paths and a stable host lock.
Inspect a failed run under that lock, identify the current and recoverable code
artifacts, and follow the [artifact runbook](.docs/phase0-release-artifacts.md).

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
target's GitHub environment and restrict the port at the firewall instead.

Belt and braces — the raw ports should not be open regardless:

```bash
ufw allow 22,80,443/tcp
ufw deny 4000/tcp
ufw deny 4002/tcp
ufw enable
ufw status verbose
```

---

## Appendix: Running two instances of the same release

Production and the demo are the same release, so they default to the same Erlang
node name (`residency_schedule@<hostname>`). Only one can register it with EPMD —
whichever starts second exits immediately with:

```
Protocol 'inet_tcp': the name residency_schedule@<host> seems to be in use by
another Erlang node
```

systemd then restarts it on a loop, so the symptom is a 502 from nginx for the
instance that lost the race, not an obvious crash.

The generated demo configuration therefore needs a distinct node name:

```
RELEASE_NODE=residency_schedule_demo@127.0.0.1
RELEASE_DISTRIBUTION=name
```

Anything else sharing this droplet with another copy of the release needs the
same treatment. To check which node names are registered:

```bash
epmd -names
```
