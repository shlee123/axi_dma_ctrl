# AXI2AXI DMA Controller Architecture

Version: v0.2  
Based on: AXI2AXI_DMA_Specification_v0.2  
Architecture review baseline: Q1-Q12 accepted  
Date: 2026-10-04

## 1. Purpose

This document defines the implementation architecture for the AXI-to-AXI DMA Controller and incorporates the reviewed architecture decisions from the v0.1 design review.

The architecture follows the behavior defined by the specification. This document does not change the software-visible register map or the externally observable protocol requirements.

## 2. Reviewed Architecture Decisions

The following decisions are frozen for v0.2:

1. Source data qualification is burst-based. A Source burst becomes verified only after the complete burst is received with all RRESP=OKAY and correct RLAST position.
2. Source and Target burst partitioning are independent. Target may form one Target burst from verified data originating from multiple successful Source bursts.
3. The complete Target burst payload must be reserved before AWVALID is asserted.
4. Reserved FIFO payload is released as a complete burst immediately after the final W handshake. BRESP tracking no longer consumes FIFO data storage.
5. Any RRESP error causes the entire current Source burst to fail and be discarded.
6. A Source R-channel timeout immediately marks the current Source burst failed. Later responses are drain-only and cannot make that burst verified.
7. After any Source error, no new Target transaction may be created. Previously verified but not yet committed data is discarded after obligations are resolved.
8. Ordinary error/timeout recovery returns BUSY to 0 after all existing AXI obligations complete. STATUS_CODE and IRQ remain available to software.
9. SRC_PROTOCOL_ERROR remains reset-required. BUSY remains 1 until coordinated reset.
10. START serialization remains a software contract. Hardware does not add a command queue or CDC-window pending protection.
11. Timeout detection remains phase-based for AR, R, AW, W, and B waits.
12. Normal DMA completion requires acceptance of the final successful BRESP.

## 3. Design Scope

The DMA controller contains:

- one APB3 slave register interface;
- one Source AXI4 master interface using AR/R only;
- one Target AXI4 master interface using AW/W/B only;
- one PCLK domain;
- one shared AXI_CLK domain for Source and Target;
- one synchronous shared DMA data FIFO;
- at most one Source read transaction outstanding;
- at most one Target write transaction outstanding.

Not included:

- scatter-gather;
- descriptor fetch;
- command queue;
- multiple outstanding transactions per side;
- AXI USER signals;
- overlap-safe memmove behavior.

## 4. Top-Level Architecture

```text
                         PCLK domain
                  +----------------------+
 APB3 ----------->|     dma_apb_regs     |
                  | registers / IRQ      |
                  +----------+-----------+
                             |
                             | config snapshot / START
                             v
                  +----------------------+
                  |       dma_cdc        |
                  | bundled-data CDC     |
                  +----------+-----------+
                             |
=============================|============================= clock boundary
                             |
                             v
                         AXI_CLK domain
                  +----------------------+
                  |       dma_ctrl       |
                  | lifecycle / policy   |
                  +-----+----------+-----+
                        |          |
                        v          v
              +---------------+  +----------------+
Source AXI <-->| dma_read_     |  | dma_write_     |--> Target AXI
 AR / R        | engine        |  | engine         |    AW / W / B
              +-------+-------+  +--------+-------+
                      |                   ^
                      | FIFO write        | FIFO consume
                      v                   |
                  +--------------------------+
                  |      dma_data_fifo       |
                  | U / V / R bookkeeping   |
                  +--------------------------+
```

FIFO logical states:

- U = unverified Source data;
- V = verified Source data;
- R = reserved for the current Target burst;
- F = free.

## 5. Module Responsibilities

### 5.1 axi_dma_ctrl

Top-level integration only.

Responsibilities:

- external ports;
- parameter propagation;
- module instantiation;
- reset distribution.

No main DMA FSM and no channel FSM should be placed here.

### 5.2 dma_apb_regs

PCLK-domain register block.

Responsibilities:

