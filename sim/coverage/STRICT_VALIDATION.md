# Strict per-stage VDB validation

Run portable contract tests without Synopsys licenses:

    cd sim
    make coverage-merge-test

Merge existing collected databases in the licensed environment:

    cd sim
    make coverage-map-check
    make coverage-merge URG=urg SYNOPSYS_VERSION=V-2023.12-SP2-6

Use make coverage to clean/rebuild/recollect all coverage first.

Every input and every stage output must contain nonempty regular files.
Each stage is then reopened with URG using only that stage VDB (no inputs
or mapfile) and a separate full-hierarchy text/HTML verification report.
Only validated stages can become inputs to the next merge.

The report audit requires hierarchy.txt with NAME and LINE/COND/TOGGLE/FSM/
BRANCH columns (TGL and CONDITION aliases are supported). Exact full instance
paths must occur on metric rows, with numeric percentages or explicit N/A/--
values. Unknown report layouts fail closed and retain merge-work-* for
inspection; confirm the text layout on URG V-2023.12-SP2-6 before relying on
a licensed run. Zero percent is valid coverage, not a missing shape.
Top-level inputs require all five metrics. All DUT rows require line/toggle,
and FIFO requires every non-FSM metric. Every instrumented metric from the
previous stage or mapped source must remain available at its destination.

Warnings/errors/fatals and SHAPEMISMATCH fail even with exit status zero.
The sole missing-FSM candidate is an exact UCAPI-SNF diagnostic for the
tb_dma_data_fifo source VDB, during its input read or stage 03 mapping.
It is accepted only when independent source metrics show no FSM but complete
non-FSM metrics, and the output passes the canonical hierarchy/metric audit.
Missing, empty, unreadable, or incomplete stage databases always fail.

Successful output preserves input-audit.json, mapping-audit.json, mapfiles,
logs, and input/stage merge/stage verification reports under coverage/mapping.
On failure existing published merged.vdb/report/mapping remain untouched and
merge-work-* retains evidence. Files alone do not prove VDB validity.
Mapping records and report scores establish a checked read/hierarchy/metric
contract; they are not a bin-by-bin proof of contribution or a substitute for
licensed Synopsys validation. Portable stub tests do not emulate URG semantics.
