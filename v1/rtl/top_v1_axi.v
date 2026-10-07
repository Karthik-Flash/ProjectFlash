// top_v1_axi.v -- Project FLASH V1.2, AXI wrapper around top_v1 for the
// Zynq PS (PYNQ-Z2). Verilog-2001: usable as a Vivado block-design module
// reference and compiles on iverilog 0.9.7 -g2005.
//
// Interfaces
//   s_axis : AXI4-Stream slave, 32-bit, 4 pixels per beat, byte 0 = first
//            pixel. N_PIXELS/4 beats per image (12544 for 224x224), tlast on
//            the final beat.
//   s_axi  : AXI4-Lite slave, 6-bit address, OKAY responses only, aw and w
//            accepted in either order, unmapped reads return 0.
//   irq_done : level-high while STATUS.done is set.
//
// Register map (32-bit)
//   0x00 CTRL      W   bit0 start (self-clearing), bit1 soft_reset (self-clearing,
//                      holds the core and this FSM in reset for 16 cycles). Reads 0.
//   0x04 STATUS    R   bit0 busy, bit1 done, bit2 ready_for_pixels, bit3 err.
//                      done and err clear on the next accepted start, not on read.
//   0x08 THRESHOLD RW  signed 32, reset DEFAULT_THRESHOLD. Sent to top_v1 at the
//                      start of every run (top_v1's own register resets to 0).
//   0x0C LOGIT0    R   signed 32, latched when result_valid rises
//   0x10 LOGIT1    R
//   0x14 MARGIN    R
//   0x18 DECISION  R   bit0 positive
//   0x1C VERSION   R   32'hF1A5_0102
//   0x20 CYCLES    R   core clock cycles from the core start pulse to
//                      result_valid (compute latency only, excludes streaming)
//
// Software sequence (PYNQ): write THRESHOLD, write CTRL=1, start the DMA
// transfer of the image, poll STATUS.done (or wait for irq_done), check
// STATUS.err, read the results. The DMA may also be started before CTRL.start:
// tready stays low until the run is armed.
//
// ---------------------------------------------------------------------------
// DRIVE SEQUENCE -- mirrored from v1/sim/tb_v1.v, the sequence that produced
// the 16/16 + 12/12 xsim PASS. Quoted lines:
//
//   reset, then threshold write (tb_v1.v lines 191-197):
//       repeat (5) @(posedge clk);
//       rst = 1'b0;
//       @(posedge clk);
//       threshold_wr    <= DEFAULT_THRESHOLD;
//       threshold_wr_en <= 1'b1;
//       @(posedge clk);
//       threshold_wr_en <= 1'b0;
//
//   pixels FIRST, one per cycle, then ONE start pulse (run_image, lines 152-164):
//       @(posedge clk);
//       for (p = 0; p < 50176; p = p + 1) begin
//           @(posedge clk);
//           pixel_valid <= 1'b1;
//           pixel_in    <= img[p];
//       end
//       @(posedge clk);
//       pixel_valid <= 1'b0;
//
//       @(posedge clk);
//       start <= 1'b1;
//       @(posedge clk);
//       start <= 1'b0;
//
//   result wait (lines 170-172):
//       wait (!result_valid);
//       wait (result_valid);
//       @(posedge clk);
//
// How this wrapper maps it:
//   - Reset: core rst = ~aresetn (proc_sys_reset holds it far longer than 5
//     cycles) or the 16-cycle soft reset.
//   - Threshold: one threshold_wr_en pulse carrying THRESHOLD, issued when a
//     run is armed, before any pixel. tb_v1 writes it once after reset; doing
//     it per run gives the same value at the decision and lets software change
//     THRESHOLD between images.
//   - Pixels: written into top_v1 BEFORE start, exactly as tb_v1 does. This
//     ordering is required: top_v1's `start` zeroes its pixel address counter
//     and layer_seq starts reading buffer A on the same pulse, so pixels must
//     already be in place. tb_v1 drives pixels back to back; here pixel_valid
//     may have gaps when the DMA stalls. top_v1's loader only advances on
//     pixel_valid, so gaps do not change what lands in buffer A.
//   - Start: one idle cycle after the last pixel, then a single one-cycle
//     start pulse. tb_v1 uses ONE pulse: the double-pulse need seen during
//     bring-up was fixed in layer_seq (S_DONE relaunches on a single pulse,
//     commit f964249), and tb_v1 does not double-pulse.
//   - Result: wait for result_valid low, then high, then latch logit0,
//     logit1, margin and positive.
//
// Error handling: tlast on a beat before the last -> STATUS.err, the run is
// aborted (no core start), the core gets a soft reset so its pixel address
// returns to 0, and done is raised so software does not hang. Last beat
// without tlast -> STATUS.err, the run still completes. Beats beyond
// N_PIXELS/4 are not accepted (tready low).
// ---------------------------------------------------------------------------

