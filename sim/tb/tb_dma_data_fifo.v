`timescale 1ns/1ps

module tb_dma_data_fifo;

    localparam DATA_WIDTH  = 32;
    localparam DEPTH       = 8;
    localparam PTR_WIDTH   = 3;
    localparam COUNT_WIDTH = 4;

    reg clk;
    reg rst_n;

    reg                       src_burst_begin;
    reg                       src_wr_valid;
    wire                      src_wr_ready;
    reg  [DATA_WIDTH-1:0]      src_wr_data;
    reg                       src_commit_valid;
    reg  [COUNT_WIDTH-1:0]     src_commit_beats;
    reg                       src_discard_valid;
    reg  [COUNT_WIDTH-1:0]     src_discard_beats;

    reg                       dst_reserve_valid;
    reg  [COUNT_WIDTH-1:0]     dst_reserve_beats;
    wire                      dst_reserve_ready;
    wire                      dst_rd_valid;
    wire [DATA_WIDTH-1:0]      dst_rd_data;
    reg                       dst_rd_advance;
    reg                       dst_release_valid;
    reg  [COUNT_WIDTH-1:0]     dst_release_beats;

    reg                       flush_uncommitted;

    wire [COUNT_WIDTH-1:0]     free_count;
    wire [COUNT_WIDTH-1:0]     verified_count;
    wire [COUNT_WIDTH-1:0]     unverified_count;
    wire [COUNT_WIDTH-1:0]     reserved_count;
    wire                      empty;
    wire                      full;

    integer errors;

    dma_data_fifo #(
        .DATA_WIDTH(DATA_WIDTH),
        .DEPTH(DEPTH),
        .PTR_WIDTH(PTR_WIDTH),
        .COUNT_WIDTH(COUNT_WIDTH)
    ) dut (
        .clk(clk),
        .rst_n(rst_n),
        .src_burst_begin(src_burst_begin),
        .src_wr_valid(src_wr_valid),
        .src_wr_ready(src_wr_ready),
        .src_wr_data(src_wr_data),
        .src_commit_valid(src_commit_valid),
        .src_commit_beats(src_commit_beats),
        .src_discard_valid(src_discard_valid),
        .src_discard_beats(src_discard_beats),
        .dst_reserve_valid(dst_reserve_valid),
        .dst_reserve_beats(dst_reserve_beats),
        .dst_reserve_ready(dst_reserve_ready),
        .dst_rd_valid(dst_rd_valid),
        .dst_rd_data(dst_rd_data),
        .dst_rd_advance(dst_rd_advance),
        .dst_release_valid(dst_release_valid),
        .dst_release_beats(dst_release_beats),
        .flush_uncommitted(flush_uncommitted),
        .free_count(free_count),
        .verified_count(verified_count),
        .unverified_count(unverified_count),
        .reserved_count(reserved_count),
        .empty(empty),
        .full(full)
    );

    always #5 clk = ~clk;

    task check_counts;
        input [COUNT_WIDTH-1:0] exp_free;
        input [COUNT_WIDTH-1:0] exp_v;
        input [COUNT_WIDTH-1:0] exp_u;
        input [COUNT_WIDTH-1:0] exp_r;
        begin
            #1;
            if ((free_count !== exp_free) ||
                (verified_count !== exp_v) ||
                (unverified_count !== exp_u) ||
                (reserved_count !== exp_r)) begin
                $display("[%0t] ERROR counts: free=%0d/%0d V=%0d/%0d U=%0d/%0d R=%0d/%0d",
                         $time,
                         free_count, exp_free,
                         verified_count, exp_v,
                         unverified_count, exp_u,
                         reserved_count, exp_r);
                errors = errors + 1;
            end
        end
    endtask

    task source_write_beat;
        input [DATA_WIDTH-1:0] data;
        begin
            @(negedge clk);
            src_wr_data  = data;
            src_wr_valid = 1'b1;
            @(posedge clk);
            #1;
            if (!src_wr_ready) begin
                $display("[%0t] ERROR src_wr_ready unexpectedly low", $time);
                errors = errors + 1;
            end
            @(negedge clk);
            src_wr_valid = 1'b0;
        end
    endtask

    task target_expect_and_advance;
        input [DATA_WIDTH-1:0] exp_data;
        input                  is_last;
        input [COUNT_WIDTH-1:0] release_beats;
        begin
            @(negedge clk);
            #1;
            if (!dst_rd_valid || dst_rd_data !== exp_data) begin
                $display("[%0t] ERROR target data: valid=%b data=%h expected=%h",
                         $time, dst_rd_valid, dst_rd_data, exp_data);
                errors = errors + 1;
            end
            dst_rd_advance = 1'b1;
            if (is_last) begin
                dst_release_valid = 1'b1;
                dst_release_beats = release_beats;
            end
            @(posedge clk);
            @(negedge clk);
            dst_rd_advance    = 1'b0;
            dst_release_valid = 1'b0;
            dst_release_beats = 0;
        end
    endtask

    initial begin
        clk = 1'b0;
        rst_n = 1'b0;
        src_burst_begin = 0;
        src_wr_valid = 0;
        src_wr_data = 0;
        src_commit_valid = 0;
        src_commit_beats = 0;
        src_discard_valid = 0;
        src_discard_beats = 0;
        dst_reserve_valid = 0;
        dst_reserve_beats = 0;
        dst_rd_advance = 0;
        dst_release_valid = 0;
        dst_release_beats = 0;
        flush_uncommitted = 0;
        errors = 0;

        repeat (3) @(posedge clk);
        @(negedge clk);
        rst_n = 1'b1;
        @(posedge clk);
        check_counts(8, 0, 0, 0);

        // ------------------------------------------------------------
        // TEST 1: successful Source burst -> reserve -> final-W release
        // ------------------------------------------------------------
        $display("[%0t] TEST1 successful burst", $time);
        @(negedge clk);
        src_burst_begin = 1'b1;
        @(posedge clk);
        @(negedge clk);
        src_burst_begin = 1'b0;

        source_write_beat(32'h1111_0001);
        source_write_beat(32'h1111_0002);
        source_write_beat(32'h1111_0003);
        source_write_beat(32'h1111_0004);
        check_counts(4, 0, 4, 0);

        @(negedge clk);
        src_commit_valid = 1'b1;
        src_commit_beats = 4;
        @(posedge clk);
        @(negedge clk);
        src_commit_valid = 1'b0;
        src_commit_beats = 0;
        check_counts(4, 4, 0, 0);

        @(negedge clk);
        dst_reserve_valid = 1'b1;
        dst_reserve_beats = 4;
        #1;
        if (!dst_reserve_ready) begin
            $display("[%0t] ERROR reserve not ready", $time);
            errors = errors + 1;
        end
        @(posedge clk);
        @(negedge clk);
        dst_reserve_valid = 1'b0;
        dst_reserve_beats = 0;
        check_counts(4, 0, 0, 4);

        target_expect_and_advance(32'h1111_0001, 0, 0);
        target_expect_and_advance(32'h1111_0002, 0, 0);
        target_expect_and_advance(32'h1111_0003, 0, 0);
        target_expect_and_advance(32'h1111_0004, 1, 4);
        check_counts(8, 0, 0, 0);

        // ------------------------------------------------------------
        // TEST 2: failed Source burst rolls write pointer back
        // ------------------------------------------------------------
        $display("[%0t] TEST2 failed burst rollback", $time);
        @(negedge clk);
        src_burst_begin = 1'b1;
        @(posedge clk);
        @(negedge clk);
        src_burst_begin = 1'b0;

        source_write_beat(32'hDEAD_0001);
        source_write_beat(32'hDEAD_0002);
        source_write_beat(32'hDEAD_0003);
        check_counts(5, 0, 3, 0);

        @(negedge clk);
        src_discard_valid = 1'b1;
        src_discard_beats = 3;
        @(posedge clk);
        @(negedge clk);
        src_discard_valid = 1'b0;
        src_discard_beats = 0;
        check_counts(8, 0, 0, 0);

        // New successful burst should reuse the rolled-back locations.
        @(negedge clk);
        src_burst_begin = 1'b1;
        @(posedge clk);
        @(negedge clk);
        src_burst_begin = 1'b0;

        source_write_beat(32'h2222_0001);
        source_write_beat(32'h2222_0002);

        @(negedge clk);
        src_commit_valid = 1'b1;
        src_commit_beats = 2;
        @(posedge clk);
        @(negedge clk);
        src_commit_valid = 1'b0;
        src_commit_beats = 0;
        check_counts(6, 2, 0, 0);

        // ------------------------------------------------------------
        // TEST 3: Source commit and Target reserve in same cycle
        // ------------------------------------------------------------
        $display("[%0t] TEST3 concurrent commit/reserve", $time);
        @(negedge clk);
        src_burst_begin = 1'b1;
        @(posedge clk);
        @(negedge clk);
        src_burst_begin = 1'b0;

        source_write_beat(32'h3333_0001);
        source_write_beat(32'h3333_0002);
        check_counts(4, 2, 2, 0);

        @(negedge clk);
        src_commit_valid  = 1'b1;
        src_commit_beats  = 2;
        dst_reserve_valid = 1'b1;
        dst_reserve_beats = 2;
        #1;
        if (!dst_reserve_ready) begin
            $display("[%0t] ERROR concurrent reserve unexpectedly blocked", $time);
            errors = errors + 1;
        end
        @(posedge clk);
        @(negedge clk);
        src_commit_valid  = 1'b0;
        src_commit_beats  = 0;
        dst_reserve_valid = 1'b0;
        dst_reserve_beats = 0;
        check_counts(4, 2, 0, 2);

        // Reservation contains the older verified burst.
        target_expect_and_advance(32'h2222_0001, 0, 0);
        target_expect_and_advance(32'h2222_0002, 1, 2);
        check_counts(6, 2, 0, 0);

        // Reserve and consume the newly committed burst.
        @(negedge clk);
        dst_reserve_valid = 1'b1;
        dst_reserve_beats = 2;
        @(posedge clk);
        @(negedge clk);
        dst_reserve_valid = 1'b0;
        dst_reserve_beats = 0;

        target_expect_and_advance(32'h3333_0001, 0, 0);
        target_expect_and_advance(32'h3333_0002, 1, 2);
        check_counts(8, 0, 0, 0);

        if (errors == 0)
            $display("[%0t] PASS tb_dma_data_fifo", $time);
        else
            $display("[%0t] FAIL tb_dma_data_fifo errors=%0d", $time, errors);

        $finish;
    end

endmodule
