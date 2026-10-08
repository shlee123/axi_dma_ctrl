# VCS Coverage

Per-test VCS coverage databases are written to:

```text
sim/coverage/vdb/<test>.vdb
```

Run the complete VCS regression and retain/update the per-test VDBs:

```bash
cd sim
make coverage-run
```

Clean old coverage, run all nine patterns, and merge in one command:

```bash
make coverage
```

Check that all six unit-level and three top-level databases exist:

```bash
make coverage-check
```

Preview the generated hierarchy map and exact URG command without invoking a
licensed tool:

```bash
make coverage-dry-run
```

Merge all current databases with URG instance mapping:

```bash
make coverage-merge
```

The merge invokes `urg` and creates:

- `coverage/merged.vdb`
- `coverage/report/`
- `coverage/axi_dma_ctrl.map`

The default merge uses `tb_axi_dma_ctrl_smoke.dut` as the canonical hierarchy.
The other two top-level testbench DUTs are mapped to it, and the six unit-test
`dut` instances are mapped to the matching instances below the canonical DUT.
This avoids treating unit-level and top-level VDBs as identical hierarchies.

The flow checks both VCS and URG for `V-2023.12-SP2-6`. Override only when
intentionally validating another installed release:

```bash
make coverage \
  VCS_EXPECTED_VERSION=<installed-version> \
  URG_EXPECTED_VERSION=<installed-version>
```

An optional Verdi exclusion file can be applied during merge:

```bash
make coverage-merge COV_ELFILE=/path/to/exclusions.el
```

Open the merged database in Verdi:

```bash
make coverage-verdi
```

Default code-coverage metrics are:

```text
line+cond+fsm+tgl+branch
```

Override when needed:

```bash
make SIMULATOR=vcs VCS_CM=line+cond+fsm+tgl+branch regression
```

When a new pattern is added, rerun that pattern and then rerun `make coverage-merge`. If RTL has changed materially, regenerate all per-test VDBs rather than mixing stale and current coverage databases.
