#!/usr/bin/env bash
#
# Provisions the public demo instance alongside production on the same droplet.
#
# Run as root ON THE DROPLET:
#   sudo bash provision_demo.sh
#
# What it does NOT do, deliberately:
#   - It never touches the production .env, systemd unit, nginx block, or
#     database. Production keeps running throughout.
#   - It does not migrate production off the postgres superuser. That is a
#     separate manual step, printed at the end.
#
# Safe to re-run: every step is idempotent and skips work already done.

set -euo pipefail

DOMAIN="residency-schedule.jeffreybaird.com"
PORT=4002
INSTALL_DIR="/home/deploy/residency_schedule_demo"
SERVICE="residency_schedule_demo"
DB_NAME="residency_schedule_demo"
DB_ROLE="rs_demo"
PROD_DB="residency_schedule_prod"
ENV_FILE="$INSTALL_DIR/.env"

log()  { printf '\n\033[1;34m==> %s\033[0m\n' "$1"; }
warn() { printf '\033[1;33m    %s\033[0m\n' "$1"; }
die()  { printf '\n\033[1;31mFAILED: %s\033[0m\n' "$1" >&2; exit 1; }

[ "$(id -u)" -eq 0 ] || die "run this as root (sudo bash provision_demo.sh)"
id deploy >/dev/null 2>&1 || die "the 'deploy' user does not exist — run Part 1 of DEPLOY.md first"

# ── 1. Database role and database ────────────────────────────────────────────
# A non-superuser role that owns only the demo database. A mistyped
# DATABASE_URL then fails to connect instead of quietly writing to production.

log "Creating the demo database role and database"

if [ -f "$ENV_FILE" ]; then
  warn "$ENV_FILE exists — reusing its DB password so the role stays in sync"
  DB_PASSWORD="$(grep -oP '(?<=ecto://'"$DB_ROLE"':)[^@]+' "$ENV_FILE")"
  [ -n "$DB_PASSWORD" ] || die "could not read the existing DB password from $ENV_FILE"
else
  DB_PASSWORD="$(openssl rand -hex 24)"
fi

sudo -u postgres psql -v ON_ERROR_STOP=1 << EOF
DO \$\$
BEGIN
  IF NOT EXISTS (SELECT FROM pg_roles WHERE rolname = '$DB_ROLE') THEN
    CREATE ROLE $DB_ROLE LOGIN PASSWORD '$DB_PASSWORD';
  ELSE
    ALTER ROLE $DB_ROLE LOGIN PASSWORD '$DB_PASSWORD';
  END IF;
END
\$\$;

-- Explicitly not a superuser, and not allowed to create more databases.
ALTER ROLE $DB_ROLE NOSUPERUSER NOCREATEDB NOCREATEROLE;
EOF

if sudo -u postgres psql -lqt | cut -d'|' -f1 | grep -qw "$DB_NAME"; then
  warn "database $DB_NAME already exists — leaving it in place"
else
  sudo -u postgres createdb -O "$DB_ROLE" "$DB_NAME"
fi

# Keep the demo role out of production, and the public role out of both.
sudo -u postgres psql -v ON_ERROR_STOP=1 << EOF
REVOKE ALL ON DATABASE $PROD_DB FROM $DB_ROLE;
REVOKE ALL ON DATABASE $PROD_DB FROM PUBLIC;
REVOKE ALL ON DATABASE $DB_NAME FROM PUBLIC;
EOF

# ── 2. Prove the isolation actually holds ────────────────────────────────────
# This is the whole reason for the separate role. If the demo can reach the
# production database, stop before anything else is set up.

log "Verifying the demo role cannot reach the production database"

PGPASSWORD="$DB_PASSWORD" psql -U "$DB_ROLE" -h localhost -d "$DB_NAME" -c '\conninfo' >/dev/null \
  || die "demo role cannot connect to its OWN database — check pg_hba.conf allows md5/scram on localhost"

if PGPASSWORD="$DB_PASSWORD" psql -U "$DB_ROLE" -h localhost -d "$PROD_DB" -c '\conninfo' >/dev/null 2>&1; then
  die "demo role CAN reach $PROD_DB — isolation is broken, do not continue"
fi

warn "confirmed: $DB_ROLE reaches $DB_NAME only"

# ── 3. Deployment directory and environment ──────────────────────────────────
# The deploy workflow copies this .env into each new release, so it must exist
# before the first demo deploy runs.

log "Creating $INSTALL_DIR and its environment file"

mkdir -p "$INSTALL_DIR"
chown deploy:deploy "$INSTALL_DIR"

if [ -f "$ENV_FILE" ]; then
  warn "$ENV_FILE already exists — leaving it untouched"
else
  # SECRET_KEY_BASE must differ from production: a shared value would let a
  # session cookie minted by the public demo be replayed against the real app.
  # No admin password is set — admin is a user role, and the demo database has
  # no user accounts, so /admin/* is unreachable by construction.
  # RELEASE_NODE must differ from production's. Both instances are the same
  # release, so without this they claim the same Erlang node name and whichever
  # starts second dies with "name ... seems to be in use by another Erlang node".
  cat > "$ENV_FILE" << EOF
