# Phase 0 production backup preparation — October 17, 2026

> Historical record. The owner canceled the Phase 0 recovery program on October
> 21, 2026. Pending tasks, targets, activation proposals and gates below are
> retired, not a continuation queue. See the [current recovery decision](schedule-adapter-recovery-decision.md).

Status: tooling passed its accepted tests and independent code/security review;
the bounded synthetic scheduling proof is in progress. Production backup
scheduling, off-host storage/key custody and alerting are not activated.
Production RTO/RPO and PITR remain unproven.

Branch `codex/phase0-production-backups` starts at `main` commit
`9d87d544eed3d1565b822b63683c2341b442530c`, which merged
[PR #79](https://github.com/jeffreybaird/residency-schedule/pull/79).
The requester authorized proceeding to this next task. The earlier
[database recovery record](phase0-database-recovery.md) remains the evidence for
the isolated synthetic restore; it does not certify production backup coverage.

## Verified predecessor rollout

PR #79 merged October 17 at 16:04:52 UTC. The requester separately approved its
exact production rollout after actual staging checksum, all 18 table fingerprints
and the original authenticated HTTP/WebSocket session passed.
[Main workflow 39047848285](https://github.com/jeffreybaird/residency-schedule/actions/runs/39047848285)
passed test, build, staging, production and demo.

The actual archive SHA256 on all three installations is
`949b99fe6b711fc6adbd3c7fd5500ee0d102020b91240b6bad43947762bb6db9`.
Selected configurations: staging `39047848285-1.Lu595X`, production
`39047848285-1.8m1RmB`, demo `39047848285-1.hfldpi`.
Production/demo retained checksums and selected metadata match; local and public
HTTPS login checks return 200. Original signing/provider/database secrets and
effective cookies are preserved, private modes and transfer cleanup pass, and
both databases retain 22 migrations ending `20261013143545`.
Authenticated production reads report build `9d87d54`, four schedules and
32 residents. No recovery was required. This deployment did not activate a
production backup service.

## Current production baseline

Bounded read-only inspection found PostgreSQL 16.15, an approximately 16 MB
production database, 18 public tables and 16 sequences. Those 34 objects are owned
by `postgres`; grants for future migrations must account for that owner.
The existing application pool also uses `postgres`, a previously recorded
privilege concern that remains a separate transition. About 39 GB of disk is
available at this observation. WAL settings remain `archive_mode=off`,
`archive_timeout=0`, `wal_level=replica`.

There are existing DigitalOcean Spaces access keys, but no application-specific
key or local AWS/rclone credential binding was found. Key presence does not prove
that a suitable bucket, subscription or approved recovery policy exists. Storage
and durable operator private-key custody choices were requested separately.
No private key or credential value was printed.

## Delivery under preparation

The proposed implementation is separate from PR #79's synthetic CLI, whose
production-target rejection remains intact. It will provide production logical
capture and verified object-storage delivery, plus an independent off-host
freshness check. The initial transport under preparation is a dedicated private
DigitalOcean Spaces bucket; no bucket or paid resource has been created.
[Spaces pricing](https://docs.digitalocean.com/products/spaces/details/pricing/)
lists a $5/month base subscription when one is not already active, with shared
storage/transfer allowances and possible overage. Actual usage must be measured
before the activation proposal, rather than inferred from database size alone.

The intended controls are:

- Capture a held read-only PostgreSQL snapshot while normal application writes
  continue. Coordinate with the existing deployment lock without changing its
  mode, owner or inode. A dedicated peer-authenticated database role gets only
  the read permissions and catalog identity checks needed for backup.
- Stream dump and manifest through GPG to encrypted output. Keep the production
  private key off the servers, with verified durable custody. The 45-day synthetic
  key is not a production key. Do not create production plaintext dump files.
- Use the official AWS CLI with private credential files, a pinned HTTPS Spaces
  endpoint and restricted bucket credentials. Publish a completion receipt only
  after full ciphertext read-back and SHA256 verification. Never count partial
  uploads or a failed attempt as a new recovery point.
- Schedule capture every five minutes with a bounded execution deadline and no
  overlapping capture. Run the independent checker every minute; use snapshot
  age, not upload-completion time, to enforce the 900-second freshness threshold.
- Verify each new completed point fully. A protected cache may reuse verification
  of exact version IDs while checking their availability, with periodic full
  scrubbing and bounded download/page/object limits. Mutable or unavailable
  version IDs require the safer verification path, not an assumed ETag checksum.
- Preserve designated off-host recovery copies. The tool will not delete objects
  or install automatic pruning. Bucket read/write credentials include delete
  capability; versioning is not object lock or a guarantee against root/account
  compromise. External alert delivery needs an explicitly chosen destination.

Sequence values are not MVCC snapshot data. The production format must not claim
that a live source sequence's `last_value` equals a frozen table snapshot. Its
isolated restore must use archive sequence state and demonstrate safe sequence
allocation against recovered rows. PR #79's exact frozen-sequence comparison
cannot be reused as evidence under concurrent writes.

## Isolated rehearsal preparation

A separate small PostgreSQL 16.15 cluster was created on the already approved
staging host, using a separate loopback port and an independently recorded cluster
identity. It contains only the existing enriched synthetic dataset, streamed
directly from the earlier disposable source. A database named like production in
this separate cluster permits testing the complete production profile without
production records. The active staging database and service remain untouched.
The test role SQL and operational fixtures received independent safety review
before execution; their guards exclude both actual production and original
staging cluster identities. After the runner recorded the expected absent-role
failure, the reviewed bootstrap SQL
(`23e44aa3594637d9dc9ee8fdffb275f5bbccce4c3899ce450ca44c0e15df81c8`)
was applied under the existing lock to the new synthetic cluster only. The
runner then verified actual peer-authenticated reads, representative synthetic
data access and future-table/sequence SELECT defaults. Eight explicit write or
sensitive-catalog probes returned permission denial with the read-only default
disabled; source rows remained unchanged. The accepted role-check fixture hash
is `cc15c332311c40b337437bc7702ac5d3be8dba1dfd483e58c158ac11ab96411f`.
The SQL's production-database CONNECT grant does not override PostgreSQL's
pre-existing PUBLIC connection grants on other databases. It establishes scoped
object reads, not proven connection isolation across the whole server.

The staging-only AWS CLI preparation used AWS's official archive and verified its
signature against the documented signing fingerprint
`FB5DB77FD5C118B80511ADA8A6310ACC4672475C` before extraction/execution.
Observed CLI version: **2.38.1**. Archive SHA256:
`b11ed416d91f4251da363a17706938eeaf0e520745754c104c0c1890dd8363c7`.
The installed archive utility was added without restarting application services.
This does not establish a complete audit of the CLI's bundled dependencies.

For the actual systemd sandbox rehearsal, that verified bundle was copied to
`/opt/phase0-production-backups-20261017/vendor/aws` with root ownership and no
group/other write permissions. Its executable reports the same CLI version.
This keeps the runtime outside `/root`, which the proposed unit hides.
Streaming encryption with the public-only synthetic keyring also passed using
GPG's `--no-autostart` option. The synthetic private key remains off the host;
this probe does not establish production key custody.

The rehearsal database is on Unix-socket port `5544`, with cluster identifier
`7697672234186579740`. Both actual production (`7614919976833599739`) and the
original staging cluster (`7697284806683061366`) are excluded by the operational
fixture guards. The separate cluster contains the synthetic 18-table,
22-migration dataset. No production application directory was created on staging.

The accepted loopback S3 fixture runs on staging port `4594`; it stores only
synthetic ciphertext under a private directory. The real maintained AWS CLI
successfully listed the fixture bucket and uploaded/downloaded an encrypted probe
with exact byte equality. This fixture does not verify SigV4, provider access
scopes, version retention or real DigitalOcean compatibility.

An initial reviewed helper candidate (`968af187640ade4335c7446dfc723395104b58fdf6ca318402d33d1e72d7a143`)
completed direct synthetic capture, but the exact systemd sandbox failed. A
minimal `SELECT 1` probe using identical protections localized the failure to
`runuser: cannot set user id: Operation not permitted`. No production change was
made. Independent diagnosis found that systemd v255 drops effective `CAP_SETUID`
for this `User=` execution path unless it is ambient
([primary implementation](https://github.com/systemd/systemd/blob/v255/src/core/exec-invoke.c)).
The runner's actual A/B test passed with only `AmbientCapabilities=CAP_SETUID`:
the root parent retained the original four-capability bound, and the switched
`rs_backup` child had zero effective, permitted and ambient capabilities, with
`NoNewPrivileges` still set. The accepted unit fixture also passed its read and
eight permission-denial checks. The corrected exact source unit
(`ce62126d139a1a00e95bea86b952a121279154595fed3a06c9a69c7ea0c476d8`)
then completed capture in 14.482 seconds from snapshot start to receipt
completion. The exact reader unit
(`be89c683d4cfc42b11a15658a86d59aaae568425597226217e3f98853d544b7c`)
performed full ciphertext verification and reported healthy at snapshot age
57.811 seconds, with an empty capability set. Both loaded units have hard and
soft core-dump limits of zero. These are synthetic loopback transport results;
concurrent-write restore, deadline and recurring-schedule evidence remain pending.
The temporary private native-debug logs were removed after diagnosis.
That exploratory synthetic point took 10.188 seconds from snapshot start to
completion: encrypted dump 70,365 bytes, encrypted manifest 60,716 bytes and
receipt 701 bytes. At that fixed size, 8,640 points would retain approximately
1.14 GB before version/failed-upload overhead. Publication read-back, one new-point
monitor read and hourly full scrubs would read roughly 2.36 GB of ciphertext over
30 days, before receipts and other overhead. These are synthetic-fixture usage
calculations, not measured production volume or a billing quote.

## Concurrent capture and isolated restore

The independently accepted concurrent fixture
(`252caa9437af3ea185bb1f344961b91db659e3ebdbccfad556908b716ec619c2`)
ran only on the new synthetic cluster. It committed 120 transactions between
16:58:13.710607 and 16:59:18.840483 UTC, updating the approved-request note,
synthetic OAuth scope and provenance note together. It also made 120 explicit
calls to the validated owned resident sequence, advancing it from 2 to 122.
The sequence ownership, positive increment, noncycling/cache-one behavior and
remaining capacity were checked before mutation.

The exact corrected source unit captured its snapshot at 16:58:36.252679 UTC and
completed the verified receipt at 16:58:46.271837 UTC: **10.019 seconds**. Both
source and monitor units exited zero. The monitor fully verified the new point
and reported snapshot age **29.157 seconds**. Ciphertext sizes were 70,416 bytes
for the dump and 60,716 bytes for the manifest, plus a 701-byte receipt.
The writer continued after capture completed.

The operator retrieved exact recorded object versions, verified ciphertext
SHA256, and decrypted locally. The synthetic private key never reached either
server. The manifest/dump pairing SHA256 was
`6a934b7d427a8db205ec3d3233725388eedb6bf9d3a669ac713547de6025013f`.
The accepted preflight confirmed the new cluster and absent restore target before
creation. A fresh `residency_schedule_recovery_20261017_online` database and
restricted `rs_recovery_online_20261017` role were created there, with PUBLIC
database access revoked. Actual direct TCP authentication confirmed the target,
role, primary status and cluster identity. Password creation used private stdin
with the reviewed same-backend logging controls; no audit extension or preload
was present in this isolated cluster.

PostgreSQL 16.15 `pg_restore`, authenticated directly as the restricted role,
exited zero with `--no-owner --no-acl --single-transaction --exit-on-error`.
Its coarse wall-clock timestamps were 17:03:56–17:03:57 UTC; this one-second
restore command is not a production end-to-end RTO measurement.
The accepted readonly verifier
(`503cdd8ca939716c1fd4247cfea7ba194b1ebefc279596add77d76938f10bd9f`)
matched all **18** tables' full raw row fingerprints, owner-neutral schema,
constraints, extensions and migrations. All **16** owned sequences had a next
allocation within supported bounds and above recovered IDs. The separate
concurrent verifier confirmed coherent committed-generation markers and preserved
synthetic authentication/feed state.

The restored resident sequence was **50**, while the source finished at **122**.
This demonstrates actual sequence drift during online capture and safe restored
allocation without claiming sequence state belongs to the MVCC row snapshot.
The independent runner repeated both readonly verifiers successfully, checking
their accepted hashes before execution. The temporary passfile and both decrypted
files were removed from the operator workstation and staging after verification;
encrypted designated rehearsal copies and the isolated restored database remain
retained.
Deadline and recurring-schedule proofs remain separate acceptance requirements.

The first short-deadline probe was inconclusive because it did not observe an
actual blocked SQL query. A strengthened independently reviewed probe did observe
the `rs_backup` lock wait. The helper exited in 5.956 seconds, released its
deployment lock, left no client processes and preserved its prior verified
status, but the PostgreSQL backend remained blocked for more than the five-second
cleanup grace while the blocker still held the lock. The bounded synthetic
blocker then rolled back normally. This is a real cleanup defect; it is not a
passing deadline test. Scheduling remains off pending the role-owned timeout fix
and authoritative repetition. No production database settings were changed.

The timeout-only candidate
`1e937d553889d9baeaa22b03f5dc7e6d8fe4c598cbecc49013810c3d0634cbd4`
was independently compared with the earlier successful restore's helper. Its
inventory, snapshot SQL, manifest, encryption, archive and reader semantics are
unchanged. It generates per-connection remaining-budget timeouts, a two-second
connect timeout and a one-second PostgreSQL client-disconnect check. Because
`pg_dump` resets its startup statement/lock/idle-transaction timeouts, its lock
budget is also passed explicitly through `--lock-wait-timeout`; the disconnect
check remains active. These are session settings, not global/role changes.

Two consecutive real exact-unit captures passed with this candidate. The first
snapshot at 17:18:42.366726 UTC completed at 17:18:52.182518 UTC (**9.816 seconds**);
the exact monitor performed full verification and reported healthy at age
**23.717 seconds**. A five-second deadline replay remained inconclusive because
it did not observe the required blocked query; the next accepted probe must allow
enough startup time to observe that wait before evaluating cleanup. Full offline
regression acceptance and the meaningful real replay were still pending at that
point.

The renewed ten-second probe then **passed meaningfully** against `1e937d…`:
the runner observed the actual `rs_backup` lock wait, a bounded helper exit in
**8.839 seconds**, and zero remaining backup backends within the five-second
cleanup grace while PostgreSQL still reported the blocker's granted exclusive
lock. Client cgroup cleanup, deployment-lock release and the unchanged previous
success status all passed. The bounded blocker subsequently rolled back and the
fixture exited zero, removing its private temporary configuration. This closes
the observed cleanup defect for the tested path; it is not a claim that every
possible PostgreSQL extension or workload is interruptible.

Final independent review additionally requested canonical executable pinning and
trusted production private-path ancestry. The actual `/etc`, `/var/lib` and
`/opt` rehearsal paths already satisfy that boundary. The deploy-owned stable
lock remains an intentional exception with its original permissions/inode
preserved. The final helper is
`1295c017ad3dab1d165a180f623b8c0586ead5522070c3a8b386bf5d647a78bb`;
its frozen 58-test contract is
`e8ddafabbf0476f7b9b3e19505c842855dbb090069e1486272ccef6c78d40ad8`.
The runner recorded **58 tests / 1,126 assertions**, zero failures/errors/skips,
with independent source/CI/security/audit acceptance. The final helper also passed
the real blocked-query cleanup probe: **8.899 seconds**, actual wait observed,
zero backends within five seconds while the blocker's lock remained granted,
clean client cgroup, released deploy lock and preserved prior success state.

The exact final source unit captured a fresh point at 17:34:00.907689 UTC and
completed it at 17:34:11.945487 UTC (**11.038 seconds**). The exact monitor fully
verified it and reported healthy at age **29.577 seconds**. The reviewed timers
were started only as temporary `/run/systemd/system` units on staging at
17:34:30 UTC, for three scheduled source points at 17:35, 17:40 and 17:45 UTC
with one-minute monitor checks. Results and timer shutdown remain pending.

The source rehearsal, object fixture and reader unit share the staging machine.
Separate reader credentials/state and a capability-free unit demonstrate the
reader's runtime boundary, not physical failure-domain independence or provider
access enforcement. The encrypted transfer to the operator workstation and local
decryption were real. DigitalOcean permissions, HTTPS/versioning compatibility,
durable storage and a physically independent production monitor still require
their activation evidence.

After the isolated restore, all 18 original persistent staging table fingerprints
still matched the saved baseline, including identities, auth/feed state and
history. The original authenticated session again loaded the synthetic schedule
through Nginx, upgraded the real WebSocket, joined LiveView and completed filter
and academic-year events. Its release/artifact identity remained the verified
PR #79 `9d87d54` / `949b99fe…bb6db9` installation.

## Production activation packet requirements

Before requesting activation, the final reviewed packet must identify:

- The exact reviewed tool and unit hashes, installation paths, PostgreSQL role
  grants and existing deployment-lock behavior, with staging evidence.
- A private bucket name/region, versioning and retention policy, credential
  scopes, measured storage/transfer estimates and approved spending. Read/write
  credentials permit deletion; this design does not provide object lock.
- The production encryption recipient and proven durable private-key custody,
  including an independently usable recovery copy outside both servers.
- An independent monitor host, read-only storage credential, stale-point
  threshold and an explicitly authorized alert destination with delivery proof.
- The first verified encrypted production recovery point, restricted restore
  handling and a measured restore/validation procedure. Synthetic results alone
  cannot close the production recovery objectives.

The requester already approved PR #79's rollout; that completed authorization is
separate from creating storage, provisioning production backup access or enabling
the new timers. No repeat approval for PR #79 is required.

For the cost packet, a five-minute schedule produces 288 points per day and
8,640 points over 30 days. Multiply the measured combined ciphertext size by
that count for retained bytes, then add receipts, version overhead and failed
uploads. Initial publication verification reads each point back once, and the
independent monitor reads each new point again; hourly full scrubs add further
traffic. Version-cache hits reduce repeated downloads but do not eliminate those
baseline reads. Account-wide allowances and provider billing rules must be
checked before assigning a dollar estimate. With no automatic pruning, retained
storage continues growing beyond the minimum retention window until an explicit
reviewed retention process exists.

## Acceptance still required

The accepted test/review pipeline, real restricted-role capture, concurrent
synthetic restore, explicit permissions and backend-cleanup checks have passed.
The three scheduled captures, final operational closeout and CI remain pending.
Production activation additionally requires a
concrete approved storage/cost policy, durable key recovery, retention and alert
destination, restricted production restore handling and an owner go/no-go.

Logical snapshots do not implement PITR. Multiple successful five-minute snapshots
can demonstrate the observed recovery-point age, but cannot promise a 15-minute
maximum during a prolonged outage. Loss/replay beyond each snapshot, a proven
production restore, the 60-minute production RTO and later Phase 0 disaster
recovery remain separate evidence gates.
