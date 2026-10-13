# Schedule date-window verification

## Scope and baseline

Verification uses only synthetic fixture data in the disposable local PostgreSQL database `residency_schedule_cache_bench_window`. The fixture contains four academic years, 128 schedule-resident links, 10,404 rotations, and 11,680 detailed activities. Before windowing, the prepared grid contains 56 rows, 611 date columns, and 13,437 merged cells.

The baseline invokes Phoenix's actual `Renderer.to_rendered/2` and `Diff.render/4`, preserving fingerprints between subsequent updates and clearing changed assigns. JSON encoding is measured separately. Initial connected diffs are **5,259,726 bytes uncompressed** in all three baseline runs. Render durations were 1,218.909, 269.220, and 359.268 ms; process reductions ranged from 8.95 million to 12.18 million. Separate JSON encoding took 991.568, 955.590, and 286.510 ms. Host contention and garbage collection produced substantial timing variation; payload size and structural counts are more reproducible than these timings.

Evidence: `/tmp/schedule-window-before.log`; reproducible runner artifact `/tmp/schedule-render-diff.exs`.

## Authoritative red

Commands, before source implementation:

```sh
MIX_ENV=test mix test test/residency_schedule/schedule_window_test.exs test/residency_schedule_web/live/schedule_window_test.exs test/residency_schedule_web/render_diagnostics_test.exs --seed 0
node --test test/assets/schedule_window.test.js test/assets/browser_latency.test.js
```

- Elixir: exit 2; 20 tests, 19 failures. Failures concern missing window APIs, events, assigns, and the newly required render diagnostic flags/count API. No unrelated baseline failure was identified.
- Node: exit 1; 16 tests, 10 passes, 6 failures. Five tests require the absent window hook; one exercises the new control-acknowledgment behavior. Existing browser latency cases pass.
- Logs: `/tmp/schedule-window-red-final.log` and `/tmp/schedule-window-red-node-final.log`.

The reviewer accepted the final modal fixture correction, which supplies a valid last-window first/start index without changing the expected eviction and restoration behavior.

## Accepted test contract

SHA-256 snapshot before implementation:

```text
1e4e4d16b47db38636d33a4570505578bfc15da83e1d5f6da554f024b98dfd9e  test/assets/browser_latency.test.js
b8159d920f26f5ea3405e64286019efae617820cfcc69bb5bf215a03d7371a8f  test/assets/schedule_window.test.js
6ad6f4da85c512af7c29016f18a9a1985c00cbdd0608a61966a979222cc21487  test/residency_schedule/schedule_window_test.exs
5cfb65e685e95b75d2525f692bab7e90b9daf1a87c0f357c183e8ce4ea62961b  test/residency_schedule_web/live/schedule_window_test.exs
2a50322e2f7e385b947c61a74da5deefbf276fd61446741a1d49c84f0f7264a5  test/residency_schedule_web/live/schedule_render_updates_test.exs
6bd5d2be64155a0789de5555fec14b1f097d27eef81245f3fd5838c615c6e914  test/residency_schedule_web/operation_tracing_test.exs
de9b9dd9dd07ebd72411089695da50c2cf90f3fabe3844f5b39a45f866f9828b  test/residency_schedule_web/render_diagnostics_test.exs
```

Snapshot artifact: `/tmp/schedule-window-accepted.sha256`.

## Authoritative green

- Full suite: `MIX_ENV=test mix test --seed 238741` — exit 0; **214 doctests, 1,636 tests, zero failures**. Log: `/tmp/schedule-window-green-full.log`.
- Focused window, render-update and telemetry contracts: **2 doctests, 39 tests, zero failures**. Log: `/tmp/schedule-window-green-focused-final.log`.
- All asset tests: `node --test test/assets/*.test.js` — exit 0; **38 tests, zero failures**. Log: `/tmp/schedule-window-green-node-final.log`. This includes the real Chrome neutral-color/contrast check; native execution was necessary because the process sandbox prevented Chrome startup in the first attempt.
- `mix compile --warnings-as-errors`, `mix format --check-formatted`, `mix deps.unlock --check-unused`: all exit 0. Logs: `/tmp/schedule-window-green-{compile,format,deps}.log`.
- `mix credo --strict`: exit 0; **301 files, 2,482 modules/functions, no issues**. Log: `/tmp/schedule-window-green-credo.log`.
- `mix assets.build`: exit 0, rebuilt after the hook initialization-order correction. Log: `/tmp/schedule-window-assets-final.log`.

Additional reviewed regressions cover oversized viewport acknowledgment without a request loop, deferred focus after materialization, and restoring the original cohort/window when a modal closes after changing years under an R-level filter. The theme fixture's hook-factory extraction was updated without changing its style assertions. These changes received renewed reviewer acceptance.

Final accepted hashes:

