`timescale 1ns/1ps

module mesi_coherence_fabric #(
    parameter int CORE_COUNT = 2,
    localparam int CORE_ID_WIDTH = (CORE_COUNT > 1) ? $clog2(CORE_COUNT) : 1
) (
    input  logic                               clk,
    input  logic                               rst_n,
    input  logic [CORE_COUNT-1:0]              req_valid,
    input  logic [CORE_COUNT-1:0]              req_read,
    input  logic [CORE_COUNT-1:0]              req_write,
    input  logic [CORE_COUNT-1:0]              req_done,
    input  logic                               bus_ready,
    output logic [CORE_COUNT-1:0]              bus_req,
    output logic [CORE_COUNT-1:0][1:0]         bus_cmd_out,
    output logic [CORE_COUNT-1:0][1:0]         state,
    output logic [CORE_COUNT-1:0]              bus_grant,
    output logic [CORE_COUNT-1:0]              bus_shared,
    output logic [CORE_COUNT-1:0]              snoop_valid,
    output logic [CORE_COUNT-1:0][1:0]         snoop_cmd,
    output logic                               grant_valid,
    output logic [CORE_ID_WIDTH-1:0]           grant_core,
    output logic [1:0]                         grant_cmd
);
    logic [CORE_COUNT-1:0] request_valid;
    logic arbiter_grant_valid;
    logic arbiter_ready;
    logic transaction_pending;
    logic [CORE_ID_WIDTH-1:0] transaction_core;

    assign request_valid = bus_req;
    assign arbiter_ready = bus_ready && !transaction_pending;
    assign grant_valid = arbiter_grant_valid && !transaction_pending;

    mesi_bus_arbiter #(.CORE_COUNT(CORE_COUNT)) shared_bus (
        .clk(clk),
        .rst_n(rst_n),
        .request_valid(request_valid),
        .request_cmd(bus_cmd_out),
        .grant_ready(arbiter_ready),
        .grant_valid(arbiter_grant_valid),
        .grant_core(grant_core),
        .grant_cmd(grant_cmd)
    );

    // The control-only fabric has no address tag, so serialize coherence
    // transactions until the granted core reports completion.
    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            transaction_pending <= 1'b0;
            transaction_core <= '0;
        end else if (transaction_pending) begin
            if (req_done[transaction_core])
                transaction_pending <= 1'b0;
        end else if (grant_valid && bus_ready && !req_done[grant_core]) begin
            transaction_pending <= 1'b1;
            transaction_core <= grant_core;
        end
    end

    always_comb begin
        bus_grant = '0;
        bus_shared = '0;
        snoop_valid = '0;
        snoop_cmd = '0;
        for (integer core = 0; core < CORE_COUNT; core = core + 1) begin
            for (integer peer = 0; peer < CORE_COUNT; peer = peer + 1) begin
                if (peer != core && state[peer] != 2'b00)
                    bus_shared[core] = 1'b1;
            end
            if (grant_valid && bus_ready) begin
                if (grant_core == core)
                    bus_grant[core] = 1'b1;
                else begin
                    snoop_valid[core] = 1'b1;
                    snoop_cmd[core] = grant_cmd;
                end
            end
        end
    end

`ifndef SYNTHESIS
    always @(posedge clk) begin
        if (rst_n) begin
            for (integer owner = 0; owner < CORE_COUNT; owner = owner + 1) begin
                assert (state[owner] == 2'b00 || state[owner] == 2'b01
                        || state[owner] == 2'b10 || state[owner] == 2'b11)
                    else $error("Fabric observed an illegal MESI state encoding");
                for (integer peer = owner + 1; peer < CORE_COUNT; peer = peer + 1) begin
                    assert (!((state[owner] == 2'b11 || state[owner] == 2'b10)
                            && state[peer] != 2'b00))
                        else $error("MESI M/E ownership must be exclusive across cores");
                    assert (!((state[peer] == 2'b11 || state[peer] == 2'b10)
                            && state[owner] != 2'b00))
                        else $error("MESI M/E ownership must be exclusive across cores");
                end
            end
        end
    end
`endif

    genvar core_index;
    generate
        for (core_index = 0; core_index < CORE_COUNT; core_index = core_index + 1) begin : core
            mesi_controller controller (
                .clk(clk),
                .rst_n(rst_n),
                .req_valid(req_valid[core_index]),
                .req_read(req_read[core_index]),
                .req_write(req_write[core_index]),
                .req_done(req_done[core_index]),
                .bus_shared(bus_shared[core_index]),
                .bus_grant(bus_grant[core_index]),
                .bus_valid(snoop_valid[core_index]),
                .bus_cmd(snoop_cmd[core_index]),
                .bus_req(bus_req[core_index]),
                .bus_cmd_out(bus_cmd_out[core_index]),
                .state(state[core_index])
            );
        end
    endgenerate
endmodule
