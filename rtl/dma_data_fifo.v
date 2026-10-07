`timescale 1ns/1ps

module dma_data_fifo #(
    parameter integer DATA_WIDTH      = 32,
    parameter integer DEPTH           = 8,
    parameter integer PTR_WIDTH       = (DEPTH <= 2) ? 1 : $clog2(DEPTH),
    parameter integer COUNT_WIDTH     = $clog2(DEPTH + 1)
)(
    input  wire                         clk,
    input  wire                         rst_n,

    // Source burst lifecycle
    input  wire                         src_burst_begin,
    input  wire                         src_wr_valid,
    output wire                         src_wr_ready,
    input  wire [DATA_WIDTH-1:0]        src_wr_data,

    input  wire                         src_commit_valid,
    input  wire [COUNT_WIDTH-1:0]       src_commit_beats,
    input  wire                         src_discard_valid,
    input  wire [COUNT_WIDTH-1:0]       src_discard_beats,

    // Target reservation
    input  wire                         dst_reserve_valid,
    input  wire [COUNT_WIDTH-1:0]       dst_reserve_beats,
    output wire                         dst_reserve_ready,

    // Target W data consumption.
    // dst_rd_advance must pulse only on a successful W handshake.
    output wire                         dst_rd_valid,
    output wire [DATA_WIDTH-1:0]        dst_rd_data,
    input  wire                         dst_rd_advance,

    // Entire reservation is released on the final W handshake.
    input  wire                         dst_release_valid,
    input  wire [COUNT_WIDTH-1:0]       dst_release_beats,

    // Recovery flush is legal only after protected Target obligations end.
    input  wire                         flush_uncommitted,

    // Bookkeeping status
    output wire [COUNT_WIDTH-1:0]       free_count,
    output reg  [COUNT_WIDTH-1:0]       verified_count,
    output reg  [COUNT_WIDTH-1:0]       unverified_count,
    output reg  [COUNT_WIDTH-1:0]       reserved_count,
    output wire                         empty,
    output wire                         full
);

    reg [DATA_WIDTH-1:0] mem [0:DEPTH-1];

    reg [PTR_WIDTH-1:0] wr_ptr;
    reg [PTR_WIDTH-1:0] burst_start_wr_ptr;
    reg [PTR_WIDTH-1:0] rd_ptr;

    reg [COUNT_WIDTH-1:0] verified_count_n;
    reg [COUNT_WIDTH-1:0] unverified_count_n;
    reg [COUNT_WIDTH-1:0] reserved_count_n;

    wire [COUNT_WIDTH:0] occupied_ext;
    wire                  src_write_fire;
    wire                  dst_reserve_fire;

    assign occupied_ext = {1'b0, verified_count}
                        + {1'b0, unverified_count}
                        + {1'b0, reserved_count};

    assign free_count = DEPTH - occupied_ext[COUNT_WIDTH-1:0];

    assign empty = (occupied_ext == 0);
    assign full  = (occupied_ext == DEPTH);

    assign src_wr_ready = !full;
    assign src_write_fire = src_wr_valid && src_wr_ready;

    // Only verified data can be reserved.
    assign dst_reserve_ready =
        (dst_reserve_beats != 0) &&
        (verified_count >= dst_reserve_beats);

    assign dst_reserve_fire = dst_reserve_valid && dst_reserve_ready;

    assign dst_rd_valid = (reserved_count != 0);
    assign dst_rd_data  = mem[rd_ptr];

    function [PTR_WIDTH-1:0] ptr_next;
        input [PTR_WIDTH-1:0] ptr;
        begin
            if (ptr == DEPTH-1)
                ptr_next = {PTR_WIDTH{1'b0}};
            else
                ptr_next = ptr + 1'b1;
        end
    endfunction

    // Counter next-state logic.
    // This form intentionally supports independent Source and Target
    // state transitions in the same AXI_CLK cycle.
    always @(*) begin
        verified_count_n   = verified_count;
        unverified_count_n = unverified_count;
        reserved_count_n   = reserved_count;

        if (src_write_fire)
            unverified_count_n = unverified_count_n + 1'b1;

        if (src_commit_valid) begin
            unverified_count_n = unverified_count_n - src_commit_beats;
            verified_count_n   = verified_count_n + src_commit_beats;
        end

        if (src_discard_valid)
            unverified_count_n = unverified_count_n - src_discard_beats;

        if (dst_reserve_fire) begin
            verified_count_n = verified_count_n - dst_reserve_beats;
            reserved_count_n = reserved_count_n + dst_reserve_beats;
        end

        if (dst_release_valid)
            reserved_count_n = reserved_count_n - dst_release_beats;

        if (flush_uncommitted) begin
            verified_count_n   = {COUNT_WIDTH{1'b0}};
            unverified_count_n = {COUNT_WIDTH{1'b0}};
            // By contract flush_uncommitted is asserted only when
            // reserved_count is already zero.
            reserved_count_n   = reserved_count;
        end
    end

    // Data RAM write and pointer progression.
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            wr_ptr             <= {PTR_WIDTH{1'b0}};
            burst_start_wr_ptr <= {PTR_WIDTH{1'b0}};
            rd_ptr             <= {PTR_WIDTH{1'b0}};
        end else begin
            if (src_burst_begin)
                burst_start_wr_ptr <= wr_ptr;

            if (src_write_fire) begin
                mem[wr_ptr] <= src_wr_data;
                wr_ptr      <= ptr_next(wr_ptr);
            end

            // Discard has priority over normal write-pointer progression.
            // Contract: discard is issued after the last accepted/drained
            // beat decision, not in the same cycle as src_write_fire.
            if (src_discard_valid)
                wr_ptr <= burst_start_wr_ptr;

            if (dst_rd_advance)
                rd_ptr <= ptr_next(rd_ptr);

            // Recovery flush occurs only after all protected Target
            // obligations are complete, so rd_ptr marks the empty boundary.
            if (flush_uncommitted)
                wr_ptr <= rd_ptr;
        end
    end

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            verified_count   <= {COUNT_WIDTH{1'b0}};
            unverified_count <= {COUNT_WIDTH{1'b0}};
            reserved_count   <= {COUNT_WIDTH{1'b0}};
        end else begin
            verified_count   <= verified_count_n;
            unverified_count <= unverified_count_n;
            reserved_count   <= reserved_count_n;
        end
    end

endmodule
