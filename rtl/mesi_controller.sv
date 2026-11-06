`timescale 1ns/1ps

module mesi_controller (
    input  logic       clk,
    input  logic       rst_n,

    input  logic       req_valid,
    input  logic       req_read,
    input  logic       req_write,
    input  logic       req_done,
    input  logic       bus_shared,
    input  logic       bus_grant,

    input  logic       bus_valid,
    input  logic [1:0] bus_cmd,

    output logic       bus_req,
    output logic [1:0] bus_cmd_out,
    output logic [1:0] state
);

    localparam logic [1:0] MESI_I = 2'b00;
    localparam logic [1:0] MESI_S = 2'b01;
    localparam logic [1:0] MESI_E = 2'b10;
    localparam logic [1:0] MESI_M = 2'b11;

    localparam logic [1:0] BUS_NONE = 2'b00;
    localparam logic [1:0] BUS_RD   = 2'b01;
    localparam logic [1:0] BUS_RDX  = 2'b10;
    localparam logic [1:0] BUS_UPGR = 2'b11;

    logic bus_needed;
    logic bus_request_pending;
    logic bus_request_issued;
    logic [1:0] pending_command;
    logic [1:0] requested_command;
    logic shared_response_latched;
    logic [1:0] next_state;

`ifndef SYNTHESIS
    logic assertion_history_valid;
    logic [1:0] previous_state;
    logic stalled_request;
    logic [1:0] stalled_command;
    logic stalled_upgrade_retry;
    logic tracked_request;
    logic tracked_read;
    logic tracked_write;
    logic request_grant_seen;

    function automatic legal_mesi_transition(
        input logic [1:0] prior,
        input logic [1:0] current
    );
        begin
            legal_mesi_transition = (prior == MESI_I
                    && (current == MESI_S || current == MESI_E || current == MESI_M))
                || (prior == MESI_S && (current == MESI_I || current == MESI_M))
                || (prior == MESI_E
                    && (current == MESI_I || current == MESI_S || current == MESI_M))
                || (prior == MESI_M && (current == MESI_I || current == MESI_S));
        end
    endfunction

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            previous_state <= MESI_I;
            assertion_history_valid <= 1'b0;
            stalled_request <= 1'b0;
            stalled_command <= BUS_NONE;
            stalled_upgrade_retry <= 1'b0;
            tracked_request <= 1'b0;
            tracked_read <= 1'b0;
            tracked_write <= 1'b0;
            request_grant_seen <= 1'b0;
        end else begin
            if (assertion_history_valid)
                assert (state == previous_state
                        || legal_mesi_transition(previous_state, state))
                    else $error("Illegal MESI state transition");
            if (stalled_request) begin
                assert (bus_req && (bus_cmd_out == stalled_command
                        || (stalled_upgrade_retry
                            && stalled_command == BUS_UPGR
                            && bus_cmd_out == BUS_RDX)))
                    else $error("Controller request changed while stalled");
            end
            previous_state <= state;
            assertion_history_valid <= 1'b1;
            stalled_request <= bus_req && !bus_grant;
            if (bus_req && !bus_grant)
                stalled_command <= bus_cmd_out;
            stalled_upgrade_retry <= bus_valid
                && (bus_cmd == BUS_RDX || bus_cmd == BUS_UPGR)
                && ((bus_request_pending && pending_command == BUS_UPGR)
                    || (!bus_request_pending && bus_req
                        && requested_command == BUS_UPGR));
            if (tracked_request) begin
                assert (req_valid)
                    else $error("Presented request was withdrawn before completion");
                assert (req_read == tracked_read && req_write == tracked_write)
                    else $error("Request operation changed before completion");
            end
            if (req_done && req_valid)
                tracked_request <= 1'b0;
            else if (req_valid) begin
                tracked_request <= 1'b1;
                tracked_read <= req_read;
                tracked_write <= req_write;
            end
            if (!req_valid || req_done)
                request_grant_seen <= 1'b0;
            else if (bus_grant && bus_req) begin
                assert (!request_grant_seen)
                    else $error("A request received more than one bus grant");
                request_grant_seen <= 1'b1;
            end
        end
    end
