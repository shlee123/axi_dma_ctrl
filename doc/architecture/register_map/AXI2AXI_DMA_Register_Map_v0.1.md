# AXI2AXI DMA Register Map

Version: v0.1  
Based on: AXI2AXI_DMA_Specification_v0.2  
Date: 2026-10-04

## 1. APB Interface

Interface type: APB3

Parameters:

- APB_DATA_WIDTH = 32;
- APB_ADDR_WIDTH default = 12;
- APB_ADDR_WIDTH must be >= 5.

Signals:

- PCLK
- PRESETn
- PSEL
- PENABLE
- PWRITE
- PADDR
- PWDATA
- PRDATA
- PREADY
- PSLVERR

Rules:

- register offsets are byte addresses;
- PREADY is permanently asserted;
- no APB wait states are inserted;
- APB transfer completes on PSEL && PENABLE && PREADY;
- PADDR[1:0] must be 2'b00;
- unsupported or unaligned address returns PSLVERR;
- invalid reads return PRDATA=0;
- invalid writes have no side effect;
- reserved bits read as zero and ignore writes.

## 2. Register Summary

| Offset | Name | Access | Description |
|---:|---|---|---|
| 0x000 | DMA_SRC_ADDR | R/W | Source byte address |
| 0x004 | DMA_TARGET_ADDR | R/W | Target byte address |
| 0x008 | DMA_LENGTH | R/W | Transfer length and Source/Target Single mode |
| 0x00C | DMA_CTRL | mixed | START command, BUSY, STATUS_CODE |
| 0x010 | INTR_CTRL | mixed | IRQ pending and W1C clear |

## 3. DMA_SRC_ADDR — 0x000

| Bits | Access | Reset | Name | Description |
|---|---|---:|---|---|
| [31:0] | R/W | 0x00000000 | SRC_ADDR | Source byte address |

Requirements:

- must align to BYTES_PER_BEAT;
- misalignment causes CONFIG_ERROR when START is validated;
- the stored value may be changed while DMA is running, but the current transfer uses the accepted snapshot.

## 4. DMA_TARGET_ADDR — 0x004

| Bits | Access | Reset | Name | Description |
|---|---|---:|---|---|
| [31:0] | R/W | 0x00000000 | TARGET_ADDR | Target byte address |

Requirements:

- must align to BYTES_PER_BEAT;
- misalignment causes CONFIG_ERROR when START is validated;
- current DMA execution uses the START snapshot.

## 5. DMA_LENGTH — 0x008

| Bits | Access | Reset | Name | Description |
|---|---|---:|---|---|
| [31:18] | RAZ/WI | 0 | RESERVED | Reserved |
| [17] | R/W | 0 | TARGET_SINGLE | 1: every Target AWLEN=0; 0: burst mode |
| [16] | R/W | 0 | SOURCE_SINGLE | 1: every Source ARLEN=0; 0: burst mode |
| [15:12] | RAZ/WI | 0 | RESERVED | Reserved |
| [11:0] | R/W | 0 | LENGTH_MINUS_1 | Transfer bytes minus one |

Transfer size:

```text
TRANSFER_BYTES = LENGTH_MINUS_1 + 1
```

Legal range:

- 1 byte to 4096 bytes.

Examples:

- LENGTH_MINUS_1 = 0x000 -> 1 byte;
- LENGTH_MINUS_1 = 0x003 -> 4 bytes;
- LENGTH_MINUS_1 = 0xFFF -> 4096 bytes.

Single mode changes AxLEN only. AxSIZE remains based on AXI_DATA_WIDTH.

## 6. DMA_CTRL — 0x00C

### 6.1 Read view

| Bits | Access | Reset | Name | Description |
|---|---|---:|---|---|
| [31] | R | 0 | BUSY | Synchronized AXI-domain busy state |
| [30:4] | RAZ | 0 | RESERVED | Reserved |
| [3:0] | R | 0 | STATUS_CODE | Current/last accepted DMA status |

### 6.2 Write view

| Bits | Access | Name | Description |
|---|---|---|---|
| [31] | W1 command | START | Write 1 requests a DMA start |
| [30:0] | WI | - | Ignored |

START is a command, not a stored register bit.

