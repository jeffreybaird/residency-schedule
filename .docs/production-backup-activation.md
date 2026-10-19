# Production backup activation packet — October 18, 2026

Status: preparation only. PR #81 merged at `9b9e6cc`; its application rollout is
separate from backup activation. No production backup role, key, bucket or timer
is activated by this packet. The owner has selected the storage, custody and
alert destination below; paid provisioning, test-message delivery and the final
production go/no-go remain unapproved.

## Reviewed tooling prerequisite

The follow-up branch `codex/phase0-backup-activation` carries the previously
reviewed reader correction and final synthetic evidence left local when #81
merged. Duplicate JSON keys remain invalid, while a malformed newer receipt no
longer hides an older valid recovery point. Source SHA256:
`a47ef4cb33f0797c8eb5a6f7803f8f7fa65c8caba119b2bbdc68f0dd678c1c09`.
Frozen test SHA256:
`3a3ccbd6baa67b2c58bb4e7f09d90e61ce5e31847311cb1da87f20fc21b0c071`.
The accepted RED, 59-test GREEN, concurrent restore, three scheduled points,
final exact-helper check and rehearsal cleanup are recorded in
[tooling verification](production-backup-tooling-verification.md) and
[the operational record](phase0-production-backups.md). The follow-up must pass
fresh checks and CI before its exact files become production candidates.

## Selected topology and storage proposal

The production scheduler is droplet `556814550`, `urcm-residency-scheduler`, in
NYC3. The proposed independent reader is existing staging droplet `609726362`,
`urcm-residency-staging`, in NYC1; these regions and active states were refreshed
with `doctl compute droplet list` on October 18. No new compute resource is
proposed. The reader receives no production database access or decryption key.
Separate hosts provide host-failure separation, but share the DigitalOcean
account/provider and NYC region group. The offline recovery copy must be outside
both droplets and Spaces.

