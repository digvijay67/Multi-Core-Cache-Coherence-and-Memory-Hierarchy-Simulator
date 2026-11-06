`timescale 1ns/1ps

module mesi_bus_arbiter #(
    parameter int CORE_COUNT = 2,
    localparam int CORE_ID_WIDTH = (CORE_COUNT > 1) ? $clog2(CORE_COUNT) : 1
) (
    input  logic                               clk,
    input  logic                               rst_n,
    input  logic [CORE_COUNT-1:0]              request_valid,
    input  logic [CORE_COUNT-1:0][1:0]         request_cmd,
    input  logic                               grant_ready,
    output logic                               grant_valid,
    output logic [CORE_ID_WIDTH-1:0]           grant_core,
    output logic [1:0]                         grant_cmd
);

    logic [CORE_ID_WIDTH-1:0] round_robin_ptr;
    logic [CORE_ID_WIDTH-1:0] selected_core;
    logic [CORE_ID_WIDTH:0] candidate;
    logic selected_valid;
    logic grant_locked;
    logic [CORE_ID_WIDTH-1:0] locked_core;
    logic [1:0] locked_command;
    integer offset;

    always @* begin
        selected_valid = 1'b0;
        selected_core = round_robin_ptr;
        candidate = '0;
        grant_cmd = 2'b00;
        for (offset = 0; offset < CORE_COUNT; offset = offset + 1) begin
            candidate = round_robin_ptr + offset;
            if (candidate >= CORE_COUNT)
                candidate = candidate - CORE_COUNT;
            if (!selected_valid
                && request_valid[candidate[CORE_ID_WIDTH-1:0]]) begin
                selected_valid = 1'b1;
                selected_core = candidate[CORE_ID_WIDTH-1:0];
                grant_cmd = request_cmd[candidate[CORE_ID_WIDTH-1:0]];
            end
        end
        grant_valid = grant_locked || selected_valid;
        grant_core = grant_locked ? locked_core : selected_core;
        if (grant_locked)
            grant_cmd = locked_command;
    end

    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            round_robin_ptr <= '0;
            grant_locked <= 1'b0;
            locked_core <= '0;
            locked_command <= 2'b00;
        end else begin
            if (grant_valid && grant_ready) begin
                if (grant_core == CORE_COUNT - 1)
                    round_robin_ptr <= '0;
                else
                    round_robin_ptr <= grant_core + 1'b1;
                grant_locked <= 1'b0;
            end else if (grant_valid && !grant_locked) begin
                grant_locked <= 1'b1;
                locked_core <= selected_core;
                locked_command <= grant_cmd;
            end
        end
    end

`ifndef SYNTHESIS
    logic stalled_grant;
    logic [CORE_ID_WIDTH-1:0] stalled_core;
    logic [1:0] stalled_command;

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            stalled_grant <= 1'b0;
            stalled_core <= '0;
            stalled_command <= 2'b00;
        end else begin
            if (stalled_grant)
                assert (grant_valid && grant_core == stalled_core
                        && grant_cmd == stalled_command)
                    else $error("Arbiter grant changed while backpressured");
            if (stalled_grant)
                assert (request_valid[stalled_core]
                        && request_cmd[stalled_core] == stalled_command)
                    else $error("Arbiter requester withdrew or changed a stalled request");
            stalled_grant <= grant_valid && !grant_ready;
            if (grant_valid && !grant_ready) begin
                stalled_core <= grant_core;
                stalled_command <= grant_cmd;
            end
        end
    end

    always @(posedge clk) begin
        if (rst_n && grant_valid && grant_ready) begin
            assert (request_valid[grant_core])
                else $error("Arbiter granted a core without a pending request");
        end
    end
`endif

endmodule
