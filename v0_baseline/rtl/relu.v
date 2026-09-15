`timescale 1ns / 1ps
//////////////////////////////////////////////////////////////////////////////////
// Module Name: relu
// Description: ReLU (Rectified Linear Unit) Activation Function
//              for TinyML Cancer Detection Accelerator
//
// Port Connections:
//   - data_in  : 20-bit signed input from MAC unit or previous layer
//   - data_out : 20-bit output (0 if input < 0, else input)
//
// Operation:
//   ReLU(x) = max(0, x)
//   - If data_in[19] == 1 (negative): data_out = 0
//   - If data_in[19] == 0 (positive or zero): data_out = data_in
//
// Timing:
//   Purely combinational logic - no clock or registers
//   Zero propagation delay (aside from gate delays)
//
// Notes:
//   - Applied after each convolution MAC operation
//   - Introduces non-linearity needed for neural network learning
//   - Zeroing negative values prevents negative activations in feature maps
//
//////////////////////////////////////////////////////////////////////////////////

module relu(
    input wire signed [19:0] data_in,   // 20-bit signed input
    output wire [19:0] data_out         // 20-bit unsigned output (ReLU result)
);

    // Combinational ReLU logic
    // Check MSB (sign bit): if negative, output 0; else pass through
    assign data_out = (data_in[19] == 1'b1) ? 20'b0 : data_in;

endmodule