Proposed Standard Storage bucket: `urcm-residency-backups`, NYC3, regional
endpoint `https://nyc3.digitaloceanspaces.com`, production prefix `production/`.
The name is a proposal; global availability and remaining shared capacity have
not been established. A filtered read of the October invoice preview on
October 18 found Spaces subscription charges accrued this month; that does not
prove a bucket or subscription is active now. Keep the bucket private, with no
CDN, public listing or anonymous access. Enable and read back versioning before
placing a recovery point in it. Use separate bucket-limited source Read/Write/
Delete and reader Read credentials. Keep bucket administration credentials off
both runtime services. Limited keys do not support bucket policies, so this
proposal does not claim deny-delete enforcement or object lock. The installed
`doctl spaces keys` exposes credential-management commands, consistent with the
[current CLI reference](https://docs.digitalocean.com/reference/doctl/reference/spaces/keys/create/)
generated October 15. Older product guidance still says control-panel-only; do
not infer that limitation from the older page. No key-creation command has been
run. A DigitalOcean API token is not itself an S3 runtime credential.

These provider boundaries are described in DigitalOcean's
[access-key documentation](https://docs.digitalocean.com/products/spaces/how-to/manage-access/)
and [versioning procedure](https://docs.digitalocean.com/products/spaces/how-to/enable-versioning/).
Real-provider checks must verify exact VersionIDs, ciphertext SHA256 readback,
reader access, and reader write denial. The loopback rehearsal did not test
provider authentication, permissions, HTTPS or durability.

## Exact price schedule and usage uncertainty

DigitalOcean's [current Standard Storage pricing](https://docs.digitalocean.com/products/spaces/details/pricing/),
checked October 18, lists a **$5/month account subscription**, including 250 GiB
storage and 1,024 GiB outbound transfer shared across buckets. Additional storage
is **$0.02/GiB-month** and chargeable outbound transfer **$0.01/GiB**. A second
bucket does not add another base subscription. NYC3 Spaces-to-NYC droplets is a
documented free-transfer route; production uploads still count against the
droplet's own allowance. No new droplet cost is proposed.

The read-only invoice check found subscription charges this month. Additional
base cost is **$0 if that subscription remains active at provisioning**, otherwise
**$5/month** for the first bucket, plus any shared-allowance overage. The invoice
can retain accrued charges after the last bucket is deleted, so it alone does
not settle current activity. No unrelated invoice details or account totals are
stored here. Taxes, discounts and remaining shared capacity are not established. The packet cannot
promise a fixed all-in bill or a provider-enforced spending cap. Confirm live
bucket/subscription state, remaining capacity and projected usage before
authorizing provisioning and production backup storage growth. Browser inventory
was unavailable because the Mac was locked; no existing S3 credential binding is
established for a live bucket-list read.

Five-minute snapshots produce 288 points/day and 8,640 points/30 days. If the
combined encrypted dump and manifest average 16 MiB, 30 days requires 135 GiB;
32 MiB requires 270 GiB. With no other storage, the latter exceeds the included
250 GiB by 20 GiB, or $0.40/month. These are scenarios, not measured production
sizes. Add receipts, versions, partial uploads and retention beyond 30 days.
Initial readbacks and subsequent reader verification also consume traffic; the
documented free NYC route must be validated rather than assumed for other paths.

Retain designated recovery points for at least 30 days. Start with no automated
delete or lifecycle expiration. Record the first production ciphertext size and
daily storage/transfer growth, project shared allowances, and resolve a cleanup
policy before accumulated retention can incur unapproved overage. No existing
code/configuration recovery copy is deleted by this work.

## Key custody and alerts

The owner selected the actual vault and external recovery volume. On October 19,
the dedicated item `Residency Schedule production backup decryption` was created
in that vault. Because the external volume is unencrypted, recovery files were
placed inside a new AES-256 encrypted disk image rather than directly on it.
The secret export, its passphrase, revocation certificate, public recipient and
recovery instructions are protected in the vault and encrypted image. No private
key was placed on a droplet, in the repository or in a plaintext temporary file
outside the encrypted image.

Production recipient fingerprint:
`CDED2E523FD7AC8F0E2A9924D7CA786EE4D64F0A`.
The certification primary is Ed25519, with a cv25519 encryption subkey; expiry is
October 19, 2027 at 10:35:15 UTC. This is a new production recipient, distinct
from the earlier expiring synthetic rehearsal key. Retain its private material
for existing backups even after encryption expiry, and review renewal before
that date. No public recipient has yet been installed for production backups.

A public-only keyring with no secret keys encrypted a synthetic challenge.
Fresh, separate keyrings imported the vault export and drive export, and each
recovered the exact original bytes. The encrypted image was then closed,
reopened using its vault-held password, checked against the saved export and
closed again. The software checks passed at 10:41–10:42 UTC on October 19 using
GnuPG 2.5.24 / libgcrypt 1.12.4. See the
[custody verification record](production-backup-tooling-verification.md#production-recipient-custody--october-19).

**Owner custody confirmation completed October 19:** the owner confirmed that
the independently retained image password record was tested and the drive was
disconnected. Subsequent local checks found neither the external volume nor the
recovery image mounted. The independent password test and physical disconnection
are owner attestations, distinct from the software checks above. Retain that
password outside both 1Password and the drive so loss of vault access does not
prevent offline recovery. Only the public recipient may go on production;
the reader needs neither public nor secret GPG material. A workstation temporary
directory does not count as durable offline custody.

The selected alert address is held in private operational configuration, not
committed to this repository. Alerts must contain only fixed service/health
labels and bounded snapshot age, without resident data, database contents,
credentials or private object manifests. The current checker exits on failure;
the committed units do not yet send email or independently detect loss of the
monitor host. Before activation, implement and review a notifier and an external
dead-man check so a stopped monitor is observable. Establish an approved sender
and provider credential; existing application email credentials are not silently
reused. Use synthetic stale/recovery events and obtain explicit test-send
authorization before delivery to the selected address. Record received delivery,
failure handling and deduplication evidence. Choosing an address did not
authorize a message.

## Installation, validation and recovery sequence

1. Deliver and review the focused tooling follow-up. Record its exact source,
   role SQL, source/reader unit and timer hashes. Verify the merged application's
   deployment separately; a successful deployment never starts these timers.
2. Confirm live subscription state and remaining shared capacity/usage; obtain
   approval for the exact bucket/cost
   proposal. Provision private versioned storage and separate credentials. Test
   encrypted synthetic upload, exact-version readback and reader permissions.
3. Complete and independently prove both private-key recovery copies. Finish
   reviewed alert/dead-man integration and authorized synthetic delivery tests.
4. Refresh the production baseline read-only: expected PostgreSQL cluster
   `7614919976833599739`, database `residency_schedule_prod`, primary status,
   object ownership, disk headroom and stable deployment-lock inode. Recheck
   compatible client/runtime versions and current relevant advisories.
   Approve a separate protected recovery target, network/role restrictions,
   operator access and plaintext cleanup before the production go/no-go.
   Production data must not enter the synthetic staging application or original
   staging database.
5. Present the final production go/no-go with all preceding evidence, exact
   installation paths, grants, timings and rollback. No role grants, service
   installation, production dump or timer activation occurs before that approval.
6. After approval, install verified root-owned helper/config/public key, create
   only the reviewed `rs_backup` grants and run permission probes. Preserve the
   application credentials and deployment-lock inode. Take one manual encrypted
   point, verify it from the reader host and perform the approved restricted
   restore before enabling the five-minute source and one-minute monitor timers.
7. Execute that restore only on the previously approved protected recovery
   target. Validate table fingerprints, schema, migrations and safe sequences;
   measure the real RTO and complete the approved plaintext cleanup.
8. Observe repeated healthy points and delivered failure/recovery signals.
   Record exact timestamps and costs. Recovery objectives remain unproven until
   measured; logical snapshots do not provide PITR.

If a gate fails, leave scheduling disabled. To stop an approved activation,
disable/stop only the new backup timers and services, preserve all encrypted
recovery points and private configuration, and diagnose before removing grants.
Do not stop the application, alter its credentials, replace its deployment lock,
delete the bucket or erase the offline key. A notifier failure leaves activation
incomplete even when a local backup status says healthy.
