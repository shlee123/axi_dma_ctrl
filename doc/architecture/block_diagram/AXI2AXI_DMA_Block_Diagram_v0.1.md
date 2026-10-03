# AXI2AXI DMA Block Diagram

Version: v0.1  
Based on: AXI2AXI_DMA_Specification_v0.2  
Date: 2026-10-04

## 1. Top-Level Block Diagram

```text
                                     +--------------------------+
                                     |      axi_dma_ctrl        |
                                     |                          |
 PCLK ------------------------------>|                          |
 PRESETn --------------------------->|                          |
                                     |   +------------------+   |
 APB3 PSEL/PENABLE/PWRITE/PADDR ---> |   |  dma_apb_regs    |   |
 APB3 PWDATA -----------------------> |   |                  |   |
 APB3 PRDATA/PREADY/PSLVERR <------- |   +--------+---------+   |
                                     |            |             |
 dma_irq <-------------------------- |            |             |
                                     |            v             |
                                     |   +------------------+   |
                                     |   |     dma_cdc      |   |
                                     |   +--------+---------+   |
                                     |            |             |
                                     |============|=============|
                                     |            |             |
 AXI_CLK --------------------------->|            v             |
                                     |   +------------------+   |
                                     |   |     dma_ctrl     |   |
                                     |   +----+--------+----+   |
                                     |        |        |        |
                                     |        |        |        |
                                     |  +-----v---+ +--v------+ |
 Source AXI AR/R <-----------------> |  | read_   | | write_  | | <-----------------> Target AXI AW/W/B
                                     |  | engine  | | engine  | |
                                     |  +----+----+ +----+----+ |
                                     |       |           ^      |
                                     |       v           |      |
                                     |   +------------------+   |
                                     |   |  dma_data_fifo   |   |
                                     |   +------------------+   |
                                     +--------------------------+
```

## 2. Clock-Domain Partition

```text
 PCLK DOMAIN
 ----------------------------------------------------------------
 dma_apb_regs
 - software-visible registers
 - START command
 - IRQ pending
 - STATUS_CODE image
 - synchronized BUSY

 dma_cdc PCLK side
 - snapshot holding
 - START request/ack
 - event receive
 ----------------------------------------------------------------
                        CDC boundary
 ----------------------------------------------------------------
 AXI_CLK DOMAIN
 dma_cdc AXI side
 dma_ctrl
 dma_read_engine
 dma_write_engine
 dma_data_fifo
 Source AXI master
 Target AXI master
 ----------------------------------------------------------------
```

## 3. Data Path

```text
       Source AXI R
            |
            v
 +-----------------------+
 | dma_read_engine       |
 | RID/RRESP/RLAST check |
 +-----------+-----------+
             |
             | unverified FIFO write
             v
 +-----------------------+
 | dma_data_fifo         |
 |                       |
 | U -> V -> R -> free   |
 +-----------+-----------+
             |
             | verified / reserved payload
             v
 +-----------------------+
 | dma_write_engine      |
 | WSTRB/WLAST/BRESP     |
 +-----------+-----------+
             |
             v
        Target AXI W
```

## 4. Control Path

```text
 APB configuration
       |
       v
 dma_apb_regs
       |
       | coherent snapshot + START
       v
 dma_cdc
       |
       v
 dma_ctrl
   |       |
   |       +--------------------+
   |                            |
   v                            v
 read engine control       write engine control
   |                            |
   +------------+---------------+
                |
                v
         lifecycle status
                |
                v
             dma_cdc
                |
                v
      APB-visible status / IRQ
```

## 5. Source Read Flow

```text
                +----------------+
                |   PREPARE_AR   |
                +-------+--------+
                        |
                        v
                +----------------+
                |    AR_WAIT     |
                +-------+--------+
                        |
                  AR handshake
                        |
                        v
                +----------------+
                |     R_DATA     |
                +---+--------+---+
                    |        |
         good burst |        | error / protocol fault
                    |        |
                    v        v
             +---------+   +----------------+
             | VERIFY  |   | DRAIN / FAULT  |
             +----+----+   +----------------+
                  |
                  v
               NEXT
```

## 6. Target Write Flow

```text
          +----------------------+
          | WAIT_VERIFIED_DATA   |
          +----------+-----------+
                     |
                     v
          +----------------------+
          | RESERVE_FIFO_PAYLOAD |
          +----------+-----------+
                     |
                     v
          +----------------------+
          |       AW_WAIT        |
          +----------+-----------+
                     |
                AW handshake
                     |
                     v
          +----------------------+
          |        W_DATA        |
          +----------+-----------+
                     |
               final W handshake
                     |
                     v
          +----------------------+
          |        B_WAIT        |
          +-----+-----------+----+
                |           |
             OKAY         ERROR
                |           |
                v           v
              NEXT       RECOVERY
```

## 7. FIFO Logical State Diagram

```text
 free entries
    |
    | Source R handshake
    v
 unverified entries
    |
    | complete Source burst
    | all RRESP == OKAY
    | correct RLAST
    v
 verified entries
    |
    | Target burst planned
    | before AWVALID
    v
 reserved entries
    |
    | W transfer / write obligation completion
    v
 free entries
```

A Source failure may discard unverified/uncommitted entries, but cannot discard entries already reserved for a launched Target write.

## 8. CDC Block Diagram

```text
 PCLK                                           AXI_CLK
 -----                                          -------

 config regs
    |
 START
    v
 snapshot holding registers
    |
 req toggle -----------------------------------> sync/detect
                                                  |
                                                  v
                                             shadow config
                                                  |
 ack toggle <-------------------------------------+

 event/status <-------------------------------- AXI event latch
 IRQ/status update
```

BUSY is owned by AXI_CLK and synchronized separately for APB readback.

## 9. Error Flow

```text
                    error detected
                         |
                         v
                 latch first error
                         |
                         v
             stop new AXI transactions
                         |
             +-----------+-----------+
             |                       |
      ordinary error            protocol fault
             |                       |
             v                       v
         RECOVERY               PROTOCOL_FAULT
             |                       |
 existing obligations done        reset only
             |                       |
             v                       v
            IDLE                    IDLE
```

## 10. Normal Completion Flow

```text
 Source requested bytes complete
          +
 FIFO contains no unwritten requested data
          +
 Target final W beat accepted
          +
 Target final successful B accepted
          +
 no pending VALID / outstanding AXI
          |
          v
     DMA COMPLETE
          |
          v
 status/event CDC
          |
          v
 IRQ pending in PCLK domain
```

## 11. Design Review Focus

The block diagram should be considered stable only after review of:

- FIFO logical regions;
- reservation point relative to AWVALID;
- Source burst verification point;
- ordinary recovery versus protocol fault split;
- CDC snapshot handshake;
- completion event timing.
