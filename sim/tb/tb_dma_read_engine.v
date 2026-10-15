`timescale 1ns/1ps

module tb_dma_read_engine;

    localparam AXI_ADDR_WIDTH   = 32;
    localparam AXI_DATA_WIDTH   = 32;
    localparam AXI_ID_WIDTH     = 6;
    localparam FIFO_COUNT_WIDTH = 4;
    localparam TIMEOUT_CYCLES   = 64;

    reg clk;
    reg rst_n;

    reg rd_start;
    reg rd_abort_new;
    reg [31:0] rd_src_addr;
    reg [12:0] rd_transfer_bytes;
    reg rd_source_single;

    wire rd_busy;
    wire rd_done;
    wire rd_error_valid;
    wire [3:0] rd_error_code;
    wire rd_protocol_fault;

    reg [FIFO_COUNT_WIDTH-1:0] fifo_free_count;
    wire fifo_burst_begin;
    wire fifo_wr_valid;
    reg fifo_wr_ready;
    wire [31:0] fifo_wr_data;
    wire fifo_commit_valid;
    wire [FIFO_COUNT_WIDTH-1:0] fifo_commit_beats;
    wire fifo_discard_valid;
    wire [FIFO_COUNT_WIDTH-1:0] fifo_discard_beats;

    wire [AXI_ID_WIDTH-1:0] m_axi_arid;
    wire [31:0] m_axi_araddr;
    wire [7:0] m_axi_arlen;
    wire [2:0] m_axi_arsize;
    wire [1:0] m_axi_arburst;
    wire m_axi_arvalid;
    reg  m_axi_arready;

    reg [AXI_ID_WIDTH-1:0] m_axi_rid;
    reg [31:0] m_axi_rdata;
    reg [1:0] m_axi_rresp;
    reg m_axi_rlast;
    reg m_axi_rvalid;
    wire m_axi_rready;

    integer errors;
    integer commit_seen;
    integer discard_seen;
    integer timeout_seen;
    integer resp_error_seen;
    integer protocol_seen;
    integer done_seen;

    dma_read_engine #(
        .AXI_ADDR_WIDTH(AXI_ADDR_WIDTH),
        .AXI_DATA_WIDTH(AXI_DATA_WIDTH),
        .AXI_ID_WIDTH(AXI_ID_WIDTH),
        .MAX_BURST_LENGTH(4),
        .FIFO_COUNT_WIDTH(FIFO_COUNT_WIDTH),
        .AXI_TIMEOUT_CYCLES(TIMEOUT_CYCLES),
        .AXI_ID_VALUE(0)
    ) dut (
        .clk(clk),
        .rst_n(rst_n),
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
        .fifo_wr_valid(fifo_wr_valid),
        .fifo_wr_ready(fifo_wr_ready),
        .fifo_wr_data(fifo_wr_data),
        .fifo_commit_valid(fifo_commit_valid),
        .fifo_commit_beats(fifo_commit_beats),
        .fifo_discard_valid(fifo_discard_valid),
        .fifo_discard_beats(fifo_discard_beats),
        .m_axi_arid(m_axi_arid),
        .m_axi_araddr(m_axi_araddr),
        .m_axi_arlen(m_axi_arlen),
        .m_axi_arsize(m_axi_arsize),
        .m_axi_arburst(m_axi_arburst),
        .m_axi_arvalid(m_axi_arvalid),
        .m_axi_arready(m_axi_arready),
        .m_axi_rid(m_axi_rid),
        .m_axi_rdata(m_axi_rdata),
        .m_axi_rresp(m_axi_rresp),
        .m_axi_rlast(m_axi_rlast),
        .m_axi_rvalid(m_axi_rvalid),
        .m_axi_rready(m_axi_rready)
    );

    always #5 clk = ~clk;

    // Sample DUT outputs after the NBA update at the clock edge.
    // rd_error_valid/rd_done are one-cycle registered pulses.
    always @(posedge clk) begin
        #1;
        if (fifo_commit_valid) begin
            commit_seen = commit_seen + 1;
        end
        if (fifo_discard_valid) begin
            discard_seen = discard_seen + 1;
        end
        if (rd_error_valid && rd_error_code == 4'hA)
            timeout_seen = timeout_seen + 1;
        if (rd_error_valid && rd_error_code == 4'h8)
            resp_error_seen = resp_error_seen + 1;
        if (rd_error_valid && rd_error_code == 4'hD)
            protocol_seen = protocol_seen + 1;
        if (rd_done)
            done_seen = done_seen + 1;
    end

    task pulse_start;
        input [31:0] addr;
        input [12:0] bytes;
        begin
            @(negedge clk);
            rd_src_addr = addr;
            rd_transfer_bytes = bytes;
            rd_start = 1'b1;
            @(posedge clk);
            @(negedge clk);
            rd_start = 1'b0;
        end
    endtask

    task wait_ar_and_accept;
        input [31:0] exp_addr;
        input [7:0] exp_len;
        begin
            while (!m_axi_arvalid) @(posedge clk);
            #1;
            if (m_axi_araddr !== exp_addr || m_axi_arlen !== exp_len) begin
                $display("[%0t] ERROR AR addr/len got %h/%0d expected %h/%0d",
                         $time,m_axi_araddr,m_axi_arlen,exp_addr,exp_len);
                errors = errors + 1;
            end
            @(negedge clk);
            m_axi_arready = 1'b1;
            @(posedge clk);
            @(negedge clk);
            m_axi_arready = 1'b0;
        end
    endtask

    task send_rbeat;
        input [31:0] data;
        input [1:0] resp;
        input last;
        begin
            @(negedge clk);
            m_axi_rdata  = data;
            m_axi_rresp  = resp;
            m_axi_rlast  = last;
            m_axi_rvalid = 1'b1;
            while (!m_axi_rready) @(negedge clk);
            @(posedge clk);
            @(negedge clk);
            m_axi_rvalid = 1'b0;
            m_axi_rlast  = 1'b0;
            m_axi_rresp  = 2'b00;
        end
    endtask

    task wait_cycles;
        input integer n;
        integer i;
        begin
            for (i=0;i<n;i=i+1) @(posedge clk);
        end
    endtask



    // Observe actual handshakes before sequential updates.
    integer ar_seen = 0;
    integer r_seen = 0;
    integer stored_seen = 0;
    integer begin_seen = 0;
    integer base_ar, base_r, base_stored, base_begin;
    integer base_commit, base_discard, base_done, base_timeout, base_protocol;

    always @(posedge clk) begin
        if (rst_n) begin
            if (m_axi_arvalid && m_axi_arready) ar_seen = ar_seen + 1;
            if (m_axi_rvalid && m_axi_rready) r_seen = r_seen + 1;
            if (fifo_wr_valid && fifo_wr_ready) stored_seen = stored_seen + 1;
        end
        #1;
        if (rst_n && fifo_burst_begin) begin_seen = begin_seen + 1;
    end

    // Bound all helper waits, including pre-existing cases.
    initial begin
        #200000;
        $fatal(1, "tb_dma_read_engine watchdog expired");
    end

    task reset_read;
        begin
            @(negedge clk);
            rst_n = 0;
            rd_start = 0;
            rd_abort_new = 0;
            m_axi_arready = 0;
            m_axi_rvalid = 0;
            m_axi_rlast = 0;
            m_axi_rresp = 0;
            m_axi_rid = 0;
            fifo_wr_ready = 1;
            repeat (3) @(negedge clk);
            rst_n = 1;
            repeat (2) @(negedge clk);
        end
    endtask

    task snapshot_read;
        begin
            base_ar = ar_seen;
            base_r = r_seen;
            base_stored = stored_seen;
            base_begin = begin_seen;
            base_commit = commit_seen;
            base_discard = discard_seen;
            base_done = done_seen;
            base_timeout = timeout_seen;
            base_protocol = protocol_seen;
        end
    endtask

    task test_ar_timeout;
        begin
            $display("[%0t] TEST6 AR timeout, late handshake and drain", $time);
            reset_read();
            snapshot_read();
            pulse_start(32'h0000_5000, 13'd16);
            while (!m_axi_arvalid) @(negedge clk);
            // Continue stalling for twice the timeout: the event must not repeat.
            repeat (2 * TIMEOUT_CYCLES) begin
                @(negedge clk);
                #1;
                if (m_axi_arvalid !== 1'b1 || m_axi_araddr !== 32'h0000_5000 ||
                    m_axi_arlen !== 8'd3 || m_axi_arid !== 0 ||
                    m_axi_arsize !== 3'd2 || m_axi_arburst !== 2'b01 ||
                    rd_busy !== 1'b1)
                    $fatal(1, "TEST6 AR obligation/payload changed under stall");
            end
            if (timeout_seen != base_timeout + 1 || ar_seen != base_ar ||
                begin_seen != base_begin || commit_seen != base_commit ||
                discard_seen != base_discard || done_seen != base_done ||
                protocol_seen != base_protocol)
                $fatal(1, "TEST6 timeout or pre-handshake accounting");
            fifo_wr_ready = 0;
            wait_ar_and_accept(32'h0000_5000, 8'd3);
            send_rbeat(32'h6000_0001, 0, 0);
            send_rbeat(32'h6000_0002, 0, 0);
            send_rbeat(32'h6000_0003, 0, 0);
            send_rbeat(32'h6000_0004, 0, 1);
            wait_cycles(4);
            #2;
            if (ar_seen != base_ar + 1 || r_seen != base_r + 4 ||
                begin_seen != base_begin + 1 || stored_seen != base_stored ||
                discard_seen != base_discard + 1 || fifo_discard_beats !== 0 ||
                commit_seen != base_commit || done_seen != base_done ||
                timeout_seen != base_timeout + 1 || protocol_seen != base_protocol ||
                rd_busy !== 0 || rd_protocol_fault !== 0)
                $fatal(1, "TEST6 late drain stored/committed data or lost obligation");
            // Ordinary timeout recovery permits a successful new command.
            fifo_wr_ready = 1;
            pulse_start(32'h0000_5100, 13'd4);
            wait_ar_and_accept(32'h0000_5100, 0);
            send_rbeat(32'hA5A5_5A5A, 0, 1);
            wait_cycles(4);
            #2;
            if (commit_seen != base_commit + 1 || done_seen != base_done + 1 ||
                stored_seen != base_stored + 1 || timeout_seen != base_timeout + 1 ||
                discard_seen != base_discard + 1)
                $fatal(1, "TEST6 successful restart failed");
        end
    endtask

    task test_missing_rlast;
        begin
            $display("[%0t] TEST7 missing RLAST, late drain and reset recovery", $time);
            reset_read();
            snapshot_read();
            pulse_start(32'h0000_6000, 13'd8);
            wait_ar_and_accept(32'h0000_6000, 1);
            send_rbeat(32'h7000_0001, 0, 0);
            send_rbeat(32'h7000_0002, 0, 0);
            #2;
            if (protocol_seen != base_protocol + 1 || rd_protocol_fault !== 1 ||
                rd_busy !== 1 || stored_seen != base_stored + 2 ||
                commit_seen != base_commit || discard_seen != base_discard)
                $fatal(1, "TEST7 missing RLAST failed to enter fault drain");
            fifo_wr_ready = 0;
            // A mismatched RID with RLAST must not close the drain.
            @(negedge clk);
            m_axi_rid = 1;
            m_axi_rvalid = 1;
            m_axi_rlast = 1;
            repeat (4) begin
                @(negedge clk);
                #1;
                if (m_axi_rready !== 0 || r_seen != base_r + 2 ||
                    discard_seen != base_discard || rd_busy !== 1)
                    $fatal(1, "TEST7 mismatched RID escaped fault drain");
            end
            m_axi_rvalid = 0;
            m_axi_rlast = 0;
            m_axi_rid = 0;
            send_rbeat(32'hDEAD_0001, 0, 0);
            #2;
            if (discard_seen != base_discard || stored_seen != base_stored + 2 ||
                rd_busy !== 1)
                $fatal(1, "TEST7 drained extra data stored or ended before RLAST");
            send_rbeat(32'hDEAD_0002, 0, 1);
            wait_cycles(4);
            #2;
            if (r_seen != base_r + 4 || ar_seen != base_ar + 1 ||
                discard_seen != base_discard + 1 || fifo_discard_beats !== 2 ||
                stored_seen != base_stored + 2 || commit_seen != base_commit ||
                done_seen != base_done || protocol_seen != base_protocol + 1 ||
                timeout_seen != base_timeout || rd_protocol_fault !== 1)
                $fatal(1, "TEST7 late RLAST discard/fault accounting");
            pulse_start(32'h0000_6100, 13'd4);
            repeat (8) begin
                @(negedge clk);
                #1;
                if (m_axi_arvalid !== 0 || rd_protocol_fault !== 1 ||
                    ar_seen != base_ar + 1 || done_seen != base_done)
                    $fatal(1, "TEST7 protocol fault restarted without reset");
            end
            reset_read();
            pulse_start(32'h0000_6200, 13'd4);
            wait_ar_and_accept(32'h0000_6200, 0);
            send_rbeat(32'h5A5A_A5A5, 0, 1);
            wait_cycles(4);
            #2;
            if (rd_protocol_fault !== 0 || commit_seen != base_commit + 1 ||
                done_seen != base_done + 1 || discard_seen != base_discard + 1 ||
                stored_seen != base_stored + 3 || protocol_seen != base_protocol + 1)
                $fatal(1, "TEST7 coordinated reset recovery failed");
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
        $fsdbDumpvars(0, tb_dma_read_engine);
    end
`endif

    initial begin
        clk = 0;
        rst_n = 0;
        rd_start = 0;
        rd_abort_new = 0;
        rd_src_addr = 0;
        rd_transfer_bytes = 0;
        rd_source_single = 0;
        fifo_free_count = 8;
        fifo_wr_ready = 1;
        m_axi_arready = 0;
        m_axi_rid = 0;
        m_axi_rdata = 0;
        m_axi_rresp = 0;
        m_axi_rlast = 0;
        m_axi_rvalid = 0;
        errors = 0;
        commit_seen = 0;
        discard_seen = 0;
        timeout_seen = 0;
        resp_error_seen = 0;
        protocol_seen = 0;
        done_seen = 0;

        repeat (3) @(posedge clk);
        @(negedge clk);
        rst_n = 1;

        // TEST1: 16 bytes -> 4 beats -> successful commit.
        $display("[%0t] TEST1 normal 4-beat burst", $time);
        pulse_start(32'h0000_1000, 13'd16);
        wait_ar_and_accept(32'h0000_1000, 8'd3);
        send_rbeat(32'h1001,2'b00,0);
        send_rbeat(32'h1002,2'b00,0);
        send_rbeat(32'h1003,2'b00,0);
        send_rbeat(32'h1004,2'b00,1);
        wait_cycles(4);
        if (commit_seen != 1 || discard_seen != 0 || done_seen != 1) begin
            $display("[%0t] ERROR TEST1 commit=%0d discard=%0d done_seen=%0d",
                     $time,commit_seen,discard_seen,done_seen);
            errors = errors + 1;
        end

        // rd_done is a pulse; allow engine to settle in IDLE.
        wait_cycles(2);

        // TEST2: RRESP error. Entire burst must discard.
        $display("[%0t] TEST2 RRESP error", $time);
        pulse_start(32'h0000_2000, 13'd16);
        wait_ar_and_accept(32'h0000_2000, 8'd3);
        send_rbeat(32'h2001,2'b00,0);
        send_rbeat(32'h2002,2'b10,0);
        send_rbeat(32'h2003,2'b00,0);
        send_rbeat(32'h2004,2'b00,1);
        wait_cycles(3);
        if (resp_error_seen != 1 || discard_seen != 1) begin
            $display("[%0t] ERROR TEST2 resp_error=%0d discard=%0d",
                     $time,resp_error_seen,discard_seen);
            errors = errors + 1;
        end

        // Restart from HALT for an ordinary error scenario.
        pulse_start(32'h0000_3000, 13'd16);
        wait_ar_and_accept(32'h0000_3000, 8'd3);

        // TEST3: one stored beat, then R timeout. Late beats are drain-only.
        $display("[%0t] TEST3 R timeout and late drain", $time);
        send_rbeat(32'h3001,2'b00,0);
        wait_cycles(TIMEOUT_CYCLES + 1);
        if (timeout_seen != 1) begin
            $display("[%0t] ERROR TEST3 timeout_seen=%0d", $time,timeout_seen);
            errors = errors + 1;
        end
        // Failed-burst drain must ignore FIFO backpressure.
        fifo_wr_ready = 1'b0;
        send_rbeat(32'h3002,2'b00,0);
        send_rbeat(32'h3003,2'b00,0);
        send_rbeat(32'h3004,2'b00,1);
        fifo_wr_ready = 1'b1;
        wait_cycles(3);
        if (discard_seen != 2) begin
            $display("[%0t] ERROR TEST3 expected second discard, got %0d", $time,discard_seen);
            errors = errors + 1;
        end
        if (fifo_discard_beats > 1) begin
            $display("[%0t] ERROR TEST3 drain beats incorrectly included in discard count", $time);
            errors = errors + 1;
        end

        // TEST4: 4KB boundary split. 0x0FFC + 8 bytes must become
        // one beat at 0x0FFC followed by one beat at 0x1000.
        $display("[%0t] TEST4 4KB boundary split", $time);
        pulse_start(32'h0000_0FFC, 13'd8);
        wait_ar_and_accept(32'h0000_0FFC, 8'd0);
        send_rbeat(32'h4B00_0001,2'b00,1);
        wait_ar_and_accept(32'h0000_1000, 8'd0);
        send_rbeat(32'h4B00_0002,2'b00,1);
        wait_cycles(4);
        if (commit_seen != 3 || done_seen != 2) begin
            $display("[%0t] ERROR TEST4 commit=%0d done=%0d",
                     $time,commit_seen,done_seen);
            errors = errors + 1;
        end

        // TEST5: early protocol fault; later cases explicitly reset the DUT.
        $display("[%0t] TEST5 early RLAST protocol fault", $time);
        pulse_start(32'h0000_4000, 13'd16);
        wait_ar_and_accept(32'h0000_4000, 8'd3);
        send_rbeat(32'h4001,2'b00,0);
        send_rbeat(32'h4002,2'b00,1);
        wait_cycles(3);
        if (protocol_seen != 1 || !rd_protocol_fault) begin
            $display("[%0t] ERROR TEST5 protocol_seen=%0d fault=%b",
                     $time,protocol_seen,rd_protocol_fault);
            errors = errors + 1;
        end

        test_ar_timeout();
        test_missing_rlast();

        if (errors == 0)
            $display("[%0t] PASS tb_dma_read_engine", $time);
        else
            $display("[%0t] FAIL tb_dma_read_engine errors=%0d", $time, errors);

        $finish;
    end

endmodule
