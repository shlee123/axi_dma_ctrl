# DMA Controller FSM Design

Version: v0.1  
Based on: AXI2AXI_DMA_Architecture_v0.2  
Date: 2026-10-04

## 1. Controller Ownership

dma_ctrl owns the DMA lifecycle, not the detailed AXI channel handshakes.

Recommended states:

```text
CTRL_IDLE
CTRL_VALIDATE
CTRL_RUN
CTRL_RECOVERY
CTRL_COMPLETE
CTRL_PROTOCOL_FAULT
```

## 2. State Transition

```text
CTRL_IDLE
   |
   | cmd_valid && cmd_ready
   v
CTRL_VALIDATE
   |
   +-- invalid config --> publish CONFIG_ERROR --> CTRL_IDLE
   |
   +-- valid ----------> CTRL_RUN

CTRL_RUN
   |
   +-- normal done --------------------------> CTRL_COMPLETE
   |
   +-- ordinary first error -----------------> CTRL_RECOVERY
   |
   +-- protocol fault -----------------------> CTRL_PROTOCOL_FAULT

CTRL_COMPLETE
   |
   | publish success event
   v
CTRL_IDLE

CTRL_RECOVERY
   |
   | all existing AXI obligations complete
   v
CTRL_IDLE

CTRL_PROTOCOL_FAULT
   |
   | reset only
   v
CTRL_IDLE
```

## 3. CTRL_IDLE

Conditions:

- dma_busy = 0
- no pending AR/AW/W
- no outstanding Source transaction
- no outstanding Target transaction
- FIFO has no active transfer bookkeeping

cmd_ready may assert in this state.

## 4. CTRL_VALIDATE

Checks:

- Source address aligned to BYTES_PER_BEAT
- Target address aligned to BYTES_PER_BEAT
- transfer length is already structurally 1..4096 by register encoding

If invalid:

- do not issue AXI transaction
- STATUS_CODE = CONFIG_ERROR
- IRQ event generated
- BUSY remains 0

If valid:

- latch shadow configuration
- initialize read/write engines
- BUSY = 1
- enter CTRL_RUN

## 5. CTRL_RUN

Parallel operation is allowed:

- Source Read Engine may fetch new verified data.
- Target Write Engine may consume verified data.

The controller must allow one Source read and one Target write to coexist.

On any Source error:

- inhibit new AR
- inhibit new AW
- protect already reserved Target payload

On Target error:

- inhibit new AR/AW as global DMA error policy
- preserve already existing Source/Target obligations

## 6. First Error Arbitration

Recommended priority:

```text
1. Source protocol fault
2. Source response error
3. Source timeout
4. Target response error
5. Target timeout
```

This implements:

- Source before Target for same-cycle first error
- protocol > response > timeout on Source side

Once error_valid_latched=1:

- STATUS_CODE no longer changes
- later errors may still affect required recovery behavior
- protocol fault always forces CTRL_PROTOCOL_FAULT even if another status was latched first

## 7. CTRL_RECOVERY

Entry actions:

- stop generation of new AR
- stop generation of new AW
- mark current failed Source burst discard if applicable
- prevent new use of verified-but-unreserved FIFO data

Wait until:

- no pending ARVALID
- no accepted Source read remains undrained
- no pending AWVALID
- no active W burst
- no pending matching B response
- protected reserved FIFO payload has been released by final W handshake

Then:

- discard remaining uncommitted FIFO data
- BUSY = 0
- retain STATUS_CODE
- retain IRQ pending in PCLK domain
- return to CTRL_IDLE

## 8. CTRL_PROTOCOL_FAULT

Entry condition:

- early RLAST
- missing RLAST at expected final beat

Behavior:

- BUSY remains 1
- no new AR/AW
- existing Target obligation must complete
- accepted Source response may be drained as required
- no success completion event
- new START ignored
- only reset exits state

## 9. CTRL_COMPLETE

Entry condition requires:

- Source requested transfer complete
- no unverified requested data
- no verified pending requested data
- no reserved Target payload
- final matching BRESP accepted with OKAY
- no pending VALID
- no outstanding AXI transaction
- no error recorded

Action:

- publish NO_ERROR completion event
- BUSY deasserts
- return to IDLE

## 10. Recommended Internal State

```text
busy
first_error_valid
first_error_code[3:0]
protocol_fault_latched

src_remaining_bytes[12:0]
dst_remaining_bytes[12:0]

src_done_seen
dst_done_seen
```

Exact registers may be adjusted during RTL design.
