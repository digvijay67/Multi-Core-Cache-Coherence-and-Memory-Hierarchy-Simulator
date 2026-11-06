module mesi_coherence_fabric_formal;
    localparam logic [1:0] MESI_I = 2'b00;
    localparam logic [1:0] MESI_S = 2'b01;
    localparam logic [1:0] MESI_E = 2'b10;
    localparam logic [1:0] MESI_M = 2'b11;

    (* gclk *) logic clk;
    logic rst_n = 1'b0;
    logic reset_cycle_seen = 1'b0;
    (* anyseq *) logic [1:0] req_valid;
    (* anyseq *) logic [1:0] req_read;
    (* anyseq *) logic [1:0] req_write;
    (* anyseq *) logic [1:0] req_done;
    (* anyseq *) logic bus_ready;

    logic [1:0] bus_req;
    logic [1:0][1:0] bus_cmd_out;
    logic [1:0][1:0] state;
    logic [1:0] bus_grant;
    logic [1:0] bus_shared;
    logic [1:0] snoop_valid;
    logic [1:0][1:0] snoop_cmd;
    logic grant_valid;
    logic grant_core;
    logic [1:0] grant_cmd;
    logic [1:0] grant_seen = '0;
    logic [1:0] needs_bus;
    logic past_valid = 1'b0;

    always_comb begin
        needs_bus[0] = req_valid[0]
            && ((req_read[0] && state[0] == MESI_I)
                || (req_write[0] && (state[0] == MESI_I || state[0] == MESI_S)));
        needs_bus[1] = req_valid[1]
            && ((req_read[1] && state[1] == MESI_I)
                || (req_write[1] && (state[1] == MESI_I || state[1] == MESI_S)));
    end

    always @(posedge clk) begin
        if (!reset_cycle_seen) begin
            rst_n <= 1'b0;
            reset_cycle_seen <= 1'b1;
        end else begin
            rst_n <= 1'b1;
        end
    end

    mesi_coherence_fabric #(.CORE_COUNT(2)) dut (
        .clk(clk),
        .rst_n(rst_n),
        .req_valid(req_valid),
        .req_read(req_read),
        .req_write(req_write),
        .req_done(req_done),
        .bus_ready(bus_ready),
        .bus_req(bus_req),
        .bus_cmd_out(bus_cmd_out),
        .state(state),
        .bus_grant(bus_grant),
        .bus_shared(bus_shared),
        .snoop_valid(snoop_valid),
        .snoop_cmd(snoop_cmd),
        .grant_valid(grant_valid),
        .grant_core(grant_core),
        .grant_cmd(grant_cmd)
    );

    function automatic logic legal_transition(
        input logic [1:0] prior,
        input logic [1:0] current
    );
        begin
            legal_transition = prior == current
                || (prior == MESI_I
                    && (current == MESI_S || current == MESI_E || current == MESI_M))
                || (prior == MESI_S && (current == MESI_I || current == MESI_M))
                || (prior == MESI_E
                    && (current == MESI_I || current == MESI_S || current == MESI_M))
                || (prior == MESI_M && (current == MESI_I || current == MESI_S));
        end
    endfunction

    always @(posedge clk) begin
        past_valid <= 1'b1;
        if (!rst_n) begin
            assume (req_valid == 2'b00);
            if (reset_cycle_seen)
                assert (state == {MESI_I, MESI_I});
            grant_seen <= '0;
        end else begin
            for (integer core = 0; core < 2; core = core + 1) begin
                assume (!req_done[core] || req_valid[core]);
                assume (!req_done[core] || !needs_bus[core]
                        || grant_seen[core] || bus_grant[core]);
                if (req_valid[core])
                    assume (req_read[core] ^ req_write[core]);
                if (past_valid && $past(rst_n && req_valid[core] && !req_done[core])) begin
                    assume (req_valid[core]);
                    assume (req_read[core] == $past(req_read[core]));
                    assume (req_write[core] == $past(req_write[core]));
                end

                if (!req_valid[core] || req_done[core])
                    grant_seen[core] <= 1'b0;
                else if (bus_grant[core])
                    grant_seen[core] <= 1'b1;
            end

            for (integer core = 0; core < 2; core = core + 1) begin
                assert (state[core] == MESI_I || state[core] == MESI_S
                        || state[core] == MESI_E || state[core] == MESI_M);
                if (past_valid && $past(rst_n))
                    assert (legal_transition($past(state[core]), state[core]));
            end

            assert (!((state[0] == MESI_M || state[0] == MESI_E)
                    && state[1] != MESI_I));
            assert (!((state[1] == MESI_M || state[1] == MESI_E)
                    && state[0] != MESI_I));
        end
    end
endmodule
