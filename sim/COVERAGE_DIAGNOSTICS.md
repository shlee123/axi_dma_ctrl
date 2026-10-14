# Coverage preflight and one-shot diagnostics

Requirements on the EDA host: Python 3.6+, VCS/URG V-2023.12-SP2-6, existing nine `sim/coverage/vdb/*.vdb` inputs.

Run from `sim/`:

```sh
make coverage-preflight
make coverage-diagnose
make coverage-merge
```

`coverage-preflight` validates mapping paths, installed tool version strings, all nine VDB directories, URG readability, and produces reports for all patterns before attempting merge. Missing FSM shapes are flagged for review rather than silently accepted. Unexpected URG diagnostics cause preflight failure.

`coverage-diagnose` scans all nine patterns even after one fails and writes `sim/coverage/coverage_diagnostic.tar.gz` with `summary.json`, per-pattern URG logs and `hierarchy.txt` evidence. Inspect archive for confidential paths before sharing outside your organization. The archive is diagnostic evidence, **not** proof of successful strict merge.

GitHub Actions runs parser unit tests and static mapping validation without licensed EDA tools. **Passing GitHub CI does not prove that URG merge succeeded on your EDA host.** `make coverage-merge` still runs strict stage VDB validation and rejects shape mismatches.

If `make coverage-preflight` flags FSM shape missing, verify the hierarchy report lists FSM as N/A on the affected unit. Only an object with no instrumentable FSM can legitimately be N/A; a mismatched FSM is not acceptable.

Note: the historical strict merge script may retain special-case FSM allowances for selected units until verified general classification is implemented. Do not treat the preflight as overriding strict merge validation.
