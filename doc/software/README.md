# AXI2AXI DMA Software Programming Guide

Word guides based on the existing specification v0.2 and register map v0.1.
The guide documents the current APB3 programming contract; the previously discussed AXI4-Lite, 64-bit address, and software Abort proposals are not incorporated.

- [Traditional Chinese](AXI2AXI_DMA_Software_Programming_Guide_v0.1_zh-TW.docx)
- [English](AXI2AXI_DMA_Software_Programming_Guide_v0.1_en.docx)

C-style examples require platform MMIO, barriers, DMA cache ownership, timer, IRQ, and coordinated-reset hooks.
Software must serialize START, wait for the current command's event, and finish error recovery before reuse.

Inspected RTL baseline: `62afb73f64ca234cd5cc13379527a5b7152fd93f`.
