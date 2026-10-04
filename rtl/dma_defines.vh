`ifndef AXI2AXI_DMA_DEFINES_VH
`define AXI2AXI_DMA_DEFINES_VH

// DMA status codes
`define DMA_STATUS_NO_ERROR            4'h0
`define DMA_STATUS_SRC_RESP_ERROR      4'h8
`define DMA_STATUS_DST_RESP_ERROR      4'h9
`define DMA_STATUS_SRC_TIMEOUT         4'hA
`define DMA_STATUS_DST_TIMEOUT         4'hB
`define DMA_STATUS_CONFIG_ERROR        4'hC
`define DMA_STATUS_SRC_PROTOCOL_ERROR  4'hD

// AXI response encodings
`define AXI_RESP_OKAY                  2'b00
`define AXI_RESP_EXOKAY                2'b01
`define AXI_RESP_SLVERR                2'b10
`define AXI_RESP_DECERR                2'b11

// AXI burst encodings
`define AXI_BURST_FIXED                2'b00
`define AXI_BURST_INCR                 2'b01
`define AXI_BURST_WRAP                 2'b10

`endif
