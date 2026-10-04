`timescale 1ns/1ps

module tb_dma_cdc;

    reg pclk;
    reg preset_n;
    reg axi_clk;
    reg axi_reset_n;

    reg start_pulse;
    reg [31:0] cfg_src_addr_pclk;
    reg [31:0] cfg_dst_addr_pclk;
    reg [11:0] cfg_length_minus_1_pclk;
    reg cfg_source_single_pclk;
    reg cfg_target_single_pclk;

    wire start_pending_pclk;
    wire busy_pclk;
    wire [3:0] status_code_pclk;
    wire event_pulse_pclk;

    wire cmd_valid;
    reg  cmd_ready;
    wire [31:0] cmd_src_addr;
    wire [31:0] cmd_dst_addr;
    wire [11:0] cmd_length_minus_1;
    wire cmd_source_single;
    wire cmd_target_single;

    reg dma_busy_axi;
    reg event_valid_axi;
    wire event_ready_axi;
    reg [3:0] event_status_axi;

    integer errors;
    integer pclk_event_count;

    dma_cdc dut (
        .pclk(pclk),
        .preset_n(preset_n),
        .start_pulse(start_pulse),
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
        .axi_reset_n(axi_reset_n),
        .cmd_valid(cmd_valid),
        .cmd_ready(cmd_ready),
        .cmd_src_addr(cmd_src_addr),
        .cmd_dst_addr(cmd_dst_addr),
        .cmd_length_minus_1(cmd_length_minus_1),
        .cmd_source_single(cmd_source_single),
        .cmd_target_single(cmd_target_single),

        .dma_busy_axi(dma_busy_axi),
        .event_valid_axi(event_valid_axi),
        .event_ready_axi(event_ready_axi),
        .event_status_axi(event_status_axi)
    );

    always #7 pclk = ~pclk;
    always #5 axi_clk = ~axi_clk;

    always @(posedge pclk)
        if (event_pulse_pclk)
            pclk_event_count = pclk_event_count + 1;

    task wait_pclk_cycles;
        input integer n;
        integer i;
        begin
            for (i=0;i<n;i=i+1) @(posedge pclk);
        end
    endtask

    task wait_axi_cycles;
        input integer n;
        integer i;
        begin
            for (i=0;i<n;i=i+1) @(posedge axi_clk);
        end
    endtask

    initial begin
        pclk = 0;
        axi_clk = 0;
        preset_n = 0;
        axi_reset_n = 0;
        start_pulse = 0;
        cfg_src_addr_pclk = 0;
        cfg_dst_addr_pclk = 0;
        cfg_length_minus_1_pclk = 0;
        cfg_source_single_pclk = 0;
        cfg_target_single_pclk = 0;
        cmd_ready = 0;
        dma_busy_axi = 0;
        event_valid_axi = 0;
        event_status_axi = 0;
        errors = 0;
        pclk_event_count = 0;

        wait_pclk_cycles(2);
        @(negedge pclk);
        preset_n = 1;
        axi_reset_n = 1;

        // TEST1: coherent START/config transfer and request ACK.
        $display("[%0t] TEST1 START/config CDC", $time);
        @(negedge pclk);
        cfg_src_addr_pclk = 32'h1234_1000;
        cfg_dst_addr_pclk = 32'h5678_2000;
        cfg_length_minus_1_pclk = 12'd63;
        cfg_source_single_pclk = 1;
        cfg_target_single_pclk = 0;
        start_pulse = 1;
        @(posedge pclk);
        @(negedge pclk);
        start_pulse = 0;

        // Change writable config after START. Holding snapshot must not change.
        cfg_src_addr_pclk = 32'hAAAA_AAAA;
        cfg_dst_addr_pclk = 32'hBBBB_BBBB;

        while (!cmd_valid) @(posedge axi_clk);
        #1;
        if (cmd_src_addr !== 32'h1234_1000 ||
            cmd_dst_addr !== 32'h5678_2000 ||
            cmd_length_minus_1 !== 12'd63 ||
            cmd_source_single !== 1'b1 ||
            cmd_target_single !== 1'b0) begin
            $display("[%0t] ERROR TEST1 incoherent command snapshot", $time);
            errors = errors + 1;
        end

        if (!start_pending_pclk) begin
            $display("[%0t] ERROR TEST1 pending dropped before command ACK", $time);
            errors = errors + 1;
        end

        @(negedge axi_clk);
        cmd_ready = 1;
        @(posedge axi_clk);
        @(negedge axi_clk);
        cmd_ready = 0;

        wait_pclk_cycles(4);
        if (start_pending_pclk) begin
            $display("[%0t] ERROR TEST1 pending did not clear after ACK", $time);
            errors = errors + 1;
        end

        // TEST2: BUSY level synchronization.
        $display("[%0t] TEST2 BUSY synchronization", $time);
        @(negedge axi_clk);
        dma_busy_axi = 1;
        wait_pclk_cycles(4);
        if (!busy_pclk) begin
            $display("[%0t] ERROR TEST2 BUSY did not cross high", $time);
            errors = errors + 1;
        end
        @(negedge axi_clk);
        dma_busy_axi = 0;
        wait_pclk_cycles(4);
        if (busy_pclk) begin
            $display("[%0t] ERROR TEST2 BUSY did not cross low", $time);
            errors = errors + 1;
        end

        // TEST3: acknowledged event/status transfer.
        $display("[%0t] TEST3 event/status handshake", $time);
        while (!event_ready_axi) @(posedge axi_clk);
        @(negedge axi_clk);
        event_status_axi = 4'h8;
        event_valid_axi = 1;
        @(posedge axi_clk);
        @(negedge axi_clk);
        event_valid_axi = 0;

        // event_ready must drop while event is in flight.
        wait_axi_cycles(1);
        if (event_ready_axi) begin
            $display("[%0t] ERROR TEST3 event_ready stayed high while pending", $time);
            errors = errors + 1;
        end

        while (pclk_event_count < 1) @(posedge pclk);
        #1;
        if (status_code_pclk !== 4'h8) begin
            $display("[%0t] ERROR TEST3 status got %h expected 8", $time,status_code_pclk);
            errors = errors + 1;
        end

        while (!event_ready_axi) @(posedge axi_clk);

        // Second event must cross after ACK of first.
        @(negedge axi_clk);
        event_status_axi = 4'h9;
        event_valid_axi = 1;
        @(posedge axi_clk);
        @(negedge axi_clk);
        event_valid_axi = 0;

        while (pclk_event_count < 2) @(posedge pclk);
        #1;
        if (status_code_pclk !== 4'h9) begin
            $display("[%0t] ERROR TEST3 second status got %h expected 9",
                     $time,status_code_pclk);
            errors = errors + 1;
        end

        if (errors == 0)
            $display("[%0t] PASS tb_dma_cdc", $time);
        else
            $display("[%0t] FAIL tb_dma_cdc errors=%0d", $time,errors);

        $finish;
    end

endmodule
