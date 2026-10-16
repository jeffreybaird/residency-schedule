# Private configuration transfer verification

October 16, 2026. Real staging run 38922335321, attempt 2, failed before
configuration upload: the pinned SCP action printed `tar: empty archive`.
Rendering and private remote inbox preparation had succeeded; promotion had not
started.

The pinned `appleboy/scp-action@v0.1.7` uses
`ghcr.io/appleboy/drone-scp:1.6.14`, whose image runs as UID/GID 1000. The hosted
runner renders its private directory/file as UID 1001 with modes 700/600. The
container cannot traverse that directory, and upstream `filepath.Glob` returns
no source matches. A Linux Docker-volume reproduction using the exact upstream
action Dockerfile/entrypoint, real image user and synthetic data reproduced the
same error without network access. The preceding SSH step was not required.

Both staging and production/demo jobs now check fixed private paths are not
symlinks, transfer ownership to the pinned action user with
`sudo chown --no-dereference`, and retain modes 700/600. Local cleanup always uses
`sudo rm -f --` against the fixed JSON path. Remote `tar_tmp_path` now ends with
`/`: upstream concatenates this value directly with its random filename, so the
separator is necessary to keep temporary archives inside the per-run private
inbox and its cleanup boundary.

Primary implementation evidence:
[action Dockerfile](https://github.com/appleboy/scp-action/blob/v0.1.7/Dockerfile),
[image Dockerfile](https://github.com/appleboy/drone-scp/blob/v1.6.14/docker/Dockerfile),
[source selection and temporary archive paths](https://github.com/appleboy/drone-scp/blob/v1.6.14/plugin.go).

The test writer added both-job workflow contracts and an optional actual-image
integration script. The reviewer accepted the contracts before source changes.
Authoritative red evidence included the missing workflow ownership handoff and
the actual container's empty archive. Accepted SHA-256 hashes:

| Test | SHA-256 |
| --- | --- |
| `test/deploy/release_artifacts_test.rb` | `759e175b68ee8fdf50f87942a0651030890e90896de6870a7f4cc51a85b07b94` |
| `test/deploy/private_transfer_test.sh` | `0d06b0ab91e63e3bfdf4cd26187f922d4e7cffc3b98c14122550198b644b6df9` |

Final runner green:

- `ruby test/deploy/release_artifacts_test.rb`, real Linux Ruby 3.3.12/flock,
  network disabled, seed 63856: **48 tests, 10,664 assertions, zero failures,
  errors or skips**.
- `bash test/deploy/private_transfer_test.sh phase0-scp-action-repro:v0.1.7`:
  both jobs passed actual extracted workflow handoff and cleanup. The real pinned
  action reproduced the denied baseline, then archived successfully after
  handoff. Exact payload bytes and mode 600 survived the archive round trip;
  directory mode 700 remained unchanged, and no synthetic sentinel appeared
  in logs. A cached GNU-coreutils helper runs the host commands, matching the
  Ubuntu runner; the transfer and tar checks retain the actual action user.
- Ruby/Bash syntax, diff checks and frozen hashes passed. Fresh `mix hex.audit`
  reported no retired or advisory packages. No application/dependency code changed;
  the preceding complete application checks remain separately recorded.

This integration uses no network. Reaching the expected connection refusal
after archiving proves archive selection, not successful SSH upload, remote
extraction or remote cleanup. A real staging rerun of the final candidate must
establish those outcomes. Existing Ruby runtime advisory scope is unchanged from
[staging tooling verification](phase0-staging-tooling-verification.md).
