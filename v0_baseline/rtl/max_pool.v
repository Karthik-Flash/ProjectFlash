`timescale 1ns / 1ps
//////////////////////////////////////////////////////////////////////////////////
// Module Name: max_pool
// Description: 22 Max Pooling Unit for TinyML Cancer Detection Accelerator
//
// Port Connections:
//   - in0, in1, in2, in3 : 20-bit signed inputs representing 22 spatial window
//                          Layout: in0=top-left, in1=top-right,
//                                  in2=bottom-left, in3=bottom-right
//   - max_out            : 20-bit output containing maximum of 4 inputs
//
// Operation:
//   max_out = MAX(in0, in1, in2, in3)
//   - Compares all 4 inputs using a comparator tree
//   - Returns the largest value (signed comparison)
//   - Used to downsample feature maps from 2828 to 1414
//
// Timing:
//   Purely combinational logic - no clock or registers
//   Two-level comparator tree for optimal delay
//
// Architecture:
//   Level 1: max01 = MAX(in0, in1)
//            max23 = MAX(in2, in3)
//   Level 2: max_out = MAX(max01, max23)
//
// After Convolution:
//   - Input: 4 feature maps  2828 (post-ReLU, non-negative)
//   - Max pooling reduces to: 4 feature maps  1414
//   - Stride = 2, so we sample every other 22 block
//
//////////////////////////////////////////////////////////////////////////////////

module max_pool(
    input wire signed [19:0] in0,    // Top-left pixel
    input wire signed [19:0] in1,    // Top-right pixel
    input wire signed [19:0] in2,    // Bottom-left pixel
    input wire signed [19:0] in3,    // Bottom-right pixel
    output wire signed [19:0] max_out // Maximum value
);

    // Internal wires for two-level comparator tree
    wire signed [19:0] max01;  // Max of in0 and in1
    wire signed [19:0] max23;  // Max of in2 and in3
    
    // Level 1: Compare pairs
    assign max01 = (in0 > in1) ? in0 : in1;
    assign max23 = (in2 > in3) ? in2 : in3;
    
    // Level 2: Compare the two maximums
    assign max_out = (max01 > max23) ? max01 : max23;

endmodule