```text
1e4e4d16b47db38636d33a4570505578bfc15da83e1d5f6da554f024b98dfd9e  test/assets/browser_latency.test.js
1c9a7f36045817cd5aa7ec121d2a351f5cf054541029f6962f54d195384845b6  test/assets/schedule_window.test.js
42e398a7816711f894492f67eb639eca639c4a9eac435facaecac2dd7b156261  test/assets/theme_hooks.test.js
84e20bd15e85dc2dfce761e91b95f1fa72f9e53903d872e951348fab1c624f7f  test/residency_schedule/schedule_window_test.exs
d9dfb902103902b663363b978bdfad205f687b695473e388ae6b6ab73e1f394e  test/residency_schedule_web/live/schedule_window_test.exs
2a50322e2f7e385b947c61a74da5deefbf276fd61446741a1d49c84f0f7264a5  test/residency_schedule_web/live/schedule_render_updates_test.exs
6bd5d2be64155a0789de5555fec14b1f097d27eef81245f3fd5838c615c6e914  test/residency_schedule_web/operation_tracing_test.exs
de9b9dd9dd07ebd72411089695da50c2cf90f3fabe3844f5b39a45f866f9828b  test/residency_schedule_web/render_diagnostics_test.exs
```

## Comparable connected-render measurements

The after measurement uses the same database rows and the same Phoenix renderer/diff entry points as the baseline. It does not use `HTML.Safe.to_iodata` as a substitute for connected rendering. JSON byte counts exclude transport envelopes and compression; they are not network transfer measurements.

| Measurement | Before | After |
|---|---:|---:|
| Available date columns | 611 | 611 |
| Initially materialized columns | 611 | 40 |
| Initially materialized merged cells | 13,437 | 901 |
| Initial uncompressed diff | 5,259,726 bytes | 467,358 bytes |
| Initial render, three runs | 1,218.909 / 269.220 / 359.268 ms | 137.301 / 8.777 / 3.117 ms |
| Initial process reductions, three runs | 12,181,292 / 9,292,165 / 8,948,732 | 1,177,119 / 759,667 / 738,035 |

The initial diff shrank **91.1%**. Timing comparisons are illustrative only: VM warm-up, garbage collection and host contention vary markedly. The fixed fixture, materialization bounds and byte counts provide the stronger evidence.

Subsequent actual diff measurements:

- 64-column windows at the start, middle and end: 505,912–578,250 bytes, with 1,402–1,461 clipped cells.
- 128-column window: 1,051,149 bytes and 2,899 clipped cells.
- Unchanged render: 2 bytes.
- Modal open: 2,461 bytes; modal close: 8 bytes.
- No SQL queries occurred within these measured render intervals.

Evidence: `/tmp/schedule-window-after.log`; runner artifact `/tmp/schedule-window-after.exs`.

The committed fixture/profile entry point remains available for reproduction:

```sh
createdb -h localhost -U postgres residency_schedule_cache_bench_reproduce
SCHEDULE_BENCHMARK_DATABASE=residency_schedule_cache_bench_reproduce MIX_ENV=test mix run --no-start test/support/benchmarks/render_diagnostics.exs
dropdb -h localhost -U postgres residency_schedule_cache_bench_reproduce
```

This script seeds the same four-year synthetic fixture and invokes the current windowed template through the real renderer/diff pipeline. Remove the disposable database even if the command fails. The `/tmp` runner artifact adds the explicit 64/128-column updates and modal measurements shown above; no new benchmark framework was introduced.

## Real browser verification

The parent independently controls the browser; the runner does not manipulate its viewport. The server binds only to `127.0.0.1:4417`, uses the disposable synthetic database, and serves rebuilt assets. Browser authentication uses a synthetic administrator account; no production or development database is accessed.

Parent-reported desktop checks at 1280 pixels:

- Initial 40 rendered headers measured exactly 80 pixels each.
- Full scroll width remains 49,028 pixels: 148-pixel name column plus 611 × 80-pixel date columns.
- Initial scroll position 40,320 keeps today visible; sticky names and date labels are readable.
- Year-pill navigation materializes the target year with correct dates and start/scroll position.
- Modal open/close restores the exact original opener focus and scroll position.
- Calendar → Schedule connected navigation remounts with 32 materialized headers and preserves full geometry.
- No new JavaScript bundle errors after the final rebuild.

Parent-reported mobile and ultrawide checks:

- At 390 × 844 pixels, page width remains 390 pixels with no outer horizontal overflow; the sticky name column remains 148 pixels wide.
- A mobile boundary scroll materializes start 525/count 21 at scrollLeft 42,660, shows the expected December dates, and does not reset the scroll position.
- Resizing to 3840 × 1080 materializes 64 columns, each 80 pixels wide. Full table width remains 49,028 pixels, page width is 3840, and scrollLeft 36,320 is preserved.
- No new console errors were observed with the final assets.

Screenshot artifacts: [desktop](/tmp/schedule-window-desktop.jpg) and [mobile](/tmp/schedule-window-mobile.jpg). These show the synthetic fixture, not real resident data.

Browser review is complete. The runner stopped the localhost server and dropped `residency_schedule_cache_bench_window` successfully after the final desktop/mobile/ultrawide checks.

