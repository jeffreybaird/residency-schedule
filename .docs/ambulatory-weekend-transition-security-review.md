# Ambulatory/weekend transition security review — October 13, 2026

Independent reviewer checks in the managed cloud environment:

- `source /workspace/.setup/activate.sh; mix hex.audit`: exit 0, “No retired or security advisory packages found.” Hex 2.5.2's `mix help hex.audit` explicitly documents both retirement and vulnerability advisory checks. Network permissions were needed for Mix's local PubSub socket. No advisory/retirement suppression or offline environment variables were set; no matching ignore configuration was found in `mix.exs`. The lock contains 51 Hex packages.
- Direct Python requests to OSV `/v1/querybatch` and the official Erlang/OTP advisory API failed with sandbox `EPERM`, then proxy `403 Forbidden` with network permissions. These independent feeds were unavailable; previous documents' downloaded snapshots were not treated as current data.
- `elixir -e` verified OTP 28 / ERTS 16.4.0.6, from the installed OTP 28.5.0.7 toolchain. Installed components: ssl 11.6.0.6; ssh 5.5.2.6; inets 9.6.2.3; snmp 5.20.2.2; eldap 1.2.16.1; asn1 5.4.3.1; public_key 1.20.3.5; megaco 4.8.3.2; stdlib 7.3.0.3; erl_interface 5.7.0.2; ftp 1.2.4.1.

The [previous runtime advisory table](qgenda-oct12-security-review.md#pre-existing-host-runtime-findings) documents 40 findings against a separate macOS OTP 29.0.1 runtime, including every advisory identifier, installed/affected version, patch version and exposure condition. The cloud component versions above meet the patched OTP 28 ranges in that table. Those findings are not established against the runtime used for this task. The previous host runtime has not been replaced or reverified; actual production runtime remains unverified. New OTP findings cannot be excluded because the current official feed was unavailable.

No compatible locked-dependency security upgrade is indicated by the successful current Hex audit. No npm manifest or lockfile exists in `assets`. Git/vendored assets, operating-system packages, undisclosed vulnerabilities and actual production runtime are outside this package audit. This review does not claim comprehensive application security.

Initial Bash audit baseline: 280 entries, 98 with `violations`, all 98 marked `attribution: ambiguous`; no exclusive violation. These pre-existing flags require attribution checks rather than assuming the flagged role made the edit. The last baseline timestamp was `2026-10-13T18:53:45+00:00`. Final task-specific changes and audit activation are reviewed separately.

Final source review repeated the current Hex advisory audit with the same command: exit 0, “No retired or security advisory packages found.” The dependency manifests and lockfile are unchanged. The audit log still has exactly the baseline 280 entries and 98 ambiguous flags, so current cloud Bash audit activation is unverified. Accepted test hashes and the final role-owned source/test diff were independently checked; no unowned task edit was established by the available evidence.
