# VCS Coverage

Per-test VCS coverage databases are written to:

```text
sim/coverage/vdb/<test>.vdb
```

Run the complete VCS regression:

```bash
cd sim
make SIMULATOR=vcs regression
```

Merge all current databases:

```bash
make coverage-merge
```

The merge invokes `urg` and creates:

- `coverage/merged.vdb`
- `coverage/report/`

Default code-coverage metrics are:

```text
line+cond+fsm+tgl+branch
```

Override when needed:

```bash
make SIMULATOR=vcs VCS_CM=line+cond+fsm+tgl+branch regression
```

When a new pattern is added, rerun that pattern and then rerun `make coverage-merge`. If RTL has changed materially, regenerate all per-test VDBs rather than mixing stale and current coverage databases.
