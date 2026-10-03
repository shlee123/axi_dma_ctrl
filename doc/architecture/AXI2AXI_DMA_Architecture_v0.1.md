# AXI2AXI DMA Controller Architecture

Version: v0.1  
Based on: AXI2AXI_DMA_Specification_v0.2  
Date: 2026-10-04

## 1. Purpose

This document defines the implementation architecture for the AXI-to-AXI DMA Controller.

The architecture follows the behavior defined by the specification. This document does not change software-visible register behavior, AXI protocol behavior, timeout behavior, error handling, or reset requirements.

The main objectives are:

- separate control path and data path;
- isolate clock-domain crossing logic;
- keep AXI read and write protocol engines independent;
- maintain explicit FIFO state for unverified, verified, and target-reserved data;
- make timeout and error recovery structurally reviewable;
- provide a direct mapping between specification, RTL modules, and verification targets.

## 2. Design Scope

The DMA controller contains:

- one APB3 slave register interface;
- one Source AXI4 master interface using AR/R channels only;
- one Target AXI4 master interface using AW/W/B channels only;
- one PCLK domain;
- one AXI_CLK domain shared by Source and Target AXI interfaces;
- one synchronous shared DMA data FIFO in AXI_CLK domain;
- maximum one outstanding Source read transaction;
- maximum one outstanding Target write transaction.

The following functions are intentionally not included:

- scatter-gather;
- descriptor fetch engine;
- command queue;
- multiple outstanding transactions per AXI side;
- AXI USER signals;
- overlap-safe memmove semantics.

## 3. Top-Level Architecture

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
             control ---+          +--- control
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

 AXI_CLK status / completion / error
                  |
                  v
               dma_cdc
                  |
==================|========================================
                  v
               PCLK domain
          STATUS / BUSY / IRQ
```

Legend for FIFO logical states:

- U: unverified Source data;
- V: verified Source data;
- R: data reserved for an asserted or accepted Target write;
- F: free entry.

## 4. RTL Module Partition

### 4.1 axi_dma_ctrl

Top-level integration only.

Responsibilities:

- expose external APB3, Source AXI, Target AXI, reset, and interrupt ports;
- propagate parameters;
- instantiate internal modules;
- connect reset synchronization infrastructure.

It should not contain the main DMA FSM or AXI protocol state machines.

### 4.2 dma_apb_regs

PCLK-domain software-visible register bank.

Responsibilities:

- APB3 protocol handling;
- DMA_SRC_ADDR;
- DMA_TARGET_ADDR;
- DMA_LENGTH;
- DMA_CTRL access;
- INTR_CTRL access;
- START command detection;
- PCLK-domain IRQ pending register;
- APB-visible STATUS_CODE;
- APB-visible synchronized BUSY;
- creation of the configuration snapshot presented to dma_cdc.

Invalid APB accesses must follow the specification:

- PREADY fixed high;
- unsupported address or unaligned address returns PSLVERR;
- invalid read returns PRDATA=0;
- invalid write causes no side effect.

### 4.3 dma_cdc

Clock-domain crossing block.

Responsibilities:

PCLK -> AXI_CLK:

- coherent configuration snapshot transfer;
- START request transfer.

AXI_CLK -> PCLK:

- completion/error event transfer;
- STATUS_CODE transfer associated with event;
- BUSY synchronization.

A multi-bit configuration snapshot must not be transferred through independent per-bit synchronizers.

### 4.4 dma_ctrl

AXI_CLK-domain DMA lifecycle controller.

Responsibilities:

- accept a coherent START/configuration snapshot;
- validate runtime configuration such as address alignment;
- control DMA lifecycle;
- arbitrate first-error-wins status;
- stop creation of new transactions after an error;
- coordinate normal completion;
- coordinate ordinary error recovery;
- enter reset-required protocol fault state;
- manage overall remaining-byte accounting and end-of-transfer condition.

It does not implement detailed AR/R/AW/W/B handshakes.

### 4.5 dma_read_engine

AXI_CLK-domain Source AXI engine.

Responsibilities:

- Source address tracking;
- Source burst-length calculation;
- AR channel generation and stability;
- R channel acceptance;
- RID qualification;
- RRESP checking;
- RLAST position checking;
- Source timeout watchdog;
- write unverified data into the FIFO;
- report burst-success or burst-failure result to the controller/FIFO bookkeeping;
- drain accepted Source transactions during recovery.

### 4.6 dma_write_engine

AXI_CLK-domain Target AXI engine.

Responsibilities:

- Target address tracking;
- Target burst-length calculation;
- reserve verified FIFO data before AWVALID assertion;
- AW channel generation and stability;
- WDATA/WSTRB/WLAST generation;
- BID qualification;
- BRESP checking;
- Target timeout watchdog;
- release consumed FIFO entries after the Target write obligation completes as defined by implementation bookkeeping.

### 4.7 dma_data_fifo

Synchronous AXI_CLK-domain shared data FIFO.

Data width:

- AXI_DATA_WIDTH bits per entry.

Default depth:

- DATA_FIFO_DEPTH = 8 entries.

The FIFO must distinguish logical classes of data:

1. free entries;
2. current Source-burst unverified entries;
3. verified entries that may be used by Target;
4. entries reserved for an already launched Target write.

Physical per-entry tags are not mandatory. Equivalent pointer/count bookkeeping is allowed.

## 5. Clock and Reset Architecture

### 5.1 Clock domains

PCLK domain:

- APB interface;
- software-visible registers;
- IRQ pending;
- synchronized BUSY/status image.

AXI_CLK domain:

- dma_ctrl;
- dma_read_engine;
- dma_write_engine;
- dma_data_fifo;
- Source AXI;
- Target AXI.

Source and Target AXI share the same AXI_CLK.

### 5.2 Reset

External reset is asynchronous.

Each clock domain uses:

- asynchronous assertion;
- synchronous deassertion.

Conceptual structure:

```text
                    external reset
                         |
             +-----------+-----------+
             |                       |
             v                       v
      PCLK reset sync          AXI_CLK reset sync
             |                       |
             v                       v
      APB / IRQ / CDC          DMA / AXI / FIFO
