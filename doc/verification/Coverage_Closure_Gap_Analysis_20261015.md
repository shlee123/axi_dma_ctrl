# Coverage closure gap analysis — 2026-10-15

## Evidence baseline

Reviewed main commit `fed20cbe696c8a4daa105ba6a9364a88c46e42aa` (merge of PR #10).
PR head `5d4437c73447cdca5996d45f7d803d2aab5fbf40` had 16 successful check runs.
All eight workflow runs on the resulting main commit completed successfully,
including Coverage Merge CI, Coverage Preflight Python CI and Full Regression CI.

## Supplied licensed report baseline

The supplied archive is now readable. SHA256:
`66e5b15f846ab71ee40b48daad28003b6ebcd17b467cc2ebb8f611aba8a5f0b4`
(7,128,345 bytes). Its dashboard records URG V-2023.12-SP2-6 and
`Wed Oct 14 16:37:14 2026` (report timezone unspecified). The nested diagnostic
also records VCS V-2023.12-SP2-6, Python 3.6.8, nine readable inputs with URG
exit 0, no diagnostic-summary errors and three missing-FSM warnings.

`coverage/export/version.txt` identifies only branch
`fix/urg-strict-shape-20261014`, with no commit SHA or dirty-tree manifest.
The archive contains reports, mapping evidence and a nested diagnostic archive,
but no VDB or simulation build/run logs. Therefore these are supplied licensed
report results, not a reproduced run or proven measurement of the reviewed main
commit. Matching report snippets were checked against the repository RTL, but
that does not establish whole-build identity or all nine simulation PASS results.

Scope is `+tree tb_axi_dma_ctrl_smoke.dut`. Use hierarchy subtree coverage
rather than module-only top-wrapper coverage when assessing the integrated DUT.

| Canonical DUT subtree | Line % | Condition % | Toggle % | FSM transition % | Branch % |
| --- | ---: | ---: | ---: | ---: | ---: |
| Entire DUT | 93.65 | 80.82 | 59.88 | 74.42 | 85.71 |
| u_dma_read_engine | 90.26 | 68.24 | 59.64 | 62.50 | 76.74 |
| u_dma_ctrl | 91.67 | 86.57 | 65.71 | 81.82 | 77.78 |
| u_dma_write_engine | 96.15 | 85.71 | 51.86 | 81.25 | 91.11 |
| u_dma_apb_regs | 97.50 | 80.85 | 63.81 | N/A | 95.24 |
| u_dma_cdc | 100.00 | 86.96 | 66.91 | N/A | 100.00 |
| u_dma_data_fifo | 100.00 | 89.47 | 72.30 | N/A | 100.00 |
| Both reset synchronizers (each) | 100.00 | N/A | 100.00 | N/A | 100.00 |

The DUT is short of the verification-plan goals by 1.35 percentage points of
line, 9.18 of condition, 4.29 of branch and 20.58 of FSM transition coverage.
FSM scores here are transition coverage: read has 6/7 states but 10/16
transitions; controller 6/6 states and 9/11 transitions; write 7/7 states and
13/16 transitions. State coverage alone would conceal the remaining gaps.

### Exact actionable uncovered points

Locations refer to the source embedded in `coverage/report/modinfo.txt`.
Instance prefix is `tb_axi_dma_ctrl_smoke.dut.`; RTL paths are repository-relative.

| Priority / point | Report evidence | Next stimulus and required checks |
| --- | --- | --- |
| P1 R-AR | `u_dma_read_engine`, `rtl/dma_read_engine.v` lines 269–272: four uncovered timeout assignments in RD_AR_WAIT | Hold ARREADY low beyond the timeout, assert exactly one source timeout, preserve AR payload/VALID, then accept AR and drain the obligation without committing failed data. Check recovery and restart. |
| P1 R-LAST | Read lines 307–312 and 334–335; RD_FAULT_DRAIN state unhit, RD_R_DATA->RD_FAULT_DRAIN and RD_FAULT_DRAIN->RD_FINALIZE unhit | Omit expected final RLAST, then deliver extra matching-ID beats and a late RLAST. Check protocol error, discarded data, drain until RLAST and reset-required halt; no Target eligibility or false success. |
| P1 W-STALL | `u_dma_write_engine`, `rtl/dma_write_engine.v` lines 303–306 uncovered | Accept AW, stall WREADY with WVALID asserted through timeout. Check stable W payload, exactly one timeout, late W/B completion, exactly one reservation release and no successful done. |
| P1 C-RECOVERY | `u_dma_ctrl`, `rtl/dma_ctrl.v` lines 274, 276–280, 282; CTRL_RECOVERY->CTRL_PROTOCOL_FAULT unhit | Inject ordinary error while an obligation prevents recovery exit, then source protocol fault. Assert the controller is actually in recovery at injection, preserves first error/status/event, holds BUSY until reset and recovers after coordinated reset. |
| P2 APB-INTR | `u_dma_apb_regs`, `rtl/dma_apb_regs.v` line 99 and ADDR_INTR read branch unhit | Read interrupt register before event, after event and after W1C; compare pending bit and reserved zeros. This is a small direct coverage increment. |
| P2 R-ABORT | Read line 235 and RD_PLAN->RD_HALT transition unhit | Assert rd_abort_new in RD_PLAN before AR issue; check no new AR, halt and later restart. Observe actual state at stimulus. |
| P2 RESET | Read reset transitions from RD_AR_WAIT, RD_FAULT_DRAIN and RD_FINALIZE unhit; controller CTRL_RUN->CTRL_IDLE unhit; write WR_AW_WAIT/WR_RESERVE/WR_W_DATA->WR_IDLE unhit | Apply coordinated slave/DUT reset in each named phase, verify no stale completion, synchronous release in both domains and fresh successful command. |

Read line coverage is 139/154, controller 99/108, write 150/156 and APB 39/40.
The controller unit bench already labels a protocol-fault-during-recovery case,
yet this report leaves the transition unhit. Resolve by checking actual state/
pulse timing, mapped unit report and collection provenance; the case label is
not sufficient evidence of closure.

### Review separately from reachable runtime holes

- Wrapper `axi_dma_ctrl.v` lines 97, 102, 104, 106, 108, 110, 112 are seven
  uncovered illegal-parameter $fatal arms (wrapper line/branch 7/14). Verify
  them in separate expected-failure parameter tests; do not merge incompatible
  elaboration shapes into the canonical legal-profile VDB.
- Read line 155 and write line 139 are defensive zero-4KB-beat guards.
  Establish reachability for the legal aligned profile before writing tests or
  proposing narrowly justified exclusions.
- Default state arms (read 371, write 360, controller 311–312) need an illegal-
  state/fault-injection policy or an explicit reachability rationale. Do not
  force state values merely to increase the score.
- Toggle holes include varying data that can be exercised (e.g. source
  RDATA[15:3]) and profile constants (ID/sideband/size, aligned address bits,
  burst-length high bits with MAX_BURST_LENGTH=4). Use varied checked data for
  the former; justify constants per signal/profile. Do not disable strict
  shape checking to combine different parameter profiles.

### Mapping evidence reviewed

The archive contains nine input-audit entries and all eight expected exact
source/destination mapfiles, merge logs, independent verification logs and
verification hierarchy/dashboard/detail reports. Every stage verification
dashboard records a single stage-NN.vdb input and no mapfile. No previously
numeric metric becomes unavailable in the audit chain, and no audited
percentage decreases. The final audited DUT metrics agree with the final
hierarchy report. These are consistency checks on supplied evidence, not an
independent reopening of a VDB or bin-by-bin contribution proof.

Six warning-bearing mapping logs were found: FIFO, CDC and APB input reads and
their stages 03, 07 and 08. Each is the UCAPI-SNF missing-FSM warning. The audits
classify those stages validated-no-fsm and show source FSM N/A with all four
non-FSM metrics present; independent stage verification logs have no such
warning. No other Warning-/Error-/Fatal/SHAPEMISMATCH diagnostic was found in
the mapping logs scanned. The source merger explicitly allows these three
named FSM-free units under path-specific and metric-validation conditions.
Earlier FIFO-only wording in this analysis and STRICT_VALIDATION.md was stale.

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

## Evidence still needed for sign-off

Record the exact source commit and dirty-tree/build manifest, all nine compile/
simulation results, instrumentation/parameter profile, and collection time/
timezone with the next licensed run. Preserve the raw VDBs if independent
reopening or bin contribution investigation is needed. The supplied reports
already contain detailed line, branch, condition, FSM and toggle information;
a second request for those same reports is unnecessary.

For each increment record canonical instance, RTL revision/path/location,
metric point identity, hit/total before and after, stimulus/checks and remaining
reachability/exclusion rationale. Recollect all nine databases after modifying
instrumented RTL or elaboration, and compare only compatible baselines.

## Strict mapping invariants

Retain `sim/coverage/instances.json`, exact paths and all eight staged mappings.
Preserve independent reopen validation, required metric availability and
fail-closed unknown report layouts. Keep SHAPEMISMATCH and URG warnings/errors/
fatals fatal, with only the precisely validated missing-FSM exceptions for FIFO, CDC and APB
source VDBs documented in `STRICT_VALIDATION.md`. Do not use wildcard/flexible mapping,
warning suppression or exclusions merely to raise percentages.

The mapping audit describes requested mappings and checked hierarchy/metrics;
it is not bin-by-bin contribution proof. Do not call coverage closed until the
licensed run and detailed uncovered-point review meet the verification plan:
line >=95%, condition/branch >=90%, FSM >=95%, reviewed toggles and justified
exclusions, plus all required functional scenarios.
