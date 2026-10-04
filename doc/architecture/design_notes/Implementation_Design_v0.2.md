# AXI2AXI DMA Implementation Design

Version: v0.2  
Based on: AXI2AXI_DMA_Architecture_v0.2  
Review baseline: Implementation Review Q1-Q6 accepted  
Date: 2026-10-04

## 1. Frozen Implementation Decisions

The following implementation decisions are frozen:

1. Failed Source burst uses `burst_start_wr_ptr` rollback.
2. Source next-address counter advances on AR handshake.
3. Target next-address counter advances on AW handshake.
4. Before ARVALID, the Read Engine must confirm FIFO free space for the complete planned Source burst.
5. `src_burst_commit` / `src_burst_discard` are generated directly by `dma_read_engine`.
6. Target FIFO reservation is initiated directly by `dma_write_engine`.

## 2. Ownership Partition

```text
dma_ctrl
  - global lifecycle
  - first-error-wins
  - stop-new-transaction policy
  - recovery / BUSY / IRQ event

dma_read_engine
  - Source burst planning
  - AR/R protocol
  - Source address advance on AR handshake
  - burst-level success/failure
  - FIFO unverified write
  - FIFO commit/discard

dma_write_engine
  - Target burst planning
  - FIFO reservation
  - AW/W/B protocol
  - Target address advance on AW handshake
  - FIFO release on final W handshake

dma_data_fifo
  - data RAM
  - unverified/verified/reserved/free bookkeeping
  - failed Source burst rollback
```

## 3. Source Burst Launch Rule

Before asserting ARVALID:

```text
planned_beats <= fifo_free_count
```

Because only one Source read transaction may be outstanding, no second Source burst can consume free entries while this AR request is pending.

Target activity can only preserve or increase free space; therefore a separate Source-reservation state is not required.

Once AR handshake occurs, the complete burst capacity is guaranteed.

## 4. Source Address Update

On:

```text
ARVALID && ARREADY
```

update:

```text
next_src_addr = current_src_addr + burst_beats * BYTES_PER_BEAT
```

The address is not rolled back after RRESP error, timeout, or protocol fault.

## 5. Failed Source Burst Rollback

At Source burst start:

```text
burst_start_wr_ptr = wr_ptr
```

Each accepted R beat advances `wr_ptr` and increments unverified count.

On successful burst completion:

```text
unverified -> verified
wr_ptr remains advanced
```

On burst failure:

```text
wr_ptr = burst_start_wr_ptr
all entries written by this burst become free
```

No per-entry qualification tag is required.

## 6. Source Commit / Discard Ownership

`dma_read_engine` directly generates:

```text
src_commit_valid
src_commit_beats

src_discard_valid
src_discard_beats_received
```

The controller receives the corresponding error event separately and applies global policy.

This avoids routing local FIFO state transitions through `dma_ctrl`.

## 7. Target Reservation Ownership

`dma_write_engine` performs:

```text
plan burst
   |
   v
dst_reserve_valid + dst_reserve_beats
   |
   v
dma_data_fifo
   |
   v
dst_reserve_ready
   |
   v
AWVALID may assert
```

A reservation is atomic for the complete Target burst.

## 8. Target Address Update

On:

```text
AWVALID && AWREADY
```

update:

```text
next_dst_addr = current_dst_addr + burst_beats * BYTES_PER_BEAT
```

No rollback occurs after W/B error.

## 9. FIFO Logical State

```text
oldest                                             newest
+-----------+-----------+-------------+-------------+
| RESERVED  | VERIFIED  | UNVERIFIED  | FREE        |
+-----------+-----------+-------------+-------------+
```

Required counters:

```text
reserved_count
verified_count
unverified_count
free_count
```

Invariant:

```text
reserved_count + verified_count +
unverified_count + free_count = DATA_FIFO_DEPTH
```

## 10. FIFO Pointer Candidate

Recommended initial RTL implementation:

```text
wr_ptr
burst_start_wr_ptr
reserve_ptr
w_rd_ptr
```

The exact minimum pointer set may be simplified during implementation, provided all reviewed invariants remain true.

## 11. First RTL Implementation Order

Recommended order:

1. `dma_defines.vh`
2. `dma_data_fifo.v`
3. `dma_read_engine.v`
4. `dma_write_engine.v`
5. `dma_ctrl.v`
6. `dma_cdc.v`
7. `dma_apb_regs.v`
8. `axi_dma_ctrl.v`

FIFO is implemented first because Read and Write Engine interfaces depend on its exact commit/reserve/release behavior.