```

Reset clears all software-visible registers and internal state to zero, including FIFO bookkeeping and CDC state.

A DMA-local reset cannot guarantee cancellation of an already accepted external AXI transaction. System-level coordinated reset remains a platform responsibility.

## 6. DMA Data Flow

Normal data flow:

```text
 Source memory
      |
      | AXI R beat
      v
 +----------------+
 | Read Engine    |
 +----------------+
      |
      | write to FIFO
      | state = unverified
      v
 +----------------+
 | Shared FIFO    |
 +----------------+
      |
      | Source burst completes:
      | all RRESP == OKAY
      | RLAST position correct
      v
 mark burst data verified
      |
      v
 +----------------+
 | Write Engine   |
 +----------------+
      |
      | reserve verified prefix
      | AW / W / B
      v
 Target memory
```

A received Source beat is not immediately writable to the Target.

The data becomes eligible for a new Target transaction only after the full Source burst is successfully qualified.

## 7. FIFO Architecture

### 7.1 Logical FIFO state

A conceptual FIFO layout may look like:

```text
              oldest                              newest
                |                                   |
                v                                   v
 +-----+-----+-----+-----+-----+-----+-----+-----+
 |  R  |  R  |  V  |  V  |  U  |  U  |  F  |  F  |
 +-----+-----+-----+-----+-----+-----+-----+-----+
   ^         ^           ^                       ^
   |         |           |                       |
 target   verified   current Source            free
 consume  boundary    burst region
```

Logical regions must remain ordered.

Required bookkeeping concepts:

- total occupied entries;
- unverified count for the current Source burst;
- verified prefix count;
- reserved Target count;
- free count.

Equivalent pointer-based implementation is acceptable.

### 7.2 Source burst qualification

For each accepted Source burst:

1. entries may be written into FIFO while R beats are received;
2. those entries remain unverified until the burst ends;
3. every accepted R beat must have matching RID;
4. every accepted R beat must have RRESP=OKAY;
5. RLAST must occur exactly at the expected final beat;
6. only then is the entire burst promoted to verified.

If the Source burst fails:

- that burst is never promoted to verified;
- uncommitted/unreserved data from the failed transfer may be discarded;
- already reserved Target payload must remain intact.

### 7.3 Target payload reservation

Before asserting AWVALID:

- the complete planned write burst payload must already exist;
- all payload must be verified;
- the required FIFO prefix is reserved for that Target burst.

Once AWVALID is asserted, the corresponding payload reservation cannot be revoked because of a later Source error.

This requirement avoids a state in which AW has been launched without guaranteed W payload.

## 8. DMA Control Flow

Recommended controller states:

```text
 IDLE
   |
   | coherent START received
   v
 VALIDATE
   |
   +---- invalid configuration ----> REPORT_CONFIG_ERROR
   |
   v
 RUN
   |
   +---- normal end ----------------> COMPLETE
   |
   +---- ordinary error/timeout ----> RECOVERY
   |
   +---- RLAST protocol fault ------> PROTOCOL_FAULT

 COMPLETE
   |
   v
 IDLE

 RECOVERY
   |
   | all existing AXI obligations safely complete
   v
 IDLE

 PROTOCOL_FAULT
   |
   | coordinated reset only
   v
 IDLE
