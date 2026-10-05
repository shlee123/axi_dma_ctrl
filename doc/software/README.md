# AXI2AXI DMA Software Programming Guide

Word guides based on the existing specification v0.2 and register map v0.1.
The guide documents the current APB3 programming contract; the previously discussed AXI4-Lite, 64-bit address, and software Abort proposals are not incorporated.

## Review draft v0.2

- [Traditional Chinese](AXI2AXI_DMA_Software_Programming_Guide_v0.2_zh-TW.docx)
- [English](AXI2AXI_DMA_Software_Programming_Guide_v0.2_en.docx)

Eight separate chapters: Register map; Register bit-fields; Software programming flow; Interrupt; Error handling; Transfer restrictions; C / pseudocode; Software-visible limitations.
The datasheet includes a block diagram and full hardware interface tables.
The functional contract remains based on the existing specification v0.2.

## Previous edition v0.1

- [Traditional Chinese](AXI2AXI_DMA_Software_Programming_Guide_v0.1_zh-TW.docx)
- [English](AXI2AXI_DMA_Software_Programming_Guide_v0.1_en.docx)

C-style examples require platform MMIO, barriers, DMA cache ownership, timer, IRQ, and coordinated-reset hooks.
Software must serialize START, wait for the current command's event, and finish error recovery before reuse.

Inspected RTL baseline: `62afb73f64ca234cd5cc13379527a5b7152fd93f`.