- APB3 protocol;
- software-visible configuration registers;
- START command detection;
- IRQ pending;
- APB-visible STATUS_CODE;
- synchronized BUSY;
- stable START configuration snapshot source.

### 5.3 dma_cdc

Responsibilities:

PCLK -> AXI_CLK:

- coherent configuration snapshot transfer;
- START request transfer.

AXI_CLK -> PCLK:

- completion/error event;
- STATUS_CODE associated with event;
- BUSY synchronization.

Multi-bit configuration must use a bundled-data style coherent transfer and must not use independent bit synchronizers.

### 5.4 dma_ctrl

AXI_CLK-domain lifecycle controller.

Responsibilities:

- accept START snapshot;
- runtime configuration validation;
- overall DMA RUN/RECOVERY/FAULT lifecycle;
- first-error-wins status;
- stop-new-transaction policy after error;
- normal completion decision;
- protocol-fault reset-required behavior.

### 5.5 dma_read_engine

Responsibilities:

- Source address and burst planning;
- AR generation;
- R acceptance;
- RID qualification;
- RRESP accumulation;
- RLAST checking;
- Source AR/R phase timeout;
- FIFO unverified writes;
- burst success/failure reporting;
- drain behavior after Source failure.

### 5.6 dma_write_engine

Responsibilities:

- Target address and burst planning;
- verified-data availability check;
- full-burst payload reservation before AWVALID;
- AW generation;
- WDATA/WSTRB/WLAST;
- AW/W/B phase timeout;
- BID qualification and BRESP checking;
- final-W-handshake FIFO release;
- B response state retention independent of FIFO payload storage.

### 5.7 dma_data_fifo

Synchronous AXI_CLK-domain storage.

The FIFO must support the following ordered logical regions:

```text
oldest                                                  newest
  |                                                       |
  v                                                       v
+---------+---------+-----------+---------------------------+
| reserved| verified| unverified| free                      |
+---------+---------+-----------+---------------------------+
```

Implementation may use pointers/counts instead of physical tags.

## 6. Source Burst Qualification

Source data is qualified at burst granularity.

For one accepted Source burst:

1. each accepted matching-RID beat is written into the FIFO as unverified;
2. the complete burst remains unverified until its expected final beat;
3. every accepted beat must have RRESP=OKAY;
4. RLAST must occur exactly at the expected final beat;
5. only if all conditions succeed is the whole burst promoted to verified.

Example:

```text
R0 OK
R1 OK
R2 OK
R3 OK + correct RLAST
        |
        v
[U U U U] -> [V V V V]
```

A single RRESP error causes the complete current burst to fail:

```text
R0 OK
R1 OK
R2 SLVERR
R3 OK + RLAST
        |
        v
entire burst failed
        |
        v
discard all U entries of this burst
```

Good beats before the failing beat are not retained for Target use.

## 7. Source Timeout Behavior

If a Source R timeout occurs after AR has already been accepted:

- the current Source burst is immediately marked failed;
- no later returned beat can restore the burst to verified status;
- the engine continues only as required to drain the accepted AXI obligation;
- all data belonging to that failed burst is discarded after the obligation is safely resolved.

A Source timeout therefore behaves as an error cut-off point, not as a temporary warning.

## 8. Independent Source and Target Burst Formation

Source and Target burst boundaries are intentionally independent.

Example:

```text
Source verified bursts:
[ V V V V ] [ V V V V ]

Target may issue:
[       8-beat burst       ]
```

Target burst planning uses:

- target remaining beats;
- Target-side 4KB boundary;
- MAX_BURST_LENGTH;
- contiguous verified FIFO data available at the FIFO head.

Target does not need to preserve Source burst boundaries.

## 9. Target Payload Reservation

Before AWVALID can assert:

1. the entire planned Target burst payload must already be present;
2. all payload must be verified;
3. the complete payload range must be reserved.

Once AWVALID is asserted:

- the reservation cannot be revoked;
- a later Source error cannot discard those entries;
- if AW is accepted, the corresponding W obligation must be completed.

This guarantees that no write address is launched without guaranteed write payload.

## 10. FIFO Release Policy