```

This is the lifecycle FSM. Channel-specific handshakes remain in the read/write engines.

## 9. Source Read Engine

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
   +---- burst success ----> VERIFY_BURST
   |
   +---- response error ---> DRAIN_ERROR
   |
   +---- protocol error ---> PROTOCOL_FAULT
   |
   v
 DONE / NEXT
```

Required behavior:

- ARVALID payload remains stable until ARREADY;
- one Source command slot maximum;
- ARLEN fixed after ARVALID assertion;
- ARSIZE always represents full AXI_DATA_WIDTH;
- ARBURST=INCR;
- RID mismatch is not accepted;
- only accepted matching RID beats advance beat count;
- RRESP is evaluated on accepted matching RID beats;
- RLAST is checked against expected final beat;
- FIFO-full internal backpressure does not count toward Source timeout.

## 10. Target Write Engine

Recommended logical states:

```text
 IDLE
   |
   v
 WAIT_VERIFIED_DATA
   |
   v
 RESERVE_PAYLOAD
   |
   v
 AW_WAIT
   |
   | AW handshake
   v
 W_DATA
   |
   | final W handshake
   v
 B_WAIT
   |
   +---- OKAY ----> DONE / NEXT
   |
   +---- error ---> RECOVERY
```

Required behavior:

- reserve complete payload before AWVALID;
- AWVALID payload remains stable until AWREADY;
- one Target command slot maximum;
- WVALID payload remains stable until WREADY;
- WLAST asserted only on the AWLEN-selected final beat;
- BID mismatch is not accepted;
- BRESP is evaluated only on accepted matching BID response;
- Target timeout watchdogs are phase-aware.

## 11. Burst and Address Calculation

Constants:

```text
 BYTES_PER_BEAT = AXI_DATA_WIDTH / 8
```

Source burst:

```text
 source_remaining_beats
 source_beats_before_4KB
 MAX_BURST_LENGTH
 available_FIFO_space
          |
          v
        min()
          |
          v
 source_burst_beats
```

Target burst:

```text
 target_remaining_beats
 target_beats_before_4KB
 MAX_BURST_LENGTH
 FIFO_verified_data_count
          |
          v
        min()
          |
          v
 target_burst_beats
```

Single mode forces burst_beats = 1.

AxLEN = burst_beats - 1.

Source and Target burst lengths are independent.

Address bookkeeping is 32-bit modulo arithmetic. Each actual burst must still independently obey the 4KB boundary rule.

## 12. Partial Final Beat

Source always performs full-width reads.

For a final transfer smaller than BYTES_PER_BEAT:

- Source still reads a complete beat;
- extra bytes are not written to Target;
- Target WSTRB selects only requested bytes.

Example for AXI_DATA_WIDTH=32 and 10-byte transfer:

```text
 beat 0 WSTRB = 1111
 beat 1 WSTRB = 1111
 beat 2 WSTRB = 0011
```

## 13. CDC Architecture

### 13.1 START and configuration snapshot

Recommended bundled-data handshake:

```text
 PCLK domain
 +------------------------+
 | writable config regs   |
 +------------------------+
            |
            | START
            v
 +------------------------+
 | snapshot holding regs  |
 +------------------------+
            |
            | request toggle
            v
 ================= CDC =================
            |
            v
 AXI_CLK request detector
            |
            | capture stable snapshot
            v
 AXI shadow configuration
            |
            | acknowledge toggle
            v
 ================= CDC =================
            |
            v
 PCLK completion of request
```

The snapshot holding registers must remain stable until acknowledgment.

Per current software contract, hardware does not provide a command queue or repeated-START protection during the CDC acceptance window.

### 13.2 BUSY

BUSY owner is AXI_CLK domain.

APB readback uses a synchronized BUSY indication.

Therefore, software must not treat an immediate BUSY=0 read after START as proof of completion.

### 13.3 Status and IRQ event

STATUS_CODE and completion/error event must cross coherently.

