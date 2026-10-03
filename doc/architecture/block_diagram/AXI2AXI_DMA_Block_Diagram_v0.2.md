# AXI2AXI DMA Block Diagram

Version: v0.2  
Based on: AXI2AXI_DMA_Specification_v0.2  
Architecture review baseline: Q1-Q12 accepted  
Date: 2026-10-04

## 1. Top-Level Block Diagram

```text
                                     +--------------------------+
                                     |      axi_dma_ctrl        |
 PCLK ------------------------------>|                          |
 PRESETn --------------------------->|   +------------------+   |
 APB3 <----------------------------> |   |  dma_apb_regs    |   |
 dma_irq <-------------------------- |   +--------+---------+   |
                                     |            |             |
                                     |            v             |
                                     |   +------------------+   |
                                     |   |     dma_cdc      |   |
                                     |   +--------+---------+   |
                                     |============|=============|
 AXI_CLK --------------------------->|            v             |
                                     |   +------------------+   |
                                     |   |     dma_ctrl     |   |
                                     |   +----+--------+----+   |
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

## 2. Reviewed FIFO Lifecycle

```text
Source R beats
    |
    v
+----------------+
| UNVERIFIED (U) |
+----------------+
    |
    | complete Source burst
    | all RRESP = OKAY
    | correct RLAST
    v
+----------------+
| VERIFIED (V)   |
+----------------+
    |
    | Target plans burst
    | complete payload available
    | before AWVALID
    v
+----------------+
| RESERVED (R)   |
+----------------+
    |
    | final W handshake
    v
+----------------+
| FREE (F)       |
+----------------+
```

BRESP is tracked after FIFO payload has already been released.

## 3. Burst-Level Source Qualification

```text
Source burst:
R0  R1  R2  R3
 |   |   |   |
 U   U   U   U
             |
             | all RRESP OKAY
             | correct RLAST
             v
 V   V   V   V
```

Any RRESP error or Source R timeout causes the entire current Source burst to fail.

```text
R0 OK
R1 OK
R2 SLVERR
R3 ...
   |
   v
entire burst = failed
all U data from burst = discard
```

## 4. Independent Burst Formation

```text
Source successful bursts:
[ V V V V ] [ V V V V ]

Target may independently form:
[       R R R R R R R R       ]
```

Target burst boundaries do not need to match Source burst boundaries.

## 5. Target Reservation and Release

```text
verified FIFO data
      |
      v
plan Target burst
      |
      v
reserve COMPLETE payload
      |
      v
assert AWVALID
      |
      v
send W0 ... Wn
      |
      | final WVALID && WREADY && WLAST
      v
release COMPLETE reserved payload
      |
      v
wait for B using transaction state only
```

A later Source error cannot revoke a reservation after AWVALID has asserted.

## 6. Source Error Cut-Off

```text
FIFO before Source error:

+----------+----------+-----------+
| RESERVED | VERIFIED | CURRENT U |
+----------+----------+-----------+

Source error
    |
    +--> RESERVED : must finish existing Target obligation
    |
    +--> VERIFIED : no new AW; discard during recovery
    |
    +--> CURRENT U: failed burst; discard
```

No new Target transaction is created after Source error.

## 7. Ordinary Error Recovery

```text
ordinary error / timeout
          |
          v
   latch first error
          |
          v
   publish STATUS + IRQ
          |
          v
  stop new AR / AW
          |
          v
finish existing AXI obligations
          |
          v
discard uncommitted FIFO data
          |
          v
        BUSY=0
          |
          +--> STATUS retained
          +--> IRQ retained until W1C
          +--> later START allowed
```

## 8. Protocol Fault

```text
RLAST framing error
       |
       v
SRC_PROTOCOL_ERROR
       |
       +--> stop new AR/AW
       +--> preserve existing Target obligation
       +--> drain only as required
       +--> BUSY stays 1
       |
       v
 coordinated reset
       |
       v
      IDLE
```

## 9. Source Read Flow

```text
 PREPARE_AR
     |
     v
   AR_WAIT
     |
     | AR handshake
     v
   R_DATA
     |
     +---- all OK + correct RLAST ---> VERIFY_BURST
     |
     +---- RRESP error --------------> DRAIN_FAILED
     |
     +---- R timeout ----------------> DRAIN_FAILED
     |
     +---- RLAST error --------------> PROTOCOL_FAULT
```

A failed Source burst can never return to verified status.

## 10. Target Write Flow

```text
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
        | FIFO payload released
        v
      B_WAIT
      /    \
   OKAY    ERROR
    |        |
    v        v
 NEXT     RECOVERY
```

## 11. Phase-Based Timeout

```text
Source:
AR_WAIT -> Source AR timeout counter
R_DATA  -> Source R timeout counter

Target:
AW_WAIT -> Target AW timeout counter
W_DATA  -> Target W timeout counter
B_WAIT  -> Target B timeout counter
```

Each phase starts with a reset counter. A qualifying handshake resets progress timing.

## 12. START CDC Contract

```text
PCLK                                  AXI_CLK
----                                  -------

config registers
      |
START |
      v
snapshot holding
      |
req toggle --------------------------> detect request
                                        |
                                        v
                                   capture snapshot
                                        |
ack toggle <---------------------------+
```

No command queue or extra repeated-START protection is added. Software serializes START.

## 13. Normal Completion

```text
all Source requested data successful
            +
no U / V / R requested payload remains
            +
final W handshake complete
            +
final matching BRESP handshake = OKAY
            +
no pending VALID
            +
no outstanding AXI transaction
            +
no error recorded
            |
            v
        DMA COMPLETE
            |
            v
        BUSY -> 0
            |
            v
       completion IRQ
```

The final W handshake alone is not sufficient for success.

## 14. Review Status

The following architecture points are now reviewed and accepted:

- burst-level Source qualification;
- independent Source/Target burst formation;
- complete Target reservation before AWVALID;
- release on final W handshake;
- whole-burst discard on Source RRESP error;
- failed-burst behavior on Source timeout;
- stop-new-AW policy after Source error;
- ordinary recovery returns BUSY to 0;
- protocol fault requires reset;
- software-serialized START;
- phase-based timeout;
- final successful BRESP required for normal completion.
