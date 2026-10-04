# DMA Data FIFO Design

Version: v0.1  
Based on: AXI2AXI_DMA_Architecture_v0.2  
Date: 2026-10-04

## 1. Purpose

The FIFO is not a conventional single-state queue. It must preserve ordered logical regions for Source qualification and Target reservation.

## 2. Logical Regions

At any time, FIFO content conceptually follows:

```text
oldest                                             newest
  |                                                  |
  v                                                  v
+-----------+-----------+-------------+---------------+
| RESERVED  | VERIFIED  | UNVERIFIED  | FREE          |
+-----------+-----------+-------------+---------------+
```

The regions are ordered and contiguous.

## 3. Required Counts

Recommended logical counters:

```text
reserved_count
verified_count
unverified_count
free_count
```

Invariant:

```text
reserved_count +
verified_count +
unverified_count +
free_count
=
DATA_FIFO_DEPTH
```

## 4. Source Write

Each accepted Source R beat:

- writes one FIFO entry
- decrements free_count
- increments unverified_count

The data write pointer advances per accepted beat.

## 5. Source Commit

When a Source burst completes successfully:

```text
unverified_count -= burst_beats
verified_count   += burst_beats
```

No data movement is required.

## 6. Source Discard

When current Source burst fails:

```text
unverified_count -= burst_beats_received
free_count       += burst_beats_received
```

The implementation must restore the write-side logical position so failed-burst entries are reusable.

Because only one Source burst may be outstanding, rollback can be implemented with a saved burst-start write pointer.

Recommended pointer concept:

```text
wr_ptr
burst_start_wr_ptr
```

At burst start:

```text
burst_start_wr_ptr = wr_ptr
```

On failed burst:

```text
wr_ptr = burst_start_wr_ptr
```

This avoids per-entry validity tags for unverified data.

## 7. Target Reserve

Reservation takes verified data from the FIFO head-side verified region.

Atomic operation:

```text
verified_count -= reserve_beats
reserved_count += reserve_beats
```

No physical data movement occurs.

Reservation must happen before AWVALID.

## 8. Target Read

During W transfer:

- reserved data is read in FIFO order
- the physical read pointer may advance per successful W handshake
- logical reserved_count is not released until the final W handshake

Because the reviewed policy releases the complete burst at the end, implementation should distinguish:

- read-progress within the current reservation
- logical release of reservation

A saved reservation start/count may be useful.

## 9. Target Release

On final W handshake:

```text
reserved_count -= burst_beats
free_count     += burst_beats
```

At that point all data entries in that reservation become reusable.

B response tracking is outside the FIFO.

## 10. Error Recovery

On Source error:

- current unverified burst is discarded
- verified but unreserved data is no longer eligible for new Target AW
- already reserved data remains protected until final W handshake

After existing obligations complete:

- remaining verified/unverified uncommitted data may be flushed
- FIFO returns to empty logical state

## 11. Proposed Pointer Model

Recommended implementation candidate:

```text
wr_ptr                 // next physical Source write
burst_start_wr_ptr     // rollback point for current Source burst
reserve_ptr            // first verified entry available to reserve
w_rd_ptr               // current W data read position
free_ptr/release_ptr   // oldest reusable boundary if needed
```

A simpler equivalent implementation using fewer pointers plus counts is acceptable.

## 12. Key Invariants

RTL assertions/testbench checks should verify:

1. counts never exceed DATA_FIFO_DEPTH;
2. count sum always equals DATA_FIFO_DEPTH;
3. reserved data is never discarded by Source recovery;
4. unverified data is never visible to Target reservation;
5. AWVALID cannot assert unless full payload is reserved;
6. failed Source burst never contributes to verified_count;
7. release happens only on final W handshake;
8. no Target read crosses reservation length.
