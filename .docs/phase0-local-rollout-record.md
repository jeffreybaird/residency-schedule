# Phase 0 local continuation — October 16, 2026

> Historical record. The owner canceled the Phase 0 recovery program on October
> 21, 2026. Pending tasks, targets, activation proposals and gates below are
> retired, not a continuation queue. See the [current recovery decision](schedule-adapter-recovery-decision.md).

Status: repository changes independently accepted; staging rehearsed; final owner decision pending.
Parent: [handoff](schedule-adapter-phase-0-handoff.md).

## Owner and retention

The requester confirmed availability today as release/recovery operator and
approved retaining designated code/configuration recovery copies for at least
30 days. The requester remains the production go/no-go owner. The final rollout
decision is pending the concrete candidate and staging evidence.

## Live baseline

Read-only observations at approximately **15:01–15:06 UTC**:

- Local DigitalOcean `default` profile and existing deployment SSH identity work.
  Administrative and deployment access were verified without printing keys.
- Production and demo are active on the existing Ubuntu 24.04.3 host. Both
  installed `priv/deploy_sha` files identify
  `8e44767943da87fa5f2713fa24522aa138d13d66`; the corresponding successful
  [deployment run](https://github.com/jeffreybaird/residency-schedule/actions/runs/38811145486)
  is recorded independently from those live file observations.
- Both loopback `/login` checks returned HTTP 200. These are bounded readiness
  observations, not authenticated schedule or semantic acceptance.
- Production RPC from its working directory reports Elixir 1.19.5, OTP 28 and
  ERTS 16.4.0.6. A complete OTP patch version file is absent from the packaged
  release; do not infer that version solely from the major version string.
  The installed production library is Bandit 1.12.5, so the fixes in PR #78
  have **not** reached production yet.
  Installed Bandit 1.12.5 is affected by
  [CVE-2026-105659 / GHSA-69m6-wcv4-rwcf](https://github.com/mtrudel/bandit/security/advisories/GHSA-69m6-wcv4-rwcf)
  (affected >=1.4.0,<1.13.0; fixed 1.13.0): HTTP/2 WINDOW_UPDATE traffic can pin
  resources. Source disables HTTP/2, but the effective live option was not
  queried. It is also affected by
  [CVE-2026-105660 / GHSA-v53v-9hvg-37jf](https://github.com/mtrudel/bandit/security/advisories/GHSA-v53v-9hvg-37jf)
  (affected >=0.6.0,<1.13.0; fixed 1.13.0): HTTP/1 request-target authority can
  affect `conn.host`. Proxy normalization/rejection was not established. No
  exploit was demonstrated. Candidate Bandit 1.13.0 fixes both findings.
- PostgreSQL server/client are 16.15. Both databases have 22 applied migrations,
  ending at `20261013143545`; this matches the repository's current schema.
- Both systemd services run directly as `deploy`, with one installation-local
  EnvironmentFile, no drop-ins, and no competing Environment assignments found.
  The production and demo installations use distinct service and node identities.
- Private comparison confirms all recognized legacy configuration values match
  their running-process values. Both database URLs have no query/fragment.
  Existing signing-key lengths are 64 and 88 bytes. Cookies are present.
  No values are included in this record.
- Database ownership is `deploy` for production and `rs_demo` for demo.
  The running production pool nevertheless authenticates as `postgres`
  (superuser); this existing exposure is a follow-up requiring a reviewed
  credential/privilege transition. Demo authenticates as non-superuser `rs_demo`.
  Database ACLs explicitly exclude public CONNECT; `rs_demo` cannot CONNECT to
  production. Name checks alone were not used as proof of isolation.
- Observed writers: the production pool (10 idle connections), demo pool (5),
  and the bounded read-only inventory connection. No deploy/root user crontab
  or application-specific timer was found. This does not prove absence of
  external writers or supply a tested write-freeze procedure.
- PostgreSQL `archive_mode=off`, `wal_level=replica`, archive command disabled.
  DigitalOcean lists no backup images for this droplet. No application database
  backup/restore evidence was found in the inspected timer/cron paths. Other
  backup facilities remain unverified; RTO/RPO are not demonstrated.
- Host capacity: 1 vCPU, about 2 GiB RAM, about 1.1 GiB available, 2 GiB swap,
  39 GiB disk available at inventory time. `flock`, Bash, curl and systemd exist.
  Existing cookie files were mode 644, incompatible with the required private
  mode 600. Both were tightened to 600 under deploy-owned stable locks; byte
  digests and service process identities remained unchanged. The locks were
  initialized by `deploy`, not root.

Earlier RPC attempts from root's inaccessible working directory failed without
altering the running service. Running from the installation directory succeeded.
The failed auxiliary processes do not establish an application failure.

## Completed preparation

The requester explicitly approved importing existing production/demo runtime
secrets into this repository's GitHub environments. Import completed privately
through CLI stdin; values never appeared in arguments, chat, logs or Git.
`prod` and `demo` now have explicit required/conditional runtime settings, target
and database markers, and `main`-only deployment branch policies. Existing
repository transport secrets remain intact. Signing keys and effective release
cookies were preserved. Presence/import success does not establish deployment
success or independently verify the unreadable GitHub secret values afterward.

Ruby 3.3.12 was installed separately under `/opt/hostedtoolcache/Ruby/3.3.12`,
using the official ruby-builder Ubuntu 24.04 x64 archive, SHA256
`3fa2d6242e105a65f694fae86e9f68d9617c827fc14d1fcf611035b9ae2cbdb8`.
The deployment user can execute it through `/usr/local/bin/ruby`. Its bundled
`resolv` 0.3.1 was upgraded compatibly to active 0.3.2 for CVE-2026-80212 and
CVE-2026-80213. No production service was restarted by this installation.

## Separate persistent staging

The requester rejected shared-host staging and explicitly approved a separate
DigitalOcean Ubuntu 24.04 droplet: `urcm-residency-staging`, NYC1, 1 vCPU,
2 GiB RAM, 50 GiB disk, $12/month ($0.01786/hour). The droplet was created;
PostgreSQL 16.15, Nginx, SSH-only inbound firewall and Ruby 3.3.12 with active
`resolv` 0.3.2 are installed. Separate-host bootstrap is complete.
No production data is copied. The rejected shared-host bootstrap was not run.

The separate host now has a restricted `rs_staging` database role, its own
`residency_schedule_staging` database, fresh signing key/cookie/password, a
loopback-only application service on port 4004 and Nginx on port 8080. Only SSH
is exposed; authorized operators reach the proxy through an SSH tunnel. Public
CONNECT is revoked and the application role has no superuser, database/role
creation or replication privilege. No production database exists on this host.
The approved staging GitHub configuration is populated independently; only
`main` and the exact candidate branch may deploy there. Production requires
the confirmed release owner's environment approval as well as `main`.

## Rehearsal evidence collected so far

The first Actions rehearsal exposed missing deployment public keys, corrected
without copying any private key. Its retry exposed the pinned SCP image's
UID-1000 ownership mismatch against hosted-runner UID 1001: private mode-700/600
payloads were invisible to its local glob. No active release was changed by
either failure. The independently accepted
[transfer fix](private-transfer-verification.md) preserves private modes and
hands ownership to that pinned container, uses privileged always-run cleanup,
and contains remote temporary archives within the per-run private inbox.

While that transfer fix was developed, the exact Actions-uploaded artifact was
promoted manually through the real helper on isolated staging. This is explicitly
distinct from a successful end-to-end Actions private transfer.

Initial managed candidate: `5ecc9202ebc1b679cc8d9e50094a653bed58a30d`, archive
SHA256 `8f1a399d394686201537d0d7c2837f4c2e23b42e7563e1e810d37c39812eda70`.
Live process inspection confirmed the staging marker, unchanged signing key and
cookie, and absence of mail/assistant/telemetry credentials. Its retained archive
has 2,511 entries; no `.env`, cookie or supplied staging secret bytes were found.

| Drill | Live result |
| --- | --- |
| Migration connection failure | Failed in 16.796 seconds; active artifact, config, process and readiness unchanged; incoming payload removed. |
| Readiness failure | Deliberate alternate loopback bind failed readiness; exact prior artifact and config restored, service verified, payload removed; 47.750 seconds end-to-end, below 10-minute objective. |
| Configuration replacement | Pool-size change applied in 16.055 seconds; identical artifact preserved; provider credentials remained absent. |
| Two simultaneous promotions | Real migration-metadata lock held the first operation; kernel lock-wait evidence proved the second waited on the same stable destination lock. Both migrated/restarted successfully in 35.722 seconds; lock inode preserved. |
| Literal EnvironmentFile parsing | Real transient systemd service on staging's systemd 255 preserved synthetic dollar/backtick/quote/backslash values from the actual renderer; no shell evaluation. |

The later fixture candidate `79457e410ff3a74c3399938e4caa395818b2ae08` was
promoted with archive SHA256
`097bfa2a4c962a702a29f56737fcc76fdf5f82c9b9026f26e67475b1a544386b`.
The guarded manual seed succeeded against the actual dedicated database;
deployment never invokes it. A private synthetic-admin password was set through
the Accounts context, without including its value in arguments or logs.

Authenticated HTTP and real WebSocket checks through Nginx passed: schedule
fixture rendering, authenticated LiveView join, resident-year filter and academic
year event. Only fixed booleans were reported; credentials, cookies, session
tokens and page content stayed private. Private fingerprints record all rows
across 18 tables for later deployment/recovery comparison: three schedules, two
residents, six memberships, 14 rotations, 22 activities and provenance records,
one historical override, two users and 22 migrations. This baseline alone is
not yet the two-deployment persistence result.

The fixed end-to-end
[Actions run 38924786385](https://github.com/jeffreybaird/residency-schedule/actions/runs/38924786385)
passed tests, built once, transferred private configuration successfully,
promoted staging and cleaned its private transfer inbox. Production/demo were
skipped on the candidate branch. Reviewed code candidate:
`fb658d78e5d2e19501e37bf328670eec7915ad53`; actual archive SHA256:
`820365fbb7c50dfae2f2c51bc0c16fdff0fe5687be9421b5e83e1c4dcaec5394`;
selected staging configuration: `38924786385-1.dfomGo`.

After that real deployment, all 18 private table fingerprints matched the
predeployment fixture baseline, including IDs, feed tokens, account credentials
and historical rows. The prior authenticated session still rendered the schedule
and passed the same real Nginx/WebSocket interactions. Final-candidate readiness
failure was then repeated: exact code and configuration recovered in **48.013
seconds**, with incoming payload cleanup and HTTP readiness verified. This
measures bounded application recovery, not database restore or data-loss RPO.

Two further actual promotions of that final artifact were serialized with the
same kernel-observed lock wait, completed in **31.454 seconds**, and preserved
the stable lock inode. All 18 complete-table fingerprints still matched after
both deployments and rollback; the original login session again passed schedule
and LiveView checks. This establishes persistent fixture evidence across two
real deployments rather than relying on the mocked suite.

The prior exact artifact (`79457e4`, SHA256 `097bfa2a4c962a702a29f56737fcc76fdf5f82c9b9026f26e67475b1a544386b`)
was retrieved and verified against its retained checksum after the later deploy.
Its matching private configuration `manual-fixtures-1792164707.CltYfy` remains
retained, alongside the earlier baseline and current artifacts. The code store
is mode 700; configuration files and stable lock are mode 600. Private Actions
incoming files were absent after cleanup.

The connected production OAuth/MCP session also supplied a bounded read-only
baseline: authenticated `whoami` reported build `8e44767` and four loaded
schedules; the current roster query returned 32 records. Only build/count results
were reported. User identity, names and resident identifiers were not exported.
Repeat those existing authenticated checks after deployment; no new production
account or synthetic write is needed.

## Independent review and production packet

The required role-owned pipeline accepted the final implementation and complete
PR diff at `fb658d7`, including frozen test hashes and ownership-audit review.
The 32 current flagged audit entries were all concurrent/ambiguous, with no
exclusive violation or ownership evasion established. Final checks: **217
doctests, 1,722 application tests, 48 deployment tests / 10,664 assertions**;
format, warnings-as-errors compilation, strict Credo, unused dependencies,
Ruby/Bash/workflow syntax, actual pinned-container transfer regression, and fresh
Hex audit all passed. The Ruby-style comment was addressed without RuboCop and
its review thread resolved. These checks do not imply complete OS/all-gem audits.

Production and demo remain on source `8e44767`, with the same 22 migrations
ending `20261013143545`. No new migration file or adapter-model change is in
this PR. The protected code-only legacy baseline snapshot has SHA256
`6b259454d2f7fe90cab4b7f4db0cc10fecc6295d7182c979342eaae49185e775`.
Its protected operational reference and current legacy configuration/cookie
remain on the original host. Promotion must additionally retain and associate
the actual previous code/configuration under its stable destination lock before
any migration/swap. No automatic pruning is enabled; retain designated code and
private configuration for at least 30 days.

Verified target prerequisites include Ruby 3.3.12 with patched `resolv` 0.3.2,
Bash/flock/checksum/tar/curl, service-user ownership, private cookie/config/lock
modes, 39 GiB free disk, literal legacy inputs, matching effective cookies and
signing keys, absence of competing service overrides, and permitted service
restart commands. Both existing processes remained unchanged during those checks.
GitHub required/conditional secret names are explicit in prod/demo/staging;
production is protected by the owner review gate and main-only branch policy.

The requester is available as release/recovery operator today. Final go/no-go
selects the actual rollout window. Merge is still pending approval. After merge,
the main workflow builds once, stages that exact archive, then offers the same
bytes to production/demo. Keep the production owner gate held until the main
artifact/config identity and persistent staging health are verified. Do not
equate a rebuilt commit with the earlier artifact digest recorded above.

Abort for failed required checks, failed staging, target/database/cookie/config
rejection, migration failure, failed readiness or unexplained data/identity
changes. Validation/migration failures must preserve the current process;
swap/restart/readiness failure must restore and verify the exact prior code and
configuration. The real staging drills above cover those application boundaries.
If automatic recovery itself fails, retain protected recovery state, exclude
further deploys using the same stable lock, and escalate to the confirmed owner;
never publish raw private diagnostics. Binary rollback does not undo database
writes or migrations. Operator rollback after a successful startup but later
semantic failure remains separate Phase 0 work, not a capability certified here.

## Remaining release gates

- Final documentation-head checks and staging identity; final production owner
  go/no-go, merge, resulting main artifact/staging check, owner gate and bounded
  production/demo verification.
- Backup restore/PITR, semantic/operator rollback, additive compatibility and
  disaster recovery remain separate Phase 0 work; do not mark them complete.
