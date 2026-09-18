// fmap_ram.v -- Project FLASH V1, feature-map BRAM wrapper.
//
// Trivial single-clock RAM, uint8, 131072-deep (2^17). Sized for the
// largest V1.2 feature map: conv1's output at 8*112*112 = 100,352 bytes,
// which does not fit the previous 65,536-byte depth. Kept a power of two so
// it maps cleanly onto BRAM tiles. V1.1's largest map is only 1,568 bytes,
// so this is heavily oversized there but harmless.
// Synchronous read: rd_data reflects rd_addr one cycle later.
// Write-then-read to the same address in the same cycle reads the OLD value
// (rd_data is registered from the pre-write memory contents), which matches
// ordinary block-RAM read-first behaviour and is never relied on by any V1
// consumer of this module (nothing both reads and writes the same fmap_ram
// instance in the same cycle -- top_v1 always finishes writing one buffer
// before switching a downstream reader onto it).
//
// Two instances are ping-ponged (A/B) at the top level: while layer N writes
// its output into one instance, layer N+1 reads its input from the other.

module fmap_ram (
    input  wire        clk,
    input  wire        we,
    input  wire [17:0] wr_addr,
    input  wire [7:0]  wr_data,
    input  wire [17:0] rd_addr,
    output reg  [7:0]  rd_data
);

    reg [7:0] mem [0:131071];

    always @(posedge clk) begin
        if (we) mem[wr_addr] <= wr_data;
        rd_data <= mem[rd_addr]; // LATENCY: rd_addr -> rd_data is 1 cycle (BRAM output reg)
    end

endmodule
