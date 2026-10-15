# Temporary Bandit HTTP/2 audit exception

The user explicitly authorized this exception on October 15, 2026: “Let’s make
the change and do a temporary override with a directive to check for a patch
every commit”. This project-specific exception applies only to Bandit
**CVE-2026-105659 / GHSA-69m6-wcv4-rwcf / EEF-CVE-2026-105659**. It permits
committing with that disclosed dependency-audit finding while the conditions
below hold. It does not declare the dependency fixed or deployed.

## Conditions

- HTTP/2 must be disabled on **every configured application Bandit listener**.
  The base Phoenix endpoint HTTP config uses
  `http: [http_2_options: [enabled: false]]`, inherited by development, test,
  and production config. The application currently has no HTTPS listener;
  creating one while this exception is active requires the same HTTP/2 disable
  option. Do not add an HTTPS configuration just to disable an unused listener.
- Real listener regression tests must pass: HTTP/1 requests and WebSocket
  upgrade remain available, while the HTTP/2 connection preface is rejected.
  Other ordinary formatting, compilation, static analysis and test gates remain.
- Preserve raw security audit output and its actual exit status. Do not use an
  ignore file, advisory suppression flag, successful substitute status, or a
  global audit bypass. The raw audit continues to report this advisory.
- Any unrelated advisory, audit execution failure, ambiguous result, or failed
  mitigation invalidates this exception and blocks the commit.
- Run and record a **fresh live patch check immediately before every commit**,
  including documentation, follow-up, and rotation-merge commits. A check from
  another commit, cached/offline response, or unavailable metadata cannot qualify.

## Before every commit

Use the active project Elixir runtime. In the current managed environment this
is loaded with `source /workspace/.setup/activate.sh`. Run the audit as a
standalone command so a pipe or shell suffix cannot hide its exit status:

```sh
MIX_ENV=test mix hex.audit
rg '"bandit":' mix.lock
date -u +%Y-%m-%dT%H:%M:%SZ
curl --fail --silent --show-error --header 'Cache-Control: no-cache' https://hex.pm/api/packages/bandit
```

Read `latest_stable_version` and the release list from the fresh package response.
Fetch the latest stable release metadata (substitute the live version), and the
installed release metadata if different:

```sh
curl --fail --silent --show-error --header 'Cache-Control: no-cache' https://hex.pm/api/packages/bandit/releases/1.12.5
```

The example version above is the version at authorization, **not a fixed future
check target**. Inspect the advisory aliases, affected ranges, retirement status,
and maintainer fix information. If any newer stable release exists, investigate
its advisory metadata and upstream release notes to determine the newest
non-vulnerable compatible release; do not assume “latest” means “patched”. If
patch availability cannot be determined from current evidence, stop the commit.

Record the UTC check timestamp, installed version, latest stable version,
available patched version (or confirmed none), successful live retrieval,
raw audit finding/exit status, and passing mitigation check in the commit body
or committed verification record. Do not commit raw environment secrets.

## Expiry and removal

This exception expires as soon as a published patched release is available.
Upgrade to a compatible fixed release, rerun the relevant tests and the full
security audit, and remove this exception and the project-guidance directive.
If upgrading requires significant application changes, obtain the user approval
required by the shared workflow; expiration still blocks ordinary commits under
this exception. HTTP/2 may be restored only as a separately tested decision.

Current authorization baseline: Bandit installed/latest stable **1.12.5**;
fresh Hex metadata on October 15, 2026 lists the advisory as affecting
`>= 1.4.0`, with no published patched package release. HTTP/2 blocked-send
deadlines can be reset by WINDOW_UPDATE traffic, pinning stream processes.
Disabling HTTP/2 removes this protocol path from the configured app listener;
the vulnerable package remains installed. This baseline does not substitute
for any future per-commit check. Deployment is separate and has not occurred.
