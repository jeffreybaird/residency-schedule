# Residency Schedule

An Elixir / Phoenix LiveView application that imports OB/GYN residency schedules
from CSV uploads and turns them into interactive views: a Gantt-style rotation
grid, monthly calendars, side-by-side resident comparisons, and per-resident
iCal feeds. It also includes an experimental schedule **builder** that generates
draft rotation assignments under coverage and duty-hour constraints.

The full architectural spec lives in [`residency_schedule_plan_v2.md`](residency_schedule_plan_v2.md).

---

## Tech stack

| Concern | Choice |
|---|---|
| Language / runtime | Elixir `~> 1.15` on Erlang/OTP 26–27 (CI runs 1.18 / OTP 27) |
| Web framework | Phoenix 1.8 + Phoenix LiveView 1.1 |
| Database | PostgreSQL 14+ via Ecto 3.13 |
| HTTP server | Bandit |
| Assets | Tailwind + esbuild (downloaded by Mix — no Node required) |
| Email | Swoosh |
| Auth | Session-based, with bcrypt passwords and magic-link email tokens |
| Deploy | GitHub Actions → Digital Ocean droplet (systemd + Nginx + Let's Encrypt) |

---

## Codebase organization

The project follows the standard Phoenix split between a web-agnostic domain
layer (`lib/residency_schedule`) and the Phoenix web layer
(`lib/residency_schedule_web`). **All database access goes through context
modules** — LiveViews and controllers never call `Repo` directly.

```
lib/
├── residency_schedule/                # Domain logic (no web dependencies)
│   ├── schedules/                     # Schedule context + schema (one per academic year)
│   ├── residents/                     # Resident + ScheduleResident contexts/schemas
│   ├── rotations/                     # Rotation context + schema (a resident's assignment for a date slot)
│   ├── shift_overrides/               # Manual edits layered on top of imported rotations
│   ├── accounts/                      # Users, passwords, and magic-link tokens
│   ├── oauth/                         # OAuth 2.1 authorization server backing the MCP endpoint
│   ├── change_requests/               # Pending schedule-change requests (approval creates a ShiftOverride)
│   ├── assistant/                     # Name/rotation resolvers, duty-hour check, question-answering facade
│   ├── importer/                      # CSV → database pipeline
│   │   ├── csv_parser.ex              #   parse raw CSV into dated slots + resident rows
│   │   ├── csv.ex                     #   low-level CSV decoding
│   │   ├── name_normalizer.ex         #   canonicalize resident names
│   │   ├── schedule_importer.ex       #   persist parsed data into a Schedule
│   │   ├── schedule_merger.ex         #   merge multiple source files into one year
│   │   └── summer_float_splitter.ex   #   split/merge the shared "summer float" rotation
│   ├── schedule_builder/              # Draft schedule generation (the /admin/build tool)
│   │   ├── generator.ex               #   core assignment generator
│   │   ├── coverage.ex                #   coverage requirements per rotation/date
│   │   ├── duty_hours.ex              #   ACGME duty-hour constraints
│   │   ├── resident_roster.ex         #   who is available to be assigned
│   │   ├── slot_calendar.ex           #   the grid of date slots to fill
│   │   ├── template_loader.ex         #   load rotation templates
│   │   └── builder_state.ex           #   in-progress builder state
│   ├── ical.ex                        # iCal feed builder for calendar subscriptions
│   ├── mailer.ex                      # Swoosh emails (magic link, approval notices)
│   ├── release.ex                     # Migration entrypoint for compiled prod releases
│   ├── repo.ex                        # Ecto repo
│   └── application.ex                 # OTP supervision tree
│
├── residency_schedule_web/            # Phoenix web layer
│   ├── controllers/
│   │   ├── auth_controller.ex         #   login, magic-link verify/confirm, set-password
│   │   ├── ical_controller.ex         #   serves .ics calendar feeds
│   │   ├── oauth_controller.ex        #   OAuth discovery, registration, consent page, token endpoint
│   │   ├── mcp_controller.ex          #   "/mcp" — Streamable HTTP MCP transport
│   │   └── page_controller.ex
│   ├── mcp/                           # JSON-RPC handling, MCP server core, tool catalogue
│   ├── live/                          # LiveView pages
│   │   ├── schedule_live/             #   "/" — Gantt rotation grid
│   │   ├── resident_live/             #   "/residents/:id" — one resident's year
│   │   ├── calendar_live/             #   "/calendar" — monthly calendar
│   │   ├── compare_live/              #   "/compare" — side-by-side residents
│   │   ├── upload_live/               #   "/admin/upload" — CSV import
│   │   ├── builder_live/              #   "/admin/build" — schedule generator
│   │   ├── edit_live/                 #   "/admin/edit" — manual rotation edits
│   │   └── admin_live/                #   "/admin" — user approvals
│   ├── plugs/                         # require_auth / require_admin / require_bearer_token
│   ├── components/                    # Layouts + core components
│   └── router.ex
│
└── mix/tasks/                         # One-off CSV maintenance Mix tasks

test/
├── fixtures/                          # Sample CSV files used by tests
├── residency_schedule/                # Unit + integration tests for the domain
├── residency_schedule_web/            # Controller + LiveView tests
└── support/                           # DataCase / ConnCase helpers

config/                                # config.exs, dev.exs, test.exs, prod.exs, runtime.exs
priv/repo/migrations/                  # Ecto migrations
.github/workflows/                     # ci.yml (PR checks) + deploy.yml (push to main)
```

### Core domain model

- **Schedule** — one academic year (e.g. `2026–2027`). The year is *derived from
  the dates in the imported CSV*, never hardcoded. Multiple years coexist.
- **Resident** — a person; linked to a Schedule through **ScheduleResident**
  (their PGY level / position, like `R4-1`, for that year).
- **Rotation** — a single resident's assignment for a single dated slot.
- **ShiftOverride** — a manual edit layered on top of the imported rotations so
  corrections survive re-imports.

### Routes at a glance

| Path | Access | Purpose |
|---|---|---|
| `/login`, `/auth/verify`, `/auth/set-password` | public | Password + magic-link login (all roles) |
| `/` | authenticated | Gantt rotation grid |
| `/residents/:id` | authenticated | Per-resident year view |
| `/calendar`, `/compare` | authenticated | Monthly calendar, comparison |
| `/residents/:id/calendar.ics`, `/feed/:token/calendar.ics` | authenticated / tokened | iCal subscription feeds |
| `/admin`, `/admin/upload`, `/admin/build`, `/admin/edit` | admin role | Approvals, roles, CSV import, builder, editor |

Accounts carry a **role**: `user` (default — any email, needs admin approval;
can follow a resident's schedule), `resident` (URMC email, auto-approved), or
`admin` (granted from the admin page, or bootstrapped with
`bin/residency_schedule eval 'ResidencySchedule.Release.promote_admin("email")'`).

> **Convention:** every public function carries a doctest, and every branch is
> covered by an ExUnit test. See [`CLAUDE.md`](CLAUDE.md) for the full code-style
> and testing rules this project enforces.

---

## Assistant API (MCP over OAuth)

The app exposes a [Model Context Protocol](https://modelcontextprotocol.io)
server so an assistant such as Claude can answer schedule questions and file
change requests on a user's behalf. It is a Streamable HTTP endpoint at
`POST /mcp`, protected by OAuth 2.1 (authorization code + PKCE, dynamic client
registration, refresh-token rotation). The app is its own authorization server;
users log in with their normal magic-link or password login and approve access
on a consent page.

**Connecting a client.** Point the client at `https://<PHX_HOST>/mcp`. Discovery
is automatic: a 401 from `/mcp` carries a `WWW-Authenticate` header pointing at
`/.well-known/oauth-protected-resource`, which names the authorization server
(`/.well-known/oauth-authorization-server`), which lists the registration,
authorize, and token endpoints. Redirect URIs must be `https` or `localhost`.

**Tools.**

| Tool | What it answers | Writes? |
|---|---|---|
| `whoami` | Caller's email, role, home resident, today's date | no |
| `find_resident` | Resolve a first name / nickname; lists candidates when ambiguous | no |
| `list_residents` | Residents in a schedule, optionally one residency year (R1–R4) | no |
| `who_is_on` | Who is effectively on a service on a date ("strong ob", "onc", "NF") | no |
| `resident_schedule` | A resident's effective blocks in a date range | no |
| `shifts_remaining` | A resident's working days from a date onward (float counts; vacation and post-call do not) | no |
| `shared_shifts` | Days two residents are on the same shared service from a date onward (solo rotations such as float never count) | no |
| `shared_shifts_by_coworker` | One resident's shared-shift count with every other resident, most shared first | no |
| `check_coverage` | Dry run of one resident covering another's shift: problems + estimated 80-hour check | no |
| `request_coverage` | Files a **pending** change request | yes |
| `list_change_requests` | Requests visible to the caller (admins: all) | no |
| `review_change_request` | Admin approves (creates the shift override) or denies | yes |
| `cancel_change_request` | Requester or admin cancels a pending request | yes |

**Permissions.** Any approved user may read. A resident may file a request only
when their home resident is the person covering or the person covered; admins
may file, approve, deny, and cancel anything. Nothing changes on the schedule
until an admin approves, either from the **Pending Change Requests** block on
`/admin` (which updates live as requests are filed or decided) or through the
`review_change_request` tool.

**Limits.** Duty-hour results are estimates from nominal hours per rotation
(12 h or 9 h per day); only the 80-hour rolling 4-week average is checked.
"Today" is America/New_York. The MCP server is stateless (no session ids, no
server-initiated SSE stream).

---

## Quick start (development)

```bash
mix setup          # deps.get + ecto.setup + assets.setup + assets.build
mix phx.server     # or: iex -S mix phx.server
```

Visit [localhost:4000](http://localhost:4000) and log in with the dev password
`dev-password` (configurable in `config/dev.exs`). Then upload a schedule at
[/admin/upload](http://localhost:4000/admin/upload).

Run the checks CI enforces:

```bash
mix test           # creates + migrates the test DB, then runs the suite
mix precommit      # compile --warnings-as-errors, unused-deps, format, test
```

Full setup instructions, the expected CSV format, and troubleshooting are in
[`DEVELOPMENT.md`](DEVELOPMENT.md).

---

## Deploying from scratch

Production runs as a compiled Elixir release on a single Ubuntu droplet, behind
Nginx with a Let's Encrypt certificate. Pushing to `main` runs the test suite
and, only if it passes, builds the release, ships it, migrates the database,
atomically swaps the binary, and restarts the service — rolling back
automatically if the health check fails.

This section is the high-level walkthrough. The exhaustive, copy-pasteable
commands (systemd unit, Nginx server block, SSH key setup, troubleshooting) live
in [`DEPLOY.md`](DEPLOY.md).

### 1. Provision the server (one time)

On a fresh Ubuntu 24.04 droplet, as root:

1. Install dependencies: `erlang elixir postgresql postgresql-contrib nginx certbot python3-certbot-nginx git curl`.
2. Create a non-root `deploy` user and add the deploy SSH **public** key to `/home/deploy/.ssh/authorized_keys`.
3. Grant `deploy` passwordless `systemctl` start/stop/restart on the `residency_schedule` service (`/etc/sudoers.d/deploy`).
4. Create the PostgreSQL database `residency_schedule_prod`.
5. Create the deploy directory `/home/deploy/residency_schedule`.
6. Create the secrets file `/home/deploy/residency_schedule/.env` (see below), `chmod 600`.
7. Install the systemd unit that runs `bin/residency_schedule start` with `EnvironmentFile=.../.env`.
8. Configure the Nginx reverse proxy to `localhost:4000` (the `Connection: upgrade` header is required for LiveView WebSockets).
9. Issue the TLS cert: `certbot --nginx -d yourdomain.com`.

### 2. Configure secrets

Runtime configuration is read from the environment in `config/runtime.exs` using
`System.fetch_env!/1`, so a missing variable fails loudly at boot.

| Variable | Lives in | Notes |
|---|---|---|
| `DATABASE_URL` | server `.env` **only** | e.g. `ecto://postgres:pw@localhost:5432/residency_schedule_prod` |
| `ACCESS_PASSWORD` | server `.env` **only** | App login password |
| `SECRET_KEY_BASE` | server `.env` **and** GitHub Secret | Generate with `mix phx.gen.secret`; needed at build time for asset digests |
| `PHX_HOST` | server `.env` **and** GitHub Secret | Your public domain |
| `POOL_SIZE` | server `.env` | DB connection pool size (e.g. `10`) |
| `DB_SSL` | server `.env` | Set `true` for managed Postgres over SSL |

> Secrets never appear in source, `config/`, or logs. `DATABASE_URL` and
> `ACCESS_PASSWORD` never leave the server — they are **not** GitHub Secrets.

In **GitHub → Settings → Secrets and variables → Actions**, add:
`DEPLOY_HOST`, `DEPLOY_SSH_KEY` (the private deploy key), `SECRET_KEY_BASE`, and `PHX_HOST`.

### 3. First deploy

```bash
git push origin main
```

The [`deploy.yml`](.github/workflows/deploy.yml) workflow:

1. **test** — runs the full suite against a Postgres service container.
2. **deploy** (`needs: test`, so it never runs on a red build):
   - builds the release with `mix release` (assets compiled via `mix assets.deploy`),
   - copies it to the server and pulls the existing `.env` into the new release,
   - runs migrations via `ResidencySchedule.Release.migrate/0` (no Mix on the server),
   - swaps old/new release directories and restarts systemd,
   - health-checks `systemctl is-active` and **rolls back to the previous release on failure**.

Then load data by uploading a CSV at `https://yourdomain.com/admin/upload`.

### Day-to-day

Every push to `main` deploys automatically. For maintenance — logs, manual
rollback, editing `.env`, resetting the database — see the **Maintenance** and
**Troubleshooting** sections of [`DEPLOY.md`](DEPLOY.md).

---

## Documentation map

| File | What it covers |
|---|---|
| [`README.md`](README.md) | This overview — structure + deploy summary |
| [`DEVELOPMENT.md`](DEVELOPMENT.md) | Local setup, CSV format, DB management, common issues |
| [Assistant API](#assistant-api-mcp-over-oauth) | Connecting an MCP client, tools, permissions |
| [`DEPLOY.md`](DEPLOY.md) | Step-by-step production provisioning + maintenance |
| [`CLAUDE.md`](CLAUDE.md) | Code-style and testing rules enforced in this repo |
| [`residency_schedule_plan_v2.md`](residency_schedule_plan_v2.md) | Full architectural spec |