Write 0 to START has no effect.

If DMA is already known busy, START is ignored.

Hardware does not implement a command queue or protection against repeated START during the CDC acceptance window. Software must serialize START requests.

### 6.3 STATUS_CODE

| Value | Name | Meaning |
|---:|---|---|
| 0x0 | NO_ERROR | No error / normal completion status |
| 0x8 | SRC_RESP_ERROR | Source RRESP error |
| 0x9 | DST_RESP_ERROR | Target BRESP error |
| 0xA | SRC_TIMEOUT | Source AXI timeout |
| 0xB | DST_TIMEOUT | Target AXI timeout |
| 0xC | CONFIG_ERROR | Runtime configuration validation failure |
| 0xD | SRC_PROTOCOL_ERROR | Source RLAST protocol fault |

Codes not listed above are reserved.

Status handling:

- accepted START clears prior status;
- ignored START does not change status;
- first-error-wins;
- same-cycle first Source and Target error -> Source wins;
- same-side priority -> protocol > response > timeout;
- protocol fault may force reset-required behavior even if another status was already latched.

## 7. INTR_CTRL — 0x010

### 7.1 Read view

| Bits | Access | Reset | Name | Description |
|---|---|---:|---|---|
| [0] | R | 0 | IRQ_PENDING | 1 when interrupt is pending |
| [31:1] | RAZ | 0 | RESERVED | Reserved |

### 7.2 Write view

| Bits | Access | Name | Description |
|---|---|---|---|
| [0] | W1C | IRQ_CLEAR | Write 1 clears pending IRQ |
| [31:1] | WI | - | Ignored |

Interrupt events include:

- normal DMA completion;
- Source timeout;
- Target timeout;
- Source response error;
- Target response error;
- CONFIG_ERROR;
- SRC_PROTOCOL_ERROR.

If an interrupt clear and a new event reach the PCLK domain in the same cycle, the new event wins and IRQ_PENDING remains set.

An error/timeout IRQ may be published before BUSY returns to zero because recovery can still be in progress.

## 8. Reset Values

All software-visible registers reset to zero.

Therefore after reset:

```text
DMA_SRC_ADDR      = 0x00000000
DMA_TARGET_ADDR   = 0x00000000
DMA_LENGTH        = 0x00000000
DMA_CTRL.BUSY     = 0
DMA_CTRL.STATUS   = 0x0
INTR_CTRL.PENDING = 0
```

DMA_LENGTH=0 encodes a 1-byte transfer configuration, but reset itself does not start a DMA.

Source and Target default to burst mode because SOURCE_SINGLE and TARGET_SINGLE reset to zero.

## 9. Accepted START Sequence

Conceptual software-visible sequence:

```text
APB START write accepted
        |
        v
clear previous STATUS_CODE
        |
        v
clear previous IRQ pending
        |
        v
latch configuration snapshot
        |
        v
transfer snapshot to AXI_CLK
        |
        v
runtime validation
        |
        +---- invalid ----> CONFIG_ERROR + IRQ, BUSY remains 0
        |
        +---- valid ------> BUSY=1, DMA execution begins
```

Configuration writes during an active DMA only affect the next DMA snapshot.

## 10. Recommended Software Sequence

1. Ensure previous DMA result has been fully observed.
2. Write DMA_SRC_ADDR.
3. Write DMA_TARGET_ADDR.
4. Write DMA_LENGTH.
5. Write 1 to DMA_CTRL[31].
6. Wait for interrupt/event.
7. Read DMA_CTRL.BUSY and STATUS_CODE.
8. Treat NO_ERROR as success only after normal completion.
9. Clear IRQ using INTR_CTRL[0]=1.
10. If SRC_PROTOCOL_ERROR occurs, perform coordinated reset before reuse.

Software must not use an immediate BUSY=0 read after START as proof that the DMA has completed because BUSY crosses from AXI_CLK to PCLK asynchronously.

## 11. Architecture Notes

The APB register bank is owned entirely by the PCLK domain.

The active DMA configuration is owned by AXI_CLK-domain shadow registers created from the coherent START snapshot.

This separation allows software-visible configuration registers to be modified for the next DMA while the current DMA continues using an immutable snapshot.
