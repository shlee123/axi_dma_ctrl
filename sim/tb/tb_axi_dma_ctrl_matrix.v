`timescale 1ns/1ps

module tb_axi_dma_ctrl_matrix;

    localparam AXI_DATA_WIDTH = 32;
    localparam AXI_ID_WIDTH   = 6;
    localparam BYTES_PER_BEAT = 4;

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
    integer case_id;

    integer src_burst_beats_left;
    integer src_word_seq;
    integer src_base_seq;
    reg [31:0] src_burst_addr;
    reg src_active;

    integer dst_burst_beats_left;
    integer dst_word_seq;
    integer dst_base_seq;
    integer dst_remaining_bytes;
    reg [31:0] dst_burst_addr;
    reg dst_active;
    reg b_pending;

    reg expect_source_single;
    reg expect_target_single;

    integer source_ar_count;
    integer target_aw_count;
    integer target_w_count;

    axi_dma_ctrl #(
        .APB_ADDR_WIDTH(12),
        .AXI_ADDR_WIDTH(32),
        .AXI_DATA_WIDTH(32),
        .AXI_ID_WIDTH(AXI_ID_WIDTH),
        .MAX_BURST_LENGTH(4),
        .DATA_FIFO_DEPTH(8),
        .AXI_TIMEOUT_CYCLES(64),
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

    function [31:0] make_data;
        input integer seq;
        begin
            make_data = 32'hA500_0000 + seq;
        end
    endfunction

    function [3:0] expected_strb;
        input integer rem_bytes;
        begin
            if (rem_bytes >= 4)
                expected_strb = 4'b1111;
            else if (rem_bytes == 3)
                expected_strb = 4'b0111;
            else if (rem_bytes == 2)
                expected_strb = 4'b0011;
            else if (rem_bytes == 1)
                expected_strb = 4'b0001;
            else
                expected_strb = 4'b0000;
        end
    endfunction

    // Source AXI slave model.
    always @(posedge axi_clk or negedge reset_n) begin
        if (!reset_n) begin
            m_src_arready      <= 1'b0;
            m_src_rid          <= 0;
            m_src_rdata        <= 0;
            m_src_rresp        <= 2'b00;
            m_src_rlast        <= 1'b0;
            m_src_rvalid       <= 1'b0;
            src_burst_beats_left <= 0;
            src_word_seq       <= 0;
            src_active         <= 1'b0;
            source_ar_count    <= 0;
        end else begin
            m_src_arready <= !src_active;

            if (m_src_arvalid && m_src_arready) begin
                source_ar_count <= source_ar_count + 1;
                src_active <= 1'b1;
                src_burst_addr <= m_src_araddr;
                src_burst_beats_left <= m_src_arlen + 1;

                if (m_src_arsize !== 3'b010 || m_src_arburst !== 2'b01) begin
                    $display("[%0t] ERROR case%0d source AxSIZE/BURST", $time,case_id);
                    errors = errors + 1;
                end
                if (expect_source_single && (m_src_arlen != 0)) begin
                    $display("[%0t] ERROR case%0d SOURCE_SINGLE ARLEN=%0d", $time,case_id,m_src_arlen);
                    errors = errors + 1;
                end
                if ((m_src_araddr[11:0] + ((m_src_arlen + 1) * 4)) > 4096) begin
                    $display("[%0t] ERROR case%0d source burst crosses 4KB addr=%h len=%0d",
                             $time,case_id,m_src_araddr,m_src_arlen);
                    errors = errors + 1;
                end
            end

            if (src_active && !m_src_rvalid) begin
                m_src_rvalid <= 1'b1;
                m_src_rid    <= 0;
                m_src_rresp  <= 2'b00;
                m_src_rdata  <= make_data(src_word_seq);
                m_src_rlast  <= (src_burst_beats_left == 1);
            end

            if (m_src_rvalid && m_src_rready) begin
                m_src_rvalid <= 1'b0;
                src_word_seq <= src_word_seq + 1;
                if (src_burst_beats_left == 1) begin
                    src_burst_beats_left <= 0;
                    src_active <= 1'b0;
                    m_src_rlast <= 1'b0;
                end else begin
                    src_burst_beats_left <= src_burst_beats_left - 1;
                end
            end
        end
    end

    // Target AXI slave model.
    always @(posedge axi_clk or negedge reset_n) begin
        if (!reset_n) begin
            m_dst_awready <= 1'b0;
            m_dst_wready  <= 1'b0;
            m_dst_bid     <= 0;
            m_dst_bresp   <= 2'b00;
            m_dst_bvalid  <= 1'b0;
            dst_burst_beats_left <= 0;
            dst_word_seq <= 0;
            dst_remaining_bytes <= 0;
            dst_active <= 1'b0;
            b_pending <= 1'b0;
            target_aw_count <= 0;
            target_w_count <= 0;
        end else begin
            m_dst_awready <= !dst_active && !b_pending && !m_dst_bvalid;
            m_dst_wready  <= dst_active;

            if (m_dst_awvalid && m_dst_awready) begin
                target_aw_count <= target_aw_count + 1;
                dst_active <= 1'b1;
                dst_burst_addr <= m_dst_awaddr;
                dst_burst_beats_left <= m_dst_awlen + 1;

                if (m_dst_awsize !== 3'b010 || m_dst_awburst !== 2'b01) begin
                    $display("[%0t] ERROR case%0d target AxSIZE/BURST", $time,case_id);
                    errors = errors + 1;
                end
                if (expect_target_single && (m_dst_awlen != 0)) begin
                    $display("[%0t] ERROR case%0d TARGET_SINGLE AWLEN=%0d", $time,case_id,m_dst_awlen);
                    errors = errors + 1;
                end
                if ((m_dst_awaddr[11:0] + ((m_dst_awlen + 1) * 4)) > 4096) begin
                    $display("[%0t] ERROR case%0d target burst crosses 4KB addr=%h len=%0d",
                             $time,case_id,m_dst_awaddr,m_dst_awlen);
                    errors = errors + 1;
                end
            end

            if (m_dst_wvalid && m_dst_wready) begin
                target_w_count <= target_w_count + 1;

                if (m_dst_wdata !== make_data(dst_word_seq)) begin
                    $display("[%0t] ERROR case%0d WDATA=%h expected=%h",
                             $time,case_id,m_dst_wdata,make_data(dst_word_seq));
                    errors = errors + 1;
                end

                if (m_dst_wstrb !== expected_strb(dst_remaining_bytes)) begin
                    $display("[%0t] ERROR case%0d WSTRB=%b expected=%b rem=%0d",
                             $time,case_id,m_dst_wstrb,expected_strb(dst_remaining_bytes),
                             dst_remaining_bytes);
                    errors = errors + 1;
                end

                if (m_dst_wlast !== (dst_burst_beats_left == 1)) begin
                    $display("[%0t] ERROR case%0d WLAST=%b expected=%b",
                             $time,case_id,m_dst_wlast,(dst_burst_beats_left == 1));
                    errors = errors + 1;
                end

                dst_word_seq <= dst_word_seq + 1;
                if (dst_remaining_bytes > 4)
                    dst_remaining_bytes <= dst_remaining_bytes - 4;
                else
                    dst_remaining_bytes <= 0;

                if (dst_burst_beats_left == 1) begin
                    dst_burst_beats_left <= 0;
                    dst_active <= 1'b0;
                    b_pending <= 1'b1;
                end else begin
                    dst_burst_beats_left <= dst_burst_beats_left - 1;
                end
            end

            if (b_pending && !m_dst_bvalid) begin
                m_dst_bvalid <= 1'b1;
                m_dst_bid    <= 0;
                m_dst_bresp  <= 2'b00;
                b_pending    <= 1'b0;
            end

            if (m_dst_bvalid && m_dst_bready)
                m_dst_bvalid <= 1'b0;
        end
    end

    task apb_write;
        input [11:0] addr;
        input [31:0] data;
        begin
            @(negedge pclk);
            psel = 1'b1;
            penable = 1'b1;
            pwrite = 1'b1;
            paddr = addr;
            pwdata = data;
            @(posedge pclk);
            @(negedge pclk);
            psel = 1'b0;
            penable = 1'b0;
            pwrite = 1'b0;
            paddr = 0;
            pwdata = 0;
        end
    endtask

    task apb_read;
        input [11:0] addr;
        output [31:0] data;
        begin
            @(negedge pclk);
            psel = 1'b1;
            penable = 1'b1;
            pwrite = 1'b0;
            paddr = addr;
            #1 data = prdata;
            @(posedge pclk);
            @(negedge pclk);
            psel = 1'b0;
            penable = 1'b0;
            paddr = 0;
        end
    endtask

    task run_case;
        input integer id;
        input [31:0] src_addr;
        input [31:0] dst_addr;
        input integer length_bytes;
        input src_single;
        input dst_single;
        integer guard;
        integer expected_words;
        reg [31:0] ctrl;
        reg [31:0] len_reg;
        begin
            case_id = id;
            expect_source_single = src_single;
            expect_target_single = dst_single;

            src_word_seq = 0;
            dst_word_seq = 0;
            source_ar_count = 0;
            target_aw_count = 0;
            target_w_count = 0;
            dst_remaining_bytes = length_bytes;
            expected_words = (length_bytes + 3) / 4;

            len_reg = (length_bytes - 1);
            if (src_single) len_reg[16] = 1'b1;
            if (dst_single) len_reg[17] = 1'b1;

            $display("[%0t] CASE%0d src=%h dst=%h len=%0d Ssingle=%0d Tsingle=%0d",
                     $time,id,src_addr,dst_addr,length_bytes,src_single,dst_single);

            apb_write(12'h000,src_addr);
            apb_write(12'h004,dst_addr);
            apb_write(12'h008,len_reg);
            apb_write(12'h00C,32'h8000_0000);

            guard = 0;
            while (!dma_irq && guard < 3000) begin
                @(posedge pclk);
                guard = guard + 1;
            end

            if (!dma_irq) begin
                $display("[%0t] ERROR case%0d completion timeout", $time,id);
                errors = errors + 1;
            end

            apb_read(12'h00C,ctrl);
            if (ctrl[31] !== 1'b0 || ctrl[3:0] !== 4'h0) begin
                $display("[%0t] ERROR case%0d CTRL=%h", $time,id,ctrl);
                errors = errors + 1;
            end

            if (target_w_count != expected_words) begin
                $display("[%0t] ERROR case%0d target words=%0d expected=%0d",
                         $time,id,target_w_count,expected_words);
                errors = errors + 1;
            end

            if (src_single && source_ar_count != expected_words) begin
                $display("[%0t] ERROR case%0d source AR count=%0d expected=%0d",
                         $time,id,source_ar_count,expected_words);
                errors = errors + 1;
            end

            if (dst_single && target_aw_count != expected_words) begin
                $display("[%0t] ERROR case%0d target AW count=%0d expected=%0d",
                         $time,id,target_aw_count,expected_words);
                errors = errors + 1;
            end

            apb_write(12'h010,32'h1);
            repeat (3) @(posedge pclk);
            if (dma_irq) begin
                $display("[%0t] ERROR case%0d IRQ failed to clear", $time,id);
                errors = errors + 1;
            end

            repeat (4) @(posedge axi_clk);
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
        case_id = 0;
        expect_source_single = 0;
        expect_target_single = 0;

        repeat (5) @(posedge axi_clk);
        @(negedge axi_clk);
        reset_n = 1;

        repeat (5) @(posedge axi_clk);
        repeat (5) @(posedge pclk);

        run_case(1,32'h0000_1000,32'h0000_2000,1, 0,0);
        run_case(2,32'h0000_1100,32'h0000_2100,10,0,0);
        run_case(3,32'h0000_1200,32'h0000_2200,20,1,0);
        run_case(4,32'h0000_1300,32'h0000_2300,20,0,1);
        run_case(5,32'h0000_1400,32'h0000_2400,20,1,1);
        run_case(6,32'h0000_0FFC,32'h0000_3000,8,0,0);
        run_case(7,32'h0000_4000,32'h0000_3FFC,8,0,0);
        run_case(8,32'hFFFF_FFFC,32'hFFFF_EFFC,8,0,0);

        if (errors == 0)
            $display("[%0t] PASS tb_axi_dma_ctrl_matrix", $time);
        else
            $display("[%0t] FAIL tb_axi_dma_ctrl_matrix errors=%0d", $time,errors);

        $finish;
    end

endmodule
