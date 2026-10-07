// tb_v1_axi.v -- Project FLASH V1.2, end-to-end test of top_v1_axi.
//
// Drives the wrapper the way the PS will: AXI4-Lite register writes/reads
// (aw/w issued in different orders) and the image as an AXI4-Stream of
// 32-bit beats with pseudo-random tvalid gaps (LFSR), so tready backpressure
// is exercised. Checks logits/margin/decision against the golden model's
// exported vectors for images 0 and 1, then:
//   - VERSION == F1A50102, THRESHOLD resets to -646, unmapped read == 0
//   - STATUS.err == 0 after every good run, CYCLES nonzero (printed)
//   - image 0 again with THRESHOLD = 32'h7FFFFFFF -> DECISION == 0
//   - STATUS.done clears on the next start
//   - early tlast -> STATUS.err and done; err clears on the next start
// Verilog-2001 (iverilog -g2005 compatible). Run with
// v1/scripts/sim_tb_v1_axi.bat (Vivado xsim).

module tb_v1_axi;

    localparam N_PIXELS = 50176;
    localparam N_BEATS  = N_PIXELS / 4;
    localparam VEC = "C:/KarDRIVE/Projects/ProjectFlash/v1/mem/v1_2/flash_v1_2/vectors/";

    reg         aclk, aresetn;
    reg  [31:0] s_axis_tdata;
    reg         s_axis_tvalid, s_axis_tlast;
    wire        s_axis_tready;
    reg  [5:0]  s_axi_awaddr, s_axi_araddr;
    reg         s_axi_awvalid, s_axi_wvalid, s_axi_bready, s_axi_arvalid, s_axi_rready;
    reg  [31:0] s_axi_wdata;
    reg  [3:0]  s_axi_wstrb;
    wire        s_axi_awready, s_axi_wready, s_axi_bvalid, s_axi_arready, s_axi_rvalid;
    wire [1:0]  s_axi_bresp, s_axi_rresp;
    wire [31:0] s_axi_rdata;
    wire        irq_done;

    top_v1_axi dut (
        .aclk(aclk), .aresetn(aresetn),
        .s_axis_tdata(s_axis_tdata), .s_axis_tvalid(s_axis_tvalid),
        .s_axis_tready(s_axis_tready), .s_axis_tlast(s_axis_tlast),
        .s_axi_awaddr(s_axi_awaddr), .s_axi_awvalid(s_axi_awvalid), .s_axi_awready(s_axi_awready),
        .s_axi_wdata(s_axi_wdata), .s_axi_wstrb(s_axi_wstrb), .s_axi_wvalid(s_axi_wvalid),
        .s_axi_wready(s_axi_wready), .s_axi_bresp(s_axi_bresp), .s_axi_bvalid(s_axi_bvalid),
        .s_axi_bready(s_axi_bready), .s_axi_araddr(s_axi_araddr), .s_axi_arvalid(s_axi_arvalid),
        .s_axi_arready(s_axi_arready), .s_axi_rdata(s_axi_rdata), .s_axi_rresp(s_axi_rresp),
        .s_axi_rvalid(s_axi_rvalid), .s_axi_rready(s_axi_rready),
        .irq_done(irq_done)
    );

    initial aclk = 1'b0;
    always #5 aclk = ~aclk;

    // ---- vectors ----
    reg [7:0]  img        [0:N_PIXELS-1];
    reg [31:0] exp_l0     [0:243];
    reg [31:0] exp_l1     [0:243];
    reg [31:0] exp_margin [0:243];
    reg [7:0]  exp_dec    [0:243];

    // ---- scoreboard ----
    integer n_checks, n_fail;
    task check;
        input [255:0] what;   // label, right-aligned ASCII
        input [31:0]  got;
        input [31:0]  exp;
        begin
            n_checks = n_checks + 1;
            if (got !== exp) begin
                n_fail = n_fail + 1;
                $display("  FAIL %0s: got=%0d (0x%h) expected=%0d (0x%h)",
                         what, $signed(got), got, $signed(exp), exp);
            end
        end
    endtask

    // ---- tvalid gap generator ----
    reg [15:0] lfsr;
    task lfsr_step;
        begin
            lfsr = {lfsr[14:0], lfsr[15] ^ lfsr[13] ^ lfsr[12] ^ lfsr[10]};
        end
    endtask

    // ------------------------------------------------------------------
    // AXI4-Lite master. Signals change on negedge; ready/valid are sampled
    // at negedge (stable), so a ready seen there completes on the next
    // posedge.
    // ------------------------------------------------------------------
    task axil_aw;
        input [5:0] a;
        begin
            s_axi_awaddr = a; s_axi_awvalid = 1'b1;
            while (!s_axi_awready) @(negedge aclk);
            @(negedge aclk);
            s_axi_awvalid = 1'b0;
        end
    endtask

    task axil_w;
        input [31:0] d;
        begin
            s_axi_wdata = d; s_axi_wstrb = 4'hF; s_axi_wvalid = 1'b1;
            while (!s_axi_wready) @(negedge aclk);
            @(negedge aclk);
            s_axi_wvalid = 1'b0;
        end
    endtask

    // ord 0: aw then w, 1: w then aw, 2: both together
    task axil_write;
        input [5:0]  a;
        input [31:0] d;
        input [1:0]  ord;
        begin
            @(negedge aclk);
            if (ord == 2'd0) begin
                axil_aw(a); repeat (2) @(negedge aclk); axil_w(d);
            end else if (ord == 2'd1) begin
                axil_w(d);  repeat (3) @(negedge aclk); axil_aw(a);
            end else begin
                fork
                    axil_aw(a);
                    axil_w(d);
                join
            end
            while (!s_axi_bvalid) @(negedge aclk);
            if (s_axi_bresp !== 2'b00) begin
                n_fail = n_fail + 1;
                $display("  FAIL bresp=%b at 0x%h", s_axi_bresp, a);
            end
            @(negedge aclk);          // bready is held high: handshake done
        end
    endtask

    task axil_read;
        input  [5:0]  a;
        output [31:0] d;
        begin
            @(negedge aclk);
            s_axi_araddr = a; s_axi_arvalid = 1'b1;
            while (!s_axi_arready) @(negedge aclk);
            @(negedge aclk);
            s_axi_arvalid = 1'b0;
            while (!s_axi_rvalid) @(negedge aclk);
            d = s_axi_rdata;
            if (s_axi_rresp !== 2'b00) begin
                n_fail = n_fail + 1;
                $display("  FAIL rresp=%b at 0x%h", s_axi_rresp, a);
            end
            @(negedge aclk);          // rready is held high: handshake done
        end
    endtask

    // ------------------------------------------------------------------
    // AXI4-Stream master: N_BEATS beats (or n_beats for the error test),
    // byte 0 = first pixel, tlast on the final beat, random idle gaps.
    // ------------------------------------------------------------------
    task send_stream;
        input integer n_beats;
        integer b, g;
        begin
            for (b = 0; b < n_beats; b = b + 1) begin
                lfsr_step;
                for (g = 0; g < lfsr[1:0]; g = g + 1) @(negedge aclk);   // 0..3 idle cycles
                s_axis_tdata  = {img[4*b+3], img[4*b+2], img[4*b+1], img[4*b]};
                s_axis_tlast  = (b == n_beats - 1);
                s_axis_tvalid = 1'b1;
                while (!s_axis_tready) @(negedge aclk);
                // tready was high at this negedge -> taken at the next posedge
                @(negedge aclk);
                s_axis_tvalid = 1'b0;
                s_axis_tlast  = 1'b0;
            end
        end
    endtask

    // ------------------------------------------------------------------
    // One image through the wrapper
    // ------------------------------------------------------------------
    reg [31:0] rd, st, r_l0, r_l1, r_mg, r_dec, r_cyc;
    integer    run_no;

    task run_image;
        input integer    k;
        input [31:0]     thr;
        begin
            run_no = run_no + 1;
            axil_write(6'h08, thr, run_no % 3);
            axil_write(6'h00, 32'd1, (run_no + 1) % 3);
            axil_read(6'h04, st);
            check("STATUS.done clear after start", {31'd0, st[1]}, 32'd0);
            check("STATUS.busy after start",       {31'd0, st[0]}, 32'd1);
            send_stream(N_BEATS);
            st = 32'd0;
            while (!st[1]) begin
                repeat (4096) @(posedge aclk);
                axil_read(6'h04, st);
            end
            check("irq_done with STATUS.done", {31'd0, irq_done}, 32'd1);
            check("STATUS.err", {31'd0, st[3]}, 32'd0);
            axil_read(6'h0C, r_l0);
            axil_read(6'h10, r_l1);
            axil_read(6'h14, r_mg);
            axil_read(6'h18, r_dec);
            axil_read(6'h20, r_cyc);
            $display("  run %0d image %0d thr=%0d: logit0=%0d logit1=%0d margin=%0d decision=%0d CYCLES=%0d",
                     run_no, k, $signed(thr), $signed(r_l0), $signed(r_l1), $signed(r_mg), r_dec[0], r_cyc);
            if (r_cyc == 32'd0) begin
                n_fail = n_fail + 1;
                $display("  FAIL CYCLES is zero");
            end
        end
    endtask

    integer k;

    initial begin
        n_checks = 0; n_fail = 0; run_no = 0; lfsr = 16'hACE1;
        aresetn = 1'b0;
        s_axis_tdata = 32'd0; s_axis_tvalid = 1'b0; s_axis_tlast = 1'b0;
        s_axi_awaddr = 6'd0; s_axi_awvalid = 1'b0;
        s_axi_wdata = 32'd0; s_axi_wstrb = 4'h0; s_axi_wvalid = 1'b0;
        s_axi_bready = 1'b1;
        s_axi_araddr = 6'd0; s_axi_arvalid = 1'b0; s_axi_rready = 1'b1;

        $readmemh({VEC, "exp_logit0.mem"},   exp_l0);
        $readmemh({VEC, "exp_logit1.mem"},   exp_l1);
        $readmemh({VEC, "exp_margin.mem"},   exp_margin);
        $readmemh({VEC, "exp_decision.mem"}, exp_dec);

        repeat (16) @(posedge aclk);
        @(negedge aclk) aresetn = 1'b1;

        axil_read(6'h1C, rd);  check("VERSION", rd, 32'hF1A5_0102);
        axil_read(6'h08, rd);  check("THRESHOLD reset", rd, -32'sd646);
        axil_read(6'h3C, rd);  check("unmapped read", rd, 32'd0);
        axil_read(6'h04, rd);  check("STATUS after reset", rd, 32'd0);

        // ---- images 0 and 1 at the default threshold ----
        for (k = 0; k < 2; k = k + 1) begin
            if (k == 0) $readmemh({VEC, "img_0.mem"}, img);
            else        $readmemh({VEC, "img_1.mem"}, img);
            run_image(k, -32'sd646);
            check("logit0",   r_l0,  exp_l0[k]);
            check("logit1",   r_l1,  exp_l1[k]);
            check("margin",   r_mg,  exp_margin[k]);
            check("decision", {31'd0, r_dec[0]}, {31'd0, exp_dec[k][0]});
        end

        // ---- image 0 again, threshold at max: decision must be 0 ----
        $readmemh({VEC, "img_0.mem"}, img);
        run_image(0, 32'h7FFF_FFFF);
        check("logit0 (rerun)",      r_l0, exp_l0[0]);
        check("logit1 (rerun)",      r_l1, exp_l1[0]);
        check("margin (rerun)",      r_mg, exp_margin[0]);
        check("decision @ thr max",  {31'd0, r_dec[0]}, 32'd0);
        axil_read(6'h08, rd);  check("THRESHOLD readback", rd, 32'h7FFF_FFFF);

        // ---- early tlast: err + done, no hang; err clears on next start ----
        axil_write(6'h00, 32'd1, 2'd2);
        send_stream(3);
        st = 32'd0;
        while (!st[1]) axil_read(6'h04, st);
        check("STATUS.err on early tlast", {31'd0, st[3]}, 32'd1);
        axil_write(6'h00, 32'd1, 2'd0);
        axil_read(6'h04, st);
        check("STATUS.err clear on next start", {31'd0, st[3]}, 32'd0);
        check("STATUS.ready_for_pixels",        {31'd0, st[2]}, 32'd1);
        axil_write(6'h00, 32'd2, 2'd1);          // soft reset out of the armed run
        repeat (32) @(posedge aclk);
        axil_read(6'h04, st);
        check("STATUS after soft reset", st, 32'd0);

        $display("V1 AXI WRAPPER TEST (images 0, 1, image 0 @ thr max, early tlast):");
        $display("  checks: %0d, failures: %0d", n_checks, n_fail);
        if (n_fail == 0) $display("RESULT: PASS");
        else             $display("RESULT: FAIL");
        $finish;
    end

    // Cycle-counted timeout. Budget: 3 image runs x ~12.3M cycles + streaming
    // ~= 38M cycles; 100,000,000 gives ~2.5x headroom.
    initial begin : timeout_block
        integer to_cycles;
        to_cycles = 0;
        while (to_cycles < 100_000_000) begin
            @(posedge aclk);
            to_cycles = to_cycles + 1;
        end
        $display("RESULT: FAIL  (timeout at %0d cycles)", to_cycles);
        $finish;
    end

endmodule
