`timescale 1ns/1ps

module mesi_fabric_completion_serialization_tb;
    logic clk = 1'b0;
    logic rst_n = 1'b0;
    logic [1:0] req_valid = '0;
    logic [1:0] req_read = '0;
    logic [1:0] req_write = '0;
    logic [1:0] req_done = '0;
    logic bus_ready = 1'b1;
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
    integer first_core;
    integer second_core;

    always #5 clk = ~clk;

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

    initial begin
        repeat (2) @(posedge clk);
        @(negedge clk);
        rst_n = 1'b1;
        req_valid = 2'b11;
        req_write = 2'b11;
        #1;
        if (!grant_valid || !bus_grant[grant_core])
            $fatal(1, "The first write request was not granted");
        first_core = grant_core;
        second_core = 1 - first_core;

        @(posedge clk);
        repeat (3) begin
            @(posedge clk);
            #1;
            if (grant_valid)
                $fatal(1, "A second grant escaped before first completion");
        end

        @(negedge clk);
        req_done[first_core] = 1'b1;
        @(posedge clk);
        #1;
        if (state[first_core] != 2'b11)
            $fatal(1, "First granted write did not establish Modified state");
        if (!grant_valid || grant_core != second_core)
            $fatal(1, "Second request did not become grantable after completion");

        @(negedge clk);
        req_done[first_core] = 1'b0;
        req_valid[first_core] = 1'b0;
        req_write[first_core] = 1'b0;
        #1;
        if (!grant_valid || grant_core != second_core || !bus_grant[second_core])
            $fatal(1, "Second request grant was not routed to its core");

        @(posedge clk);
        @(negedge clk);
        req_done[second_core] = 1'b1;
        @(posedge clk);
        #1;
        if (state[first_core] != 2'b00 || state[second_core] != 2'b11)
            $fatal(1, "Serialized writes violated exclusive Modified ownership");

        @(negedge clk);
        req_valid = '0;
        req_write = '0;
        req_done = '0;
        $display("PASS: fabric serializes same-line grants through completion");
        $finish;
    end
endmodule
