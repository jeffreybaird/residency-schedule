# Ruby deployment test contract

The user requested removal of Python from PR 78. The Ruby Minitest suite replaces
the previously accepted `test/deploy/release_artifacts_test.py` contract without
changing its deployment behavior. It uses Ruby standard/default libraries only,
real temporary directories, tar/gzip archives, checksums, FIFOs and `flock`, and
local stubs for service and network commands. It never contacts a deployment host.

Each of the original eighteen test names is retained in the Ruby suite:

1. Identical immutable bytes promote to production and demo, including demo seed ordering.
2. Later successful deployment retains verified earlier and sanitized legacy archives.
3. Different builds of one commit retain both exact content-addressed artifacts.
4. Corrupt retained content cannot overwrite an immutable artifact or trigger deployment.
5. Migration and seed processes cannot inherit the destination lock descriptor.
6. Packaging rejects environment files and links outside the release tree.
7. Checksum failure occurs before configuration or service mutation.
8. Otherwise valid archives containing traversal, absolute paths, secret files,
   symlinks, hardlinks or FIFO entries fail before sourcing configuration.
9. Migration failure leaves current files/configuration untouched without restart.
10. Missing both cookie file and environment override fails before service mutation.
11. An environment-only cookie is preserved without generating a cookie file.
12. Each swap move failure keeps or recovers the original tree.
13. Restart failure recovers the original and checks its health.
14. Startup health failure recovers the original and checks its health.
15. Recovery health failure reports failure and retains private operator evidence.
16. Real stable destination locking extends through health checks; workspaces differ.
17. Separate destinations have independent locks.
18. Workflows build once, use the same named artifact, preserve test gates and
    destination concurrency, and execute the deployment tests in CI.

The nineteenth test requires a Ruby deployment helper and no Python deployment
scripts or tests. Workflow assertions now require Ruby setup and execution.
Three additional parser regressions require rejection of invalid tar header
checksums, truncated member data, and PAX/GNU metadata headers. Each uses an
otherwise valid release payload in a valid gzip stream with a newly computed
external checksum, so archive structure validation must reject the input before
configuration is sourced or services change.
Synthetic release and service-command stubs are Ruby; the no-op retry delay stub
is POSIX shell. All existing archive privacy, cookie continuity, file permissions,
dated state-transition ordering, corruption and lock assertions are retained.
