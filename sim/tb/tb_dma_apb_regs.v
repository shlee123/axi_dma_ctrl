`timescale 1ns/1ps

module tb_dma_apb_regs;

    reg pclk;
    reg preset_n;
    reg psel;
    reg penable;
    reg pwrite;
    reg [11:0] paddr;
    reg [31:0] pwdata;
    wire [31:0] prdata;
    wire pready;
    wire pslverr;

    wire [31:0] cfg_src_addr;
    wire [31:0] cfg_dst_addr;
    wire [11:0] cfg_length_minus_1;
    wire cfg_source_single;
    wire cfg_target_single;
    wire start_pulse;

    reg start_pending;
    reg busy_pclk;
    reg [3:0] status_code_pclk;
    reg event_pulse_pclk;
    wire dma_irq;

    integer errors;
    integer start_count;

    dma_apb_regs dut (
        .pclk(pclk),
        .preset_n(preset_n),
        .psel(psel),
        .penable(penable),
        .pwrite(pwrite),
        .paddr(paddr),
        .pwdata(pwdata),
        .prdata(prdata),
        .pready(pready),
        .pslverr(pslverr),

        .cfg_src_addr(cfg_src_addr),
        .cfg_dst_addr(cfg_dst_addr),
        .cfg_length_minus_1(cfg_length_minus_1),
        .cfg_source_single(cfg_source_single),
        .cfg_target_single(cfg_target_single),
        .start_pulse(start_pulse),

        .start_pending(start_pending),
        .busy_pclk(busy_pclk),
        .status_code_pclk(status_code_pclk),
        .event_pulse_pclk(event_pulse_pclk),
        .dma_irq(dma_irq)
    );

    always #5 pclk = ~pclk;

    always @(posedge pclk)
        if (start_pulse)
            start_count = start_count + 1;

    task apb_write;
        input [11:0] addr;
        input [31:0] data;
        begin
            @(negedge pclk);
            psel = 1;
            penable = 1;
            pwrite = 1;
            paddr = addr;
            pwdata = data;
            @(posedge pclk);
            #1;
            @(negedge pclk);
            psel = 0;
            penable = 0;
            pwrite = 0;
            paddr = 0;
            pwdata = 0;
        end
    endtask

    task apb_read_check;
        input [11:0] addr;
        input [31:0] exp;
        input exp_err;
        begin
            @(negedge pclk);
            psel = 1;
            penable = 1;
            pwrite = 0;
            paddr = addr;
            #1;
            if (prdata !== exp || pslverr !== exp_err) begin
                $display("[%0t] ERROR read addr=%h data=%h/%h err=%b/%b",
                         $time,addr,prdata,exp,pslverr,exp_err);
                errors = errors + 1;
            end
            @(posedge pclk);
            @(negedge pclk);
            psel = 0;
            penable = 0;
            paddr = 0;
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
        $fsdbDumpvars(0, tb_dma_apb_regs);
    end
`endif

    initial begin
        pclk = 0;
        preset_n = 0;
        psel = 0;
        penable = 0;
        pwrite = 0;
        paddr = 0;
        pwdata = 0;
        start_pending = 0;
        busy_pclk = 0;
        status_code_pclk = 0;
        event_pulse_pclk = 0;
        errors = 0;
        start_count = 0;

        repeat (3) @(posedge pclk);
        @(negedge pclk);
        preset_n = 1;

        // Basic R/W.
        apb_write(12'h000,32'h1000_0000);
        apb_write(12'h004,32'h2000_0000);
        apb_write(12'h008,32'h0003_000F);
        apb_read_check(12'h000,32'h1000_0000,0);
        apb_read_check(12'h004,32'h2000_0000,0);
        apb_read_check(12'h008,32'h0003_000F,0);

        // START accepted, clears old IRQ.
        event_pulse_pclk = 1;
        @(posedge pclk);
        @(negedge pclk);
        event_pulse_pclk = 0;
        if (!dma_irq) begin
            $display("[%0t] ERROR IRQ not set by event", $time);
            errors = errors + 1;
        end

        apb_write(12'h00C,32'h8000_0000);
        @(posedge pclk);
        #1;
        if (start_count != 1 || dma_irq) begin
            $display("[%0t] ERROR START count=%0d irq=%b", $time,start_count,dma_irq);
            errors = errors + 1;
        end

        // Pending START blocks repeat.
        start_pending = 1;
        apb_write(12'h00C,32'h8000_0000);
        if (start_count != 1) begin
            $display("[%0t] ERROR repeat START accepted while pending", $time);
            errors = errors + 1;
        end
        start_pending = 0;

        // BUSY blocks START.
        busy_pclk = 1;
        apb_write(12'h00C,32'h8000_0000);
        if (start_count != 1) begin
            $display("[%0t] ERROR START accepted while busy", $time);
            errors = errors + 1;
        end

        status_code_pclk = 4'h8;
        // Accepted START owns a local APB-visible clear. Changing the CDC
        // holding value alone must not change the software-visible status.
        apb_read_check(12'h00C,32'h8000_0000,0);

        // A new reliable event updates the APB-visible status image.
        event_pulse_pclk = 1;
        @(posedge pclk);
        @(negedge pclk);
        event_pulse_pclk = 0;
        apb_read_check(12'h00C,32'h8000_0008,0);
        busy_pclk = 0;

        // W1C and set-dominant same cycle.
        event_pulse_pclk = 1;
        @(negedge pclk);
        psel = 1; penable = 1; pwrite = 1; paddr = 12'h010; pwdata = 32'h1;
        @(posedge pclk);
        @(negedge pclk);
        psel = 0; penable = 0; pwrite = 0; paddr = 0; pwdata = 0;
        event_pulse_pclk = 0;
        if (!dma_irq) begin
            $display("[%0t] ERROR set-dominant IRQ behavior failed", $time);
            errors = errors + 1;
        end

        apb_write(12'h010,32'h1);
        if (dma_irq) begin
            $display("[%0t] ERROR IRQ W1C failed", $time);
            errors = errors + 1;
        end

        // Invalid and unaligned reads.
        apb_read_check(12'h014,32'h0,1);
        apb_read_check(12'h002,32'h0,1);

        if (errors == 0)
            $display("[%0t] PASS tb_dma_apb_regs", $time);
        else
            $display("[%0t] FAIL tb_dma_apb_regs errors=%0d", $time,errors);

        $finish;
    end

endmodule
