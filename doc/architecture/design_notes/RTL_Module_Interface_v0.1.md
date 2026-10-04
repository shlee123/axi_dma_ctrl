# RTL Module Interface Definition

Version: v0.1  
Based on: AXI2AXI_DMA_Architecture_v0.2  
Date: 2026-10-04

## 1. Purpose

This document defines the proposed internal RTL module boundaries and primary signals before RTL implementation.

## 2. Top-Level Module

Module:

```text
axi_dma_ctrl
```

External interfaces:

- APB3 slave
- Source AXI4 master: AR/R only
- Target AXI4 master: AW/W/B only
- PCLK / PRESETn
- AXI_CLK / AXI reset
- dma_irq

Top-level parameters:

```text
AXI_ADDR_WIDTH       = 32
AXI_DATA_WIDTH       = 32
AXI_ID_WIDTH         = 6
APB_ADDR_WIDTH       = 12
APB_DATA_WIDTH       = 32
MAX_BURST_LENGTH     = 8
DATA_FIFO_DEPTH      = 8
AXI_TIMEOUT_CYCLES   = 1024
AXI_ID_VALUE         = 0
AXI_PROT_VALUE       = 3'b000
AXI_CACHE_VALUE      = 4'b0000
```

## 3. dma_apb_regs <-> dma_cdc

PCLK-domain configuration snapshot fields:

```text
cfg_src_addr[31:0]
cfg_dst_addr[31:0]
cfg_length_minus_1[11:0]
cfg_source_single
cfg_target_single
```

Command/event handshake:

```text
start_req
start_ack
```

APB-visible return signals:

```text
busy_pclk
status_code_pclk[3:0]
irq_event_pclk
```

The exact req/ack encoding may be toggle-based internally.

## 4. dma_cdc <-> dma_ctrl

AXI_CLK-domain command interface:

```text
cmd_valid
cmd_ready
cmd_src_addr[31:0]
cmd_dst_addr[31:0]
cmd_length_minus_1[11:0]
cmd_source_single
cmd_target_single
```

The command is accepted on:

```text
cmd_valid && cmd_ready
```

Return/status interface:

```text
dma_busy
event_valid
event_status[3:0]
```

The CDC implementation may internally use a toggle handshake even if the local module boundary uses valid/ready semantics.

## 5. dma_ctrl <-> dma_read_engine

Control inputs to read engine:

```text
rd_start
rd_abort_new
rd_src_addr[31:0]
rd_transfer_bytes[12:0]
rd_source_single
```

Read engine status:

```text
rd_busy
rd_done
rd_error_valid
rd_error_code[3:0]
rd_protocol_fault
```

FIFO-related interface:

```text
fifo_free_count
fifo_wr_valid
fifo_wr_ready
fifo_wr_data[AXI_DATA_WIDTH-1:0]

src_burst_commit
src_burst_discard
src_burst_beats
```

Semantics:

- fifo_wr_valid writes unverified data.
- src_burst_commit converts the just-completed Source burst from unverified to verified.
- src_burst_discard removes the complete failed Source burst.
- exactly one of commit/discard occurs for an accepted Source burst.

## 6. dma_ctrl <-> dma_write_engine

Control:

```text
wr_start
wr_abort_new
wr_dst_addr[31:0]
wr_transfer_bytes[12:0]
wr_target_single
```

Status:

```text
wr_busy
wr_done
wr_error_valid
wr_error_code[3:0]
```

FIFO-facing interface:

```text
fifo_verified_count
reserve_req
reserve_beats
reserve_grant

fifo_rd_valid
fifo_rd_ready
fifo_rd_data[AXI_DATA_WIDTH-1:0]

release_reserved
release_beats
```

Rules:

- reservation must complete before AWVALID.
- release_reserved occurs only on the final W handshake for that Target burst.

## 7. dma_ctrl <-> dma_data_fifo

The controller should not manipulate FIFO storage directly except for high-level commit/discard/recovery actions.

Recommended FIFO commands:

```text
src_commit_valid
src_commit_beats

src_discard_valid
src_discard_beats

dst_reserve_valid
dst_reserve_beats
dst_reserve_ready

dst_release_valid
dst_release_beats

flush_uncommitted
```

Recommended FIFO status:

```text
free_count
verified_count
reserved_count
unverified_count
empty
full
```

## 8. Error Propagation

Each AXI engine reports local error events to dma_ctrl.

dma_ctrl owns:

- first-error-wins;
- Source-over-Target same-cycle priority;
- protocol > response > timeout same-side priority;
- global stop-new-transaction policy;
- recovery completion;
- final event/status publication.

AXI engines should report facts, while dma_ctrl owns system policy.

## 9. Interface Design Rule

No internal interface may require a pulse to cross clock domains directly.

All cross-domain events must be encoded through dma_cdc.

Within AXI_CLK domain, one-cycle pulses are permitted when producer and consumer are synchronous.
