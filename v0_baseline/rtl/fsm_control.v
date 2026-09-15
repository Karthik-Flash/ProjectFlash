`timescale 1ns / 1ps
//////////////////////////////////////////////////////////////////////////////////
// Module Name: fsm_control
// Description: Master Control FSM for TinyML Cancer Detection Accelerator
//              Orchestrates the complete inference pipeline
//
// Port Connections:
//   - clk           : System clock (100 MHz)
//   - rst           : Synchronous active-high reset
//   - start         : External trigger to begin inference
//   - conv_done     : Convolution layer completion signal
//   - pool_done     : Max pooling completion signal
//   - fc1_done      : FC1 layer completion signal
//   - fc2_done      : FC2 layer completion signal
//   - state         : Current FSM state (for debugging)
//   - conv_en       : Enable signal for convolution layer
//   - pool_en       : Enable signal for max pooling
//   - fc1_en        : Enable signal for FC1 layer
//   - fc2_en        : Enable signal for FC2 layer
//   - output_valid  : High when final result is ready
//
// FSM States:
//   - IDLE (000)    : Waiting for start signal
//   - CONV (001)    : Convolution + ReLU processing
//   - POOL (010)    : 22 Max pooling
//   - FC1 (011)     : Fully connected layer 1 (784?16)
//   - FC2 (100)     : Fully connected layer 2 (16?2)
//   - OUTPUT (101)  : Assert output_valid, compute argmax
//
// State Transitions:
//   IDLE ? CONV     (on start)
//   CONV ? POOL     (on conv_done)
//   POOL ? FC1      (on pool_done)
//   FC1 ? FC2       (on fc1_done)
//   FC2 ? OUTPUT    (on fc2_done)
//   OUTPUT ? IDLE   (after 1 cycle)
//
// Timing Estimates:
//   - CONV: ~1000 cycles (pixel streaming + MAC)
//   - POOL: ~200 cycles (22 pooling on 4 feature maps)
//   - FC1: ~12,560 cycles (78416 MAC operations)
//   - FC2: ~34 cycles (162 MAC operations)
//   - Total: ~13,800 cycles ? 138 ?s @ 100 MHz
//
//////////////////////////////////////////////////////////////////////////////////

module fsm_control(
    input wire clk,
    input wire rst,
    input wire start,           // Start inference
    input wire conv_done,       // Convolution done
    input wire pool_done,       // Pooling done
    input wire fc1_done,        // FC1 done
    input wire fc2_done,        // FC2 done
    output reg [2:0] state,     // Current state
    output reg conv_en,         // Convolution enable
    output reg pool_en,         // Pooling enable
    output reg fc1_en,          // FC1 enable
    output reg fc2_en,          // FC2 enable
    output reg output_valid     // Final output valid
);

    // State encoding
    localparam IDLE   = 3'b000;
    localparam CONV   = 3'b001;
    localparam POOL   = 3'b010;
    localparam FC1    = 3'b011;
    localparam FC2    = 3'b100;
    localparam OUTPUT = 3'b101;
    
    // FSM state transition logic
    always @(posedge clk) begin
        if (rst) begin
            state <= IDLE;
            conv_en <= 1'b0;
            pool_en <= 1'b0;
            fc1_en <= 1'b0;
            fc2_en <= 1'b0;
            output_valid <= 1'b0;
            
        end else begin
            case (state)
                
                IDLE: begin
                    // Reset all enable signals
                    conv_en <= 1'b0;
                    pool_en <= 1'b0;
                    fc1_en <= 1'b0;
                    fc2_en <= 1'b0;
                    output_valid <= 1'b0;
                    
                    if (start) begin
                        state <= CONV;
                        conv_en <= 1'b1;  // Start convolution
                    end
                end
                
                CONV: begin
                    if (conv_done) begin
                        conv_en <= 1'b0;
                        pool_en <= 1'b1;  // Start pooling
                        state <= POOL;
                    end
                end
                
                POOL: begin
                    if (pool_done) begin
                        pool_en <= 1'b0;
                        fc1_en <= 1'b1;   // Start FC1
                        state <= FC1;
                    end
                end
                
                FC1: begin
                    if (fc1_done) begin
                        fc1_en <= 1'b0;
                        fc2_en <= 1'b1;   // Start FC2
                        state <= FC2;
                    end
                end
                
                FC2: begin
                    if (fc2_done) begin
                        fc2_en <= 1'b0;
                        output_valid <= 1'b1;  // Assert output valid
                        state <= OUTPUT;
                    end
                end
                
                OUTPUT: begin
                    // Hold output_valid for 1 cycle, then return to IDLE
                    output_valid <= 1'b0;
                    state <= IDLE;
                end
                
                default: begin
                    state <= IDLE;
                    conv_en <= 1'b0;
                    pool_en <= 1'b0;
                    fc1_en <= 1'b0;
                    fc2_en <= 1'b0;
                    output_valid <= 1'b0;
                end
                
            endcase
        end
    end

endmodule