module top_v1_axi #(
    parameter WEIGHTS_FILE      = "C:/KarDRIVE/Projects/ProjectFlash/v1/mem/v1_2/flash_v1_2/weights.mem",
    parameter BIAS_FILE         = "C:/KarDRIVE/Projects/ProjectFlash/v1/mem/v1_2/flash_v1_2/bias.mem",
    parameter LAYER_TABLE_FILE  = "C:/KarDRIVE/Projects/ProjectFlash/v1/mem/v1_2/flash_v1_2/layer_table.mem",
    parameter N_PIXELS          = 50176,
    parameter DEFAULT_THRESHOLD = -646
) (
    (* X_INTERFACE_INFO = "xilinx.com:signal:clock:1.0 aclk CLK" *)
    (* X_INTERFACE_PARAMETER = "ASSOCIATED_BUSIF s_axi:s_axis, ASSOCIATED_RESET aresetn" *)
    input  wire        aclk,
    (* X_INTERFACE_INFO = "xilinx.com:signal:reset:1.0 aresetn RST" *)
    (* X_INTERFACE_PARAMETER = "POLARITY ACTIVE_LOW" *)
    input  wire        aresetn,

    // AXI4-Stream slave
    input  wire [31:0] s_axis_tdata,
    input  wire        s_axis_tvalid,
    output wire        s_axis_tready,
    input  wire        s_axis_tlast,

    // AXI4-Lite slave
    input  wire [5:0]  s_axi_awaddr,
    input  wire        s_axi_awvalid,
    output wire        s_axi_awready,
    input  wire [31:0] s_axi_wdata,
    input  wire [3:0]  s_axi_wstrb,
    input  wire        s_axi_wvalid,
    output wire        s_axi_wready,
    output wire [1:0]  s_axi_bresp,
    output reg         s_axi_bvalid,
    input  wire        s_axi_bready,
    input  wire [5:0]  s_axi_araddr,
    input  wire        s_axi_arvalid,
    output wire        s_axi_arready,
    output reg  [31:0] s_axi_rdata,
    output wire [1:0]  s_axi_rresp,
    output reg         s_axi_rvalid,
    input  wire        s_axi_rready,

    (* X_INTERFACE_INFO = "xilinx.com:signal:interrupt:1.0 irq_done INTERRUPT" *)
    (* X_INTERFACE_PARAMETER = "SENSITIVITY LEVEL_HIGH" *)
    output wire        irq_done
);

    localparam [31:0] VERSION = 32'hF1A5_0102;
    localparam        N_BEATS = N_PIXELS / 4;

    // ------------------------------------------------------------------
    // Control FSM states
    // ------------------------------------------------------------------
    localparam [2:0] S_IDLE      = 3'd0,  // also the "done" resting state
                     S_THR       = 3'd1,  // threshold_wr_en pulse
                     S_STREAM    = 3'd2,  // accept beats, feed pixels
                     S_GAP       = 3'd3,  // one idle cycle after the last pixel
                     S_START     = 3'd4,  // core start pulse is on the wire
                     S_WAIT_LOW  = 3'd5,  // wait (!result_valid)
                     S_WAIT_HIGH = 3'd6,  // wait (result_valid)
                     S_ABORT     = 3'd7;  // early tlast: core reset, then done

    reg  [2:0]  state;
    reg         done, err;
    reg  [4:0]  srst_cnt;                 // soft reset hold counter
    wire        srst_active = (srst_cnt != 5'd0);
    wire        busy = (state != S_IDLE);

    // ------------------------------------------------------------------
    // AXI4-Lite slave
    // ------------------------------------------------------------------
    reg         aw_full, w_full;
    reg  [5:0]  aw_addr;
    reg  [31:0] w_data;
    reg  [3:0]  w_strb;

    reg  signed [31:0] thr_reg;
    reg  signed [31:0] logit0_q, logit1_q, margin_q;
    reg                dec_q;
    reg  [31:0]        cycles_q, cyc_cnt;

    reg         start_req;                // one-cycle pulse from a CTRL write
    reg         srst_req;

    assign s_axi_awready = ~aw_full & ~s_axi_bvalid;
    assign s_axi_wready  = ~w_full  & ~s_axi_bvalid;
    assign s_axi_bresp   = 2'b00;
    assign s_axi_arready = ~s_axi_rvalid;
    assign s_axi_rresp   = 2'b00;

    always @(posedge aclk) begin
        if (!aresetn) begin
            aw_full <= 1'b0; w_full <= 1'b0;
            aw_addr <= 6'd0; w_data <= 32'd0; w_strb <= 4'd0;
            s_axi_bvalid <= 1'b0;
            thr_reg   <= DEFAULT_THRESHOLD;
            start_req <= 1'b0;
            srst_req  <= 1'b0;
        end else begin
            start_req <= 1'b0;
            srst_req  <= 1'b0;

            if (s_axi_awvalid && s_axi_awready) begin
                aw_full <= 1'b1;
                aw_addr <= s_axi_awaddr;
            end
            if (s_axi_wvalid && s_axi_wready) begin
                w_full <= 1'b1;
                w_data <= s_axi_wdata;
                w_strb <= s_axi_wstrb;
            end

            if (aw_full && w_full && !s_axi_bvalid) begin
                aw_full      <= 1'b0;
                w_full       <= 1'b0;
                s_axi_bvalid <= 1'b1;
                case (aw_addr[5:2])
                    4'h0: if (w_strb[0]) begin
                              start_req <= w_data[0];
                              srst_req  <= w_data[1];
                          end
                    4'h2: begin
                              if (w_strb[0]) thr_reg[7:0]   <= w_data[7:0];
                              if (w_strb[1]) thr_reg[15:8]  <= w_data[15:8];
                              if (w_strb[2]) thr_reg[23:16] <= w_data[23:16];
                              if (w_strb[3]) thr_reg[31:24] <= w_data[31:24];
                          end
                    default: ;
                endcase
            end

            if (s_axi_bvalid && s_axi_bready)
                s_axi_bvalid <= 1'b0;
        end
    end

    always @(posedge aclk) begin
        if (!aresetn) begin
            s_axi_rvalid <= 1'b0;
            s_axi_rdata  <= 32'd0;
        end else begin
            if (s_axi_arvalid && s_axi_arready) begin
                s_axi_rvalid <= 1'b1;
                case (s_axi_araddr[5:2])
                    4'h0: s_axi_rdata <= 32'd0;
                    4'h1: s_axi_rdata <= {28'd0, err, (state == S_STREAM), done, busy};
                    4'h2: s_axi_rdata <= thr_reg;
                    4'h3: s_axi_rdata <= logit0_q;
                    4'h4: s_axi_rdata <= logit1_q;
                    4'h5: s_axi_rdata <= margin_q;
                    4'h6: s_axi_rdata <= {31'd0, dec_q};
                    4'h7: s_axi_rdata <= VERSION;
                    4'h8: s_axi_rdata <= cycles_q;
                    default: s_axi_rdata <= 32'd0;
                endcase
            end else if (s_axi_rvalid && s_axi_rready) begin
                s_axi_rvalid <= 1'b0;
            end
        end
    end

    // ------------------------------------------------------------------
    // Core
    // ------------------------------------------------------------------
    wire core_rst = ~aresetn | srst_active;

    reg               core_start;
    reg  [7:0]        pix_data;
    reg               pix_valid;
    reg               thr_wr_en;
    wire signed [31:0] logit0, logit1, margin;
    wire              positive, result_valid;

    top_v1 #(
        .WEIGHTS_FILE    (WEIGHTS_FILE),
        .BIAS_FILE       (BIAS_FILE),
        .LAYER_TABLE_FILE(LAYER_TABLE_FILE)
    ) u_core (
        .clk(aclk), .rst(core_rst), .start(core_start),
        .pixel_in(pix_data), .pixel_valid(pix_valid),
        .threshold_wr(thr_reg), .threshold_wr_en(thr_wr_en),
        .logit0(logit0), .logit1(logit1), .margin(margin),
        .positive(positive), .result_valid(result_valid)
    );

    // ------------------------------------------------------------------
    // Stream unpacker: one 32-bit beat -> four pixels on four cycles.
    // A new beat is taken while the last byte of the current one goes out,
    // so a gap-free stream feeds the core one pixel per cycle.
    // ------------------------------------------------------------------
    reg  [31:0] beat;
    reg         have_beat;
    reg  [1:0]  sub;
    reg  [15:0] beats_in;
    reg  [17:0] pix_out;

    assign s_axis_tready = (state == S_STREAM) && (beats_in != N_BEATS) &&
                           (!have_beat || sub == 2'd3);
    wire   beat_take = s_axis_tvalid && s_axis_tready;

    wire [7:0] beat_byte = (sub == 2'd0) ? beat[7:0]   :
                           (sub == 2'd1) ? beat[15:8]  :
                           (sub == 2'd2) ? beat[23:16] : beat[31:24];

    // ------------------------------------------------------------------
    // Control FSM
    // ------------------------------------------------------------------
    always @(posedge aclk) begin
        if (!aresetn || srst_req) begin
            state      <= S_IDLE;
            done       <= 1'b0;
            err        <= 1'b0;
            srst_cnt   <= srst_req ? 5'd16 : 5'd0;
            core_start <= 1'b0;
            pix_valid  <= 1'b0;
            pix_data   <= 8'd0;
            thr_wr_en  <= 1'b0;
            have_beat  <= 1'b0;
            sub        <= 2'd0;
            beat       <= 32'd0;
            beats_in   <= 16'd0;
            pix_out    <= 18'd0;
            cyc_cnt    <= 32'd0;
            if (!aresetn) begin
                logit0_q <= 32'sd0; logit1_q <= 32'sd0; margin_q <= 32'sd0;
                dec_q    <= 1'b0;   cycles_q <= 32'd0;
            end
        end else begin
            core_start <= 1'b0;
            pix_valid  <= 1'b0;
            thr_wr_en  <= 1'b0;
            if (srst_active) srst_cnt <= srst_cnt - 5'd1;

            case (state)
                S_IDLE: begin
                    if (start_req && !srst_active) begin
                        done      <= 1'b0;
                        err       <= 1'b0;
                        have_beat <= 1'b0;
                        sub       <= 2'd0;
                        beats_in  <= 16'd0;
                        pix_out   <= 18'd0;
                        thr_wr_en <= 1'b1;          // threshold before pixels
                        state     <= S_THR;
                    end
                end

                S_THR: state <= S_STREAM;           // thr_wr_en is on the wire now

                S_STREAM: begin
                    if (have_beat) begin
                        pix_valid <= 1'b1;
                        pix_data  <= beat_byte;
                        pix_out   <= pix_out + 18'd1;
                        sub       <= sub + 2'd1;
                        if (sub == 2'd3) have_beat <= 1'b0;
                    end
                    if (beat_take) begin
                        beat      <= s_axis_tdata;
                        have_beat <= 1'b1;
                        sub       <= 2'd0;
                        beats_in  <= beats_in + 16'd1;
                        if (beats_in == N_BEATS - 1) begin
                            if (!s_axis_tlast) err <= 1'b1;   // late / missing tlast
                        end else if (s_axis_tlast) begin
                            err       <= 1'b1;                // early tlast: abort
                            have_beat <= 1'b0;
                            srst_cnt  <= 5'd16;
                            state     <= S_ABORT;
                        end
                    end
                    // The last pixel was put on the wire last cycle.
                    if (pix_out == N_PIXELS) state <= S_GAP;
                end

                S_GAP: begin                        // core sees pixel_valid = 0
                    core_start <= 1'b1;
                    state      <= S_START;
                end

                S_START: begin                      // core sees start = 1
                    cyc_cnt <= 32'd1;
                    state   <= S_WAIT_LOW;
                end

                S_WAIT_LOW: begin
                    cyc_cnt <= cyc_cnt + 32'd1;
                    if (!result_valid) state <= S_WAIT_HIGH;
                end

                S_WAIT_HIGH: begin
                    cyc_cnt <= cyc_cnt + 32'd1;
                    if (result_valid) begin
                        logit0_q <= logit0;
                        logit1_q <= logit1;
                        margin_q <= margin;
                        dec_q    <= positive;
                        cycles_q <= cyc_cnt;
                        done     <= 1'b1;
                        state    <= S_IDLE;
                    end
                end

                S_ABORT: begin
                    if (!srst_active) begin
                        done  <= 1'b1;
                        state <= S_IDLE;
                    end
                end

                default: state <= S_IDLE;
            endcase
        end
    end

    assign irq_done = done;

endmodule
