# Target Write Engine Design

Version: v0.1  
Based on: AXI2AXI_DMA_Architecture_v0.2  
Date: 2026-10-04

## 1. Responsibilities

dma_write_engine owns:

- Target burst planning
- complete-payload reservation
- AW generation
- WDATA/WSTRB/WLAST
- BRESP checking
- BID qualification
- Target AW/W/B timeout
- reserved FIFO release on final W handshake

## 2. Proposed FSM

```text
WR_IDLE
  |
  v
WR_WAIT_DATA
  |
  v
WR_PLAN
  |
  v
WR_RESERVE
  |
  v
WR_AW_WAIT
  |
  | AW handshake
  v
WR_W_DATA
  |
  | final W handshake
  | release full reservation
  v
WR_B_WAIT
  |
  +-- BRESP OKAY --> WR_NEXT / WR_DONE
  |
  +-- BRESP error -> WR_FAILED
```

## 3. Burst Planning

```text
burst_beats =
min(
  target_remaining_beats,
  target_beats_before_4KB,
  MAX_BURST_LENGTH,
  FIFO_verified_count
)
```

If TARGET_SINGLE=1:

```text
burst_beats = 1
```

The Target burst may combine data from multiple successful Source bursts.

## 4. Reservation

Before AWVALID:

- reserve exactly burst_beats entries
- reservation must succeed atomically for the whole planned burst

Only after reserve_grant may AWVALID assert.

Once reserved:

- a later Source error cannot reclaim this data
- the write engine must finish the existing Target obligation

## 5. AW Channel

AWVALID payload remains stable until AWREADY.

AW timeout runs during:

```text
AWVALID && !AWREADY
```

After global error occurs:

- no new AW may be generated
- an already asserted AWVALID must remain valid until handshake/reset

## 6. W Channel

WDATA is sourced from reserved FIFO entries.

For each beat:

- WVALID remains stable until WREADY
- WLAST is asserted only on the final beat
- beat index increments only on WVALID && WREADY

WSTRB:

- full ones except final partial beat
- final partial beat uses requested-byte mask

## 7. FIFO Release

Reviewed policy:

- do not free FIFO entries beat-by-beat
- release the complete reserved burst on final W handshake

Therefore:

```text
if (WVALID && WREADY && WLAST)
    release_reserved_burst
```

After release, B_WAIT retains only transaction metadata.

## 8. B Channel

B response is accepted only for matching BID.

If BID mismatch:

- BREADY=0
- response not processed
- B timeout continues according to specification

BRESP=OKAY:

- successful burst completion

BRESP != OKAY:

- DST_RESP_ERROR

## 9. Target Timeout

Independent phase timing:

- AW wait timeout
- W wait timeout
- B wait timeout

Internal lack of prepared WVALID before data is available must not count as slave timeout.

## 10. Done Condition

wr_done is asserted only after:

- all Target requested bytes have been sent, and
- final matching BRESP has handshaken with OKAY.

The final W handshake alone is not sufficient.