The reviewed policy is burst-level release on the final W handshake.

Example for a four-beat Target burst:

```text
Before W transfer:
[R][R][R][R]

W0 handshake:
[R][R][R][R]

W1 handshake:
[R][R][R][R]

W2 handshake:
[R][R][R][R]

W3 + WLAST handshake:
[F][F][F][F]
```

The FIFO payload storage is therefore released when:

```text
WVALID && WREADY && WLAST
```

After that point:

- B response state remains outstanding;
- BRESP may still report an error;
- no FIFO data entry is retained solely for waiting on B.

This policy trades some FIFO efficiency relative to per-beat release for simpler bookkeeping and recovery.

## 11. Error Cut-Off Policy

When a Source error occurs:

- no new AR transaction is created;
- no new AW transaction is created;
- the current failed Source burst is not promoted to verified;
- verified-but-not-yet-reserved FIFO data is not written out by new Target transactions;
- such uncommitted verified data is discarded during recovery;
- an already reserved Target burst remains protected and must complete its existing obligation.

Conceptual cut-off:

```text
before error:
[reserved][verified][verified][current U]

Source error:
[reserved]   <- must complete
[verified]   <- no new AW, eventually discard
[current U]  <- failed, discard
```

## 12. DMA Lifecycle

Recommended lifecycle:

```text
IDLE
 |
 | coherent START
 v
VALIDATE
 |
 +---- invalid ----> REPORT_CONFIG_ERROR -> IDLE
 |
 v
RUN
 |
 +---- normal end --------------------> COMPLETE -> IDLE
 |
 +---- ordinary error/timeout --------> RECOVERY -> IDLE
 |
 +---- RLAST protocol error ----------> PROTOCOL_FAULT
                                          |
                                          | coordinated reset only
                                          v
                                         IDLE
```

## 13. Ordinary Error Recovery

Applies to:

- SRC_RESP_ERROR;
- DST_RESP_ERROR;
- SRC_TIMEOUT;
- DST_TIMEOUT.

On first error:

1. latch first-error status;
2. publish status/IRQ through CDC;
3. stop creation of new AR/AW transactions;
4. finish or drain already existing AXI obligations;
5. protect any already reserved Target payload;
6. discard uncommitted data that will no longer be written;
7. when all obligations complete, deassert BUSY.

After recovery completes:

- BUSY = 0;
- STATUS_CODE remains latched;
- IRQ remains pending until W1C;
- software may initiate a later DMA transfer.

Recovery completion does not generate a second success IRQ.

## 14. Protocol Fault

An RLAST position violation produces SRC_PROTOCOL_ERROR.

Protocol fault behavior:

- stop creation of new AR/AW;
- do not promote the affected Source burst;
- preserve already existing Target obligations;
- continue only the drain behavior required by the AXI protocol;
- BUSY remains 1;
- new START is ignored;
- coordinated reset is required to return to IDLE.

Ordinary recovery does not clear a protocol fault.

## 15. Read Engine State Model

Recommended logical states:

```text
IDLE
 |
 v
PREPARE_AR
 |
 v
AR_WAIT
 |
 | AR handshake
 v
R_DATA
 |
 +---- complete + all OK + correct RLAST ---> VERIFY_BURST
 |
 +---- RRESP error -------------------------> DRAIN_FAILED
 |
 +---- R timeout ---------------------------> DRAIN_FAILED
 |
 +---- RLAST protocol error ----------------> PROTOCOL_FAULT
```

Important rules:

- only matching RID beats are accepted;
- RRESP and RLAST are evaluated only on accepted matching RID beats;
- a failed burst can never later become verified;
- internal FIFO-full backpressure does not count as Source timeout.

## 16. Write Engine State Model

Recommended logical states:

```text
IDLE
 |
 v
WAIT_VERIFIED_DATA
 |
 v
PLAN_BURST
 |
 v
RESERVE_COMPLETE_PAYLOAD
 |
 v
AW_WAIT
 |
 v
W_DATA
 |
 | final W handshake
 | release complete reservation
 v
B_WAIT
 |
 +---- BRESP OKAY ----> DONE/NEXT
 |
 +---- BRESP error ---> RECOVERY
```

