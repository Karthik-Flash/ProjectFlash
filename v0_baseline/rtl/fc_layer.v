`timescale 1ns / 1ps
//==============================================================================
// fc_layer.v — Final Bug-Fixed Version (V4)
//
// Fixes vs fc_layer2.v:
//   BUG A — READ_PREFETCH: input_idx = 16'd0  (was 16'd1, dropped pooled[0])
//   Retained: ACC_WIDTH=48, 32-bit output, inline FC2 weight address
//==============================================================================

module fc_layer #(
    parameter INPUT_SIZE    = 784,
    parameter OUTPUT_SIZE   = 16,
    parameter DATA_IN_WIDTH = 20,
    parameter ACC_WIDTH     = 48,
    parameter WEIGHT_MEM    = "fc1_weights.mem",
    parameter BIAS_MEM      = "fc1_bias.mem",
    parameter APPLY_RELU    = 1
)(
    input  wire                        clk,
    input  wire                        rst,
    output reg  [9:0]                  bram_rd_addr,
    input  wire [19:0]                 bram_rd_data,
    input  wire [DATA_IN_WIDTH-1:0]    data_in,
    input  wire                        start,
    output reg  [OUTPUT_SIZE*32-1:0]   data_out,
    output reg                         done
);

    localparam USE_BRAM  = (INPUT_SIZE > 64) ? 1 : 0;
    localparam ELEM_BITS = (USE_BRAM || INPUT_SIZE == 0) ? 32 :
                           (DATA_IN_WIDTH / INPUT_SIZE);

    (* rom_style = "block" *) reg signed [7:0] weights [0:INPUT_SIZE*OUTPUT_SIZE-1];
    reg signed [7:0] biases [0:OUTPUT_SIZE-1];

    initial begin
        $readmemh(WEIGHT_MEM, weights);
        $readmemh(BIAS_MEM,   biases);
    end

    reg signed [31:0] input_unpacked [0:INPUT_SIZE-1];

    generate
        if (USE_BRAM == 0) begin : gen_unpack
            integer iu;
            always @(*) begin
                for (iu = 0; iu < INPUT_SIZE; iu = iu + 1)
                    input_unpacked[iu] = $signed(data_in[iu*ELEM_BITS +: ELEM_BITS]);
            end
        end else begin : gen_no_unpack
            integer iu;
            always @(*) begin
                for (iu = 0; iu < INPUT_SIZE; iu = iu + 1)
                    input_unpacked[iu] = 32'sd0;
            end
        end
    endgenerate

    reg signed [19:0]          input_value;
    reg signed [ACC_WIDTH-1:0] accumulator;
    reg signed [ACC_WIDTH-1:0] neuron_results [0:OUTPUT_SIZE-1];

    reg [15:0] input_idx;
    reg [7:0]  neuron_idx;
    reg [15:0] weight_base;
    reg [15:0] weight_idx;

    localparam IDLE          = 3'd0;
    localparam READ_PREFETCH = 3'd1;
    localparam COMPUTE       = 3'd2;
    localparam BIAS_ADD      = 3'd3;
    localparam NEXT_NEURON   = 3'd4;
    localparam DONE_STATE    = 3'd5;

    reg [2:0] state;
    integer   ii;

    always @(posedge clk) begin
        if (rst) begin
            state        <= IDLE;
            done         <= 1'b0;
            accumulator  <= {ACC_WIDTH{1'b0}};
            input_idx    <= 16'd0;
            neuron_idx   <= 8'd0;
            bram_rd_addr <= 10'd0;
            input_value  <= 20'sd0;
            weight_base  <= 16'd0;
            weight_idx   <= 16'd0;
            data_out     <= {OUTPUT_SIZE*32{1'b0}};
            for (ii = 0; ii < OUTPUT_SIZE; ii = ii + 1)
                neuron_results[ii] <= {ACC_WIDTH{1'b0}};

        end else begin
            case (state)

                IDLE: begin
                    done <= 1'b0;
                    if (start) begin
                        accumulator  <= {ACC_WIDTH{1'b0}};
                        input_idx    <= 16'd0;
                        neuron_idx   <= 8'd0;
                        weight_base  <= 16'd0;
                        weight_idx   <= 16'd0;
                        if (USE_BRAM) begin
                            bram_rd_addr <= 10'd0;
                            state        <= READ_PREFETCH;
                        end else begin
                            state <= COMPUTE;
                        end
                    end
                end

                // FIX A: input_idx = 16'd0 (was 16'd1).
                // Cycle 1 of COMPUTE: latches pooled[0], does NOT accumulate (idx==0).
                // Cycle 2 onward: pooled[k] x w[k] for k=0..783. All terms correct.
                READ_PREFETCH: begin
                    bram_rd_addr <= 10'd1;
                    input_idx    <= 16'd0;   // FIX: was 16'd1
                    weight_base  <= neuron_idx * INPUT_SIZE;
                    weight_idx   <= neuron_idx * INPUT_SIZE;
                    state        <= COMPUTE;
                end

                COMPUTE: begin
                    if (USE_BRAM) begin
                        // INVARIANT: bram_rd_data == mem[input_idx] during this cycle.
                        // Held by issuing address (input_idx + 2) one cycle ahead:
                        // bram_rd_addr is a register AND the BRAM output is a
                        // register, so address->data is two cycles end to end.
                        // The V3 code issued (input_idx + 1) and also re-issued
                        // address 1 during the first COMPUTE cycle, which made the
                        // datapath read mem[1] twice and never read mem[783].
                        accumulator <= accumulator +
                            $signed({{(ACC_WIDTH-20){1'b0}}, bram_rd_data}) *
                            $signed({{(ACC_WIDTH- 8){weights[weight_idx][7]}}, weights[weight_idx]});
                        weight_idx <= weight_idx + 16'd1;

                        if (input_idx < (INPUT_SIZE[15:0] - 16'd2))
                            bram_rd_addr <= input_idx[9:0] + 10'd2;

                        if (input_idx == (INPUT_SIZE[15:0] - 16'd1)) begin
                            state     <= BIAS_ADD;
                            input_idx <= 16'd0;
                        end else begin
                            input_idx <= input_idx + 16'd1;
                        end
                    end else begin
                        accumulator <= accumulator +
                            $signed({{(ACC_WIDTH-32){input_unpacked[input_idx][31]}},
                                      input_unpacked[input_idx]}) *
                            $signed({{(ACC_WIDTH- 8){weights[weight_base + input_idx][7]}},
                                      weights[weight_base + input_idx]});

                        if (input_idx == (INPUT_SIZE[15:0] - 16'd1)) begin
                            state     <= BIAS_ADD;
                            input_idx <= 16'd0;
                        end else begin
                            input_idx <= input_idx + 16'd1;
                        end
                    end
                end

                BIAS_ADD: begin
                    accumulator <= accumulator +
                        $signed({{(ACC_WIDTH-8){biases[neuron_idx][7]}}, biases[neuron_idx]});
                    state <= NEXT_NEURON;
                end

                NEXT_NEURON: begin
                    if (APPLY_RELU && accumulator[ACC_WIDTH-1])
                        neuron_results[neuron_idx] <= {ACC_WIDTH{1'b0}};
                    else
                        neuron_results[neuron_idx] <= accumulator;

                    accumulator <= {ACC_WIDTH{1'b0}};

                    if (neuron_idx == (OUTPUT_SIZE[7:0] - 8'd1)) begin
                        state <= DONE_STATE;
                    end else begin
                        neuron_idx  <= neuron_idx + 8'd1;
                        weight_base <= (neuron_idx + 8'd1) * INPUT_SIZE;
                        weight_idx  <= (neuron_idx + 8'd1) * INPUT_SIZE;
                        if (USE_BRAM) begin
                            bram_rd_addr <= 10'd0;
                            state        <= READ_PREFETCH;
                        end else begin
                            state <= COMPUTE;
                        end
                    end
                end

                DONE_STATE: begin
                    for (ii = 0; ii < OUTPUT_SIZE; ii = ii + 1)
                        data_out[ii*32 +: 32] <= neuron_results[ii][31:0];
                    done  <= 1'b1;
                    // Hold here until the enable drops. The V3 version returned to
                    // IDLE while `start` was still asserted by the FSM, which
                    // immediately re-triggered a full 12,544-cycle pass.
                    if (!start) state <= IDLE;
                end

                default: state <= IDLE;
            endcase
        end
    end

endmodule