DEMO_MODE=true
PORT=$PORT
RELEASE_NODE=$SERVICE@127.0.0.1
RELEASE_DISTRIBUTION=name
DATABASE_URL=ecto://$DB_ROLE:$DB_PASSWORD@localhost:5432/$DB_NAME
SECRET_KEY_BASE=$(openssl rand -base64 64 | tr -d '\n')
PHX_HOST=$DOMAIN
POOL_SIZE=5
EOF
  chmod 600 "$ENV_FILE"
  chown deploy:deploy "$ENV_FILE"
fi

# ── 4. systemd unit ──────────────────────────────────────────────────────────

log "Installing the $SERVICE systemd unit"

cat > "/etc/systemd/system/$SERVICE.service" << EOF
[Unit]
Description=Residency Schedule Public Demo
After=network.target postgresql.service

[Service]
Type=simple
User=deploy
WorkingDirectory=$INSTALL_DIR
EnvironmentFile=$ENV_FILE
ExecStart=$INSTALL_DIR/bin/residency_schedule start
ExecStop=$INSTALL_DIR/bin/residency_schedule stop
Restart=on-failure
RestartSec=5
StandardOutput=journal
StandardError=journal

[Install]
WantedBy=multi-user.target
EOF

systemctl daemon-reload
systemctl enable "$SERVICE"

# Not started here: the release does not exist until the first deploy lands.

# ── 5. Let the deploy user restart the demo unit ─────────────────────────────
# Kept in its own sudoers file so the production one is never rewritten.

log "Granting the deploy user restart rights for $SERVICE"

cat > /etc/sudoers.d/deploy_demo << EOF
deploy ALL=(ALL) NOPASSWD: /usr/bin/systemctl restart $SERVICE, /usr/bin/systemctl start $SERVICE, /usr/bin/systemctl stop $SERVICE
EOF
chmod 440 /etc/sudoers.d/deploy_demo

# Validate only our own file. A pre-existing problem elsewhere in sudoers.d is
# worth reporting but is not this script's to fail on.
visudo -cf /etc/sudoers.d/deploy_demo >/dev/null \
  || die "sudoers validation failed — inspect /etc/sudoers.d/deploy_demo"

if ! visudo -c >/dev/null 2>&1; then
  warn "NOTE: visudo -c reports a problem with another file in /etc/sudoers.d."
  warn "Usually this is a mode other than 0440. sudo itself only ignores files"
  warn "that are group- or world-WRITABLE, so a 0644 file still works at runtime"
  warn "while failing this stricter lint — deploys are probably unaffected."
  warn "Tighten it anyway; a readable sudoers file is needless exposure:"
  warn "    visudo -c ; stat -c '%a %n' /etc/sudoers.d/* ; chmod 440 /etc/sudoers.d/<file>"
fi

# ── 6. Nginx vhost ───────────────────────────────────────────────────────────
# HTTP only at this stage. Certbot rewrites this block to add TLS; writing an
# ssl block up front would reference certificates that do not exist yet and
# nginx -t would fail.

log "Installing the nginx vhost for $DOMAIN"

if [ -f "/etc/nginx/sites-available/$SERVICE" ]; then
  warn "vhost already exists — leaving it untouched (certbot may have edited it)"
else
  cat > "/etc/nginx/sites-available/$SERVICE" << EOF
server {
    listen 80;
    server_name $DOMAIN;

    location / {
        proxy_pass         http://localhost:$PORT;
        proxy_http_version 1.1;
        proxy_set_header   Upgrade \$http_upgrade;
        proxy_set_header   Connection "upgrade";
        proxy_set_header   Host \$host;
        proxy_set_header   X-Real-IP \$remote_addr;
        proxy_set_header   X-Forwarded-For \$proxy_add_x_forwarded_for;
        proxy_set_header   X-Forwarded-Proto \$scheme;
    }
}
EOF
  ln -sf "/etc/nginx/sites-available/$SERVICE" /etc/nginx/sites-enabled/
fi

nginx -t || die "nginx config invalid — production vhost may be affected, fix before reloading"
systemctl reload nginx

# ── 7. Report ────────────────────────────────────────────────────────────────

log "Done. Remaining manual steps:"

cat << EOF

  1. DNS — point an A record at this droplet, then wait for it to resolve:

       $DOMAIN  ->  $(curl -s --max-time 5 ifconfig.me || echo '<this droplet IP>')

  2. TLS — only after DNS resolves:

       sudo certbot --nginx -d $DOMAIN

  3. GitHub secret — add DEMO_DEPLOY_HOST with this droplet's IP or hostname:

       gh secret set DEMO_DEPLOY_HOST

  4. Deploy — merge the demo PR to main. The demo job builds, migrates,
     seeds the synthetic fixture, and starts $SERVICE.

  5. Verify — the demo should load with no login and show the current academic year with invented names:

       curl -sI https://$DOMAIN | head -1
       systemctl status $SERVICE

  Recommended, NOT done by this script because it touches production:

     Production still connects as the postgres superuser, which is what made a
     mistyped demo DATABASE_URL dangerous in the first place. To fix, create a
     scoped role and update the production .env, then restart:

       sudo -u postgres psql -c "CREATE ROLE rs_prod LOGIN PASSWORD '<new-password>';"
       sudo -u postgres psql -c "ALTER DATABASE $PROD_DB OWNER TO rs_prod;"
       sudo -u postgres psql -c "REVOKE ALL ON DATABASE $DB_NAME FROM rs_prod;"
       # then edit DATABASE_URL in /home/deploy/residency_schedule/.env
       sudo systemctl restart residency_schedule

EOF
