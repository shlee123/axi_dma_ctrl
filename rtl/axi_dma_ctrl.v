module axi_dma_ctrl #(
    parameter integer APB_ADDR_WIDTH      = 12,
    parameter integer AXI_ADDR_WIDTH      = 32,
    parameter integer AXI_DATA_WIDTH      = 32,
    parameter integer AXI_ID_WIDTH        = 6,
    parameter integer MAX_BURST_LENGTH    = 8,
    parameter integer DATA_FIFO_DEPTH     = 8,
    parameter integer AXI_TIMEOUT_CYCLES  = 1024,
    parameter [AXI_ID_WIDTH-1:0] AXI_ID_VALUE = {AXI_ID_WIDTH{1'b0}},
    parameter [2:0] AXI_PROT_VALUE         = 3'b000,
    parameter [3:0] AXI_CACHE_VALUE        = 4'b0000
)(
    input  wire                         pclk,
    input  wire                         reset_n,

    input  wire                         psel,
    input  wire                         penable,
    input  wire                         pwrite,
    input  wire [APB_ADDR_WIDTH-1:0]    paddr,
    input  wire [31:0]                  pwdata,
    output wire [31:0]                  prdata,
    output wire                         pready,
    output wire                         pslverr,
    output wire                         dma_irq,

    input  wire                         axi_clk,

    // Source AXI4 master read channels
    output wire [AXI_ID_WIDTH-1:0]      m_src_arid,
    output wire [AXI_ADDR_WIDTH-1:0]    m_src_araddr,
    output wire [7:0]                   m_src_arlen,
    output wire [2:0]                   m_src_arsize,
    output wire [1:0]                   m_src_arburst,
    output wire [2:0]                   m_src_arprot,
    output wire [3:0]                   m_src_arcache,
    output wire                         m_src_arlock,
    output wire [3:0]                   m_src_arqos,
    output wire [3:0]                   m_src_arregion,
    output wire                         m_src_arvalid,
    input  wire                         m_src_arready,

    input  wire [AXI_ID_WIDTH-1:0]      m_src_rid,
    input  wire [AXI_DATA_WIDTH-1:0]    m_src_rdata,
    input  wire [1:0]                   m_src_rresp,
    input  wire                         m_src_rlast,
    input  wire                         m_src_rvalid,
    output wire                         m_src_rready,

    // Target AXI4 master write channels
    output wire [AXI_ID_WIDTH-1:0]      m_dst_awid,
    output wire [AXI_ADDR_WIDTH-1:0]    m_dst_awaddr,
    output wire [7:0]                   m_dst_awlen,
    output wire [2:0]                   m_dst_awsize,
    output wire [1:0]                   m_dst_awburst,
    output wire [2:0]                   m_dst_awprot,
    output wire [3:0]                   m_dst_awcache,
    output wire                         m_dst_awlock,
    output wire [3:0]                   m_dst_awqos,
    output wire [3:0]                   m_dst_awregion,
    output wire                         m_dst_awvalid,
    input  wire                         m_dst_awready,

    output wire [AXI_DATA_WIDTH-1:0]    m_dst_wdata,
    output wire [(AXI_DATA_WIDTH/8)-1:0] m_dst_wstrb,
    output wire                         m_dst_wlast,
    output wire                         m_dst_wvalid,
    input  wire                         m_dst_wready,

    input  wire [AXI_ID_WIDTH-1:0]      m_dst_bid,
    input  wire [1:0]                   m_dst_bresp,
    input  wire                         m_dst_bvalid,
    output wire                         m_dst_bready
);

    localparam integer FIFO_COUNT_WIDTH = $clog2(DATA_FIFO_DEPTH + 1);

    wire preset_n_int;
    wire axi_reset_n_int;

    assign m_src_arprot   = AXI_PROT_VALUE;
    assign m_src_arcache  = AXI_CACHE_VALUE;
    assign m_src_arlock   = 1'b0;
    assign m_src_arqos    = 4'b0000;
    assign m_src_arregion = 4'b0000;

    assign m_dst_awprot   = AXI_PROT_VALUE;
    assign m_dst_awcache  = AXI_CACHE_VALUE;
    assign m_dst_awlock   = 1'b0;
    assign m_dst_awqos    = 4'b0000;
    assign m_dst_awregion = 4'b0000;

`ifndef SYNTHESIS
    initial begin
        if (AXI_ADDR_WIDTH != 32)
            $fatal(1, "AXI_ADDR_WIDTH must be 32");
        if (!((AXI_DATA_WIDTH == 8)   || (AXI_DATA_WIDTH == 16)  ||
              (AXI_DATA_WIDTH == 32)  || (AXI_DATA_WIDTH == 64)  ||
              (AXI_DATA_WIDTH == 128) || (AXI_DATA_WIDTH == 256) ||
              (AXI_DATA_WIDTH == 512) || (AXI_DATA_WIDTH == 1024)))
            $fatal(1, "Illegal AXI_DATA_WIDTH");
        if (AXI_ID_WIDTH < 1)
            $fatal(1, "AXI_ID_WIDTH must be >= 1");
        if (APB_ADDR_WIDTH < 5)
            $fatal(1, "APB_ADDR_WIDTH must be >= 5");
        if ((MAX_BURST_LENGTH < 1) || (MAX_BURST_LENGTH > 256))
            $fatal(1, "MAX_BURST_LENGTH must be 1..256");
        if (DATA_FIFO_DEPTH < MAX_BURST_LENGTH)
            $fatal(1, "DATA_FIFO_DEPTH must be >= MAX_BURST_LENGTH");
        if (AXI_TIMEOUT_CYCLES < 0)
            $fatal(1, "AXI_TIMEOUT_CYCLES must be >= 0");
    end
`endif

    dma_reset_sync u_pclk_reset_sync (
        .clk(pclk),
        .async_reset_n(reset_n),
        .sync_reset_n(preset_n_int)
    );

    dma_reset_sync u_axi_reset_sync (
        .clk(axi_clk),
        .async_reset_n(reset_n),
        .sync_reset_n(axi_reset_n_int)
    );

    // APB / CDC signals
    wire [31:0] cfg_src_addr_pclk;
    wire [31:0] cfg_dst_addr_pclk;
    wire [11:0] cfg_length_minus_1_pclk;
    wire cfg_source_single_pclk;
    wire cfg_target_single_pclk;
    wire start_pulse_pclk;
    wire start_pending_pclk;
    wire busy_pclk;
    wire [3:0] status_code_pclk;
    wire event_pulse_pclk;

    // CDC / controller command
    wire cmd_valid_axi;
    wire cmd_ready_axi;
    wire [31:0] cmd_src_addr_axi;
    wire [31:0] cmd_dst_addr_axi;
    wire [11:0] cmd_length_minus_1_axi;
    wire cmd_source_single_axi;
    wire cmd_target_single_axi;

    wire dma_busy_axi;
    wire [3:0] dma_status_code_axi;
    wire event_valid_axi;
    wire event_ready_axi;
    wire [3:0] event_status_axi;

    // Controller / engines
    wire rd_start;
    wire rd_abort_new;
    wire [31:0] rd_src_addr;
    wire [12:0] rd_transfer_bytes;
    wire rd_source_single;
    wire rd_busy;
    wire rd_done;
    wire rd_error_valid;
    wire [3:0] rd_error_code;
    wire rd_protocol_fault;

    wire wr_start;
    wire wr_abort_new;
    wire [31:0] wr_dst_addr;
    wire [12:0] wr_transfer_bytes;
    wire wr_target_single;
    wire wr_busy;
    wire wr_done;
    wire wr_error_valid;
    wire [3:0] wr_error_code;

    // FIFO
    wire [FIFO_COUNT_WIDTH-1:0] fifo_free_count;
    wire [FIFO_COUNT_WIDTH-1:0] fifo_verified_count;
    wire [FIFO_COUNT_WIDTH-1:0] fifo_unverified_count;
    wire [FIFO_COUNT_WIDTH-1:0] fifo_reserved_count;
    wire fifo_empty;
    wire fifo_full;

    wire fifo_burst_begin;
    wire fifo_src_wr_valid;
    wire fifo_src_wr_ready;
    wire [AXI_DATA_WIDTH-1:0] fifo_src_wr_data;
    wire fifo_commit_valid;
    wire [FIFO_COUNT_WIDTH-1:0] fifo_commit_beats;
    wire fifo_discard_valid;
    wire [FIFO_COUNT_WIDTH-1:0] fifo_discard_beats;

    wire fifo_reserve_valid;
    wire [FIFO_COUNT_WIDTH-1:0] fifo_reserve_beats;
    wire fifo_reserve_ready;

    wire fifo_rd_valid;
    wire [AXI_DATA_WIDTH-1:0] fifo_rd_data;
    wire fifo_rd_advance;
    wire fifo_release_valid;
    wire [FIFO_COUNT_WIDTH-1:0] fifo_release_beats;

    wire fifo_flush_uncommitted;

    dma_apb_regs #(
        .APB_ADDR_WIDTH(APB_ADDR_WIDTH)
    ) u_dma_apb_regs (
        .pclk(pclk),
        .preset_n(preset_n_int),
        .psel(psel),
        .penable(penable),
        .pwrite(pwrite),
        .paddr(paddr),
        .pwdata(pwdata),
        .prdata(prdata),
        .pready(pready),
        .pslverr(pslverr),

        .cfg_src_addr(cfg_src_addr_pclk),
        .cfg_dst_addr(cfg_dst_addr_pclk),
        .cfg_length_minus_1(cfg_length_minus_1_pclk),
        .cfg_source_single(cfg_source_single_pclk),
        .cfg_target_single(cfg_target_single_pclk),
        .start_pulse(start_pulse_pclk),

        .start_pending(start_pending_pclk),
        .busy_pclk(busy_pclk),
        .status_code_pclk(status_code_pclk),
        .event_pulse_pclk(event_pulse_pclk),
        .dma_irq(dma_irq)
    );

    dma_cdc #(
        .AXI_ADDR_WIDTH(AXI_ADDR_WIDTH)
    ) u_dma_cdc (
        .pclk(pclk),
        .preset_n(preset_n_int),
        .start_pulse(start_pulse_pclk),
        .cfg_src_addr_pclk(cfg_src_addr_pclk),
        .cfg_dst_addr_pclk(cfg_dst_addr_pclk),
        .cfg_length_minus_1_pclk(cfg_length_minus_1_pclk),
        .cfg_source_single_pclk(cfg_source_single_pclk),
        .cfg_target_single_pclk(cfg_target_single_pclk),
        .start_pending_pclk(start_pending_pclk),
        .busy_pclk(busy_pclk),
        .status_code_pclk(status_code_pclk),
        .event_pulse_pclk(event_pulse_pclk),

        .axi_clk(axi_clk),
        .axi_reset_n(axi_reset_n_int),
        .cmd_valid(cmd_valid_axi),
        .cmd_ready(cmd_ready_axi),
        .cmd_src_addr(cmd_src_addr_axi),
        .cmd_dst_addr(cmd_dst_addr_axi),
        .cmd_length_minus_1(cmd_length_minus_1_axi),
        .cmd_source_single(cmd_source_single_axi),
        .cmd_target_single(cmd_target_single_axi),

        .dma_busy_axi(dma_busy_axi),
        .event_valid_axi(event_valid_axi),
        .event_ready_axi(event_ready_axi),
        .event_status_axi(event_status_axi)
    );

    dma_ctrl #(
        .AXI_ADDR_WIDTH(AXI_ADDR_WIDTH),
        .AXI_DATA_WIDTH(AXI_DATA_WIDTH),
        .FIFO_COUNT_WIDTH(FIFO_COUNT_WIDTH)
    ) u_dma_ctrl (
        .clk(axi_clk),
        .rst_n(axi_reset_n_int),

        .cmd_valid(cmd_valid_axi),
        .cmd_ready(cmd_ready_axi),
        .cmd_src_addr(cmd_src_addr_axi),
        .cmd_dst_addr(cmd_dst_addr_axi),
        .cmd_length_minus_1(cmd_length_minus_1_axi),
        .cmd_source_single(cmd_source_single_axi),
        .cmd_target_single(cmd_target_single_axi),

        .rd_start(rd_start),
        .rd_abort_new(rd_abort_new),
        .rd_src_addr(rd_src_addr),
        .rd_transfer_bytes(rd_transfer_bytes),
        .rd_source_single(rd_source_single),
        .rd_busy(rd_busy),
        .rd_done(rd_done),
        .rd_error_valid(rd_error_valid),
        .rd_error_code(rd_error_code),
        .rd_protocol_fault(rd_protocol_fault),

        .wr_start(wr_start),
        .wr_abort_new(wr_abort_new),
        .wr_dst_addr(wr_dst_addr),
        .wr_transfer_bytes(wr_transfer_bytes),
        .wr_target_single(wr_target_single),
        .wr_busy(wr_busy),
        .wr_done(wr_done),
        .wr_error_valid(wr_error_valid),
        .wr_error_code(wr_error_code),

        .fifo_verified_count(fifo_verified_count),
        .fifo_unverified_count(fifo_unverified_count),
        .fifo_reserved_count(fifo_reserved_count),
        .fifo_flush_uncommitted(fifo_flush_uncommitted),

        .dma_busy(dma_busy_axi),
        .dma_status_code(dma_status_code_axi),
        .event_valid(event_valid_axi),
        .event_ready(event_ready_axi),
        .event_status(event_status_axi)
    );

    dma_read_engine #(
        .AXI_ADDR_WIDTH(AXI_ADDR_WIDTH),
        .AXI_DATA_WIDTH(AXI_DATA_WIDTH),
        .AXI_ID_WIDTH(AXI_ID_WIDTH),
        .MAX_BURST_LENGTH(MAX_BURST_LENGTH),
        .FIFO_COUNT_WIDTH(FIFO_COUNT_WIDTH),
        .AXI_TIMEOUT_CYCLES(AXI_TIMEOUT_CYCLES),
        .AXI_ID_VALUE(AXI_ID_VALUE)
    ) u_dma_read_engine (
        .clk(axi_clk),
        .rst_n(axi_reset_n_int),
        .rd_start(rd_start),
        .rd_abort_new(rd_abort_new),
        .rd_src_addr(rd_src_addr),
        .rd_transfer_bytes(rd_transfer_bytes),
        .rd_source_single(rd_source_single),
        .rd_busy(rd_busy),
        .rd_done(rd_done),
        .rd_error_valid(rd_error_valid),
        .rd_error_code(rd_error_code),
        .rd_protocol_fault(rd_protocol_fault),

        .fifo_free_count(fifo_free_count),
        .fifo_burst_begin(fifo_burst_begin),
        .fifo_wr_valid(fifo_src_wr_valid),
        .fifo_wr_ready(fifo_src_wr_ready),
        .fifo_wr_data(fifo_src_wr_data),
        .fifo_commit_valid(fifo_commit_valid),
        .fifo_commit_beats(fifo_commit_beats),
        .fifo_discard_valid(fifo_discard_valid),
        .fifo_discard_beats(fifo_discard_beats),

        .m_axi_arid(m_src_arid),
        .m_axi_araddr(m_src_araddr),
        .m_axi_arlen(m_src_arlen),
        .m_axi_arsize(m_src_arsize),
        .m_axi_arburst(m_src_arburst),
        .m_axi_arvalid(m_src_arvalid),
        .m_axi_arready(m_src_arready),

        .m_axi_rid(m_src_rid),
        .m_axi_rdata(m_src_rdata),
        .m_axi_rresp(m_src_rresp),
        .m_axi_rlast(m_src_rlast),
        .m_axi_rvalid(m_src_rvalid),
        .m_axi_rready(m_src_rready)
    );

    dma_write_engine #(
        .AXI_ADDR_WIDTH(AXI_ADDR_WIDTH),
        .AXI_DATA_WIDTH(AXI_DATA_WIDTH),
        .AXI_ID_WIDTH(AXI_ID_WIDTH),
        .MAX_BURST_LENGTH(MAX_BURST_LENGTH),
        .FIFO_COUNT_WIDTH(FIFO_COUNT_WIDTH),
        .AXI_TIMEOUT_CYCLES(AXI_TIMEOUT_CYCLES),
        .AXI_ID_VALUE(AXI_ID_VALUE)
    ) u_dma_write_engine (
        .clk(axi_clk),
        .rst_n(axi_reset_n_int),
        .wr_start(wr_start),
        .wr_abort_new(wr_abort_new),
        .wr_dst_addr(wr_dst_addr),
        .wr_transfer_bytes(wr_transfer_bytes),
        .wr_target_single(wr_target_single),
        .wr_busy(wr_busy),
        .wr_done(wr_done),
        .wr_error_valid(wr_error_valid),
        .wr_error_code(wr_error_code),

        .fifo_verified_count(fifo_verified_count),
        .fifo_reserve_valid(fifo_reserve_valid),
        .fifo_reserve_beats(fifo_reserve_beats),
        .fifo_reserve_ready(fifo_reserve_ready),

        .fifo_rd_valid(fifo_rd_valid),
        .fifo_rd_data(fifo_rd_data),
        .fifo_rd_advance(fifo_rd_advance),
        .fifo_release_valid(fifo_release_valid),
        .fifo_release_beats(fifo_release_beats),

        .m_axi_awid(m_dst_awid),
        .m_axi_awaddr(m_dst_awaddr),
        .m_axi_awlen(m_dst_awlen),
        .m_axi_awsize(m_dst_awsize),
        .m_axi_awburst(m_dst_awburst),
        .m_axi_awvalid(m_dst_awvalid),
        .m_axi_awready(m_dst_awready),

        .m_axi_wdata(m_dst_wdata),
        .m_axi_wstrb(m_dst_wstrb),
        .m_axi_wlast(m_dst_wlast),
        .m_axi_wvalid(m_dst_wvalid),
        .m_axi_wready(m_dst_wready),

        .m_axi_bid(m_dst_bid),
        .m_axi_bresp(m_dst_bresp),
        .m_axi_bvalid(m_dst_bvalid),
        .m_axi_bready(m_dst_bready)
    );

    dma_data_fifo #(
        .DATA_WIDTH(AXI_DATA_WIDTH),
        .DEPTH(DATA_FIFO_DEPTH),
        .PTR_WIDTH((DATA_FIFO_DEPTH <= 2) ? 1 : $clog2(DATA_FIFO_DEPTH)),
        .COUNT_WIDTH(FIFO_COUNT_WIDTH)
    ) u_dma_data_fifo (
        .clk(axi_clk),
        .rst_n(axi_reset_n_int),

        .src_burst_begin(fifo_burst_begin),
        .src_wr_valid(fifo_src_wr_valid),
        .src_wr_ready(fifo_src_wr_ready),
        .src_wr_data(fifo_src_wr_data),
        .src_commit_valid(fifo_commit_valid),
        .src_commit_beats(fifo_commit_beats),
        .src_discard_valid(fifo_discard_valid),
        .src_discard_beats(fifo_discard_beats),

        .dst_reserve_valid(fifo_reserve_valid),
        .dst_reserve_beats(fifo_reserve_beats),
        .dst_reserve_ready(fifo_reserve_ready),

        .dst_rd_valid(fifo_rd_valid),
        .dst_rd_data(fifo_rd_data),
        .dst_rd_advance(fifo_rd_advance),

        .dst_release_valid(fifo_release_valid),
        .dst_release_beats(fifo_release_beats),

        .flush_uncommitted(fifo_flush_uncommitted),

        .free_count(fifo_free_count),
        .verified_count(fifo_verified_count),
        .unverified_count(fifo_unverified_count),
        .reserved_count(fifo_reserved_count),
        .empty(fifo_empty),
        .full(fifo_full)
    );

endmodule
