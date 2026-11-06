module mesi_controller_formal;
    localparam logic [1:0] MESI_I = 2'b00;
    localparam logic [1:0] MESI_S = 2'b01;
    localparam logic [1:0] MESI_E = 2'b10;
    localparam logic [1:0] MESI_M = 2'b11;
    localparam logic [1:0] BUS_NONE = 2'b00;
    localparam logic [1:0] BUS_UPGR = 2'b11;
    localparam logic [1:0] BUS_RDX = 2'b10;

    (* gclk *) logic clk;
    logic rst_n = 1'b0;
    logic reset_cycle_seen = 1'b0;
    (* anyseq *) logic req_valid;
    (* anyseq *) logic req_read;
    (* anyseq *) logic req_write;
    (* anyseq *) logic req_done;
    (* anyseq *) logic bus_shared;
    (* anyseq *) logic bus_grant;
    (* anyseq *) logic bus_valid;
    (* anyseq *) logic [1:0] bus_cmd;

    logic bus_req;
    logic [1:0] bus_cmd_out;
    logic [1:0] state;
    logic past_valid = 1'b0;
    logic request_grant_seen = 1'b0;
    logic read_response_pending = 1'b0;
    logic [1:0] expected_read_state;
    logic response_shared_latched = 1'b0;
    logic request_needs_bus;

    always_comb begin
        request_needs_bus = req_valid
            && ((req_read && state == MESI_I)
                || (req_write && (state == MESI_I || state == MESI_S)));
    end

    always @(posedge clk) begin
        if (!reset_cycle_seen) begin
            rst_n <= 1'b0;
            reset_cycle_seen <= 1'b1;
        end else begin
            rst_n <= 1'b1;
        end
    end

    mesi_controller dut (
        .clk(clk),
        .rst_n(rst_n),
        .req_valid(req_valid),
        .req_read(req_read),
        .req_write(req_write),
        .req_done(req_done),
        .bus_shared(bus_shared),
        .bus_grant(bus_grant),
        .bus_valid(bus_valid),
        .bus_cmd(bus_cmd),
        .bus_req(bus_req),
        .bus_cmd_out(bus_cmd_out),
        .state(state)
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
            assume (!req_valid);
            if (reset_cycle_seen) begin
                assert (state == MESI_I);
                assert (!bus_req);
                assert (bus_cmd_out == BUS_NONE);
            end
            request_grant_seen <= 1'b0;
            read_response_pending <= 1'b0;
            response_shared_latched <= 1'b0;
        end else begin
            assume (!bus_grant || bus_req);
            assume (!req_done || req_valid);
            assume (!req_done || !request_needs_bus
                    || request_grant_seen || bus_grant);
            if (req_valid)
                assume (req_read ^ req_write);

            if (past_valid && $past(rst_n)) begin
                assert (legal_transition($past(state), state));
                if ($past(bus_req && !bus_grant)) begin
                    assert (bus_req);
                    if (!$past(bus_valid
                            && (bus_cmd == BUS_RDX || bus_cmd == BUS_UPGR)
                            && bus_cmd_out == BUS_UPGR))
                        assert (bus_cmd_out == $past(bus_cmd_out));
                    else
                        assert (bus_cmd_out == BUS_RDX);
                end
                if ($past(req_valid && !req_done)) begin
                    assume (req_valid);
                    assume (req_read == $past(req_read));
                    assume (req_write == $past(req_write));
                end
            end

            assert (state == MESI_I || state == MESI_S
                    || state == MESI_E || state == MESI_M);
            assert (!request_grant_seen || !bus_req);

            if (read_response_pending)
                assert (state == expected_read_state);
            read_response_pending <= req_done && req_valid && req_read
                && state == MESI_I && !bus_valid;
            if (req_done && req_valid && req_read && state == MESI_I && !bus_valid)
                expected_read_state <= (bus_grant
                    ? bus_shared : response_shared_latched) ? MESI_S : MESI_E;

            if (!req_valid || req_done)
                request_grant_seen <= 1'b0;
            else if (bus_req && bus_grant) begin
                assert (!request_grant_seen);
                request_grant_seen <= 1'b1;
            end
            if (!req_valid || req_done)
                response_shared_latched <= 1'b0;
            else if (bus_req && bus_grant)
                response_shared_latched <= bus_shared;

            if (past_valid && !$past(rst_n))
                assert (state == MESI_I);
        end
    end
endmodule
