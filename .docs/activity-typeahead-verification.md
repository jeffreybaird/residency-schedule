# Activity-label typeahead verification

Authoritative runner evidence, 2026-10-03. No source or test edits by the runner.
No production or development data writes.

## Accepted red

The initial native-datalist implementation passed server tests but failed the
parent's in-app browser interaction check: with LiveView connected, arrow and
Enter interaction did not expose selectable choices. The user-authorized
replacement is an explicit combobox/listbox with a small keyboard/focus hook.
The native implementation and its UI contract were superseded.

`MIX_ENV=test mix test test/residency_schedule/contexts/activity_suggestions_test.exs test/residency_schedule_web/live/activity_typeahead_test.exs`
exited 2: **8 tests, 8 failures**. The runner inspected every failure: five were
missing `DetailedSchedules.activity_suggestions/1`; three were missing input
`list` linkage or datalist options. Fixture setup succeeded. The reviewer
accepted the exact contract before source implementation.

For the revised combobox, the renewed LiveView contract failed **5 tests out of
5** because combobox selectors and event handlers were absent. The initial Node
hook contract failed **3 tests out of 3** because its module did not exist.
Each failure was inspected and was not a fixture error. A separately accepted
pointer-focus regression failed **1 test out of 1** because the pointerdown
listener was absent, before its fix.

Actual browser pointer selection then exposed a separate payload collision:
the native button's empty `value` overwrote `phx-value-value`. A new accepted
LiveView regression injected that actual browser metadata and failed **1 test
out of 1** with "expected ... to patch, but got none." The source fix uses a
dedicated `label` field; stale/forged-option assertions were retained with the
updated event key.

## Final green

- Revised context/combobox targeted checks exited 0: **10 tests, 0 failures**.
- `MIX_ENV=test mix test`, normal parallelism (`max_cases: 16`), exited 0:
  **187 doctests, 1,406 tests, 0 failures**, seed 868703, 40.5 seconds.
- `node --test test/assets/*.test.js`: exit 0, **24 tests, 0 failures**, including
  keyboard handling, composition, selected-input updates, pointer focus, listener
  cleanup, and existing theme/palette checks. The existing headless Chrome test
  required running outside the sandbox; the first sandboxed run could not
  successfully launch that browser check. No assertion was changed to pass it.
- `MIX_ENV=test mix format --check-formatted`: exit 0.
- `MIX_ENV=test mix compile --warnings-as-errors`: exit 0.
- `MIX_ENV=test mix deps.unlock --check-unused`: exit 0.
- `MIX_ENV=test mix credo --strict`: exit 0; 259 files,
  2,143 modules/functions, no issues.

Accepted final SHA-256 hashes remained unchanged:

```text
38c52c1fe82f64718c689baf8dedf8e2fdd31dcdd198655b1dba7d89bd314391  test/residency_schedule/contexts/activity_suggestions_test.exs
d46108e723acf9ed14aeea73bade3215f44b1fc68c49a9e0cb0ca585c7f9928d  test/residency_schedule_web/live/activity_typeahead_test.exs
255661448479c6adedaf92874f3abf010cf5b94624b01bf2b334886f006a5fa9  test/residency_schedule_web/live/activity_typeahead_pointer_test.exs
025d1b28f6a4a5ed5edacac06e1af90b529b9004b389b3ab6785f0572a1185a6  test/assets/activity_typeahead.test.js
ad715dd111032206792103861aae80d7b77bd10480b66975362e068fd3216370  test/assets/activity_typeahead_pointer.test.js
```

## Browser verification scope

The runner prepared an isolated browser-check server on localhost port 4011,
using synthetic fixtures and a separate `_typeahead_browser` test database.
The existing application server was left untouched. Initial testing on
`127.0.0.1` encountered a Phoenix origin mismatch; using the configured
`localhost` host restored LiveView connectivity before the native-datalist
limitation was assessed. The parent agent performs final explicit-combobox
browser interaction separately; passing server/hook tests alone does not
establish end-to-end browser behavior.

The parent completed actual in-app browser verification on final assets and
compiled LiveView code, using synthetic data, on 2026-10-03 (America/New_York):

- Two matching options were visibly rendered.
- Mouse selection of the AM option populated the full label, updated the URL
  at page 1, returned two AM records, closed the list, and retained input focus.
- Escape closed the expanded list without changing the typed `clinic` query.
- Down, Down, Enter selected the PM option, populated the full label, updated
  the URL at page 1, returned one PM record with its notes, closed the list, and
  retained input focus.

The parent closed the QA tab and authorized shutdown. The runner stopped the
isolated server cleanly; the synthetic-only QA database was retained. The
existing app server was not interrupted.

See [security review](qgenda-security-review.md) for dependency and existing
runtime findings. Functional green is not a clean-runtime security claim.
