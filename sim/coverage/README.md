# Integrated VCS Coverage

Supported deployment target: VCS/URG V-2023.12-SP2-6. The portable CI checks
mapping paths and orchestration; actual URG compatibility and coverage scores
must be verified with the installed Synopsys tools.

## Run

From sim, using VDBs collected from the same RTL revision and tool environment:

```bash
make coverage-map-check
make coverage-merge
```

For a fresh collection:

```bash
make coverage-clean
make SIMULATOR=vcs regression
make coverage-merge
```

Python 3 and urg must be in PATH. All nine configured test databases under
coverage/vdb are required. Unlisted VDBs are not merged. Do not mix stale RTL
coverage with the current run.

Outputs:

- coverage/merged.vdb: one final database
- coverage/report/dashboard.html: HTML report
- coverage/report/hierarchy.txt and hierarchy.html: hierarchy reports (URG output)
- coverage/mapping/: exact mapfiles, URG logs, report scope, mapping-audit.json

## Instance mapping

The base design is tb_axi_dma_ctrl_smoke.dut. Each of the other two top-level
DUTs maps its axi_dma_ctrl subtree into this base. Six unit DUTs then map
to their corresponding u_dma_* instances. instances.json is the reviewed
source of test names, module types, and instance paths.

The driver merges sequentially with the canonical database first in every
URG -dir pair and an explicit -mapfile for each source. No wildcard instance
mapping or flexible shape merge is used. The final report scopes coverage to
the canonical DUT subtree, including its reset synchronizers, rather than
testbench stimulus code.

Unit and integration tests use different burst/timeout/FIFO parameter values.
A source-path match does not prove that their instrumented coverage shapes are
compatible. URG diagnostics are treated as failures, even if URG returns zero.
Do not suppress such warnings to obtain a higher coverage score; first inspect
the diagnostic and align incompatible instrumentation or parameter profiles.

## Validation and diagnostics

coverage-map-check verifies module and instance declarations in source.
The Coverage Merge CI additionally elaborates source and destination paths with
Icarus and runs deterministic merge-contract tests. These tests substitute URG;
they do not prove bin merging or measure RTL coverage.

In a real merge, all eight mapping operations must finish without URG
warnings/errors, the final VDB and dashboard must exist, and the full-hierarchy
report must contain the canonical top, DUT, and all six destination instances.
The mapping audit records requested mappings, not bin-level contribution.
Review mapping/*.log and the report in URG/Verdi to confirm contributions and
coverage holes. Hierarchy token checks cannot prove parameter-shape equivalence.

On failure, existing merged.vdb and report are preserved and merge-work-*/
contains the failed stage's mapfile/log. Successful merges remove intermediate
databases and retain mapping evidence.

## GitHub Actions

Coverage Merge CI runs portable checks on every relevant PR.
Full Regression CI continues running all nine Icarus testbenches.

Synopsys Coverage is a manually dispatched workflow for a trusted Linux
self-hosted runner. Install VCS/URG, Python 3, FSDB support, and configure the
Synopsys license/environment for the runner service. Supply its additional
runner label (default: synopsys). The workflow collects fresh VDBs, merges
them, and uploads the final database, report, and diagnostics as an artifact.
It is not automatically enabled for PRs, and no licensed run is claimed merely
because the portable CI is green.
