# Prepared schedule cache

The schedule grid reuses immutable prepared schedules, date slots, unified
resident rows, and grouped cells across requests. This also reuses the expensive
rotation projection needed to prepare that grid. Admin uploads and committed
admin shift changes invalidate the shared result. Calendar data has a different
range-dependent shape and is not cached by this change.

Cache keys include a calculation version, the dynamic repository, a committed
database revision, and the current date. Sockets, current users, authorization,
filters, modal state, and other request-specific assignments stay outside the
shared value. A supervised GenServer holds the bounded in-memory cache. The first request after an upload or application restart rebuilds
the grid; subsequent requests reuse it. Concurrent misses share a builder.

## Invalidation and consistency

A database migration installs statement-level revision triggers on the tables
that supply the prepared grid: `schedules`, `residents`, `schedule_residents`,
`rotations`, `shift_overrides`, `detailed_activities`, and
`detailed_activity_sources`. Revision changes are transactional: rollback
leaves the committed revision unchanged. This covers imports as well as existing
edits, deletions, overrides, and source display-name changes. Every application
node reads the database revision before lookup, so correctness does not depend
on delivery of an invalidation message between nodes.

The builder runs in the requesting process, retaining its repository and tracing
context. Shared-cache builds use read-only repeatable-read transactions for a
coherent database snapshot; Ecto runs transaction preloads serially. It checks the revision again before publishing; a concurrent committed
change discards the old result instead of publishing it under a new revision.
The cache retains at most four completed entries and coordinates at most four
distinct in-flight keys with 64 waiters per key. Excess requests fall back to
uncached coherent builds; these limits bound cache state, not overall request
concurrency. Normal same-key misses share one builder. After three revision
retries, an uncached read-only repeatable-read transaction supplies a coherent
snapshot under sustained writes. Fallback results are not published. Cold builds retain the existing
operation phase traces; warm reads avoid the projection and cell-building work.

Revision locking precedes existing row locks in mutation transactions. Future
mutation entrypoints that take explicit row locks must acquire the revision lock
first to preserve that ordering. Standalone read-only operations need no revision
lock. Ordinary database writes are covered by the statement triggers. The
singleton revision serializes relevant mutation transactions; imports are
infrequent, but concurrent administrative writes may wait for each other.

Cache coordination has bounded retries if elected builders die. A dead waiter
can occupy a waiter slot until that build terminates; overload falls back to an
uncached coherent build rather than growing the coordinator without a bound.

## Test isolation

The shared cache is bypassed for SQL Sandbox repositories and explicit application
transactions. Existing sandbox fixture transactions set a transaction-local
revision-suppression flag in test setup only, preventing unrelated asynchronous
tests from holding the singleton revision lock for their entire lifetime. No
production application configuration or request input sets this flag.

Dedicated cache/revision integration tests and the performance benchmark use an
ordinary connection pool with triggers active. They verify actual commit and
rollback visibility, concurrent builds and writes, and cache reuse. Synthetic
data is cleaned up; benchmarks must never run against production data.
