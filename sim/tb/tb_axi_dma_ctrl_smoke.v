`timescale 1ns/1ps

module tb_axi_dma_ctrl_smoke;

    localparam AXI_DATA_WIDTH = 32;
    localparam AXI_ID_WIDTH   = 6;

    reg pclk;
    reg reset_n;
    reg axi_clk;

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
    integer w_count;
    reg [31:0] captured_wdata [0:3];

    axi_dma_ctrl #(
        .APB_ADDR_WIDTH(12),
        .AXI_ADDR_WIDTH(32),
        .AXI_DATA_WIDTH(32),
        .AXI_ID_WIDTH(AXI_ID_WIDTH),
        .MAX_BURST_LENGTH(4),
        .DATA_FIFO_DEPTH(8),
        .AXI_TIMEOUT_CYCLES(32),
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

    always @(posedge axi_clk) begin
        if (m_dst_wvalid && m_dst_wready) begin
            if (w_count < 4)
                captured_wdata[w_count] <= m_dst_wdata;
            w_count = w_count + 1;
        end
    end

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

    task send_rbeat;
        input [31:0] data;
        input last;
        begin
            @(negedge axi_clk);
            m_src_rdata = data;
            m_src_rresp = 2'b00;
            m_src_rlast = last;
            m_src_rvalid = 1;
            while (!m_src_rready) @(negedge axi_clk);
            @(posedge axi_clk);
            @(negedge axi_clk);
            m_src_rvalid = 0;
            m_src_rlast = 0;
        end
    endtask

    reg [31:0] ctrl_read;
    integer timeout_guard;

    initial begin
        pclk = 0;
        axi_clk = 0;
        reset_n = 0;

        psel = 0;
        penable = 0;
        pwrite = 0;
        paddr = 0;
        pwdata = 0;

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

        errors = 0;
        w_count = 0;

        repeat (4) @(posedge axi_clk);
        @(negedge axi_clk);
        reset_n = 1;
        // Allow both domain reset synchronizers to deassert.
        repeat (4) @(posedge axi_clk);
        repeat (4) @(posedge pclk);

        if (m_src_arprot !== 3'b000 || m_src_arcache !== 4'b0000 ||
            m_src_arlock !== 1'b0 || m_src_arqos !== 4'b0000 ||
            m_src_arregion !== 4'b0000 || m_dst_awprot !== 3'b000 ||
            m_dst_awcache !== 4'b0000 || m_dst_awlock !== 1'b0 ||
            m_dst_awqos !== 4'b0000 || m_dst_awregion !== 4'b0000) begin
            $display("[%0t] ERROR AXI sideband defaults", $time);
            errors = errors + 1;
        end

        // Program 16-byte transfer.
        apb_write(12'h000,32'h0000_1000);
        apb_write(12'h004,32'h0000_2000);
        apb_write(12'h008,32'h0000_000F);
        apb_write(12'h00C,32'h8000_0000);

        // Source AR: 4 beats.
        while (!m_src_arvalid) @(posedge axi_clk);
        #1;
        if (m_src_araddr !== 32'h0000_1000 || m_src_arlen !== 8'd3) begin
            $display("[%0t] ERROR source AR addr=%h len=%0d", $time,m_src_araddr,m_src_arlen);
            errors = errors + 1;
        end

        @(negedge axi_clk);
        m_src_arready = 1;
        @(posedge axi_clk);
        @(negedge axi_clk);
        m_src_arready = 0;

        send_rbeat(32'hA001_0001,0);
        send_rbeat(32'hA002_0002,0);
        send_rbeat(32'hA003_0003,0);
        send_rbeat(32'hA004_0004,1);

        // Target AW must happen only after Source burst is committed.
        while (!m_dst_awvalid) @(posedge axi_clk);
        #1;
        if (m_dst_awaddr !== 32'h0000_2000 || m_dst_awlen !== 8'd3) begin
            $display("[%0t] ERROR target AW addr=%h len=%0d", $time,m_dst_awaddr,m_dst_awlen);
            errors = errors + 1;
        end

        @(negedge axi_clk);
        m_dst_awready = 1;
        @(posedge axi_clk);
        @(negedge axi_clk);
        m_dst_awready = 0;

        // Accept all W beats.
        m_dst_wready = 1;
        timeout_guard = 0;
        while (w_count < 4 && timeout_guard < 100) begin
            @(posedge axi_clk);
            timeout_guard = timeout_guard + 1;
        end
        @(negedge axi_clk);
        m_dst_wready = 0;

        if (w_count != 4) begin
            $display("[%0t] ERROR target W beat count=%0d", $time,w_count);
            errors = errors + 1;
        end

        if (captured_wdata[0] !== 32'hA001_0001 ||
            captured_wdata[1] !== 32'hA002_0002 ||
            captured_wdata[2] !== 32'hA003_0003 ||
            captured_wdata[3] !== 32'hA004_0004) begin
            $display("[%0t] ERROR target W data mismatch %h %h %h %h",
                     $time,captured_wdata[0],captured_wdata[1],
                     captured_wdata[2],captured_wdata[3]);
            errors = errors + 1;
        end

        // Final B response. BVALID is independent of BREADY and remains
        // asserted until the matching handshake completes.
        @(negedge axi_clk);
        m_dst_bvalid = 1;
        m_dst_bresp = 2'b00;
        while (!m_dst_bready) @(negedge axi_clk);
        @(posedge axi_clk);
        @(negedge axi_clk);
        m_dst_bvalid = 0;

        // Wait for completion event to become IRQ in PCLK.
        timeout_guard = 0;
        while (!dma_irq && timeout_guard < 100) begin
            @(posedge pclk);
            timeout_guard = timeout_guard + 1;
        end

        if (!dma_irq) begin
            $display("[%0t] ERROR completion IRQ timeout", $time);
            errors = errors + 1;
        end

        apb_read(12'h00C,ctrl_read);
        if (ctrl_read[31] !== 1'b0 || ctrl_read[3:0] !== 4'h0) begin
            $display("[%0t] ERROR CTRL readback=%h", $time,ctrl_read);
            errors = errors + 1;
        end

        apb_write(12'h010,32'h1);
        @(posedge pclk);
        if (dma_irq) begin
            $display("[%0t] ERROR IRQ clear failed", $time);
            errors = errors + 1;
        end

        if (errors == 0)
            $display("[%0t] PASS tb_axi_dma_ctrl_smoke", $time);
        else
            $display("[%0t] FAIL tb_axi_dma_ctrl_smoke errors=%0d", $time,errors);

        $finish;
    end

endmodule
