# Online backup tooling verification

Status: accepted tooling; synthetic operational rehearsal passed. The final 59-test
suite, restricted-role, restore, blocked-query cleanup, scheduled cadence and
final reader smoke checks passed. Original tooling CI passed; follow-up-head CI
is pending. Production backups remain inactive.
Branch: `codex/phase0-production-backups`, based on merged PR #79 at
`9d87d544eed3d1565b822b63683c2341b442530c`.

The shared role-owned workflow applies. The spec writer owns new tests and
fixtures; the runner records authoritative red/green; the independent reviewer
accepts frozen test hashes before implementation and reviews final source,
operations, docs and audit evidence. The parent owns infrastructure decisions and
operational mutations. Existing PR #79 code and its accepted 43-test contract
remain unchanged.

The [runbook](production-backup-runbook.md) describes the bounded online snapshot,
streaming encryption, verified object receipt and independent freshness contract.
[The operational record](phase0-production-backups.md) owns actual identities,
measurements, decisions and activation limits. Pending evidence is not acceptance.

## Security review baseline

The runner and reviewer refreshed `mix hex.audit` on October 17; no retired
packages or published Hex advisories were reported. This is not a complete OS,
GPG, PostgreSQL or bundled AWS CLI dependency audit.

The maintained AWS CLI 2.38.1 selected for rehearsal is newer than these reviewed
published fixes:

