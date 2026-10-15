# Coverage closure gap analysis — 2026-10-15

## Evidence baseline

Reviewed main commit `fed20cbe696c8a4daa105ba6a9364a88c46e42aa` (merge of PR #10).
PR head `5d4437c73447cdca5996d45f7d803d2aab5fbf40` had 16 successful check runs.
All eight workflow runs on the resulting main commit completed successfully,
including Coverage Merge CI, Coverage Preflight Python CI and Full Regression CI.

This is a source-based functional scenario gap analysis. No measured line,
condition, branch, toggle, or FSM gap is asserted here. The referenced conversation
lists a `coverage_review.tar.gz` attachment, but its bytes could not be read in
this session: local execution failed to start, and the elevated file-access
request was declined. The repository tree contains no checked-in coverage
report or VDB. No manually dispatched Actions runs were returned by the query
at review time. Licensed URG results and bin contribution remain unverified.

## Existing evidence and next increments

Paths below are relative to the repository root. A passing scenario does not
establish that every related branch, condition, or FSM transition was covered.

| Priority | Area | Existing stimulus/checks | Actionable next increment and acceptance |
| --- | --- | --- | --- |
| P1 | Source AR timeout | `sim/tb/tb_dma_read_engine.v` TEST3 covers R timeout/late drain; no dedicated AR timeout case found in the nine benches | Stall ARREADY beyond TIMEOUT_CYCLES, check one timeout event and stable ARVALID/address/length, then accept AR and drain the promised burst. Check no successful commit of failed data, obligation clears only after drain, and restart works. |
| P1 | Target W timeout | `sim/tb/tb_dma_write_engine.v` TEST3 covers AW timeout and late completion; no dedicated W timeout case found | Accept AW then stall WREADY while WVALID is asserted. Check timeout once, stable WDATA/WSTRB/WLAST under stall, late W completion, one reservation release and completion of the B obligation. Check no successful done event for the failed command. |
| P1 | Source missing RLAST | Read-engine TEST5 and integration error CASE6 exercise early RLAST | Send the expected final beat with RLAST low. Verify protocol error, no successful burst commit, reset-required behavior and coordinated reset recovery according to the RTL contract; check integrated status/IRQ/BUSY. |
| P1 | Timeout qualification | Existing R drain test deliberately disables FIFO ready after timeout; this does not test pre-timeout internal backpressure | Hold source FIFO readiness low before failure while presenting valid data; verify no inappropriate R timeout. Exercise target with no WVALID and verify W timeout is not charged. Inspect counter qualification before designing exact stimulus. |
| P2 | Error response encodings | Read/write unit tests and integration error CASE2/3 inject response `2'b10`; persistent RID/BID mismatch cases exercise timeouts | Add explicit EXOKAY (`01`) and DECERR (`11`) cases for both RRESP/BRESP. Verify specified error code, discard/release accounting, first-error retention, ordinary recovery and a subsequent successful command. |
| P2 | Length/partial strobes | `tb_axi_dma_ctrl_matrix.v` run_case lengths are 1, 10, 20 and 8 bytes; write unit TEST1 checks 10-byte WSTRB | Add 2, 3, 5, 6, 7, 9, 11 and 4096-byte transfers. Check exact beat count, WSTRB, WLAST, data, successful status/IRQ and completion within a length-aware guard. |
| P2 | Boundary planning and scoreboard | Integration matrix CASE6/7 split Source/Target separately; CASE8 wraps addresses. Model checks that bursts do not cross 4KB but does not compare every address to an independent expected sequence | Add different simultaneous Source/Target boundary positions. Independently predict each AR/AW address and length from remaining bytes, boundary and burst limit; assert progression, expected split count and final byte coverage. |
| P2 | Recovery/error ordering | Controller TEST3 checks simultaneous Source-over-Target priority; TEST4 checks protocol fault during recovery | Add ordinary errors on different cycles to prove first-error retention, with outstanding obligations drained. Add integration checks for final status/IRQ and coordinated reset after a later Source protocol fault. |
| P2 | Reset during obligations | Existing reset calls initialize cases; controller TEST4 checks reset after protocol fault | Add coordinated reset during AR/AW pending and R/W/B obligations. Check reset assertion/deassertion in both clock domains, no stale completion event and a fresh successful command after reset. |

Other existing directed evidence: FIFO TEST1–3 check commit/reserve/release,
rollback/reuse and concurrent commit/reserve; APB checks START blocking,
status clear, event/W1C priority and invalid reads; CDC checks coherent snapshot,
BUSY and acknowledged event transfer. These should remain regression requirements.

## First implementation slice

Extend the existing read-engine and write-engine benches with AR timeout/late
drain and W timeout/late READY, respectively. Keep their modules, DUT instance
paths and elaboration parameters unchanged. This reuses the existing nine-VDB
mapping and avoids introducing an unreviewed tenth source.

Each case needs bounded waits or a bench watchdog, handshake-based accounting,
and checks of the error pulse, outstanding obligation, stalled payload stability,
drain/release and subsequent recovery. Do not treat a printed case label or
PASS marker alone as evidence that the intended timeout path occurred.

Validate in order:

1. Run the two focused Icarus benches and full nine-bench regression.
2. Run `make coverage-map-check` and `make coverage-merge-test` from `sim`;
   require relevant CI to pass on the final PR commit.
3. On the licensed VCS/URG V-2023.12-SP2-6 environment run `make coverage`
   to rebuild/recollect all nine current VDBs, validate mapping and merge.
4. Compare the new report to a baseline with the same RTL, parameters, tool
   version, instrumentation and report scope. Record newly exercised exact
   instance/file/line/branch/condition/FSM points and remaining holes.
   No numerical uplift can be predicted from current evidence.

## Required measured-gap evidence

Inspect the supplied archive when it becomes readable before claiming closure.
Inventory its members and establish source commit, tool versions, collection
time and all nine test results. Determine whether it contains:

- Final dashboard and full hierarchy report scoped to
  `tb_axi_dma_ctrl_smoke.dut`, with per-module metric denominators.
- Per-instance source reports identifying uncovered lines, branch outcomes,
  condition terms, FSM states/transitions and toggle bits.
- `mapping/input-audit.json`, `mapping/mapping-audit.json`, exact mapfiles,
  input and stage logs/reports, and independent stage-reopen reports.
- Build/run logs and enough provenance to rule out mixed or stale VDBs.

If only hierarchy percentages are supplied, rank modules by metric deficit but
request detailed point reports before selecting exact uncovered RTL points.
For each measured gap record: canonical instance, RTL revision/path/location,
metric and point identity, hit/total, reachability, existing test evidence,
proposed stimulus/check, result and any justified exclusion rationale.
Do not invent point identities from hierarchy scores.

## Strict mapping invariants

Retain `sim/coverage/instances.json`, exact paths and all eight staged mappings.
Preserve independent reopen validation, required metric availability and
fail-closed unknown report layouts. Keep SHAPEMISMATCH and URG warnings/errors/
fatals fatal, with only the precisely validated FIFO missing-FSM exception
documented in `STRICT_VALIDATION.md`. Do not use wildcard/flexible mapping,
warning suppression or exclusions merely to raise percentages.

The mapping audit describes requested mappings and checked hierarchy/metrics;
it is not bin-by-bin contribution proof. Do not call coverage closed until the
licensed run and detailed uncovered-point review meet the verification plan:
line >=95%, condition/branch >=90%, FSM >=95%, reviewed toggles and justified
exclusions, plus all required functional scenarios.
