// decision.v -- Project FLASH V1, final decision logic.
//
// margin = logit1 - logit0; POSITIVE iff margin > threshold. Matches the
// golden model's `decide()` exactly (see tools/golden_model_v1.py).
// Purely combinational -- no clock, no state.

module decision (
    input  wire signed [31:0] logit0,
    input  wire signed [31:0] logit1,
    input  wire signed [31:0] threshold,
    output wire signed [31:0] margin,
    output wire                positive
);

    assign margin   = logit1 - logit0;
    assign positive = (margin > threshold);

endmodule