- [CVE-2026-13769 / GHSA-wfp6-f47h-hxc3](https://github.com/aws/aws-cli/security/advisories/GHSA-wfp6-f47h-hxc3):
  affected <=2.34.28, fixed 2.34.29; certain CodeArtifact/IAM/deployment commands
  wrote sensitive files with unsafe permissions. Those commands are outside this
  S3-only transport.
- [CVE-2026-18654 / GHSA-hqvf-45jj-mccq](https://github.com/aws/aws-cli/security/advisories/GHSA-hqvf-45jj-mccq):
  affected <=2.35.2, fixed 2.35.3; EMR SSH host-key handling. This tool performs no
  EMR or SSH operation through AWS CLI.
- [GHSA-747p-wmpv-9c78](https://github.com/aws/aws-cli/security/advisories/GHSA-747p-wmpv-9c78):
  history exposure in <=2.33.20, fixed 2.33.21. The helper also disables CLI
  history and scrubs inherited history/provider settings.

The operator verified the official Linux AWS CLI archive's signature against the
AWS-published fingerprint before extraction or execution, and observed actual
version 2.38.1. Signed vendor packaging does not establish every bundled library's
advisory status. Existing local PostgreSQL 17.10 is excluded from this path; real
rehearsals use patched PostgreSQL 16.15 and the known fixed Ruby/Resolv runtime.

The prior record's [Security review scope](database-recovery-tooling-verification.md#security-review-scope)
preserves the explicit pre-existing runtime findings and vendor backport levels.
In particular, workstation PostgreSQL 17.10 remains below the 17.11 fixes for
CVE-2026-19385 (`pg_dump`), CVE-2026-18408 (`psql`) and CVE-2026-16241 (ECPG).
Those clients are excluded from actual backup/restore commands, which use remote
16.15; no workstation service upgrade is claimed. That section also records the
fixed Ruby/Resolv versions and the scoped Ubuntu GPG/libgcrypt backports, without
claiming every installed GPG component or bundled AWS library is fully patched.

## Accepted tests and authoritative red

The independent reviewer accepted the initial 51-test contract at
`d11b41ca082a5666a626ce8a638e30b523a64f2c6d29c39365a67bfca74477ed`.
The runner recorded expected missing-helper red: **51 tests, 225 assertions,
28 failures, zero errors/skips**. Before acceptance, the spec writer added an
explicit fixture-start assertion so the timeout test failed meaningfully rather
than reading a nonexistent PID file.

A reviewed scale regression then required bounded discovery to skip over more
than 100 old objects while finding a current point. Ordinary five-minute cadence
produces 864 objects per day, so an ascending whole-day scan with a 100-object
budget would fail under normal operation. The test driver and loopback S3 server
now implement standard `StartAfter` semantics before pagination. The runner
recorded the selected scale red, and the reviewer accepted:

- Suite: `de8e5cc5ed65ad6d9d65353a52426852b58184aab6c090f02e446686436315fc` (52 tests).
- Driver: `490575e03d4c5e0ea590b0ef9d6cd7426d5b44ceab67018bbe6e6102aa29f4c6`.
- S3 server: `98a8138cd7a325c7c0b77d27904789a9517f8068e8923e7b6c644e2c6088871a`.
- AWS wrapper: `4f3bd9201a40f3bba2061fdd1aea5ccc9727195c6ce95222c71adf7f9dd8306b`.
- Concurrent writer: `36cc60e905e1a42b355b137c449f55dbe8448edb02e097b336356ea829718982`.
- Actual role checks: `cc15c332311c40b337437bc7702ac5d3be8dba1dfd483e58c158ac11ab96411f`.

The source helper was authorized only after these accepted red contracts.
Existing PR #79 source/test hashes remained unchanged. Correcting
`mix format --force` ran on test-owned Elixir paths without changing existing
Elixir tests or the accepted Ruby files.

A subsequent physical-keyring regression exposed a real fail-open gap: dangling
private-key paths and legacy secret keyrings were not rejected before database
access. With both source and off-host happy paths already passing, the runner
recorded selected red: one test, one assertion, one failure, zero errors/skips.
The reviewer accepted the 53-test suite at
`956675f4c848e7354844e2e9b46292ca0cbb1c77ba5ac1ccd88e8b087c9bcc0b`
before authorizing that correction.

The first guarded SELECT already establishes a repeatable-read snapshot, so a
timestamp recorded after that query could overstate freshness. A regression
records the first guard's start and checks that the decrypted manifest's recovery
timestamp precedes it and matches the receipt. The runner recorded selected red:
one test, six assertions, one failure, zero errors/skips. The reviewer then
accepted the 54-test suite at
`88d57acda591e185a512a9715568038b3bc9e94e0fb17d9e060d1af0e436ebc8`
and driver at
`22ba10ec3308d53e9423d97e3361835e9f70e4a3b59573b1aa7881464b678a17`
before authorizing the conservative timestamp correction.

The ciphertext-limit fixture then needed a representation correction: its
128-byte process file limit truncated the fake CLI's JSON event log before the
ciphertext path could be checked. The runner recorded that parser error. The
writer raised the test's configured ciphertext cap to 65,536 bytes and input to
131,072 bytes, retained failure/no-upload assertions, and added proof that dump
and encryption ran and the retained ciphertext stayed within the configured cap.
The reviewer accepted this stronger 54-test contract at
`b450590d184c914301e6339693e3070246a2122b8d78178caf8156ef44075436`.
The driver and operational fixtures were unchanged; production limits were not
relaxed. This is the current frozen suite for authoritative green.

## Authoritative offline green

The runner verified the frozen suite and fixture hashes against source SHA256
`968af187640ade4335c7446dfc723395104b58fdf6ca318402d33d1e72d7a143`:

- Online production-backup suite: **54 tests, 832 assertions**, all passing.
- Existing synthetic recovery suite: **43 tests, 642 assertions**, all passing.
- Existing release deployment suite: **48 tests, 10,664 assertions**, all passing.

These ran once each in the patched Ruby 3.3.12/Resolv 0.3.2 Linux image, with
network disabled, a read-only repository and real Linux `flock`. The recovery
assertion count differs from earlier macOS runs because of platform-conditional
cases; its frozen test bytes were unchanged. Ruby syntax, changed CI YAML parsing
and `git diff --check` passed. Actual systemd, PostgreSQL and official AWS CLI
rehearsal evidence was subsequently recorded in the sections below.

After source/test owners completed partitioned correcting formatting without
changing Elixir files or the frozen Ruby hashes, the runner's read-only checks
also passed: formatting, compilation with warnings as errors, strict Credo
(320 files, 69 checks, zero issues), unused-dependency checking and a fresh Hex
advisory audit. The final independent diff reviews are recorded below.

## Actual restricted-role red and green

The runner independently executed the accepted role fixture on only the new
isolated PostgreSQL 16.15 cluster. The fixture checks exact database/port/cluster,
refuses the real production and original staging clusters, and refuses a host
with a production application installation. Its initial red confirmed that
`rs_backup` did not exist, before any permission canary could run.

After independent SQL review, the parent applied
`deploy/production_backup_role.sql` at SHA256
`23e44aa3594637d9dc9ee8fdffb275f5bbccce4c3899ce450ca44c0e15df81c8`
to that isolated cluster only. The runner then recorded actual green: read-only
peer identity, actual source cluster, representative reads, future default SELECT
grants and unchanged source rows all passed, with eight explicit write/sensitive
catalog denials. The probes disable the role's read-only default before checking
permissions; sequence privilege prechecks prevent accidental nontransactional
increments, and future table/sequence canaries roll back.

These are scoped SELECT grants, not proof that the role cannot CONNECT to every
other database: PostgreSQL's PUBLIC privileges may still permit connections.
No global PUBLIC ACL was revoked. Production activation requires its own
post-grant effective-privilege proof.

## Actual systemd capability regression

The first exact source-unit rehearsal failed before PostgreSQL connection, while
the same helper succeeded outside the sandbox. A bounded native probe identified
`runuser` failing its UID change. Independent probes found root effective and
permitted capabilities `0x64` versus bounding set `0xe4`: `CAP_SETUID` was missing.
Plain kernel UID switching also failed, excluding PAM as the cause of this
failure.

The implementer and reviewer independently checked systemd 255's
[execution source](https://github.com/systemd/systemd/blob/v255/src/core/exec-invoke.c):
after sandbox setup it drops `CAP_SETUID` unless that already-bounded capability
is in the ambient set. The spec writer supplied the independently accepted,
read-only actual-unit probe at
`06fa66a00c9e86d8c89fecaa024b678b36c3e16de924696faab09b3f2f9a39fc`.
The runner recorded meaningful red under the original exact unit, then green
after adding only `AmbientCapabilities=CAP_SETUID`: actual peer identity and
representative reads passed, all eight write/sensitive-catalog denials passed,
and source rows remained unchanged.

The restricted `rs_backup` child had zero effective, permitted and ambient
capabilities; its inheritable set remained `0x80`, bounding set `0xe4`, with
`NoNewPrivs=1`. The fix does not add `CAP_SETPCAP` or expand the bounding set.
Both services also gained `LimitCORE=0`. The reviewer accepted final service
hashes:

- Source: `ce62126d139a1a00e95bea86b952a121279154595fed3a06c9a69c7ea0c476d8`.
- Monitor: `be89c683d4cfc42b11a15658a86d59aaae568425597226217e3f98853d544b7c`.

The helper and timers remained unchanged. The parent then ran both exact final
services successfully. The runner independently verified their loaded hashes,
success/status zero, zero soft/hard core limits, four source bounding capabilities
with only ambient UID switching, and empty monitor capability sets. The accepted
readonly unit fixture also passed again under the final source properties.
The concurrent capture, restore and blocked-query deadline checks subsequently
passed as detailed below.

The initial concurrent fixture updated related note/auth/provenance markers but
did not advance a sequence. Before final rehearsal the writer added explicit
allocation from the dynamically verified owned `residents.id` sequence, guarded
to the one new synthetic cluster, positive noncycling cache-1 sequences and
sufficient capacity. The reviewer accepted revised fixture SHA256
`252caa9437af3ea185bb1f344961b91db659e3ebdbccfad556908b716ec619c2`.
Its safe aggregate start/end counters and call counts permit evidence that writes
continued beyond the archive capture without claiming sequence MVCC equality.

## Final concurrent capture and restricted restore

The accepted writer ran 120 transactions/sequence allocations from
`2026-10-17T16:58:13.710607Z` through `16:59:18.840483Z`, advancing the source
counter from 2 to 122. The exact source service captured its held snapshot at
`16:58:36.252679Z` and completed verified publication at `16:58:46.271837Z`
(10.019158 seconds). The exact monitor service independently performed full
verification and reported healthy snapshot age 29.156799218 seconds. Writes
continued beyond capture and publication.

The operator retrieved exact version-pinned ciphertexts with full hashes,
decrypted only off-server and checked dump/manifest pairing. The accepted
preflight passed before a fresh restricted role and fresh isolated restore
database were created. Direct TCP identity checks bound the actual cluster,
database, role and primary status. Patched PostgreSQL 16.15 `pg_restore` ran as
that restricted role, with no owner/ACL restoration and a single transaction,
and exited zero between `17:03:56Z` and `17:03:57Z`.

The accepted readonly verifier passed all 18 raw table fingerprints, schema/FKs,
extensions, 22 migrations and 16 sequence-allocation checks. The concurrent
fixture verified coherent related markers and preserved authentication/feed
bytes. The restored residents sequence was 50/called, versus the final source
counter 122: its safe next allocation was 51. This demonstrates actual sequence
drift under continuing writes while preserving safe archive state, rather than
claiming sequence equality with the MVCC snapshot. The temporary passfile was
removed; the private GPG key never reached either server.

The runner independently reran both accepted readonly restore fixtures and
recorded the same passing integrity/coherence results before plaintext cleanup.
The operator then removed the two local and restored-host plaintext files and
their empty directories; encrypted recovery copies and the synthetic recovery
database remain designated for inspection. The parent also rechecked the
original active staging cluster: all 18 saved table fingerprints, deployed
artifact and authentication/feed/history data were unchanged. Its original
session cookie still passed authenticated HTTP and real WebSocket LiveView
join/filter/year checks. All write fixtures used the separate new cluster.

The readonly production-format restore-check fixture was independently accepted,
then hardened to verify canonical, root-owned, non-writable directory ancestors
before loading the trusted inventory helper. Its renewed accepted SHA256 is
`503cdd8ca939716c1fd4247cfea7ba194b1ebefc279596add77d76938f10bd9f`.
It verifies canonical raw fingerprints/schema and checks that a positive,
noncycling owned sequence's next value is within bounds and beyond existing IDs,
without calling `nextval` or claiming source sequence MVCC equality. It does not
create roles/databases or overwrite existing targets.

## Actual blocked-query deadline regression

The spec writer supplied a reusable guarded deadline fixture at
`b85134906b8b9dcdea8abee54f113171e47c3d5fe700a6bd37484b8b99c76d23`.
It takes a bounded transaction lock on the new synthetic cluster, proves an
actual restricted backup query is waiting, and checks helper/server cleanup
before independently proving the blocker still holds its granted relation lock.
It never cancels backends or changes source rows. An earlier three-second probe
was explicitly inconclusive because it did not observe a blocked query.

The accepted five-second fixture exposed a real defect in helper `968af187…`:
the helper exited in 5.956 seconds, its process cgroup emptied, the deployment
lock was released and prior success status was preserved, but a PostgreSQL
backend remained more than five seconds after client termination while the
blocker still held the lock. The blocker then rolled back on its bounded timer.
OS process cleanup alone therefore did not establish server query cleanup.
The reviewer accepted this meaningful red contract; a session-local timeout and
client-disconnect detection correction entered the required role pipeline.
At that stage, timers and final acceptance were held until the defect was closed.

The writer revised the PG-environment contract to permit only internally
generated numeric timeout/client-check settings while preserving rejection of
hostile inherited PG options. A new test requires fresh per-process budgets and
a matching dynamic dump-lock timeout. The reviewer corrected event ordering to
count first appearances of unique process identities: the long-lived exporter's
later rollback must not masquerade as a new spawn. After the runner's exact
selected red (one test, four assertions, one failure), the reviewer accepted the
55-test suite at
`57f545b31adc0e4450453a3a3060dd2eab4accafa711532e0648bb1d42befd78`.
The driver and actual blocked-query fixture remained unchanged.

The timeout-only correction is helper
`1e937d553889d9baeaa22b03f5dc7e6d8fe4c598cbecc49013810c3d0634cbd4`.
The reviewer compared it against a reconstructed exact SHA-verified `968af187…`
baseline: only monotonic budgets, generated PG session options/connection timeout
and the explicit dump lock budget changed. Inventory, snapshot SQL, manifest,
encryption, archive and storage semantics were byte-unchanged; the earlier
concurrent restore therefore remains explicitly anchored to its tested version.

A five-second replay on the correction was inconclusive because no actual wait
was observed. The writer increased only the bounded probe's startup allowance:
ten-second helper, thirty-second blocker and thirty-five-second SQL bound, with
all observed-wait and five-second cleanup criteria unchanged. The reviewer
accepted revised fixture
`b854cfeef99f9352c7a6739601d9fb298d56b7c4e7eba0a08ff09dfd7ff3fba9`.
Its authoritative replay passed: actual lock wait observed, helper exit in
8.839 seconds, server backends zero within five seconds while the granted blocker
lock still existed, empty cgroup, released deployment lock and preserved success
status. The blocker then rolled back and private probe configuration was removed.

Two consecutive real normal-deadline captures and a full monitor check also
passed on `1e937d…`. The first captured `17:18:42.366726Z` and completed at
`17:18:52.182518Z` (9.815792 seconds); full verification reported healthy snapshot
age 23.716664201 seconds. These demonstrate the healthy runtime independently
of the fake CLI's instrumentation.

The offline successive-run test exposed another instrumentation-size collision:
its shared fake event log reached exactly 65,536 bytes, with 41 complete events
and one truncated record. The writer retained first-run events in memory and
reset only this fake log between the two actual backups, combining both event
sets for the unchanged uniqueness checks. The reviewer accepted the correction
at suite SHA
`10f11d732155d1a6c39b7db9e9967cd007bec98f33868f8e9f6b4a7b13992122`.
Production file limits and receipt/object-count assertions were unchanged.

The runner then recorded authoritative green on `1e937d…` and the corrected
suite: **55 tests, 1,106 assertions, zero failures/errors/skips**, with the
successive-run case separately passing all nine assertions. The actual blocked
query and real healthy runtime evidence above therefore complement a clean
offline contract. The path-trust hardening pipeline below followed before the
scheduled timer rehearsal.

## Final path-trust hardening

Independent review identified two related generic path races despite the actual
rehearsal hierarchy being protected. Executable validation checked the resolved
target but later executed the original alias, which could be retargeted. A
private root-owned leaf beneath a writable ancestor could also be replaced after
validation. The writer added three meaningful regressions: retarget an alias after
validation, retarget all five configured executable aliases before a real
synthetic backup, and reject a writable ancestor while retaining a protected
positive control and the reviewed `root:false` exception.

The runner recorded three expected failures against `1e937d…`. The private-path
unit preserves actual inner file/directory modes but scopes ownership/external
temporary-directory simulation for portable testing; it is not an OS privilege
proof. Unmocked root-service captures below supplied integration evidence. An optional Minitest mock
dependency was removed in favor of standard Ruby scoped method wrappers that
restore the original methods in `ensure`, supporting both Minitest 5 and 6.
The final accepted 58-test suite is
`e8ddafabbf0476f7b9b3e19505c842855dbb090069e1486272ccef6c78d40ad8`.

Path-hardened helper
`1295c017ad3dab1d165a180f623b8c0586ead5522070c3a8b386bf5d647a78bb`
pins all five canonical executables and validates production root-owned ancestry,
preserving the configured fixed-runuser policy and deploy-owned lock exception.
Duplicate JSON rejection occurs before converting the validated top-level config
to a plain Hash for canonical replacements. Independent exact-diff review found
no budget, inventory, snapshot, archive, manifest, encryption or reader-data
changes versus `1e937d…`. The runner's focused security run passed all three cases
and twenty assertions. The final full suite then passed **58 tests and 1,126
assertions**, with zero failures/errors/skips on patched Linux Ruby 3.3.12/Resolv
0.3.2, network disabled and a read-only repository. Frozen source/test hashes
matched before and after. Syntax, diff, read-only formatting and a fresh Hex
advisory audit also passed. Final-hash runtime and timer results follow below.

The runner then replayed the accepted blocked-query fixture against final helper
`1295c017…`: actual wait observed, helper exit in 8.899 seconds, server backends
zero within five seconds while the granted blocker still held its lock, empty
cgroup, released deploy lock and preserved prior success. The fixture exited
zero after bounded rollback and private-config cleanup. The reviewer accepted
final code/CI and frozen hashes, confirmed old PR #79 source/tests unchanged, and
reviewed eleven new audit entries: all ambiguous overlaps matching authorized
role-owned work, with no unauthorized finding or exclusive violation. Scheduled
timer evidence and operational closeout follow below.

The final exact helper's normal root service and full monitor verification also
passed unmocked: snapshot `17:34:00.907689Z`, publication complete
`17:34:11.945487Z` (11.037798 seconds), monitor healthy age 29.576536969 seconds.
Runtime-only reviewed timers started at `17:34:30Z`, with planned scheduled source
firings at 17:35, 17:40 and 17:45 UTC. Those three points were independently
verified; the additional fourth firing and completed cleanup are recorded below.
No competing captures or probes ran during that window.

## Scheduled cadence and final closeout

The scheduled source/reader evidence is anchored to helper `1295c017…` and the
reviewed unchanged timer units. Runtime-only timers started at 17:34:30 UTC on
October 17, 2026; all times below are UTC on that date.

| Scheduled snapshot | Publication complete | Independent full verification |
| --- | --- | --- |
| 17:35:04.566551 | 17:35:29.217770 | 17:36:14.134108 |
| 17:40:05.171242 | 17:40:28.822807 | 17:41:16.203111 |
| 17:45:05.089528 | 17:45:30.285494 | 17:46:17.590026 |

The first two snapshot intervals were 300.604691 and 299.918286 seconds. Both
services exited zero, and protected source/reader status copies were retained.
One additional scheduled source point fired before shutdown:
`17:50:04.542523Z` to `17:50:28.855555Z`; its metadata was preserved explicitly,
rather than describing the run as exactly three firings. Timers were then
stopped. These synthetic measurements demonstrate the configured cadence and
freshness checks, not an ongoing production RPO guarantee or a separate physical
monitoring failure domain.

Final review found one reader classification edge case: duplicate keys in a newer
receipt raised a generic error instead of allowing the existing narrow malformed
candidate fallback. The writer added a regression that first verifies an older
point, reads the newer duplicate-key receipt and requires healthy older fallback.
The runner recorded meaningful RED (one test, five assertions, one failure).
The reviewer accepted frozen suite
`3a3ccbd6baa67b2c58bb4e7f09d90e61ce5e31847311cb1da87f20fc21b0c071`.
Final helper
`a47ef4cb33f0797c8eb5a6f7803f8f7fa65c8caba119b2bbdc68f0dd678c1c09`
changes only `Error` to `JSON::ParserError` for duplicate JSON keys versus the
saved exact `1295c017…` baseline. Duplicate configuration still fails closed;
archive, source, timeout and cadence behavior are unchanged.

Authoritative final GREEN: **59 tests, 1,136 assertions**, zero failures/errors/
skips, with frozen hashes unchanged before/after. The new selected case passed
all ten assertions; syntax, formatting, whitespace and a fresh Hex audit passed.
Both original commit `03d502f` CI runs (`39054652722` and `39054649260`) passed;
those results are explicitly distinct from the follow-up fix head's CI.

After the scheduled window, the final helper passed an unmocked fresh source and
full monitor smoke: snapshot `18:48:43.675515Z`, completion `18:48:53.904633Z`
(10.229118 seconds), full verification at `18:49:09.172216Z`, healthy age
25.496663735 seconds; both service exits were zero. The fresh point avoided
confusing intentionally stopped timers' aging historical points with a failure
of the final reader.

At 18:49:45 UTC, both timers were stopped, all four temporary `/run` unit files
were removed and systemd reloaded, the loopback object fixture stopped, and only
the guarded isolated PostgreSQL cluster on port 5544 was stopped with fast
shutdown. Original staging stayed active. Recovery data/database, encrypted
copies, protected configurations and the synthetic test key remain retained;
plaintext/passfiles had already been removed. Safe fixture operation counts were
GET 108, HEAD 26, LIST 58 and PUT 34, all status 200. No paid bucket, real
production backup key, production schedule or external alert was activated.

## Delivery after PR #81 merged

PR #81 merged October 18 as `9b9e6cc`. The reviewed reader correction and final
operational evidence remained local when the conflict-only commit was pushed;
they are carried forward on `codex/phase0-backup-activation`, based on that merge.
Source and accepted-test hashes still match `a47ef4cb…` and `3a3ccbd6…` exactly.
Independent review again accepted the one-exception-class fix and unchanged
fallback/configuration contracts, including the authorized native stash-apply
audit observation. No dependency or unrelated behavior changed.

Fresh authoritative checks on the new base passed: production **59 tests /
1,136 assertions**, recovery **43 / 642**, release artifacts **49 / 10,666**;
all zero failures/errors/skips on patched Linux Ruby 3.3.12/Resolv 0.3.2, image
`135e4c6c…`, network disabled and repository read-only. Hashes matched before and
after. Syntax, read-only formatting, working/staged whitespace and a fresh Hex
advisory audit passed. No live probe or rehearsal repeat was performed. Broader
OS/AWS/GPG advisories were not reaudited for this one-line follow-up; the existing
documented workstation PostgreSQL exclusions remain. Follow-up CI is distinct
from the original PR's green runs.
