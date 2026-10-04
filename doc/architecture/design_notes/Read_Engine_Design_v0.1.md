# Source Read Engine Design

Version: v0.1  
Based on: AXI2AXI_DMA_Architecture_v0.2  
Date: 2026-10-04

## 1. Responsibilities

dma_read_engine owns:

- Source AR generation
- Source R reception
- Source address progression
- Source burst sizing
- RRESP checking
- RLAST checking
- RID qualification
- Source AR/R timeout
- unverified FIFO writes
- burst commit/discard indication

## 2. Proposed FSM

```text
RD_IDLE
  |
  v
RD_PLAN
  |
  v
RD_AR_WAIT
  |
  | AR handshake
  v
RD_R_DATA
  |
  +-- complete good burst --> RD_COMMIT
  |
  +-- RRESP error --------> RD_DRAIN
  |
  +-- R timeout ----------> RD_DRAIN
  |
  +-- RLAST fault --------> RD_PROTOCOL_FAULT

RD_COMMIT --> RD_PLAN or RD_DONE
RD_DRAIN  --> RD_FAILED_DONE
```

## 3. Burst Planning

```text
burst_beats =
min(
  remaining_beats,
  beats_before_4KB,
  MAX_BURST_LENGTH,
  FIFO_free_count
)
```

If SOURCE_SINGLE=1:

```text
burst_beats = 1
```

ARLEN = burst_beats - 1.

## 4. AR Channel

Once ARVALID is asserted:

- ARADDR remains stable until ARREADY
- ARLEN remains stable
- ARSIZE = log2(BYTES_PER_BEAT)
- ARBURST = INCR
- ARID = AXI_ID_VALUE
- sideband constants follow the specification

AR timeout runs only while:

```text
ARVALID && !ARREADY
```

## 5. R Channel Acceptance

A beat is accepted only when:

```text
RVALID && RREADY && RID == AXI_ID_VALUE
```

RID mismatch:

- RREADY must be 0
- no beat count increment
- no FIFO write
- no RRESP/RLAST processing

## 6. FIFO Write

Each accepted Source data beat is written as unverified.

The engine tracks:

```text
current_burst_expected_beats
current_burst_received_beats
current_burst_bad_resp
```

At the expected final accepted beat:

- require RLAST=1
- if all RRESP were OKAY -> commit burst
- otherwise -> discard burst

Early RLAST immediately creates protocol fault.

Missing RLAST at expected final beat creates protocol fault.

## 7. RRESP Error

Any accepted beat with RRESP != OKAY:

- marks the entire burst failed
- no later beat can restore the burst
- remaining accepted transaction is drained
- complete burst is discarded

## 8. R Timeout

R timeout runs while the DMA is able and expected to receive Source progress.

If internal FIFO full prevents RREADY:

- timeout pauses

Once R timeout fires:

- current burst is permanently failed
- later data is drain-only
- burst can never commit

## 9. Address Progress

Source address increments only according to successfully launched/accepted burst bookkeeping.

Recommended update point:

- advance next Source burst address when AR command is accepted, because the command boundary is then fixed

The controller must still stop issuing new AR after a global error.

## 10. Done Condition

Read engine reports rd_done when:

- all requested Source beats have been successfully qualified, and
- no current Source transaction remains active.

A failed DMA does not report normal rd_done; it reports error/fault completion status for controller recovery.