Recommended structure:

- stable status/event data in AXI_CLK domain;
- event toggle or equivalent lossless event handshake;
- capture in PCLK domain;
- update STATUS_CODE and IRQ pending together.

If a new event and IRQ clear occur in the same PCLK cycle, set is dominant.

## 14. Timeout Architecture

Source and Target use independent watchdog counters.

Source phases:

- AR wait;
- R wait.

Target phases:

- AW wait;
- W wait;
- B wait.

Phase changes reset the associated counter.

A qualifying handshake on the timeout-expiration cycle is considered progress and prevents timeout for that cycle.

Timeout does not cancel an AXI request.

Once VALID is asserted, VALID and payload remain stable until handshake or coordinated reset.

## 15. Error and Recovery Architecture

| Event | STATUS_CODE | New transactions | Existing AXI obligation | BUSY behavior |
|---|---|---|---|---|
| Source RRESP error | SRC_RESP_ERROR | Stop | Drain accepted Source operation; protect committed Target payload | Remains high until recovery complete |
| Target BRESP error | DST_RESP_ERROR | Stop | Finish existing write obligation | Remains high until recovery complete |
| Source timeout | SRC_TIMEOUT | Stop | Keep required VALID / drain if later accepted | Remains high until recovery complete |
| Target timeout | DST_TIMEOUT | Stop | Keep required VALID / finish accepted write | Remains high until recovery complete |
| RLAST protocol fault | SRC_PROTOCOL_ERROR | Stop | Preserve existing Target obligation; Source drain/discard as allowed | Stays high until coordinated reset |
| Configuration error | CONFIG_ERROR | No AXI transaction issued | None | Remains low |

Error status policy:

- first-error-wins;
- simultaneous first Source and Target error: Source wins;
- same-side priority: protocol error > response error > timeout;
- later errors do not overwrite STATUS_CODE;
- a protocol fault still forces reset-required state even if another error was recorded first.

## 16. Normal Completion

Normal DMA completion requires:

1. all requested Source bytes have been read;
2. all data needed by Target has been verified;
3. all Target data has been transmitted;
4. the final Target B response has been accepted and is successful;
5. no pending VALID request or outstanding transaction remains.

Only then may BUSY deassert and the completion event be published.

## 17. Parameter Constraints

Architecture assumes:

- AXI_ADDR_WIDTH = 32;
- AXI_DATA_WIDTH in {8,16,32,64,128,256,512,1024};
- AXI_ID_WIDTH >= 1;
- APB_DATA_WIDTH = 32;
- APB_ADDR_WIDTH >= 5;
- 1 <= MAX_BURST_LENGTH <= 256;
- DATA_FIFO_DEPTH >= MAX_BURST_LENGTH;
- AXI_TIMEOUT_CYCLES >= 0.

Illegal elaboration parameters should fail simulation/elaboration rather than become runtime datapath logic.

## 18. Verification Mapping

Architecture blocks map directly to verification categories:

- APB register behavior -> APB/register tests;
- read engine -> AR/R, RRESP, RID, RLAST, Source timeout;
- write engine -> AW/W/B, BRESP, BID, WLAST, Target timeout;
- FIFO -> qualification, reservation, discard, partial transfer;
- CDC -> START snapshot coherency, BUSY synchronization, status/IRQ event transfer;
- controller -> first-error-wins, recovery, completion, protocol-fault reset requirement;
- burst generator -> Single/Burst, 4KB boundary, partial final beat.

## 19. Open Architecture Items

These items remain implementation choices and are not specification changes:

1. exact internal FIFO pointer/count representation;
2. whether verification state is represented by counts, pointers, or compact tags;
3. exact lifecycle/controller FSM encoding;
4. exact CDC implementation primitive style, provided coherent behavior is maintained;
5. exact reset synchronizer module partition;
6. whether timeout counters are shared by mutually exclusive phases or implemented separately;
7. internal module signal naming;
8. ASIC clock-gating integration details;
9. FPGA build-definition name.

These items should be finalized before Architecture v1.0.

## 20. Architecture Freeze Criteria

Architecture can move from v0.x to v1.0 when the following are reviewed and accepted:

- module partition;
- FIFO qualification/reservation model;
- read-engine FSM;
- write-engine FSM;
- lifecycle/error recovery FSM;
- CDC handshake;
- timeout phase behavior;
- reset behavior;
- burst calculation;
- normal completion condition;
- protocol-fault behavior.