`endif

    always_comb begin
        bus_needed = 1'b0;
        requested_command = BUS_NONE;
        if (req_valid) begin
            if (req_read && state == MESI_I) begin
                bus_needed = 1'b1;
                requested_command = BUS_RD;
            end else if (req_write) begin
                case (state)
                    MESI_I: begin
                        bus_needed = 1'b1;
                        requested_command = BUS_RDX;
                    end
                    MESI_S: begin
                        bus_needed = 1'b1;
                        requested_command = BUS_UPGR;
                    end
                    default: requested_command = BUS_NONE;
                endcase
            end
        end
        bus_cmd_out = bus_request_pending ? pending_command : requested_command;
        bus_req = bus_request_pending
            || (bus_needed && !bus_request_issued);
    end

    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            bus_request_pending <= 1'b0;
            bus_request_issued <= 1'b0;
            pending_command <= BUS_NONE;
            shared_response_latched <= 1'b0;
        end else if (!req_valid || req_done) begin
            bus_request_pending <= 1'b0;
            bus_request_issued <= 1'b0;
            shared_response_latched <= 1'b0;
        end else begin
            if (bus_grant && bus_req) begin
                bus_request_pending <= 1'b0;
                bus_request_issued <= 1'b1;
                shared_response_latched <= bus_shared;
            end else if (bus_req && !bus_request_pending) begin
                bus_request_pending <= 1'b1;
                pending_command <= requested_command;
            end
            if (bus_valid && (bus_cmd == BUS_RDX || bus_cmd == BUS_UPGR)
                && ((bus_request_pending && pending_command == BUS_UPGR)
                    || (!bus_request_pending && bus_req
                        && requested_command == BUS_UPGR)))
                pending_command <= BUS_RDX;
        end
    end

    always_comb begin
        next_state = state;
        if (req_valid && req_done && (!bus_req || bus_request_issued || bus_grant)) begin
            if (req_read && state == MESI_I) begin
                next_state = (bus_grant ? bus_shared : shared_response_latched)
                    ? MESI_S : MESI_E;
            end else if (req_write) begin
                next_state = MESI_M;
            end
        end

        if (bus_valid) begin
            case (bus_cmd)
                BUS_RD: begin
                    if (next_state == MESI_M || next_state == MESI_E)
                        next_state = MESI_S;
                end
                BUS_RDX, BUS_UPGR: begin
                    if (next_state != MESI_I)
                        next_state = MESI_I;
                end
                default: begin
                end
            endcase
        end
    end

    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n)
            state <= MESI_I;
        else
            state <= next_state;
    end

`ifndef SYNTHESIS
    always @(posedge clk) begin
        if (rst_n) begin
            assert (state == MESI_I || state == MESI_S
                    || state == MESI_E || state == MESI_M)
                else $error("Illegal MESI state encoding");
            assert (!(req_read && req_write))
                else $error("A request cannot be both a read and a write");
            assert (!req_valid || (req_read ^ req_write))
                else $error("A valid request must be exactly one of read or write");
            assert (!bus_grant || bus_req)
                else $error("A grant must correspond to an asserted request");
            assert (!req_done || req_valid)
                else $error("Completion must correspond to a valid request");
            assert (!(req_valid && state == MESI_I)
                    || bus_req || bus_request_issued)
                else $error("An invalid line cannot complete as a local hit");
            assert (!bus_request_issued || req_valid)
                else $error("A granted request must remain valid until completion");
            assert (!(req_done && bus_req && !bus_request_issued && !bus_grant))
                else $error("A bus transaction must be granted before request completion");
        end
    end
`endif

endmodule
