# AXI2AXI DMA Verification Plan

Version: v0.1
Date: 2026-10-05
Reference: AXI2AXI_DMA_Specification_v0.2

## 1. Verification Goals

The regression must prove:

1. APB programming and software-visible status/IRQ behavior.
2. Coherent START/configuration CDC between PCLK and AXI_CLK.
3. Source AXI read burst planning and protocol handling.
4. Burst-success qualification before data becomes Target-eligible.
5. FIFO unverified/verified/reserved/free lifecycle.
6. Target reservation-before-AW and W/B completion behavior.
7. 4KB boundary splitting independently on Source and Target.
8. Single/burst combinations.
9. Partial final beat WSTRB generation.
10. Timeout behavior for AR/R/AW/W/B phases.
11. RID/BID mismatch behavior.
12. First-error-wins and Source-over-Target same-cycle priority.
13. Reset-required Source protocol fault.
14. Ordinary error recovery and preservation of existing AXI obligations.
15. Parameter legality.

## 2. Regression Classes

### BASIC
- 1 beat
- exact full beat
- multiple beats
- multiple bursts
- minimum length = 1 byte
- maximum length = 4096 bytes

### SINGLE / BURST
- Source burst + Target burst
- Source single + Target burst
- Source burst + Target single
- Source single + Target single

### PARTIAL LENGTH
For 32-bit default:
- 1, 2, 3 bytes
- 5, 6, 7 bytes
- 9, 10, 11 bytes
- verify final WSTRB

### BOUNDARY
- Source split at 4KB
- Target split at 4KB
- Source and Target boundaries at different positions
- address wrap near 0xFFFFFFFF

### ERROR
- Source RRESP EXOKAY/SLVERR/DECERR
- Target BRESP EXOKAY/SLVERR/DECERR
- simultaneous Source/Target first error
- earlier ordinary error followed by Source protocol fault
- early RLAST
- missing expected RLAST

### TIMEOUT
- AR timeout then late handshake/drain
- R timeout then late R beats
- AW timeout then late handshake
- W timeout then late READY
- B timeout then late response
- timeout disabled
- no timeout while Source is internally backpressured
- no timeout while WVALID is not asserted

### ID QUALIFICATION
- RID mismatch -> RREADY=0, no progress
- BID mismatch -> BREADY=0, no completion
- persistent mismatch -> corresponding timeout

### APB / CDC
- invalid address
- unaligned address
- reserved bits
- START clear of status/IRQ
- event vs W1C set-dominant
- configuration writes after START do not change current snapshot
- BUSY CDC visibility
- repeated START prohibited by software contract; no command queue assumption

### RESET
- asynchronous assertion during idle
- asynchronous assertion during AR/AW pending
- reset during R/W/B obligation with coordinated slave reset model
- synchronous deassertion in both domains

## 3. Existing Directed Tests

- tb_dma_data_fifo
- tb_dma_read_engine
- tb_dma_write_engine
- tb_dma_ctrl
- tb_dma_cdc
- tb_dma_apb_regs
- tb_axi_dma_ctrl_smoke

These are mandatory in every full regression.

## 4. Coverage Goals

### Code coverage
Target metrics for RTL sign-off candidate:
- line >= 95%
- condition >= 90%
- branch >= 90%
- FSM state/transition >= 95%
- toggle: review uncovered bits; exclusions require justification

Coverage percentages are goals, not substitutes for functional scenario closure.

### Functional closure
Every item in Section 2 must have:
- at least one passing directed or constrained-random test;
- expected status/IRQ checked;
- AXI address/length/ID behavior checked where relevant;
- destination data/WSTRB checked for successful transfers.

## 5. VCS Coverage Flow

Each VCS test writes an independent coverage database:

```text
sim/coverage/vdb/<test>.vdb
```

After adding/fixing patterns, rerun any required tests and merge all current databases:

```text
make coverage-merge
```

Merged database:

```text
sim/coverage/merged.vdb
```

HTML/text report:

```text
sim/coverage/report/
```

Old per-test databases must not be silently reused when the RTL build signature changes.

## 6. Regression Closure Rule

RTL/verification phase is considered regression-clean only when:

- all mandatory directed tests pass;
- full integration smoke passes;
- parameter legality checks pass;
- no current main-branch CI failure exists;
- coverage merge completes on the VCS environment;
- all uncovered code is either exercised by a new test or documented as a justified exclusion.
