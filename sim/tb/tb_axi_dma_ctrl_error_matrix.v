`timescale 1ns/1ps

module tb_axi_dma_ctrl_error_matrix;

    localparam AXI_ID_WIDTH = 6;
    localparam TIMEOUT_CYCLES = 8;

    reg pclk;
    reg axi_clk;
    reg reset_n;

    reg psel;
    reg penable;
    reg pwrite;
    reg [11:0] paddr;
    reg [31:0] pwdata;
    wire [31:0] prdata;
    wire pready;
    wire pslverr;
    wire dma_irq;

    wire [AXI_ID_WIDTH-1:0] m_src_arid;
    wire [31:0] m_src_araddr;
    wire [7:0] m_src_arlen;
    wire [2:0] m_src_arsize;
    wire [1:0] m_src_arburst;
    wire [2:0] m_src_arprot;
    wire [3:0] m_src_arcache;
    wire m_src_arlock;
    wire [3:0] m_src_arqos;
    wire [3:0] m_src_arregion;
    wire m_src_arvalid;
    reg  m_src_arready;

    reg [AXI_ID_WIDTH-1:0] m_src_rid;
    reg [31:0] m_src_rdata;
    reg [1:0] m_src_rresp;
    reg m_src_rlast;
    reg m_src_rvalid;
    wire m_src_rready;

    wire [AXI_ID_WIDTH-1:0] m_dst_awid;
    wire [31:0] m_dst_awaddr;
    wire [7:0] m_dst_awlen;
    wire [2:0] m_dst_awsize;
    wire [1:0] m_dst_awburst;
    wire [2:0] m_dst_awprot;
    wire [3:0] m_dst_awcache;
    wire m_dst_awlock;
    wire [3:0] m_dst_awqos;
    wire [3:0] m_dst_awregion;
    wire m_dst_awvalid;
    reg  m_dst_awready;

    wire [31:0] m_dst_wdata;
    wire [3:0] m_dst_wstrb;
    wire m_dst_wlast;
    wire m_dst_wvalid;
    reg  m_dst_wready;

    reg [AXI_ID_WIDTH-1:0] m_dst_bid;
    reg [1:0] m_dst_bresp;
    reg m_dst_bvalid;
    wire m_dst_bready;

    integer errors;
    integer guard;
    reg [31:0] ctrl;

    axi_dma_ctrl #(
        .APB_ADDR_WIDTH(12),
        .AXI_ADDR_WIDTH(32),
        .AXI_DATA_WIDTH(32),
        .AXI_ID_WIDTH(AXI_ID_WIDTH),
        .MAX_BURST_LENGTH(4),
        .DATA_FIFO_DEPTH(8),
        .AXI_TIMEOUT_CYCLES(TIMEOUT_CYCLES),
        .AXI_ID_VALUE(0)
    ) dut (
        .pclk(pclk),
        .reset_n(reset_n),
        .psel(psel),
        .penable(penable),
        .pwrite(pwrite),
        .paddr(paddr),
        .pwdata(pwdata),
        .prdata(prdata),
        .pready(pready),
        .pslverr(pslverr),
        .dma_irq(dma_irq),
        .axi_clk(axi_clk),

        .m_src_arid(m_src_arid),
        .m_src_araddr(m_src_araddr),
        .m_src_arlen(m_src_arlen),
        .m_src_arsize(m_src_arsize),
        .m_src_arburst(m_src_arburst),
        .m_src_arprot(m_src_arprot),
        .m_src_arcache(m_src_arcache),
        .m_src_arlock(m_src_arlock),
        .m_src_arqos(m_src_arqos),
        .m_src_arregion(m_src_arregion),
        .m_src_arvalid(m_src_arvalid),
        .m_src_arready(m_src_arready),

        .m_src_rid(m_src_rid),
        .m_src_rdata(m_src_rdata),
        .m_src_rresp(m_src_rresp),
        .m_src_rlast(m_src_rlast),
        .m_src_rvalid(m_src_rvalid),
        .m_src_rready(m_src_rready),

        .m_dst_awid(m_dst_awid),
        .m_dst_awaddr(m_dst_awaddr),
        .m_dst_awlen(m_dst_awlen),
        .m_dst_awsize(m_dst_awsize),
        .m_dst_awburst(m_dst_awburst),
        .m_dst_awprot(m_dst_awprot),
        .m_dst_awcache(m_dst_awcache),
        .m_dst_awlock(m_dst_awlock),
        .m_dst_awqos(m_dst_awqos),
        .m_dst_awregion(m_dst_awregion),
        .m_dst_awvalid(m_dst_awvalid),
        .m_dst_awready(m_dst_awready),

        .m_dst_wdata(m_dst_wdata),
        .m_dst_wstrb(m_dst_wstrb),
        .m_dst_wlast(m_dst_wlast),
        .m_dst_wvalid(m_dst_wvalid),
        .m_dst_wready(m_dst_wready),

        .m_dst_bid(m_dst_bid),
        .m_dst_bresp(m_dst_bresp),
        .m_dst_bvalid(m_dst_bvalid),
        .m_dst_bready(m_dst_bready)
    );

    always #7 pclk = ~pclk;
    always #5 axi_clk = ~axi_clk;

    task idle_axi_inputs;
        begin
            m_src_arready = 0;
            m_src_rid = 0;
            m_src_rdata = 0;
            m_src_rresp = 0;
            m_src_rlast = 0;
            m_src_rvalid = 0;

            m_dst_awready = 0;
            m_dst_wready = 0;
            m_dst_bid = 0;
            m_dst_bresp = 0;
            m_dst_bvalid = 0;
        end
    endtask

    task reset_dut;
        begin
            reset_n = 0;
            idle_axi_inputs();
            psel = 0;
            penable = 0;
            pwrite = 0;
            paddr = 0;
            pwdata = 0;
            repeat (4) @(posedge axi_clk);
            @(negedge axi_clk);
            reset_n = 1;
            repeat (4) @(posedge axi_clk);
            repeat (4) @(posedge pclk);
        end
    endtask

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
            @(negedge pclk);
            psel = 0;
            penable = 0;
            pwrite = 0;
            paddr = 0;
            pwdata = 0;
        end
    endtask

    task apb_read;
        input [11:0] addr;
        output [31:0] data;
        begin
            @(negedge pclk);
            psel = 1;
            penable = 1;
            pwrite = 0;
            paddr = addr;
            #1 data = prdata;
            @(posedge pclk);
            @(negedge pclk);
            psel = 0;
            penable = 0;
            paddr = 0;
        end
    endtask

    task start_dma;
        input [31:0] src;
        input [31:0] dst;
        input integer bytes;
        begin
            apb_write(12'h000,src);
            apb_write(12'h004,dst);
            apb_write(12'h008,bytes-1);
            apb_write(12'h00C,32'h8000_0000);
        end
    endtask

    task accept_ar;
        begin
            while (!m_src_arvalid) @(posedge axi_clk);
            @(negedge axi_clk);
            m_src_arready = 1;
            @(posedge axi_clk);
            @(negedge axi_clk);
            m_src_arready = 0;
        end
    endtask

    task send_rbeat;
        input [AXI_ID_WIDTH-1:0] rid;
        input [31:0] data;
        input [1:0] resp;
        input last;
        begin
            @(negedge axi_clk);
            m_src_rid = rid;
            m_src_rdata = data;
            m_src_rresp = resp;
            m_src_rlast = last;
            m_src_rvalid = 1;
            if (rid == 0) begin
                while (!m_src_rready) @(negedge axi_clk);
                @(posedge axi_clk);
                @(negedge axi_clk);
                m_src_rvalid = 0;
                m_src_rlast = 0;
                m_src_rresp = 0;
            end
        end
    endtask

    task complete_one_beat_write;
        input [1:0] bresp;
        input [AXI_ID_WIDTH-1:0] bid;
        begin
            while (!m_dst_awvalid) @(posedge axi_clk);
            @(negedge axi_clk);
            m_dst_awready = 1;
            @(posedge axi_clk);
            @(negedge axi_clk);
            m_dst_awready = 0;

            m_dst_wready = 1;
            while (!(m_dst_wvalid && m_dst_wready)) @(posedge axi_clk);
            @(negedge axi_clk);
            m_dst_wready = 0;

            m_dst_bid = bid;
            m_dst_bresp = bresp;
            m_dst_bvalid = 1;
            if (bid == 0) begin
                while (!m_dst_bready) @(negedge axi_clk);
                @(posedge axi_clk);
                @(negedge axi_clk);
                m_dst_bvalid = 0;
                m_dst_bresp = 0;
            end
        end
    endtask

    task wait_irq_status;
        input [3:0] expected_status;
        input expected_busy;
        begin
            guard = 0;
            while (!dma_irq && guard < 500) begin
                @(posedge pclk);
                guard = guard + 1;
            end
            if (!dma_irq) begin
                $display("[%0t] ERROR IRQ timeout expected status=%h", $time,expected_status);
                errors = errors + 1;
            end
            apb_read(12'h00C,ctrl);
            if (ctrl[3:0] !== expected_status || ctrl[31] !== expected_busy) begin
                $display("[%0t] ERROR CTRL=%h expected busy=%b status=%h",
                         $time,ctrl,expected_busy,expected_status);
                errors = errors + 1;
            end
        end
    endtask

    initial begin
        pclk = 0;
        axi_clk = 0;
        reset_n = 0;
        psel = 0;
        penable = 0;
        pwrite = 0;
        paddr = 0;
        pwdata = 0;
        errors = 0;
        idle_axi_inputs();

        // CASE1: CONFIG_ERROR, no AXI transaction.
        reset_dut();
        $display("[%0t] CASE1 CONFIG_ERROR", $time);
        start_dma(32'h0000_1002,32'h0000_2000,4);
        wait_irq_status(4'hC,1'b0);
        if (m_src_arvalid || m_dst_awvalid) begin
            $display("[%0t] ERROR CONFIG_ERROR issued AXI", $time);
            errors = errors + 1;
        end

        // CASE2: Source RRESP error, ordinary recovery returns BUSY low.
        reset_dut();
        $display("[%0t] CASE2 SRC_RESP_ERROR", $time);
        start_dma(32'h0000_1000,32'h0000_2000,4);
        accept_ar();
        send_rbeat(0,32'h1111_0001,2'b10,1);
        guard = 0;
        while ((!dma_irq || dut.u_dma_cdc.busy_pclk) && guard < 500) begin
            @(posedge pclk);
            guard = guard + 1;
        end
        wait_irq_status(4'h8,1'b0);
        if (m_dst_awvalid) begin
            $display("[%0t] ERROR failed Source burst reached Target AW", $time);
            errors = errors + 1;
        end

        // CASE3: Target BRESP error after committed write.
        reset_dut();
        $display("[%0t] CASE3 DST_RESP_ERROR", $time);
        start_dma(32'h0000_1100,32'h0000_2100,4);
        accept_ar();
        send_rbeat(0,32'h2222_0001,2'b00,1);
        complete_one_beat_write(2'b10,0);
        guard = 0;
        while ((!dma_irq || dut.u_dma_cdc.busy_pclk) && guard < 500) begin
            @(posedge pclk);
            guard = guard + 1;
        end
        wait_irq_status(4'h9,1'b0);

        // CASE4: persistent RID mismatch -> SRC_TIMEOUT, obligation remains.
        reset_dut();
        $display("[%0t] CASE4 RID mismatch timeout", $time);
        start_dma(32'h0000_1200,32'h0000_2200,4);
        accept_ar();
        @(negedge axi_clk);
        m_src_rid = 1;
        m_src_rdata = 32'h3333_0001;
        m_src_rresp = 0;
        m_src_rlast = 1;
        m_src_rvalid = 1;
        repeat (TIMEOUT_CYCLES + 6) @(posedge axi_clk);
        if (m_src_rready !== 1'b0) begin
            $display("[%0t] ERROR mismatched RID was accepted", $time);
            errors = errors + 1;
        end
        wait_irq_status(4'hA,1'b1);

        // CASE5: persistent BID mismatch -> DST_TIMEOUT, obligation remains.
        reset_dut();
        $display("[%0t] CASE5 BID mismatch timeout", $time);
        start_dma(32'h0000_1300,32'h0000_2300,4);
        accept_ar();
        send_rbeat(0,32'h4444_0001,2'b00,1);

        while (!m_dst_awvalid) @(posedge axi_clk);
        @(negedge axi_clk);
        m_dst_awready = 1;
        @(posedge axi_clk);
        @(negedge axi_clk);
        m_dst_awready = 0;

        m_dst_wready = 1;
        while (!(m_dst_wvalid && m_dst_wready)) @(posedge axi_clk);
        @(negedge axi_clk);
        m_dst_wready = 0;

        m_dst_bid = 1;
        m_dst_bresp = 0;
        m_dst_bvalid = 1;
        repeat (TIMEOUT_CYCLES + 6) @(posedge axi_clk);
        if (m_dst_bready !== 1'b0) begin
            $display("[%0t] ERROR mismatched BID was accepted", $time);
            errors = errors + 1;
        end
        wait_irq_status(4'hB,1'b1);

        // CASE6: early RLAST -> reset-required protocol fault.
        reset_dut();
        $display("[%0t] CASE6 SRC_PROTOCOL_ERROR", $time);
        start_dma(32'h0000_1400,32'h0000_2400,8);
        accept_ar();
        send_rbeat(0,32'h5555_0001,2'b00,1);
        wait_irq_status(4'hD,1'b1);
        repeat (10) @(posedge axi_clk);
        apb_read(12'h00C,ctrl);
        if (ctrl[31] !== 1'b1) begin
            $display("[%0t] ERROR protocol fault BUSY escaped without reset", $time);
            errors = errors + 1;
        end

        if (errors == 0)
            $display("[%0t] PASS tb_axi_dma_ctrl_error_matrix", $time);
        else
            $display("[%0t] FAIL tb_axi_dma_ctrl_error_matrix errors=%0d", $time,errors);

        $finish;
    end

endmodule
