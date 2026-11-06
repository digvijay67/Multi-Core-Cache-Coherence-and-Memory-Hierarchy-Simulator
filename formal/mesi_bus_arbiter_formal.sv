module mesi_bus_arbiter_formal #(
    parameter bit FAIRNESS_MODE = 1'b0
);
    (* gclk *) logic clk;
    logic rst_n = 1'b0;
    (* anyseq *) logic [1:0] request_valid;
    (* anyseq *) logic [1:0][1:0] request_cmd;
    (* anyseq *) logic grant_ready;
    logic grant_valid;
    logic grant_core;
    logic [1:0] grant_cmd;
    logic past_valid = 1'b0;

    always @(posedge clk)
        rst_n <= 1'b1;

    mesi_bus_arbiter #(.CORE_COUNT(2)) dut (
        .clk(clk),
        .rst_n(rst_n),
        .request_valid(request_valid),
        .request_cmd(request_cmd),
        .grant_ready(grant_ready),
        .grant_valid(grant_valid),
        .grant_core(grant_core),
        .grant_cmd(grant_cmd)
    );

    always @(posedge clk) begin
        past_valid <= 1'b1;
        if (rst_n) begin
            if (past_valid && $past(rst_n && grant_valid && !grant_ready)) begin
                assert (grant_valid);
                assert (grant_core == $past(grant_core));
                assert (grant_cmd == $past(grant_cmd));
            end
        end
    end

    generate
        if (FAIRNESS_MODE) begin : g_fairness
            always @(posedge clk) begin
                if (rst_n) begin
                    assume (grant_ready);
                    assume (request_valid == 2'b11);
                    assert (grant_valid);
                    if (past_valid && $past(rst_n))
                        assert (grant_core != $past(grant_core));
                end
            end
        end
    endgenerate
endmodule
