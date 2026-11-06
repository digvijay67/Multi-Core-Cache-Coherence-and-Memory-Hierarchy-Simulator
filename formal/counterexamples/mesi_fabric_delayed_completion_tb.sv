`timescale 1ns/1ps

module mesi_fabric_delayed_completion_tb;
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
        $dumpfile("build\\formal\\counterexamples\\mesi_fabric_delayed_completion.vcd");
        $dumpvars(0, mesi_fabric_delayed_completion_tb);
        repeat (2) @(negedge clk);
        rst_n = 1'b1;
        req_valid = 2'b11;
        req_write = 2'b11;
        #1;
        if (!grant_valid || grant_core != 0)
            $fatal(1, "Expected the first same-line write grant for core 0");
        @(posedge clk);

        @(negedge clk);
        if (!grant_valid || grant_core != 1)
            $fatal(1, "Expected the overlapping same-line write grant for core 1");
        req_done[1] = 1'b1;
        @(posedge clk);
        #1;
        req_done[1] = 1'b0;

        @(negedge clk);
        req_done[0] = 1'b1;
        @(posedge clk);
        #1;
        if (state[0] == 2'b11 && state[1] == 2'b11)
            $display("COUNTEREXAMPLE: overlapping grants and delayed completion produced two M owners");
        else
            $fatal(1, "Expected the pre-fix ownership counterexample");
        $finish;
    end
endmodule
