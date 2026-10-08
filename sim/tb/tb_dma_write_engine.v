`timescale 1ns/1ps

module tb_dma_write_engine;

    localparam AXI_ADDR_WIDTH   = 32;
    localparam AXI_DATA_WIDTH   = 32;
    localparam AXI_ID_WIDTH     = 6;
    localparam FIFO_COUNT_WIDTH = 4;
    localparam TIMEOUT_CYCLES   = 4;

    reg clk;
    reg rst_n;

    reg wr_start;
    reg wr_abort_new;
    reg [31:0] wr_dst_addr;
    reg [12:0] wr_transfer_bytes;
    reg wr_target_single;

    wire wr_busy;
    wire wr_done;
    wire wr_error_valid;
    wire [3:0] wr_error_code;

    reg [FIFO_COUNT_WIDTH-1:0] fifo_verified_count;
    wire fifo_reserve_valid;
    wire [FIFO_COUNT_WIDTH-1:0] fifo_reserve_beats;
    reg fifo_reserve_ready;

    reg fifo_rd_valid;
    reg [31:0] fifo_rd_data;
    wire fifo_rd_advance;
    wire fifo_release_valid;
    wire [FIFO_COUNT_WIDTH-1:0] fifo_release_beats;

    wire [AXI_ID_WIDTH-1:0] m_axi_awid;
    wire [31:0] m_axi_awaddr;
    wire [7:0] m_axi_awlen;
    wire [2:0] m_axi_awsize;
    wire [1:0] m_axi_awburst;
    wire m_axi_awvalid;
    reg m_axi_awready;

    wire [31:0] m_axi_wdata;
    wire [3:0] m_axi_wstrb;
    wire m_axi_wlast;
    wire m_axi_wvalid;
    reg m_axi_wready;

    reg [AXI_ID_WIDTH-1:0] m_axi_bid;
    reg [1:0] m_axi_bresp;
    reg m_axi_bvalid;
    wire m_axi_bready;

    integer errors;
    integer reserve_seen;
    integer release_seen;
    integer done_seen;
    integer timeout_seen;
    integer resp_error_seen;

    dma_write_engine #(
        .AXI_ADDR_WIDTH(AXI_ADDR_WIDTH),
        .AXI_DATA_WIDTH(AXI_DATA_WIDTH),
        .AXI_ID_WIDTH(AXI_ID_WIDTH),
        .MAX_BURST_LENGTH(8),
        .FIFO_COUNT_WIDTH(FIFO_COUNT_WIDTH),
        .AXI_TIMEOUT_CYCLES(TIMEOUT_CYCLES),
        .AXI_ID_VALUE(0)
    ) dut (
        .clk(clk),
        .rst_n(rst_n),
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
        .m_axi_awid(m_axi_awid),
        .m_axi_awaddr(m_axi_awaddr),
        .m_axi_awlen(m_axi_awlen),
        .m_axi_awsize(m_axi_awsize),
        .m_axi_awburst(m_axi_awburst),
        .m_axi_awvalid(m_axi_awvalid),
        .m_axi_awready(m_axi_awready),
        .m_axi_wdata(m_axi_wdata),
        .m_axi_wstrb(m_axi_wstrb),
        .m_axi_wlast(m_axi_wlast),
        .m_axi_wvalid(m_axi_wvalid),
        .m_axi_wready(m_axi_wready),
        .m_axi_bid(m_axi_bid),
        .m_axi_bresp(m_axi_bresp),
        .m_axi_bvalid(m_axi_bvalid),
        .m_axi_bready(m_axi_bready)
    );

    always #5 clk = ~clk;

    // Sample the reservation handshake before the DUT's NBA updates clear
    // fifo_reserve_valid at the accepting edge.
    always @(posedge clk) begin
        if (fifo_reserve_valid && fifo_reserve_ready)
            reserve_seen = reserve_seen + 1;
    end

    // Sample registered one-cycle DUT pulses after the NBA update.  Keeping
    // this separate from the handshake monitor avoids active-region races
    // with the stimulus checks.
    always @(posedge clk) begin
        #1;
        if (fifo_release_valid)
            release_seen = release_seen + 1;
        if (wr_done)
            done_seen = done_seen + 1;
        if (wr_error_valid && wr_error_code == 4'hB)
            timeout_seen = timeout_seen + 1;
        if (wr_error_valid && wr_error_code == 4'h9)
            resp_error_seen = resp_error_seen + 1;
    end

    task pulse_start;
        input [31:0] addr;
        input [12:0] bytes;
        begin
            @(negedge clk);
            wr_dst_addr = addr;
            wr_transfer_bytes = bytes;
            wr_start = 1'b1;
            @(posedge clk);
            @(negedge clk);
            wr_start = 1'b0;
        end
    endtask

    task wait_reserve;
        input [FIFO_COUNT_WIDTH-1:0] exp_beats;
        begin
            while (!fifo_reserve_valid) @(posedge clk);
            #1;
            if (fifo_reserve_beats !== exp_beats) begin
                $display("[%0t] ERROR reserve beats got %0d expected %0d",
                         $time,fifo_reserve_beats,exp_beats);
                errors = errors + 1;
            end
            @(negedge clk);
            fifo_reserve_ready = 1'b1;
            @(posedge clk);
            @(negedge clk);
            fifo_reserve_ready = 1'b0;
        end
    endtask

    task wait_aw_and_accept;
        input [31:0] exp_addr;
        input [7:0] exp_len;
        begin
            while (!m_axi_awvalid) @(posedge clk);
            #1;
            if (m_axi_awaddr !== exp_addr || m_axi_awlen !== exp_len) begin
                $display("[%0t] ERROR AW got addr=%h len=%0d expected %h/%0d",
                         $time,m_axi_awaddr,m_axi_awlen,exp_addr,exp_len);
                errors = errors + 1;
            end
            @(negedge clk);
            m_axi_awready = 1'b1;
            @(posedge clk);
            @(negedge clk);
            m_axi_awready = 1'b0;
        end
    endtask

    task send_wbeat;
        input [31:0] data;
        input [3:0] exp_strb;
        input exp_last;
        begin
            @(negedge clk);
            fifo_rd_data = data;
            fifo_rd_valid = 1'b1;
            m_axi_wready = 1'b1;
            #1;
            if (!m_axi_wvalid || m_axi_wdata !== data ||
                m_axi_wstrb !== exp_strb || m_axi_wlast !== exp_last) begin
                $display("[%0t] ERROR W valid=%b data=%h strb=%h last=%b expected data=%h strb=%h last=%b",
                         $time,m_axi_wvalid,m_axi_wdata,m_axi_wstrb,m_axi_wlast,
                         data,exp_strb,exp_last);
                errors = errors + 1;
            end
            @(posedge clk);
            @(negedge clk);
            fifo_rd_valid = 1'b0;
            m_axi_wready = 1'b0;
        end
    endtask

    task send_bresp;
        input [1:0] resp;
        begin
            @(negedge clk);
            m_axi_bresp = resp;
            m_axi_bvalid = 1'b1;
            while (!m_axi_bready) @(negedge clk);
            @(posedge clk);
            @(negedge clk);
            m_axi_bvalid = 1'b0;
            m_axi_bresp = 2'b00;
        end
    endtask

    task wait_cycles;
        input integer n;
        integer i;
        begin
            for (i=0;i<n;i=i+1) @(posedge clk);
        end
    endtask


    // Optional FSDB dump stub.
    // Enabled by the VCS Makefile flow with +define+ENABLE_FSDB.
`ifdef ENABLE_FSDB
    reg [1023:0] fsdb_file;
    initial begin
        if (!$value$plusargs("FSDB_FILE=%s", fsdb_file))
            fsdb_file = "fsdb/default.fsdb";
        $fsdbDumpfile(fsdb_file);
        $fsdbDumpvars(0, tb_dma_write_engine);
    end