AWVALID may assert only after complete reservation exists.

## 17. Burst Calculation

```text
BYTES_PER_BEAT = AXI_DATA_WIDTH / 8
```

Source:

```text
source_burst_beats =
min(
    source_remaining_beats,
    source_beats_before_4KB,
    MAX_BURST_LENGTH,
    available_FIFO_space
)
```

Target:

```text
target_burst_beats =
min(
    target_remaining_beats,
    target_beats_before_4KB,
    MAX_BURST_LENGTH,
    FIFO_verified_data_count
)
```

Single mode forces one beat.

Source and Target address/remain counters are independent.

## 18. Phase-Based Timeout

Timeout remains phase-based.

Source phases:

- AR wait;
- R wait.

Target phases:

- AW wait;
- W wait;
- B wait.

Rules:

- counter resets on phase transition;
- qualifying handshake is progress;
- a qualifying handshake on the expiration cycle wins over timeout;
- one side's progress does not reset the other side's counter;
- timeout does not cancel an AXI request;
- internal data-preparation delay is not charged to the external slave timeout.

## 19. CDC and START Contract

START/configuration transfer uses a coherent bundled-data handshake.

PCLK side:

1. software writes START;
2. configuration snapshot is latched;
3. snapshot remains stable;
4. request toggle/event is sent.

AXI_CLK side:

1. detect request;
2. capture stable snapshot;
3. acknowledge request.

No command queue or extra pending protection is added.

Software must serialize START requests and must not exploit the BUSY synchronization latency window.

## 20. Normal Completion

Normal DMA completion requires all of the following:

1. all requested Source data has been successfully obtained;
2. no requested data remains unverified;
3. no verified requested data remains pending for Target;
4. no Target W payload remains reserved;
5. the final W beat has handshaken;
6. the final matching BRESP has handshaken and is OKAY;
7. no AR/AW/W VALID is pending;
8. no Source or Target transaction remains outstanding;
9. no error, timeout, or protocol fault has been recorded.

The final W handshake alone is not sufficient for DMA completion.

## 21. Status and IRQ

For ordinary error:

```text
error detected
   |
   +--> STATUS_CODE latched
   |
   +--> IRQ event published
   |
   +--> BUSY may remain 1 during recovery
   |
   v
recovery complete
   |
   +--> BUSY = 0
   +--> STATUS_CODE retained
   +--> IRQ retained until W1C
```

For protocol fault:

```text
SRC_PROTOCOL_ERROR
   |
   +--> STATUS_CODE / IRQ
   +--> BUSY remains 1
   +--> reset required
```

## 22. Error Priority

Status policy remains:

- first-error-wins;
- simultaneous first Source/Target error -> Source wins;
- same-side priority -> protocol error > response error > timeout;
- later errors do not overwrite STATUS_CODE;
- protocol-fault behavior still applies even if another status had already won.

## 23. Verification Implications

The reviewed architecture requires directed tests for at least:

- burst-level Source qualification;
- failure on any RRESP within a burst;
- Source R timeout followed by late data;
- multiple Source bursts merged into one Target burst;
- complete payload reservation before AWVALID;
- no new AW after Source error;
- protected reserved payload across later Source error;
- FIFO release on final W handshake;
- BRESP error after FIFO payload has already been freed;
- ordinary recovery returning BUSY to 0;
- protocol fault keeping BUSY high until reset;
- START serialization assumptions;
- phase-based timeout reset/progress rules;
- final BRESP required for success completion.

## 24. Remaining Open Implementation Items

The following remain implementation choices:

1. exact FIFO pointer/count representation;
2. exact representation of unverified/verified/reserved boundaries;
3. FSM encoding;
4. exact CDC primitive/module structure;
5. timeout counter sharing versus separate physical counters;
6. reset synchronizer module partition;
7. internal signal naming;
8. ASIC clock-gating implementation;
9. FPGA build-definition name.

These are implementation details and must not change the reviewed behavioral rules above.
