`timescale 1ns/1ps

module dma_reset_sync (
    input  wire clk,
    input  wire async_reset_n,
    output wire sync_reset_n
);

    reg [1:0] sync_ff;

    always @(posedge clk or negedge async_reset_n) begin
        if (!async_reset_n)
            sync_ff <= 2'b00;
        else
            sync_ff <= {sync_ff[0], 1'b1};
    end

    assign sync_reset_n = sync_ff[1];

endmodule
