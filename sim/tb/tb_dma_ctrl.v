`timescale 1ns/1ps

module tb_dma_ctrl;

    localparam AXI_ADDR_WIDTH = 32;
    localparam AXI_DATA_WIDTH = 32;

    reg clk;
    reg rst_n;

    reg cmd_valid;
    wire cmd_ready;
    reg [31:0] cmd_src_addr;
    reg [31:0] cmd_dst_addr;
    reg [11:0] cmd_length_minus_1;
    reg cmd_source_single;
    reg cmd_target_single;

    wire rd_start;
    wire rd_abort_new;
    wire [31:0] rd_src_addr;
    wire [12:0] rd_transfer_bytes;
    wire rd_source_single;
    reg rd_busy;
    reg rd_done;
    reg rd_error_valid;
    reg [3:0] rd_error_code;
    reg rd_protocol_fault;

    wire wr_start;
    wire wr_abort_new;
    wire [31:0] wr_dst_addr;
    wire [12:0] wr_transfer_bytes;
    wire wr_target_single;
    reg wr_busy;
    reg wr_done;
    reg wr_error_valid;
    reg [3:0] wr_error_code;

    reg [15:0] fifo_verified_count;
    reg [15:0] fifo_unverified_count;
    reg [15:0] fifo_reserved_count;
    wire fifo_flush_uncommitted;

    wire dma_busy;
    wire [3:0] dma_status_code;
    wire event_valid;
    reg event_ready;
    wire [3:0] event_status;

    integer errors;
    integer event_count;
    integer flush_count;
    reg [3:0] last_event_status;

    dma_ctrl #(
        .AXI_ADDR_WIDTH(AXI_ADDR_WIDTH),
        .AXI_DATA_WIDTH(AXI_DATA_WIDTH)
    ) dut (
        .clk(clk),
        .rst_n(rst_n),
        .cmd_valid(cmd_valid),
        .cmd_ready(cmd_ready),
        .cmd_src_addr(cmd_src_addr),
        .cmd_dst_addr(cmd_dst_addr),
        .cmd_length_minus_1(cmd_length_minus_1),
        .cmd_source_single(cmd_source_single),
        .cmd_target_single(cmd_target_single),

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

        .dma_busy(dma_busy),
        .dma_status_code(dma_status_code),
        .event_valid(event_valid),
        .event_ready(event_ready),
        .event_status(event_status)
    );

    always #5 clk = ~clk;

    always @(posedge clk) begin
        if (event_valid) begin
            event_count = event_count + 1;
            last_event_status = event_status;
        end
        if (fifo_flush_uncommitted)
            flush_count = flush_count + 1;
    end

    task issue_cmd;
        input [31:0] src;
        input [31:0] dst;
        input [11:0] len_m1;
        begin
            while (!cmd_ready) @(posedge clk);
            @(negedge clk);
            cmd_src_addr = src;
            cmd_dst_addr = dst;
            cmd_length_minus_1 = len_m1;
            cmd_valid = 1'b1;
            @(posedge clk);
            @(negedge clk);
            cmd_valid = 1'b0;
        end
    endtask

    task pulse_rd_done;
        begin
            @(negedge clk);
            rd_done = 1'b1;
            @(posedge clk);
            @(negedge clk);
            rd_done = 1'b0;
        end
    endtask

    task pulse_wr_done;
        begin
            @(negedge clk);
            wr_done = 1'b1;
            @(posedge clk);
            @(negedge clk);
            wr_done = 1'b0;
        end
    endtask

    task wait_cycles;
        input integer n;
        integer i;
        begin
            for (i=0;i<n;i=i+1) @(posedge clk);
        end
    endtask

    initial begin
        clk = 0;
        rst_n = 0;
        cmd_valid = 0;
        cmd_src_addr = 0;
        cmd_dst_addr = 0;
        cmd_length_minus_1 = 0;
        cmd_source_single = 0;
        cmd_target_single = 0;

        rd_busy = 0;
        rd_done = 0;
        rd_error_valid = 0;
        rd_error_code = 0;
        rd_protocol_fault = 0;

        wr_busy = 0;
        wr_done = 0;
        wr_error_valid = 0;
        wr_error_code = 0;

        fifo_verified_count = 0;
        fifo_unverified_count = 0;
        fifo_reserved_count = 0;

        errors = 0;
        event_count = 0;
        flush_count = 0;
        last_event_status = 0;
        event_ready = 1;

        repeat (3) @(posedge clk);
        @(negedge clk);
        rst_n = 1;

        // TEST1: invalid alignment -> CONFIG_ERROR, no engine start.
        $display("[%0t] TEST1 config error", $time);
        issue_cmd(32'h0000_1002, 32'h0000_2000, 12'd15);
        wait_cycles(3);
        if (last_event_status !== 4'hC || dma_busy !== 1'b0) begin
            $display("[%0t] ERROR TEST1 status=%h busy=%b", $time,last_event_status,dma_busy);
            errors = errors + 1;
        end

        // TEST2: normal operation. Both engines start together; completion
        // only after both done and FIFO payload is clear.
        $display("[%0t] TEST2 normal completion", $time);
        issue_cmd(32'h0000_1000, 32'h0000_2000, 12'd15);
        wait_cycles(2);
        if (!dma_busy || rd_transfer_bytes !== 13'd16 || wr_transfer_bytes !== 13'd16) begin
            $display("[%0t] ERROR TEST2 launch busy=%b rd_bytes=%0d wr_bytes=%0d",
                     $time,dma_busy,rd_transfer_bytes,wr_transfer_bytes);
            errors = errors + 1;
        end

        rd_busy = 1;
        wr_busy = 1;
        fifo_verified_count = 2;

        pulse_rd_done();
        rd_busy = 0;
        wait_cycles(1);

        pulse_wr_done();
        wr_busy = 0;

        // FIFO still contains data: must not complete.
        wait_cycles(2);
        if (!dma_busy) begin
            $display("[%0t] ERROR TEST2 completed while FIFO nonempty", $time);
            errors = errors + 1;
        end

        @(negedge clk);
        fifo_verified_count = 0;
        wait_cycles(3);

        if (last_event_status !== 4'h0 || dma_busy !== 1'b0) begin
            $display("[%0t] ERROR TEST2 completion status=%h busy=%b",
                     $time,last_event_status,dma_busy);
            errors = errors + 1;
        end

        // TEST3: simultaneous Source and Target error -> Source wins.
        $display("[%0t] TEST3 first-error priority and recovery", $time);
        issue_cmd(32'h0000_3000, 32'h0000_4000, 12'd31);
        wait_cycles(2);

        rd_busy = 1;
        wr_busy = 1;
        fifo_verified_count = 3;
        fifo_reserved_count = 2;

        @(negedge clk);
        rd_error_valid = 1;
        rd_error_code = 4'h8;
        wr_error_valid = 1;
        wr_error_code = 4'h9;
        @(posedge clk);
        @(negedge clk);
        rd_error_valid = 0;
        wr_error_valid = 0;

        wait_cycles(1);
        if (dma_status_code !== 4'h8 || !rd_abort_new || !wr_abort_new) begin
            $display("[%0t] ERROR TEST3 status=%h abort rd/wr=%b/%b",
                     $time,dma_status_code,rd_abort_new,wr_abort_new);
            errors = errors + 1;
        end

        // Recovery cannot finish while obligations/reservation remain.
        rd_busy = 0;
        wr_busy = 1;
        wait_cycles(2);
        if (!dma_busy) begin
            $display("[%0t] ERROR TEST3 busy dropped before obligations clear", $time);
            errors = errors + 1;
        end

        @(negedge clk);
        wr_busy = 0;
        fifo_reserved_count = 0;
        wait_cycles(2);

        if (flush_count == 0 || dma_busy) begin
            $display("[%0t] ERROR TEST3 recovery flush=%0d busy=%b",
                     $time,flush_count,dma_busy);
            errors = errors + 1;
        end

        // Model FIFO flush effect after controller pulse.
        fifo_verified_count = 0;
        fifo_unverified_count = 0;

        // TEST4: protocol fault is reset-required and overrides recovery.
        $display("[%0t] TEST4 protocol fault", $time);
        issue_cmd(32'h0000_5000, 32'h0000_6000, 12'd7);
        wait_cycles(2);
        rd_busy = 1;
        wr_busy = 0;

        @(negedge clk);
        rd_error_valid = 1;
        rd_error_code = 4'hD;
        rd_protocol_fault = 1;
        @(posedge clk);
        @(negedge clk);
        rd_error_valid = 0;

        wait_cycles(3);
        if (!dma_busy || dma_status_code !== 4'hD || cmd_ready) begin
            $display("[%0t] ERROR TEST4 busy=%b status=%h cmd_ready=%b",
                     $time,dma_busy,dma_status_code,cmd_ready);
            errors = errors + 1;
        end

        // Even when engine obligation clears, protocol-fault BUSY remains high.
        @(negedge clk);
        rd_busy = 0;
        wait_cycles(2);
        if (!dma_busy) begin
            $display("[%0t] ERROR TEST4 protocol fault escaped without reset", $time);
            errors = errors + 1;
        end

        // Coordinated reset returns to IDLE.
        @(negedge clk);
        rst_n = 0;
        @(posedge clk);
        @(negedge clk);
        rd_protocol_fault = 0;
        rst_n = 1;
        wait_cycles(2);
        if (dma_busy || !cmd_ready) begin
            $display("[%0t] ERROR TEST4 reset recovery busy=%b ready=%b",
                     $time,dma_busy,cmd_ready);
            errors = errors + 1;
        end

        if (errors == 0)
            $display("[%0t] PASS tb_dma_ctrl", $time);
        else
            $display("[%0t] FAIL tb_dma_ctrl errors=%0d", $time,errors);

        $finish;
    end

endmodule
