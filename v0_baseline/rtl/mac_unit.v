`timescale 1ns / 1ps
//////////////////////////////////////////////////////////////////////////////////
// Module Name: mac_unit
// Description: Multiply-Accumulate Unit for TinyML Accelerator
//              Performs signed 8-bit multiplication and accumulation
//
// Port Connections:
//   - clk       : System clock (100 MHz)
//   - rst       : Synchronous active-high reset
//   - pixel_in  : 8-bit unsigned pixel value (cast to signed for computation)
//   - weight_in : 8-bit signed weight from trained filter
//   - valid_in  : High when inputs are valid
//   - acc_out   : 20-bit signed accumulator output
//   - valid_out : Valid signal for accumulator output (delayed 1 cycle)
//
// Operation:
//   - On reset: accumulator cleared to 0
//   - On valid_in: acc_out <= acc_out + (pixel_in * weight_in)
//   - valid_out follows valid_in with 1 clock cycle delay
//
// Bit Width Selection:
//   - 8-bit  8-bit multiplication ? 16-bit product
//   - Accumulator: 20-bit signed to handle multiple accumulations
//   - Typical use: 9 MACs per convolution window (33 kernel)
//
//////////////////////////////////////////////////////////////////////////////////

module mac_unit(
    input wire clk,
    input wire rst,
    input wire signed [7:0] pixel_in,   // Unsigned pixel, treated as signed
    input wire signed [7:0] weight_in,  // Signed INT8 weight
    input wire valid_in,                // Input valid signal
    output reg signed [19:0] acc_out,   // 20-bit accumulator
    output reg valid_out                // Output valid (delayed 1 cycle)
);

    // Internal signals
    wire signed [15:0] product;  // 8-bit  8-bit = 16-bit product
    
    // Combinatorial multiplication
    assign product = pixel_in * weight_in;
    
    // Accumulator logic
    always @(posedge clk) begin
        if (rst) begin
            acc_out <= 20'sd0;
        end else if (valid_in) begin
            // Accumulate: sign-extend 16-bit product to 20-bit and add
            acc_out <= acc_out + {{4{product[15]}}, product};
        end
    end
    
    // Valid signal pipeline (1 cycle delay)
    always @(posedge clk) begin
        if (rst) begin
            valid_out <= 1'b0;
        end else begin
            valid_out <= valid_in;
        end
    end

endmodule