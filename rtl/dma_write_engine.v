`include "dma_defines.vh"

module dma_write_engine #(
    parameter integer AXI_ADDR_WIDTH      = 32,
    parameter integer AXI_DATA_WIDTH      = 32,
    parameter integer AXI_ID_WIDTH        = 6,
    parameter integer MAX_BURST_LENGTH    = 8,
    parameter integer FIFO_COUNT_WIDTH    = 4,
    parameter integer AXI_TIMEOUT_CYCLES  = 1024,
    parameter [AXI_ID_WIDTH-1:0] AXI_ID_VALUE = {AXI_ID_WIDTH{1'b0}}
)(
    input  wire                         clk,
    input  wire                         rst_n,

    // DMA command
    input  wire                         wr_start,
    input  wire                         wr_abort_new,
    input  wire [AXI_ADDR_WIDTH-1:0]    wr_dst_addr,
    input  wire [12:0]                  wr_transfer_bytes,
    input  wire                         wr_target_single,

    output reg                          wr_busy,
    output reg                          wr_done,
    output reg                          wr_error_valid,
    output reg  [3:0]                   wr_error_code,

    // FIFO reservation/data interface
    input  wire [FIFO_COUNT_WIDTH-1:0]  fifo_verified_count,
    output reg                          fifo_reserve_valid,
    output reg  [FIFO_COUNT_WIDTH-1:0]  fifo_reserve_beats,
    input  wire                         fifo_reserve_ready,

    input  wire                         fifo_rd_valid,
    input  wire [AXI_DATA_WIDTH-1:0]    fifo_rd_data,
    output wire                         fifo_rd_advance,

    output reg                          fifo_release_valid,
    output reg  [FIFO_COUNT_WIDTH-1:0]  fifo_release_beats,

    // Target AXI AW
    output reg  [AXI_ID_WIDTH-1:0]      m_axi_awid,
    output reg  [AXI_ADDR_WIDTH-1:0]    m_axi_awaddr,
    output reg  [7:0]                   m_axi_awlen,
    output reg  [2:0]                   m_axi_awsize,
    output reg  [1:0]                   m_axi_awburst,
    output reg                          m_axi_awvalid,
    input  wire                         m_axi_awready,

    // Target AXI W
    output wire [AXI_DATA_WIDTH-1:0]    m_axi_wdata,
    output wire [(AXI_DATA_WIDTH/8)-1:0] m_axi_wstrb,
    output wire                         m_axi_wlast,
    output wire                         m_axi_wvalid,
    input  wire                         m_axi_wready,

    // Target AXI B
    input  wire [AXI_ID_WIDTH-1:0]      m_axi_bid,
    input  wire [1:0]                   m_axi_bresp,
    input  wire                         m_axi_bvalid,
    output wire                         m_axi_bready
);

    localparam integer BYTES_PER_BEAT = AXI_DATA_WIDTH / 8;
    localparam integer STRB_WIDTH = AXI_DATA_WIDTH / 8;
    localparam integer BEAT_SHIFT =
        (BYTES_PER_BEAT <= 1)   ? 0 :
        (BYTES_PER_BEAT <= 2)   ? 1 :
        (BYTES_PER_BEAT <= 4)   ? 2 :
        (BYTES_PER_BEAT <= 8)   ? 3 :
        (BYTES_PER_BEAT <= 16)  ? 4 :
        (BYTES_PER_BEAT <= 32)  ? 5 :
        (BYTES_PER_BEAT <= 64)  ? 6 :
        (BYTES_PER_BEAT <= 128) ? 7 : 8;

    localparam integer TIMEOUT_WIDTH =
        (AXI_TIMEOUT_CYCLES <= 1) ? 1 : $clog2(AXI_TIMEOUT_CYCLES + 1);

    localparam [2:0]
        WR_IDLE     = 3'd0,
        WR_PLAN     = 3'd1,
        WR_RESERVE  = 3'd2,
        WR_AW_WAIT  = 3'd3,
        WR_W_DATA   = 3'd4,
        WR_B_WAIT   = 3'd5,
        WR_HALT     = 3'd6;

    reg [2:0] state;

    reg [AXI_ADDR_WIDTH-1:0] next_addr;
    reg [12:0] remaining_bytes;
    reg        target_single;

    reg [8:0] planned_beats;
    reg [8:0] active_beats;
    reg [8:0] w_beat_index;
    reg [12:0] active_bytes;
    reg [12:0] active_last_valid_bytes;

    reg       burst_error_latched;
    reg       timeout_reported;
    reg [TIMEOUT_WIDTH-1:0] timeout_count;

    reg [12:0] plan_remaining_beats;
    reg [12:0] plan_4k_beats;
    reg [12:0] plan_limit_beats_wide;
    reg [8:0]  plan_limit_beats;

    wire bid_match;
    wire aw_fire;
    wire w_fire;
    wire b_fire;
    wire final_w_beat;

    reg [STRB_WIDTH-1:0] final_wstrb;
    integer i;

    assign bid_match = (m_axi_bid == AXI_ID_VALUE);
    assign aw_fire = m_axi_awvalid && m_axi_awready;

    assign m_axi_wvalid = (state == WR_W_DATA) && fifo_rd_valid;
    assign m_axi_wdata  = fifo_rd_data;
    assign final_w_beat = (w_beat_index + 1'b1 == active_beats);
    assign m_axi_wlast  = m_axi_wvalid && final_w_beat;
    assign w_fire       = m_axi_wvalid && m_axi_wready;
    assign fifo_rd_advance = w_fire;

    assign m_axi_wstrb = final_w_beat ? final_wstrb : {STRB_WIDTH{1'b1}};

    // Mismatched BID is not accepted.
    assign m_axi_bready = (state == WR_B_WAIT) && bid_match;
    assign b_fire = m_axi_bvalid && m_axi_bready;

    always @(*) begin
        plan_remaining_beats = (remaining_bytes + BYTES_PER_BEAT - 1) >> BEAT_SHIFT;
        plan_4k_beats = (13'd4096 - {1'b0,next_addr[11:0]}) >> BEAT_SHIFT;
        if (plan_4k_beats == 0)
            plan_4k_beats = 13'd1;

        plan_limit_beats_wide = plan_remaining_beats;
        if (plan_limit_beats_wide > MAX_BURST_LENGTH)
            plan_limit_beats_wide = MAX_BURST_LENGTH;
        if (plan_limit_beats_wide > plan_4k_beats)
            plan_limit_beats_wide = plan_4k_beats;

        plan_limit_beats = plan_limit_beats_wide[8:0];
        if (target_single && (plan_limit_beats != 0))
            plan_limit_beats = 9'd1;

        final_wstrb = {STRB_WIDTH{1'b0}};
        if (active_last_valid_bytes == 0 || active_last_valid_bytes >= BYTES_PER_BEAT) begin
            final_wstrb = {STRB_WIDTH{1'b1}};
        end else begin
            for (i=0; i<STRB_WIDTH; i=i+1)
                if (i < active_last_valid_bytes)
                    final_wstrb[i] = 1'b1;
        end
    end

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            state                  <= WR_IDLE;
            wr_busy                <= 1'b0;
            wr_done                <= 1'b0;
            wr_error_valid         <= 1'b0;
            wr_error_code          <= `DMA_STATUS_NO_ERROR;

            next_addr              <= {AXI_ADDR_WIDTH{1'b0}};
            remaining_bytes        <= 13'd0;
            target_single          <= 1'b0;

            planned_beats          <= 9'd0;
            active_beats           <= 9'd0;
            w_beat_index           <= 9'd0;
            active_bytes           <= 13'd0;
            active_last_valid_bytes<= 13'd0;

            burst_error_latched    <= 1'b0;
            timeout_reported       <= 1'b0;
            timeout_count          <= {TIMEOUT_WIDTH{1'b0}};

            fifo_reserve_valid     <= 1'b0;
            fifo_reserve_beats     <= {FIFO_COUNT_WIDTH{1'b0}};
            fifo_release_valid     <= 1'b0;
            fifo_release_beats     <= {FIFO_COUNT_WIDTH{1'b0}};

            m_axi_awid             <= AXI_ID_VALUE;
            m_axi_awaddr           <= {AXI_ADDR_WIDTH{1'b0}};
            m_axi_awlen            <= 8'd0;
            m_axi_awsize           <= BEAT_SHIFT[2:0];
            m_axi_awburst          <= `AXI_BURST_INCR;
            m_axi_awvalid          <= 1'b0;
        end else begin
            wr_done            <= 1'b0;
            wr_error_valid     <= 1'b0;
            fifo_release_valid <= 1'b0;

            case (state)
                WR_IDLE: begin
                    wr_busy            <= 1'b0;
                    timeout_count      <= {TIMEOUT_WIDTH{1'b0}};
                    timeout_reported   <= 1'b0;
                    burst_error_latched<= 1'b0;
                    fifo_reserve_valid <= 1'b0;
                    m_axi_awvalid      <= 1'b0;

                    if (wr_start) begin
                        wr_busy         <= 1'b1;
                        next_addr       <= wr_dst_addr;
                        remaining_bytes <= wr_transfer_bytes;
                        target_single   <= wr_target_single;
                        wr_error_code   <= `DMA_STATUS_NO_ERROR;
                        state           <= WR_PLAN;
                    end
                end

                WR_PLAN: begin
                    timeout_count <= {TIMEOUT_WIDTH{1'b0}};

                    if (wr_abort_new) begin
                        state <= WR_HALT;
                    end else if (remaining_bytes == 0) begin
                        wr_done <= 1'b1;
                        wr_busy <= 1'b0;
                        state   <= WR_IDLE;
                    end else if ((plan_limit_beats != 0) &&
                                 (fifo_verified_count >= plan_limit_beats[FIFO_COUNT_WIDTH-1:0])) begin
                        planned_beats      <= plan_limit_beats;
                        fifo_reserve_beats <= plan_limit_beats[FIFO_COUNT_WIDTH-1:0];
                        fifo_reserve_valid <= 1'b1;
                        state              <= WR_RESERVE;
                    end
                end

                WR_RESERVE: begin
                    if (fifo_reserve_valid && fifo_reserve_ready) begin
                        fifo_reserve_valid <= 1'b0;
                        active_beats       <= planned_beats;
                        w_beat_index       <= 9'd0;

                        if (remaining_bytes < planned_beats * BYTES_PER_BEAT)
                            active_bytes <= remaining_bytes;
                        else
                            active_bytes <= planned_beats * BYTES_PER_BEAT;

                        if (remaining_bytes < planned_beats * BYTES_PER_BEAT)
                            active_last_valid_bytes <= remaining_bytes - ((planned_beats-1) * BYTES_PER_BEAT);
                        else
                            active_last_valid_bytes <= BYTES_PER_BEAT;

                        m_axi_awaddr  <= next_addr;
                        m_axi_awlen   <= planned_beats[7:0] - 1'b1;
                        m_axi_awid    <= AXI_ID_VALUE;
                        m_axi_awsize  <= BEAT_SHIFT[2:0];
                        m_axi_awburst <= `AXI_BURST_INCR;
                        m_axi_awvalid <= 1'b1;

                        timeout_count       <= {TIMEOUT_WIDTH{1'b0}};
                        timeout_reported    <= 1'b0;
                        burst_error_latched <= 1'b0;
                        state               <= WR_AW_WAIT;
                    end
                end

                WR_AW_WAIT: begin
                    if (aw_fire) begin
                        m_axi_awvalid <= 1'b0;
                        next_addr <= next_addr + (active_beats * BYTES_PER_BEAT);
                        timeout_count <= {TIMEOUT_WIDTH{1'b0}};
                        state <= WR_W_DATA;
                    end else if ((AXI_TIMEOUT_CYCLES != 0) && !timeout_reported) begin
                        if (timeout_count == AXI_TIMEOUT_CYCLES-1) begin
                            wr_error_valid      <= 1'b1;
                            wr_error_code       <= `DMA_STATUS_DST_TIMEOUT;
                            timeout_reported    <= 1'b1;
                            burst_error_latched <= 1'b1;
                        end else begin
                            timeout_count <= timeout_count + 1'b1;
                        end
                    end
                end

                WR_W_DATA: begin
                    if (w_fire) begin
                        timeout_count <= {TIMEOUT_WIDTH{1'b0}};

                        if (final_w_beat) begin
                            fifo_release_valid <= 1'b1;
                            fifo_release_beats <= active_beats[FIFO_COUNT_WIDTH-1:0];
                            state              <= WR_B_WAIT;
                            timeout_reported   <= 1'b0;
                        end else begin
                            w_beat_index <= w_beat_index + 1'b1;
                        end
                    end else if ((AXI_TIMEOUT_CYCLES != 0) &&
                                 !timeout_reported &&
                                 m_axi_wvalid) begin
                        if (timeout_count == AXI_TIMEOUT_CYCLES-1) begin
                            wr_error_valid      <= 1'b1;
                            wr_error_code       <= `DMA_STATUS_DST_TIMEOUT;
                            timeout_reported    <= 1'b1;
                            burst_error_latched <= 1'b1;
                        end else begin
                            timeout_count <= timeout_count + 1'b1;
                        end
                    end
                end

                WR_B_WAIT: begin
                    if (b_fire) begin
                        timeout_count <= {TIMEOUT_WIDTH{1'b0}};

                        if (m_axi_bresp != `AXI_RESP_OKAY) begin
                            if (!burst_error_latched) begin
                                wr_error_valid <= 1'b1;
                                wr_error_code  <= `DMA_STATUS_DST_RESP_ERROR;
                            end
                            burst_error_latched <= 1'b1;
                            state <= WR_HALT;
                        end else if (burst_error_latched || wr_abort_new) begin
                            state <= WR_HALT;
                        end else begin
                            if (remaining_bytes <= active_bytes)
                                remaining_bytes <= 13'd0;
                            else
                                remaining_bytes <= remaining_bytes - active_bytes;
                            state <= WR_PLAN;
                        end
                    end else if ((AXI_TIMEOUT_CYCLES != 0) && !timeout_reported) begin
                        if (timeout_count == AXI_TIMEOUT_CYCLES-1) begin
                            wr_error_valid      <= 1'b1;
                            wr_error_code       <= `DMA_STATUS_DST_TIMEOUT;
                            timeout_reported    <= 1'b1;
                            burst_error_latched <= 1'b1;
                        end else begin
                            timeout_count <= timeout_count + 1'b1;
                        end
                    end
                end

                WR_HALT: begin
                    wr_busy <= 1'b0;
                    fifo_reserve_valid <= 1'b0;

                    if (!wr_abort_new && wr_start) begin
                        wr_busy            <= 1'b1;
                        next_addr          <= wr_dst_addr;
                        remaining_bytes    <= wr_transfer_bytes;
                        target_single      <= wr_target_single;
                        timeout_reported   <= 1'b0;
                        burst_error_latched<= 1'b0;
                        state              <= WR_PLAN;
                    end
                end

                default: state <= WR_IDLE;
            endcase
        end
    end

endmodule
