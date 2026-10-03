# Dark mode verification — October 2, 2026

Dark mode now resolves system preference before paint, follows operating-system changes in system mode, preserves manual choices across reloads and tabs, and tolerates unavailable storage. Accessible theme controls appear in the app header. Dark surfaces, foregrounds, forms, navigation, dialogs, semantic statuses, chat, and guided tours have explicit dark styling. Existing light classes and rotation color definitions are preserved.

## Workflow and automated evidence

Separate spec writer, runner, implementer, and independent reviewer followed the repository workflow. The runner demonstrated failures before implementation; the reviewer accepted the contracts. Supplemental tour and hook regressions used original source inputs without reverting shared working files. Test harness corrections disabled fixture animations for stable color measurements and corrected whole-document descendant selection; assertions were preserved and reaccepted.

Red evidence:

- `node --test test/assets/theme.test.js`: final baseline 15 tests, 3 passed, 12 failed. Failures included system resolution, storage handling, listener lifecycle, and selected controls.
- `node --test test/assets/palette.test.js`: failed actual computed dark surface and foreground checks against compiled CSS and class strings extracted from app templates.
- `mix test test/residency_schedule_web/components/theme_controls_test.exs`: failed missing accessible header controls.
- `APP_JS_UNDER_TEST=/tmp/dark-mode-original-app-js.txt node --test test/assets/theme_hooks.test.js`: 4 tests, 4 failures against the original hook implementation.
- Original tour input produced `.shepherd-text em: unreadable dark foreground`.

Final green evidence:

- `mix assets.build`: passed.
- `node --test test/assets/*.test.js`: **20 tests, 0 failures**. Includes headless Chrome computed colors and contrast for actual template classes, semantic panels, native inputs/selects, fixed rotation badges, chat code, and tour hints/buttons; JavaScript preference and hook transitions.
- `mix test test/residency_schedule_web/components/theme_controls_test.exs`: **1 test, 0 failures**.
- `MIX_ENV=test mix test $(git ls-files 'test/**/*_test.exs' 'test/*_test.exs') test/residency_schedule_web/components/theme_controls_test.exs`: **171 doctests, 1205 tests, 0 failures**, seed `276167`. Includes all tracked tests and the new controls test.
- Compilation with warnings as errors, read-only formatting of task-owned paths, scoped strict Credo (242 files, 69 checks), and `git diff --check`: passed. Source owner ran `mix format --force` on owned source paths; test owner formatted owned Elixir tests.
- Runner and reviewer independently confirmed all four final accepted test hashes. No accepted assertions were weakened.

| Accepted test | SHA-256 |
| --- | --- |
| `test/assets/theme.test.js` | `f735c80c06ca5bb503ee5146c9822e1e08e54c34303f01eaa4155f386dcfd51c` |
| `test/assets/palette.test.js` | `1861800e047d78c10b6e3d07c6d68774e50885a7bc2c8b0563ae5082441e1bbf` |
| `test/assets/theme_hooks.test.js` | `4145b7c1a01436acc8cf3f9b653563a8767481866311168f35326a37e8c26095` |
| `test/residency_schedule_web/components/theme_controls_test.exs` | `48d4e81ae3251ce5093b30db40f26c16c2838594fcb1e3da3401301456709314` |

## Visual and independent review

Parent inspected dark login, schedule, and calendar in the local preview, including a smaller viewport, navigation/reload preference persistence, and full-viewport background continuity. The calendar screenshot is `/private/tmp/residency-dark-calendar.png`. Broader template palette coverage comes from automated computed-style checks; exhaustive interactive visual testing of every screen was not performed.

Independent review verified that non-layout Elixir/template edits add dark variants and formatting while preserving light tokens and application logic. Rotation colors remain unchanged. Review findings on tour hint/button contrast, dynamic class lifecycles, and default dark grid borders were addressed. Audit entries showed no exclusive role-ownership violations; ambiguous overlaps matched concurrent authorized role edits. Audit logging was observed during the session, without claiming exhaustive coverage.

## Current security advisory review

`mix hex.audit` passed with no retired packages; it checks retirement, not vulnerabilities. The reviewer queried current OSV advisory data for all 48 locked Hex versions and found three pre-existing advisories. Compatible upgrades resolved them:

| Advisory | Installed → updated | Patched versions and exposure |
| --- | --- | --- |
| [GHSA-8rqp-v692-v82q / CVE-2026-92106](https://github.com/dashbitco/lazy_html/security/advisories/GHSA-8rqp-v692-v82q) | `lazy_html` 0.1.10 → 0.1.13 | Fixed 0.1.13. Mutation XSS when untrusted SVG/MathML is parsed, filtered, and serialized. Dependency is test-only; no production sanitizer use observed. |
| [GHSA-36m4-rm57-3prf / CVE-2026-64941](https://github.com/phoenixframework/phoenix_live_view/security/advisories/GHSA-36m4-rm57-3prf) | `phoenix_live_view` 1.1.26 → 1.1.33 | Fixed 1.0.19, 1.1.33, 1.2.9. Open redirect through untrusted redirect targets containing ASCII TAB/LF/CR. Current socket redirects use fixed `/` or `/login`; affected input path not observed. |
| [GHSA-754j-98wh-57rf / CVE-2026-54893](https://github.com/swoosh/swoosh/security/advisories/GHSA-754j-98wh-57rf) | `swoosh` 1.23.0 → 1.28.1 | Fixed 1.26.3. Microsoft Graph URL path injection through an untrusted sender. App uses Local/Test/Resend, not MsGraph. |

Final current OSV scan: **48 locked Hex packages, zero advisory matches**. Confirmed vendored Shepherd 13.0.3, topbar 3.0.0, and DaisyUI 5.0.35 also returned zero matches. Unversioned embedded/transitive vendor components and unpublished vulnerabilities remain outside this evidence. Raw scan evidence: `/tmp/dark-mode-osv-final.json`.

## Concurrent-work limitations

Unrelated untracked rotation-support tests appeared during this work and were preserved. Unscoped `mix test` fails at `test/residency_schedule/rotation_support_test.exs:13` with `** (Kernel.TypespecError) ... invalid type specification: type`. Global formatting flags that file's line 119; global Credo reports three readability findings in it and `rotation_support_integration_test.exs`. These files were excluded from the scoped verification above and were not edited by the dark-mode roles.

No deployment or commit was performed.
