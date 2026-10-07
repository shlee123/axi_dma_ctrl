`timescale 1ns/1ps

`include "dma_defines.vh"

module dma_ctrl #(
    parameter integer AXI_ADDR_WIDTH   = 32,
    parameter integer AXI_DATA_WIDTH   = 32,
    parameter integer FIFO_COUNT_WIDTH = 4
)(
    input  wire                      clk,
    input  wire                      rst_n,

    // Command from dma_cdc
    input  wire                      cmd_valid,
    output wire                      cmd_ready,
    input  wire [AXI_ADDR_WIDTH-1:0] cmd_src_addr,
    input  wire [AXI_ADDR_WIDTH-1:0] cmd_dst_addr,
    input  wire [11:0]               cmd_length_minus_1,
    input  wire                      cmd_source_single,
    input  wire                      cmd_target_single,

    // Read-engine command/status
    output reg                       rd_start,
    output wire                      rd_abort_new,
    output reg [AXI_ADDR_WIDTH-1:0]  rd_src_addr,
    output reg [12:0]                rd_transfer_bytes,
    output reg                       rd_source_single,
    input  wire                      rd_busy,
    input  wire                      rd_done,
    input  wire                      rd_error_valid,
    input  wire [3:0]                rd_error_code,
    input  wire                      rd_protocol_fault,

    // Write-engine command/status
    output reg                       wr_start,
    output wire                      wr_abort_new,
    output reg [AXI_ADDR_WIDTH-1:0]  wr_dst_addr,
    output reg [12:0]                wr_transfer_bytes,
    output reg                       wr_target_single,
    input  wire                      wr_busy,
    input  wire                      wr_done,
    input  wire                      wr_error_valid,
    input  wire [3:0]                wr_error_code,

    // FIFO status / recovery
    input  wire [FIFO_COUNT_WIDTH-1:0] fifo_verified_count,
    input  wire [FIFO_COUNT_WIDTH-1:0] fifo_unverified_count,
    input  wire [FIFO_COUNT_WIDTH-1:0] fifo_reserved_count,
    output reg                       fifo_flush_uncommitted,

    // DMA status/event toward dma_cdc
    output reg                       dma_busy,
    output reg [3:0]                 dma_status_code,
    output reg                       event_valid,
    input  wire                      event_ready,
    output reg [3:0]                 event_status
);

    localparam integer BYTES_PER_BEAT = AXI_DATA_WIDTH / 8;
    localparam integer BEAT_SHIFT =
        (BYTES_PER_BEAT <= 1)   ? 0 :
        (BYTES_PER_BEAT <= 2)   ? 1 :
        (BYTES_PER_BEAT <= 4)   ? 2 :
        (BYTES_PER_BEAT <= 8)   ? 3 :
        (BYTES_PER_BEAT <= 16)  ? 4 :
        (BYTES_PER_BEAT <= 32)  ? 5 :
        (BYTES_PER_BEAT <= 64)  ? 6 :
        (BYTES_PER_BEAT <= 128) ? 7 : 8;

    localparam [2:0]
        CTRL_IDLE           = 3'd0,
        CTRL_VALIDATE       = 3'd1,
        CTRL_RUN            = 3'd2,
        CTRL_RECOVERY       = 3'd3,
        CTRL_COMPLETE       = 3'd4,
        CTRL_PROTOCOL_FAULT = 3'd5;

    reg [2:0] state;

    reg [AXI_ADDR_WIDTH-1:0] cfg_src_addr;
    reg [AXI_ADDR_WIDTH-1:0] cfg_dst_addr;
    reg [12:0]               cfg_transfer_bytes;
    reg                      cfg_source_single;
    reg                      cfg_target_single;

    reg first_error_valid;
    reg protocol_fault_latched;
    reg src_done_seen;
    reg dst_done_seen;

    wire src_aligned;
    wire dst_aligned;
    wire config_valid;
    wire obligations_clear;
    wire normal_payload_clear;
    wire cmd_accept;

    wire source_error_now;
    wire target_error_now;
    wire protocol_fault_now;

    assign cmd_ready  = (state == CTRL_IDLE) && !event_valid;
    assign cmd_accept = cmd_valid && cmd_ready;

    generate
        if (BEAT_SHIFT == 0) begin : g_align_1
            assign src_aligned = 1'b1;
            assign dst_aligned = 1'b1;
        end else begin : g_align_n
            assign src_aligned = (cfg_src_addr[BEAT_SHIFT-1:0] == {BEAT_SHIFT{1'b0}});
            assign dst_aligned = (cfg_dst_addr[BEAT_SHIFT-1:0] == {BEAT_SHIFT{1'b0}});
        end
    endgenerate

    assign config_valid = src_aligned && dst_aligned;

    assign source_error_now = rd_error_valid;
    assign target_error_now = wr_error_valid;
    assign protocol_fault_now = rd_protocol_fault ||
                                (rd_error_valid &&
                                 (rd_error_code == `DMA_STATUS_SRC_PROTOCOL_ERROR));

    // Engines keep busy asserted while an already-existing AXI obligation
    // still requires service. Recovery may finish only when both are idle
    // and no Target reservation remains protected.
    assign obligations_clear = !rd_busy &&
                               !wr_busy &&
                               (fifo_reserved_count == 0);

    assign normal_payload_clear = (fifo_verified_count == 0) &&
                                  (fifo_unverified_count == 0) &&
                                  (fifo_reserved_count == 0);

    assign rd_abort_new = (state == CTRL_RECOVERY) ||
                          (state == CTRL_PROTOCOL_FAULT) ||
                          first_error_valid ||
                          protocol_fault_latched;

    assign wr_abort_new = rd_abort_new;

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            state                   <= CTRL_IDLE;

            cfg_src_addr            <= {AXI_ADDR_WIDTH{1'b0}};
            cfg_dst_addr            <= {AXI_ADDR_WIDTH{1'b0}};
            cfg_transfer_bytes      <= 13'd0;
            cfg_source_single       <= 1'b0;
            cfg_target_single       <= 1'b0;

            rd_start                <= 1'b0;
            rd_src_addr             <= {AXI_ADDR_WIDTH{1'b0}};
            rd_transfer_bytes       <= 13'd0;
            rd_source_single        <= 1'b0;

            wr_start                <= 1'b0;
            wr_dst_addr             <= {AXI_ADDR_WIDTH{1'b0}};
            wr_transfer_bytes       <= 13'd0;
            wr_target_single        <= 1'b0;

            fifo_flush_uncommitted  <= 1'b0;

            dma_busy                <= 1'b0;
            dma_status_code         <= `DMA_STATUS_NO_ERROR;
            event_valid             <= 1'b0;
            event_status            <= `DMA_STATUS_NO_ERROR;

            first_error_valid       <= 1'b0;
            protocol_fault_latched  <= 1'b0;
            src_done_seen           <= 1'b0;
            dst_done_seen           <= 1'b0;
        end else begin
            rd_start               <= 1'b0;
            wr_start               <= 1'b0;
            fifo_flush_uncommitted <= 1'b0;
            if (event_valid && event_ready)
                event_valid <= 1'b0;

            case (state)
                CTRL_IDLE: begin
                    dma_busy <= 1'b0;

                    if (cmd_accept) begin
                        cfg_src_addr       <= cmd_src_addr;
                        cfg_dst_addr       <= cmd_dst_addr;
                        cfg_transfer_bytes <= {1'b0,cmd_length_minus_1} + 13'd1;
                        cfg_source_single  <= cmd_source_single;
                        cfg_target_single  <= cmd_target_single;

                        // Accepted START clears previous status in the AXI
                        // domain. PCLK-side IRQ clearing remains software/W1C.
                        dma_status_code        <= `DMA_STATUS_NO_ERROR;
                        first_error_valid      <= 1'b0;
                        protocol_fault_latched <= 1'b0;
                        src_done_seen          <= 1'b0;
                        dst_done_seen          <= 1'b0;

                        state <= CTRL_VALIDATE;
                    end
                end

                CTRL_VALIDATE: begin
                    if (!config_valid) begin
                        dma_busy        <= 1'b0;
                        dma_status_code <= `DMA_STATUS_CONFIG_ERROR;
                        event_valid     <= 1'b1;
                        event_status    <= `DMA_STATUS_CONFIG_ERROR;
                        state           <= CTRL_IDLE;
                    end else begin
                        rd_src_addr       <= cfg_src_addr;
                        rd_transfer_bytes <= cfg_transfer_bytes;
                        rd_source_single  <= cfg_source_single;

                        wr_dst_addr       <= cfg_dst_addr;
                        wr_transfer_bytes <= cfg_transfer_bytes;
                        wr_target_single  <= cfg_target_single;

                        rd_start <= 1'b1;
                        wr_start <= 1'b1;
                        dma_busy <= 1'b1;
                        state    <= CTRL_RUN;
                    end
                end

                CTRL_RUN: begin
                    dma_busy <= 1'b1;

                    if (rd_done)
                        src_done_seen <= 1'b1;
                    if (wr_done)
                        dst_done_seen <= 1'b1;

                    // Protocol fault behavior has priority over ordinary
                    // recovery, even when an earlier error already owns
                    // STATUS_CODE.
                    if (protocol_fault_now || protocol_fault_latched) begin
                        protocol_fault_latched <= 1'b1;

                        if (!first_error_valid) begin
                            first_error_valid <= 1'b1;
                            dma_status_code   <= `DMA_STATUS_SRC_PROTOCOL_ERROR;
                            event_valid       <= 1'b1;
                            event_status      <= `DMA_STATUS_SRC_PROTOCOL_ERROR;
                        end

                        state <= CTRL_PROTOCOL_FAULT;
                    end else if (source_error_now || target_error_now) begin
                        if (!first_error_valid) begin
                            first_error_valid <= 1'b1;
                            event_valid       <= 1'b1;

                            // Source wins over Target on same-cycle first error.
                            if (source_error_now) begin
                                dma_status_code <= rd_error_code;
                                event_status    <= rd_error_code;
                            end else begin
                                dma_status_code <= wr_error_code;
                                event_status    <= wr_error_code;
                            end
                        end

                        state <= CTRL_RECOVERY;
                    end else if ((src_done_seen || rd_done) &&
                                 (dst_done_seen || wr_done) &&
                                 normal_payload_clear) begin
                        state <= CTRL_COMPLETE;
                    end
                end

                CTRL_RECOVERY: begin
                    dma_busy <= 1'b1;

                    if (protocol_fault_now) begin
                        protocol_fault_latched <= 1'b1;
                        // First-error-wins preserves an earlier status/event.
                        if (!first_error_valid) begin
                            first_error_valid <= 1'b1;
                            dma_status_code   <= `DMA_STATUS_SRC_PROTOCOL_ERROR;
                            event_valid       <= 1'b1;
                            event_status      <= `DMA_STATUS_SRC_PROTOCOL_ERROR;
                        end
                        state <= CTRL_PROTOCOL_FAULT;
                    end else if (obligations_clear) begin
                        // Verified/unverified data not committed to a Target
                        // obligation is discarded after all obligations end.
                        fifo_flush_uncommitted <= 1'b1;
                        dma_busy               <= 1'b0;
                        state                  <= CTRL_IDLE;
                    end
                end

                CTRL_COMPLETE: begin
                    dma_busy        <= 1'b0;
                    dma_status_code <= `DMA_STATUS_NO_ERROR;

                    if (!event_valid) begin
                        event_valid  <= 1'b1;
                        event_status <= `DMA_STATUS_NO_ERROR;
                    end else if (event_ready) begin
                        state <= CTRL_IDLE;
                    end
                end

                CTRL_PROTOCOL_FAULT: begin
                    // Reset-required state.
                    dma_busy               <= 1'b1;
                    protocol_fault_latched <= 1'b1;
                end

                default: begin
                    state    <= CTRL_IDLE;
                    dma_busy <= 1'b0;
                end
            endcase
        end
    end

endmodule
