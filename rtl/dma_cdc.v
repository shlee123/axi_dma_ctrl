module dma_cdc #(
    parameter integer AXI_ADDR_WIDTH = 32
)(
    // PCLK domain
    input  wire                      pclk,
    input  wire                      preset_n,

    input  wire                      start_pulse,
    input  wire [AXI_ADDR_WIDTH-1:0] cfg_src_addr_pclk,
    input  wire [AXI_ADDR_WIDTH-1:0] cfg_dst_addr_pclk,
    input  wire [11:0]               cfg_length_minus_1_pclk,
    input  wire                      cfg_source_single_pclk,
    input  wire                      cfg_target_single_pclk,

    output reg                       start_pending_pclk,
    output reg                       busy_pclk,
    output reg [3:0]                 status_code_pclk,
    output reg                       event_pulse_pclk,

    // AXI clock domain
    input  wire                      axi_clk,
    input  wire                      axi_reset_n,

    output reg                       cmd_valid,
    input  wire                      cmd_ready,
    output reg [AXI_ADDR_WIDTH-1:0]  cmd_src_addr,
    output reg [AXI_ADDR_WIDTH-1:0]  cmd_dst_addr,
    output reg [11:0]                cmd_length_minus_1,
    output reg                       cmd_source_single,
    output reg                       cmd_target_single,

    input  wire                      dma_busy_axi,
    input  wire                      event_valid_axi,
    input  wire [3:0]                event_status_axi
);

    // ----------------------------------------------------------------
    // PCLK -> AXI_CLK bundled-data START transfer
    // ----------------------------------------------------------------
    reg [AXI_ADDR_WIDTH-1:0] hold_src_addr;
    reg [AXI_ADDR_WIDTH-1:0] hold_dst_addr;
    reg [11:0]               hold_length_minus_1;
    reg                      hold_source_single;
    reg                      hold_target_single;

    reg start_req_toggle_pclk;
    reg start_ack_sync1_pclk;
    reg start_ack_sync2_pclk;

    reg start_req_sync1_axi;
    reg start_req_sync2_axi;
    reg start_req_seen_axi;
    reg start_ack_toggle_axi;

    // ----------------------------------------------------------------
    // AXI_CLK -> PCLK event/status transfer
    // ----------------------------------------------------------------
    reg [3:0] event_status_hold_axi;
    reg       event_toggle_axi;

    reg event_toggle_sync1_pclk;
    reg event_toggle_sync2_pclk;
    reg event_toggle_seen_pclk;

    // BUSY level synchronizer
    reg busy_sync1_pclk;
    reg busy_sync2_pclk;

    wire start_req_arrived_axi;
    wire start_acknowledged_pclk;
    wire event_arrived_pclk;

    assign start_req_arrived_axi = (start_req_sync2_axi != start_req_seen_axi);
    assign start_acknowledged_pclk = (start_ack_sync2_pclk == start_req_toggle_pclk);
    assign event_arrived_pclk = (event_toggle_sync2_pclk != event_toggle_seen_pclk);

    // PCLK side: hold snapshot stable until ack.
    always @(posedge pclk or negedge preset_n) begin
        if (!preset_n) begin
            hold_src_addr            <= {AXI_ADDR_WIDTH{1'b0}};
            hold_dst_addr            <= {AXI_ADDR_WIDTH{1'b0}};
            hold_length_minus_1      <= 12'd0;
            hold_source_single       <= 1'b0;
            hold_target_single       <= 1'b0;
            start_req_toggle_pclk    <= 1'b0;
            start_pending_pclk       <= 1'b0;
            start_ack_sync1_pclk     <= 1'b0;
            start_ack_sync2_pclk     <= 1'b0;

            busy_sync1_pclk          <= 1'b0;
            busy_sync2_pclk          <= 1'b0;
            busy_pclk                <= 1'b0;

            event_toggle_sync1_pclk  <= 1'b0;
            event_toggle_sync2_pclk  <= 1'b0;
            event_toggle_seen_pclk   <= 1'b0;
            status_code_pclk         <= 4'h0;
            event_pulse_pclk         <= 1'b0;
        end else begin
            start_ack_sync1_pclk <= start_ack_toggle_axi;
            start_ack_sync2_pclk <= start_ack_sync1_pclk;

            busy_sync1_pclk <= dma_busy_axi;
            busy_sync2_pclk <= busy_sync1_pclk;
            busy_pclk       <= busy_sync2_pclk;

            event_toggle_sync1_pclk <= event_toggle_axi;
            event_toggle_sync2_pclk <= event_toggle_sync1_pclk;
            event_pulse_pclk        <= 1'b0;

            if (event_arrived_pclk) begin
                event_toggle_seen_pclk <= event_toggle_sync2_pclk;
                status_code_pclk       <= event_status_hold_axi;
                event_pulse_pclk       <= 1'b1;
            end

            // Software contract forbids a second START while pending.
            if (start_pulse && !start_pending_pclk) begin
                hold_src_addr         <= cfg_src_addr_pclk;
                hold_dst_addr         <= cfg_dst_addr_pclk;
                hold_length_minus_1   <= cfg_length_minus_1_pclk;
                hold_source_single    <= cfg_source_single_pclk;
                hold_target_single    <= cfg_target_single_pclk;
                start_req_toggle_pclk <= ~start_req_toggle_pclk;
                start_pending_pclk    <= 1'b1;
            end

            if (start_pending_pclk && start_acknowledged_pclk)
                start_pending_pclk <= 1'b0;
        end
    end

    // AXI clock side: request synchronizer and local valid/ready command.
    always @(posedge axi_clk or negedge axi_reset_n) begin
        if (!axi_reset_n) begin
            start_req_sync1_axi  <= 1'b0;
            start_req_sync2_axi  <= 1'b0;
            start_req_seen_axi   <= 1'b0;
            start_ack_toggle_axi <= 1'b0;

            cmd_valid            <= 1'b0;
            cmd_src_addr         <= {AXI_ADDR_WIDTH{1'b0}};
            cmd_dst_addr         <= {AXI_ADDR_WIDTH{1'b0}};
            cmd_length_minus_1   <= 12'd0;
            cmd_source_single    <= 1'b0;
            cmd_target_single    <= 1'b0;
        end else begin
            start_req_sync1_axi <= start_req_toggle_pclk;
            start_req_sync2_axi <= start_req_sync1_axi;

            if (start_req_arrived_axi && !cmd_valid) begin
                // Bundled data has been stable since the PCLK request toggle.
                cmd_src_addr       <= hold_src_addr;
                cmd_dst_addr       <= hold_dst_addr;
                cmd_length_minus_1 <= hold_length_minus_1;
                cmd_source_single  <= hold_source_single;
                cmd_target_single  <= hold_target_single;
                cmd_valid          <= 1'b1;
                start_req_seen_axi <= start_req_sync2_axi;
            end

            if (cmd_valid && cmd_ready) begin
                cmd_valid            <= 1'b0;
                start_ack_toggle_axi <= start_req_seen_axi;
            end
        end
    end

    // AXI event owner. event_status_hold_axi remains stable until the
    // next event, which occurs after the toggle has crossed to PCLK.
    always @(posedge axi_clk or negedge axi_reset_n) begin
        if (!axi_reset_n) begin
            event_status_hold_axi <= 4'h0;
            event_toggle_axi      <= 1'b0;
        end else if (event_valid_axi) begin
            event_status_hold_axi <= event_status_axi;
            event_toggle_axi      <= ~event_toggle_axi;
        end
    end

endmodule