`endif

    initial begin
        clk = 0;
        rst_n = 0;
        wr_start = 0;
        wr_abort_new = 0;
        wr_dst_addr = 0;
        wr_transfer_bytes = 0;
        wr_target_single = 0;
        fifo_verified_count = 8;
        fifo_reserve_ready = 0;
        fifo_rd_valid = 0;
        fifo_rd_data = 0;
        m_axi_awready = 0;
        m_axi_wready = 0;
        m_axi_bid = 0;
        m_axi_bresp = 0;
        m_axi_bvalid = 0;
        errors = 0;
        reserve_seen = 0;
        release_seen = 0;
        done_seen = 0;
        timeout_seen = 0;
        resp_error_seen = 0;

        repeat (3) @(posedge clk);
        @(negedge clk);
        rst_n = 1;

        // TEST1: 10-byte transfer -> 3 beats, final WSTRB=0011.
        $display("[%0t] TEST1 normal partial final beat", $time);
        pulse_start(32'h0000_1000, 13'd10);
        wait_reserve(3);
        wait_aw_and_accept(32'h0000_1000, 8'd2);
        send_wbeat(32'h1111_0001,4'b1111,0);
        send_wbeat(32'h1111_0002,4'b1111,0);
        send_wbeat(32'h1111_0003,4'b0011,1);
        wait_cycles(1);
        if (release_seen != 1) begin
            $display("[%0t] ERROR TEST1 release_seen=%0d", $time, release_seen);
            errors = errors + 1;
        end
        send_bresp(2'b00);
        wait_cycles(3);
        if (done_seen != 1) begin
            $display("[%0t] ERROR TEST1 done_seen=%0d", $time,done_seen);
            errors = errors + 1;
        end

        // TEST2: BRESP error after data/release.
        $display("[%0t] TEST2 BRESP error", $time);
        pulse_start(32'h0000_2000, 13'd8);
        wait_reserve(2);
        wait_aw_and_accept(32'h0000_2000, 8'd1);
        send_wbeat(32'h2222_0001,4'b1111,0);
        send_wbeat(32'h2222_0002,4'b1111,1);
        send_bresp(2'b10);
        wait_cycles(2);
        if (resp_error_seen != 1 || release_seen != 2) begin
            $display("[%0t] ERROR TEST2 resp_error=%0d release=%0d",
                     $time,resp_error_seen,release_seen);
            errors = errors + 1;
        end

        // TEST3: AW timeout, then late AW handshake; obligation must finish.
        $display("[%0t] TEST3 AW timeout then completion", $time);
        pulse_start(32'h0000_3000, 13'd4);
        wait_reserve(1);
        while (!m_axi_awvalid) @(posedge clk);
        wait_cycles(TIMEOUT_CYCLES + 1);
        if (timeout_seen != 1 || !m_axi_awvalid) begin
            $display("[%0t] ERROR TEST3 timeout=%0d awvalid=%b",
                     $time,timeout_seen,m_axi_awvalid);
            errors = errors + 1;
        end
        @(negedge clk);
        m_axi_awready = 1'b1;
        @(posedge clk);
        @(negedge clk);
        m_axi_awready = 1'b0;
        send_wbeat(32'h3333_0001,4'b1111,1);
        send_bresp(2'b00);
        wait_cycles(2);

        // TEST4: 4KB boundary split. 0x0FFC + 8 bytes becomes
        // one beat at 0x0FFC and one beat at 0x1000.
        $display("[%0t] TEST4 4KB boundary split", $time);
        pulse_start(32'h0000_0FFC, 13'd8);
        wait_reserve(1);
        wait_aw_and_accept(32'h0000_0FFC, 8'd0);
        send_wbeat(32'h4B00_0001,4'b1111,1);
        send_bresp(2'b00);

        wait_reserve(1);
        wait_aw_and_accept(32'h0000_1000, 8'd0);
        send_wbeat(32'h4B00_0002,4'b1111,1);
        send_bresp(2'b00);
        wait_cycles(3);
        if (done_seen != 2) begin
            $display("[%0t] ERROR TEST4 done_seen=%0d", $time,done_seen);
            errors = errors + 1;
        end

        // TEST5: Abort before reserve handshake must prevent AW.
        $display("[%0t] TEST5 abort before reserve", $time);
        pulse_start(32'h0000_4000, 13'd4);
        while (!fifo_reserve_valid) @(posedge clk);
        @(negedge clk);
        wr_abort_new = 1'b1;
        @(posedge clk);
        @(negedge clk);
        wr_abort_new = 1'b0;
        wait_cycles(2);
        if (m_axi_awvalid) begin
            $display("[%0t] ERROR TEST5 AWVALID asserted after pre-reserve abort", $time);
            errors = errors + 1;
        end

        if (errors == 0)
            $display("[%0t] PASS tb_dma_write_engine", $time);
        else
            $display("[%0t] FAIL tb_dma_write_engine errors=%0d", $time,errors);

        $finish;
    end

endmodule
