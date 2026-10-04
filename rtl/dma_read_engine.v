`include "dma_defines.vh"

module dma_read_engine #(
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
    input  wire                         rd_start,
    input  wire                         rd_abort_new,
    input  wire [AXI_ADDR_WIDTH-1:0]    rd_src_addr,
    input  wire [12:0]                  rd_transfer_bytes,
    input  wire                         rd_source_single,

    output reg                          rd_busy,
    output reg                          rd_done,
    output reg                          rd_error_valid,
    output reg  [3:0]                   rd_error_code,
    output reg                          rd_protocol_fault,

    // FIFO status/write interface
    input  wire [FIFO_COUNT_WIDTH-1:0]  fifo_free_count,
    output reg                          fifo_burst_begin,
    output wire                         fifo_wr_valid,
    input  wire                         fifo_wr_ready,
    output wire [AXI_DATA_WIDTH-1:0]    fifo_wr_data,
    output reg                          fifo_commit_valid,
    output reg  [FIFO_COUNT_WIDTH-1:0]  fifo_commit_beats,
    output reg                          fifo_discard_valid,
    output reg  [FIFO_COUNT_WIDTH-1:0]  fifo_discard_beats,

    // Source AXI AR
    output reg  [AXI_ID_WIDTH-1:0]      m_axi_arid,
    output reg  [AXI_ADDR_WIDTH-1:0]    m_axi_araddr,
    output reg  [7:0]                   m_axi_arlen,
    output reg  [2:0]                   m_axi_arsize,
    output reg  [1:0]                   m_axi_arburst,
    output reg                          m_axi_arvalid,
    input  wire                         m_axi_arready,

    // Source AXI R
    input  wire [AXI_ID_WIDTH-1:0]      m_axi_rid,
    input  wire [AXI_DATA_WIDTH-1:0]    m_axi_rdata,
    input  wire [1:0]                   m_axi_rresp,
    input  wire                         m_axi_rlast,
    input  wire                         m_axi_rvalid,
    output wire                         m_axi_rready
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

    localparam integer TIMEOUT_WIDTH =
        (AXI_TIMEOUT_CYCLES <= 1) ? 1 : $clog2(AXI_TIMEOUT_CYCLES + 1);

    localparam [2:0]
        RD_IDLE        = 3'd0,
        RD_PLAN        = 3'd1,
        RD_AR_WAIT     = 3'd2,
        RD_R_DATA      = 3'd3,
        RD_FINALIZE    = 3'd4,
        RD_FAULT_DRAIN = 3'd5,
        RD_HALT        = 3'd6;

    reg [2:0] state;

    reg [AXI_ADDR_WIDTH-1:0] next_addr;
    reg [12:0] remaining_bytes;
    reg        source_single;

    reg [8:0] planned_beats;
    reg [8:0] burst_expected_beats;
    reg [8:0] burst_received_beats;
    reg [8:0] burst_stored_beats;
    reg       burst_failed;
    reg       timeout_reported;
    reg       fault_missing_rlast;

    reg [TIMEOUT_WIDTH-1:0] timeout_count;

    wire rid_match;
    wire r_accept;
    wire expected_last_beat;
    wire rresp_bad;

    reg [12:0] plan_remaining_beats;
    reg [12:0] plan_4k_beats;
    reg [12:0] plan_limit_beats_wide;
    reg [8:0]  plan_limit_beats;
    reg [12:0] burst_bytes;

    assign rid_match = (m_axi_rid == AXI_ID_VALUE);

    // A mismatched RID is deliberately not accepted.
    assign m_axi_rready = ((state == RD_R_DATA) || (state == RD_FAULT_DRAIN))
                        && fifo_wr_ready
                        && rid_match;

    assign r_accept = m_axi_rvalid && m_axi_rready;
    assign expected_last_beat = (burst_received_beats + 1'b1 == burst_expected_beats);
    assign rresp_bad = (m_axi_rresp != `AXI_RESP_OKAY);

    // Failed/fault-drain beats are protocol drain only and are not stored.
    assign fifo_wr_valid = (state == RD_R_DATA)
                         && m_axi_rvalid
                         && rid_match
                         && !burst_failed
                         && !rd_protocol_fault;
    assign fifo_wr_data = m_axi_rdata;

    function [8:0] min9;
        input [8:0] a;
        input [8:0] b;
        begin
            min9 = (a < b) ? a : b;
        end
    endfunction

    function [12:0] bytes_for_beats;
        input [8:0] beats;
        reg [21:0] temp;
        begin
            temp = beats * BYTES_PER_BEAT;
            bytes_for_beats = temp[12:0];
        end
    endfunction

    // Combinational burst planning.
    always @(*) begin
        plan_remaining_beats = (remaining_bytes + BYTES_PER_BEAT - 1) >> BEAT_SHIFT;
        plan_4k_beats = (13'd4096 - {1'b0,next_addr[11:0]}) >> BEAT_SHIFT;
        if (plan_4k_beats == 0)
            plan_4k_beats = 9'd1;

        plan_limit_beats_wide = plan_remaining_beats;
        if (plan_limit_beats_wide > MAX_BURST_LENGTH)
            plan_limit_beats_wide = MAX_BURST_LENGTH;
        if (plan_limit_beats_wide > plan_4k_beats)
            plan_limit_beats_wide = plan_4k_beats;

        plan_limit_beats = plan_limit_beats_wide[8:0];
        if (source_single && (plan_limit_beats != 0))
            plan_limit_beats = 9'd1;

        burst_bytes = bytes_for_beats(planned_beats);
        if (burst_bytes > remaining_bytes)
            burst_bytes = remaining_bytes;
    end

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            state                  <= RD_IDLE;
            rd_busy                <= 1'b0;
            rd_done                <= 1'b0;
            rd_error_valid         <= 1'b0;
            rd_error_code          <= `DMA_STATUS_NO_ERROR;
            rd_protocol_fault      <= 1'b0;

            next_addr              <= {AXI_ADDR_WIDTH{1'b0}};
            remaining_bytes        <= 13'd0;
            source_single          <= 1'b0;

            planned_beats          <= 9'd0;
            burst_expected_beats   <= 9'd0;
            burst_received_beats   <= 9'd0;
            burst_stored_beats     <= 9'd0;
            burst_failed           <= 1'b0;
            timeout_reported       <= 1'b0;
            fault_missing_rlast    <= 1'b0;
            timeout_count          <= {TIMEOUT_WIDTH{1'b0}};

            fifo_burst_begin       <= 1'b0;
            fifo_commit_valid      <= 1'b0;
            fifo_commit_beats      <= {FIFO_COUNT_WIDTH{1'b0}};
            fifo_discard_valid     <= 1'b0;
            fifo_discard_beats     <= {FIFO_COUNT_WIDTH{1'b0}};

            m_axi_arid             <= AXI_ID_VALUE;
            m_axi_araddr           <= {AXI_ADDR_WIDTH{1'b0}};
            m_axi_arlen            <= 8'd0;
            m_axi_arsize           <= BEAT_SHIFT[2:0];
            m_axi_arburst          <= `AXI_BURST_INCR;
            m_axi_arvalid          <= 1'b0;
        end else begin
            rd_done            <= 1'b0;
            rd_error_valid     <= 1'b0;
            fifo_burst_begin   <= 1'b0;
            fifo_commit_valid  <= 1'b0;
            fifo_discard_valid <= 1'b0;

            case (state)
                RD_IDLE: begin
                    rd_busy           <= 1'b0;
                    rd_protocol_fault <= 1'b0;
                    timeout_count     <= {TIMEOUT_WIDTH{1'b0}};
                    timeout_reported  <= 1'b0;
                    m_axi_arvalid     <= 1'b0;

                    if (rd_start) begin
                        rd_busy          <= 1'b1;
                        next_addr        <= rd_src_addr;
                        remaining_bytes  <= rd_transfer_bytes;
                        source_single    <= rd_source_single;
                        rd_error_code    <= `DMA_STATUS_NO_ERROR;
                        state            <= RD_PLAN;
                    end
                end

                RD_PLAN: begin
                    timeout_count <= {TIMEOUT_WIDTH{1'b0}};

                    if (rd_abort_new) begin
                        state <= RD_HALT;
                    end else if (remaining_bytes == 0) begin
                        rd_done <= 1'b1;
                        rd_busy <= 1'b0;
                        state   <= RD_IDLE;
                    end else if ((plan_limit_beats != 0) &&
                                 (fifo_free_count >= plan_limit_beats[FIFO_COUNT_WIDTH-1:0])) begin
                        planned_beats    <= plan_limit_beats;
                        m_axi_araddr     <= next_addr;
                        m_axi_arlen      <= plan_limit_beats[7:0] - 1'b1;
                        m_axi_arid       <= AXI_ID_VALUE;
                        m_axi_arsize     <= BEAT_SHIFT[2:0];
                        m_axi_arburst    <= `AXI_BURST_INCR;
                        m_axi_arvalid    <= 1'b1;
                        state            <= RD_AR_WAIT;
                    end
                end

                RD_AR_WAIT: begin
                    if (m_axi_arvalid && m_axi_arready) begin
                        m_axi_arvalid        <= 1'b0;
                        burst_expected_beats <= planned_beats;
                        burst_received_beats <= 9'd0;
                        burst_stored_beats   <= 9'd0;
                        burst_failed         <= 1'b0;
                        timeout_reported     <= 1'b0;
                        fault_missing_rlast  <= 1'b0;
                        timeout_count        <= {TIMEOUT_WIDTH{1'b0}};
                        fifo_burst_begin     <= 1'b1;

                        next_addr <= next_addr + (planned_beats * BYTES_PER_BEAT);
                        state     <= RD_R_DATA;
                    end else if ((AXI_TIMEOUT_CYCLES != 0) && !timeout_reported) begin
                        if (timeout_count == AXI_TIMEOUT_CYCLES-1) begin
                            rd_error_valid    <= 1'b1;
                            rd_error_code     <= `DMA_STATUS_SRC_TIMEOUT;
                            timeout_reported  <= 1'b1;
                            timeout_count     <= timeout_count;
                            // ARVALID cannot be withdrawn after timeout.
                            // Wait for handshake, then drain the accepted burst.
                        end else begin
                            timeout_count <= timeout_count + 1'b1;
                        end
                    end
                end

                RD_R_DATA: begin
                    // AR timeout may have been reported before AR handshake.
                    // Once the request is accepted, the transfer is drain-only.
                    if (timeout_reported)
                        burst_failed <= 1'b1;

                    if (r_accept) begin
                        timeout_count        <= {TIMEOUT_WIDTH{1'b0}};
                        burst_received_beats <= burst_received_beats + 1'b1;
                        if (!burst_failed && !timeout_reported && !rd_protocol_fault)
                            burst_stored_beats <= burst_stored_beats + 1'b1;

                        if (rresp_bad && !burst_failed) begin
                            burst_failed   <= 1'b1;
                            rd_error_valid <= 1'b1;
                            rd_error_code  <= `DMA_STATUS_SRC_RESP_ERROR;
                        end

                        if (m_axi_rlast && !expected_last_beat) begin
                            rd_protocol_fault <= 1'b1;
                            rd_error_valid    <= 1'b1;
                            rd_error_code     <= `DMA_STATUS_SRC_PROTOCOL_ERROR;
                            burst_failed      <= 1'b1;
                            state             <= RD_FINALIZE;
                        end else if (expected_last_beat) begin
                            if (!m_axi_rlast) begin
                                rd_protocol_fault   <= 1'b1;
                                rd_error_valid      <= 1'b1;
                                rd_error_code       <= `DMA_STATUS_SRC_PROTOCOL_ERROR;
                                burst_failed        <= 1'b1;
                                fault_missing_rlast <= 1'b1;
                                state               <= RD_FAULT_DRAIN;
                            end else begin
                                state <= RD_FINALIZE;
                            end
                        end
                    end else if (AXI_TIMEOUT_CYCLES != 0 && !timeout_reported) begin
                        if (fifo_wr_ready) begin
                            if (timeout_count == AXI_TIMEOUT_CYCLES-1) begin
                                rd_error_valid   <= 1'b1;
                                rd_error_code    <= `DMA_STATUS_SRC_TIMEOUT;
                                timeout_reported <= 1'b1;
                                burst_failed     <= 1'b1;
                            end else begin
                                timeout_count <= timeout_count + 1'b1;
                            end
                        end
                    end
                end

                RD_FAULT_DRAIN: begin
                    // Framing is no longer trustworthy. Accept matching RID
                    // beats until an observed RLAST or coordinated reset.
                    if (r_accept && m_axi_rlast)
                        state <= RD_FINALIZE;
                end

                RD_FINALIZE: begin
                    if (burst_failed || timeout_reported || rd_protocol_fault) begin
                        fifo_discard_valid <= 1'b1;
                        fifo_discard_beats <= burst_stored_beats[FIFO_COUNT_WIDTH-1:0];
                        state              <= RD_HALT;
                    end else begin
                        fifo_commit_valid <= 1'b1;
                        fifo_commit_beats <= burst_expected_beats[FIFO_COUNT_WIDTH-1:0];

                        if (remaining_bytes <= burst_bytes)
                            remaining_bytes <= 13'd0;
                        else
                            remaining_bytes <= remaining_bytes - burst_bytes;

                        state <= RD_PLAN;
                    end
                end

                RD_HALT: begin
                    rd_busy <= 1'b0;
                    // Controller owns global recovery/fault lifecycle.
                    // A new transfer starts only after returning through reset
                    // or an external controller restart sequence.
                    if (!rd_abort_new && !rd_protocol_fault && rd_start) begin
                        rd_busy          <= 1'b1;
                        next_addr        <= rd_src_addr;
                        remaining_bytes  <= rd_transfer_bytes;
                        source_single    <= rd_source_single;
                        timeout_reported <= 1'b0;
                        state            <= RD_PLAN;
                    end
                end

                default: state <= RD_IDLE;
            endcase
        end
    end

endmodule
