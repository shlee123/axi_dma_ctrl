# AXI2AXI DMA Datasheet

Word datasheets based on `doc/specification/AXI2AXI_DMA_Specification_v0.2.txt`.
The existing APB3 control interface, 32-bit DMA addresses, register map, and status codes are preserved.

## Review draft v0.2

- [Traditional Chinese](AXI2AXI_DMA_Datasheet_v0.2_zh-TW.docx)
- [English](AXI2AXI_DMA_Datasheet_v0.2_en.docx)

Eight separate chapters: Features; Block diagram; Clock / Reset; HW interface; AXI protocol assumptions; Parameters; Performance / limitations; HW constraints.
The datasheet includes a block diagram and full hardware interface tables.
The functional contract remains based on the existing specification v0.2.

## Previous edition v0.1

- [Traditional Chinese](AXI2AXI_DMA_Datasheet_v0.1_zh-TW.docx)
- [English](AXI2AXI_DMA_Datasheet_v0.1_en.docx)

Inspected RTL baseline: `62afb73f64ca234cd5cc13379527a5b7152fd93f`.
See `../software/` for register programming, polling, interrupt, and recovery examples.
