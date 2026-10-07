`timescale 1ns/1ps

module dma_apb_regs #(
    parameter integer APB_ADDR_WIDTH = 12
)(
    input  wire                      pclk,
    input  wire                      preset_n,

    input  wire                      psel,
    input  wire                      penable,
    input  wire                      pwrite,
    input  wire [APB_ADDR_WIDTH-1:0] paddr,
    input  wire [31:0]               pwdata,
    output reg  [31:0]               prdata,
    output wire                      pready,
    output reg                       pslverr,

    // CDC-visible configuration and START command
    output reg  [31:0]               cfg_src_addr,
    output reg  [31:0]               cfg_dst_addr,
    output reg  [11:0]               cfg_length_minus_1,
    output reg                       cfg_source_single,
    output reg                       cfg_target_single,
    output reg                       start_pulse,

    // CDC/APB-visible status
    input  wire                      start_pending,
    input  wire                      busy_pclk,
    input  wire [3:0]                status_code_pclk,
    input  wire                      event_pulse_pclk,

    output wire                      dma_irq
);

    localparam [APB_ADDR_WIDTH-1:0] ADDR_SRC    = {{(APB_ADDR_WIDTH-3){1'b0}},3'h0};
    localparam [APB_ADDR_WIDTH-1:0] ADDR_DST    = {{(APB_ADDR_WIDTH-3){1'b0}},3'h4};
    localparam [APB_ADDR_WIDTH-1:0] ADDR_LENGTH = {{(APB_ADDR_WIDTH-4){1'b0}},4'h8};
    localparam [APB_ADDR_WIDTH-1:0] ADDR_CTRL   = {{(APB_ADDR_WIDTH-4){1'b0}},4'hC};
    localparam [APB_ADDR_WIDTH-1:0] ADDR_INTR   = {{(APB_ADDR_WIDTH-5){1'b0}},5'h10};

    reg irq_pending;
    reg [3:0] status_image;

    wire apb_access;
    wire aligned;
    wire known_addr;
    wire valid_access;
    wire start_write;
    wire irq_clear_write;

    assign pready = 1'b1;
    assign dma_irq = irq_pending;

    assign apb_access = psel && penable;
    assign aligned = (paddr[1:0] == 2'b00);
    assign known_addr = (paddr == ADDR_SRC) ||
                        (paddr == ADDR_DST) ||
                        (paddr == ADDR_LENGTH) ||
                        (paddr == ADDR_CTRL) ||
                        (paddr == ADDR_INTR);

    assign valid_access = apb_access && aligned && known_addr;

    // Ignore START when software-visible BUSY is already high, or while the
    // previous START snapshot is still pending CDC acceptance.
    assign start_write = valid_access && pwrite &&
                         (paddr == ADDR_CTRL) &&
                         pwdata[31] &&
                         !busy_pclk &&
                         !start_pending;

    assign irq_clear_write = valid_access && pwrite &&
                             (paddr == ADDR_INTR) &&
                             pwdata[0];

    always @(*) begin
        prdata  = 32'h0000_0000;
        pslverr = 1'b0;

        if (apb_access) begin
            if (!aligned || !known_addr) begin
                pslverr = 1'b1;
                prdata  = 32'h0000_0000;
            end else if (!pwrite) begin
                case (paddr)
                    ADDR_SRC:
                        prdata = cfg_src_addr;
                    ADDR_DST:
                        prdata = cfg_dst_addr;
                    ADDR_LENGTH:
                        prdata = {14'd0,
                                  cfg_target_single,
                                  cfg_source_single,
                                  4'd0,
                                  cfg_length_minus_1};
                    ADDR_CTRL:
                        prdata = {busy_pclk,27'd0,status_image};
                    ADDR_INTR:
                        prdata = {31'd0,irq_pending};
                    default:
                        prdata = 32'h0000_0000;
                endcase
            end
        end
    end

    always @(posedge pclk or negedge preset_n) begin
        if (!preset_n) begin
            cfg_src_addr       <= 32'h0000_0000;
            cfg_dst_addr       <= 32'h0000_0000;
            cfg_length_minus_1 <= 12'h000;
            cfg_source_single  <= 1'b0;
            cfg_target_single  <= 1'b0;
            start_pulse        <= 1'b0;
            irq_pending        <= 1'b0;
            status_image       <= 4'h0;
        end else begin
            start_pulse <= 1'b0;

            if (valid_access && pwrite) begin
                case (paddr)
                    ADDR_SRC:
                        cfg_src_addr <= pwdata;
                    ADDR_DST:
                        cfg_dst_addr <= pwdata;
                    ADDR_LENGTH: begin
                        cfg_length_minus_1 <= pwdata[11:0];
                        cfg_source_single  <= pwdata[16];
                        cfg_target_single  <= pwdata[17];
                    end
                    default: begin
                    end
                endcase
            end

            if (start_write) begin
                start_pulse  <= 1'b1;
                irq_pending  <= 1'b0;
                status_image <= 4'h0;
            end

            // Set-dominant when clear and event coincide.
            if (irq_clear_write)
                irq_pending <= 1'b0;
            if (event_pulse_pclk) begin
                irq_pending  <= 1'b1;
                status_image <= status_code_pclk;
            end
        end
    end

endmodule
