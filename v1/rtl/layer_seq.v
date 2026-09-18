// layer_seq.v -- Project FLASH V1, layer sequencer.
//
// Walks the 7-entry layer table, handing each descriptor to whichever engine
// implements its op (CONV3X3 -> conv_engine, GAP -> gap_unit, FC -> fc_unit)
// and flipping the A/B feature-map ping-pong between layers.
//
// Buffer assignment (layer L, 0-indexed):
//   read buffer  = A when L is even, B when L is odd
//   write buffer = the other one
// so layer 0 (conv1) reads the input image out of A and writes conv1 into B,
// layer 1 reads B writes A, ... layer 4 (conv5) reads A writes B, and layer 5
// (GAP) reads conv5 out of B. GAP and FC write no feature map at all -- GAP
// hands fc_unit a 64-entry register bus, FC produces the two logits.
//
// layer_seq also owns the GAP input stream: gap_unit wants one uint8 per
// cycle tagged with its channel, so this module generates the read addresses
// (c*in_h*in_w + y*in_w + x) and the matching channel tag. top_v1 delays the
// valid/tag by one cycle to line them up with fmap_ram's 1-cycle read data.
`include "layer_table.vh"

module layer_seq #(
    parameter LAYER_TABLE_FILE = "../mem/v1_1/flash_v1_1/layer_table.mem"
) (
    input  wire                  clk,
    input  wire                  rst,
    input  wire                  start,

    output reg  [`LT_WORD_W-1:0] layer_word,
    output reg  [2:0]            layer_idx,
    output reg                   buf_sel,      // 0: read A / write B, 1: read B / write A

    output reg                   conv_start,
    output reg                   gap_start,
    output reg                   fc_start,
    input  wire                  conv_done,
    input  wire                  gap_done,
    input  wire                  fc_done,

    // GAP input stream (address issued here; top_v1 aligns valid/tag to data)
    output reg  [17:0]           gap_stream_addr,
    output reg                   gap_stream_valid,
    output reg  [11:0]           gap_stream_c,

    output reg                   done
);

    reg [`LT_WORD_W-1:0] layer_table_rom [0:6];
    initial $readmemh(LAYER_TABLE_FILE, layer_table_rom);

    localparam S_IDLE       = 3'd0,
               S_LOAD_LAYER = 3'd1,
               S_RUN_LAYER  = 3'd2,
               S_WAIT_DONE  = 3'd3,
               S_NEXT_LAYER = 3'd4,
               S_DONE       = 3'd5;
    reg [2:0] state;

    wire [3:0] op = layer_word[`LT_OP_MSB : `LT_OP_LSB];

    // GAP stream counters
    reg [11:0] g_c, g_y, g_x;
    reg [11:0] g_in_c, g_in_h, g_in_w;
    reg        gap_streaming;

    // start-pulse guard: every engine holds `done` high from its PREVIOUS run
    // until its next start is accepted, so WAIT_DONE must not sample done
    // until the start pulse has actually cleared it.
    reg [1:0] launch_wait;

    always @(posedge clk) begin
        if (rst) begin
            state <= S_IDLE;
            done  <= 1'b0;
            layer_idx <= 3'd0;
            buf_sel   <= 1'b0;
            conv_start <= 1'b0; gap_start <= 1'b0; fc_start <= 1'b0;
            gap_streaming <= 1'b0; gap_stream_valid <= 1'b0;
            g_c <= 12'd0; g_y <= 12'd0; g_x <= 12'd0;
            launch_wait <= 2'd0;
        end else begin
            conv_start <= 1'b0;
            gap_start  <= 1'b0;
            fc_start   <= 1'b0;
            gap_stream_valid <= 1'b0;

            case (state)
                S_IDLE: begin
                    if (start) begin
                        layer_idx <= 3'd0;
                        buf_sel   <= 1'b0;
                        done      <= 1'b0;
                        state     <= S_LOAD_LAYER;
                    end
                end

                S_LOAD_LAYER: begin
                    layer_word <= layer_table_rom[layer_idx];
                    state      <= S_RUN_LAYER;
                end

                S_RUN_LAYER: begin
                    case (op)
                        `LT_OP_CONV3X3: conv_start <= 1'b1;
                        `LT_OP_GAP: begin
                            gap_start     <= 1'b1;
                            g_in_c        <= layer_word[`LT_IN_C_MSB : `LT_IN_C_LSB];
                            g_in_h        <= layer_word[`LT_IN_H_MSB : `LT_IN_H_LSB];
                            g_in_w        <= layer_word[`LT_IN_W_MSB : `LT_IN_W_LSB];
                            g_c <= 12'd0; g_y <= 12'd0; g_x <= 12'd0;
                            gap_streaming <= 1'b1;
                        end
                        `LT_OP_FC: fc_start <= 1'b1;
                        default: ;
                    endcase
                    launch_wait <= 2'd0;
                    state       <= S_WAIT_DONE;
                end

                S_WAIT_DONE: begin
                    // stream GAP input while we wait (one address per cycle)
                    if (gap_streaming) begin
                        gap_stream_addr  <= (g_c * g_in_h * g_in_w) + (g_y * g_in_w) + g_x;
                        gap_stream_c     <= g_c;
                        gap_stream_valid <= 1'b1;
                        if (g_x == g_in_w - 12'd1) begin
                            g_x <= 12'd0;
                            if (g_y == g_in_h - 12'd1) begin
                                g_y <= 12'd0;
                                if (g_c == g_in_c - 12'd1) begin
                                    gap_streaming <= 1'b0; // last sample issued
                                end else begin
                                    g_c <= g_c + 12'd1;
                                end
                            end else begin
                                g_y <= g_y + 12'd1;
                            end
                        end else begin
                            g_x <= g_x + 12'd1;
                        end
                    end

                    if (launch_wait != 2'd3) begin
                        launch_wait <= launch_wait + 2'd1;
                    end else begin
                        case (op)
                            `LT_OP_CONV3X3: if (conv_done) state <= S_NEXT_LAYER;
                            `LT_OP_GAP:     if (gap_done)  state <= S_NEXT_LAYER;
                            `LT_OP_FC:      if (fc_done)   state <= S_NEXT_LAYER;
                            default:                       state <= S_NEXT_LAYER;
                        endcase
                    end
                end

                S_NEXT_LAYER: begin
                    if (layer_idx == 3'd6) begin
                        state <= S_DONE;
                    end else begin
                        layer_idx <= layer_idx + 3'd1;
                        // only the conv layers consume/produce feature maps,
                        // so only they flip the ping-pong.
                        if (op == `LT_OP_CONV3X3) buf_sel <= ~buf_sel;
                        state <= S_LOAD_LAYER;
                    end
                end

                S_DONE: begin
                    done <= 1'b1;
                    // A single start pulse must relaunch from here, exactly as
                    // it does from S_IDLE -- bouncing through S_IDLE first
                    // would swallow the pulse and leave the previous run's
                    // result standing.
                    if (start) begin
                        layer_idx <= 3'd0;
                        buf_sel   <= 1'b0;
                        done      <= 1'b0;
                        state     <= S_LOAD_LAYER;
                    end
                end

                default: state <= S_IDLE;
            endcase
        end
    end

endmodule
