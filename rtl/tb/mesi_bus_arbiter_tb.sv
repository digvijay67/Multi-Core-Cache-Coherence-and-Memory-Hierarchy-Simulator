`timescale 1ns/1ps

module mesi_bus_arbiter_tb;
    logic clk = 1'b0;
    logic rst_n = 1'b0;
    logic [1:0] request_valid;
    logic [1:0][1:0] request_cmd;
    logic grant_ready;
    logic grant_valid;
    logic grant_core;
    logic [1:0] grant_cmd;
    integer cov_core0_grant;
    integer cov_core1_grant;
    integer cov_backpressure;

    always #5 clk = ~clk;

    mesi_bus_arbiter #(.CORE_COUNT(2)) dut (
        .clk,
        .rst_n,
        .request_valid,
        .request_cmd,
        .grant_ready,
        .grant_valid,
        .grant_core,
        .grant_cmd
    );

    initial begin
        request_valid = '0;
        request_cmd = '0;
        grant_ready = 1'b0;
        cov_core0_grant = 0;
        cov_core1_grant = 0;
        cov_backpressure = 0;

        @(posedge clk);
        #1;
        @(negedge clk);
        rst_n = 1'b1;
        request_valid = 2'b11;
        request_cmd[0] = 2'b01;
        request_cmd[1] = 2'b10;
        #1;
        if (!grant_valid || grant_core !== 1'b0 || grant_cmd !== 2'b01)
            $fatal(1, "Reset priority must grant core 0's BusRd");
        cov_core0_grant = cov_core0_grant + 1;

        grant_ready = 1'b1;
        @(posedge clk);
        #1;
        if (!grant_valid || grant_core !== 1'b1 || grant_cmd !== 2'b10)
            $fatal(1, "Round-robin arbitration must next grant core 1's BusRdX");
        cov_core1_grant = cov_core1_grant + 1;

        @(negedge clk);
        grant_ready = 1'b0;
        #1;
        if (!grant_valid || grant_core !== 1'b1)
            $fatal(1, "Grant must remain stable while downstream is not ready");
        cov_backpressure = cov_backpressure + 1;

        grant_ready = 1'b1;
        @(posedge clk);
        #1;
        if (!grant_valid || grant_core !== 1'b0)
            $fatal(1, "Round-robin pointer must wrap after the final core");
        if (cov_core0_grant == 0 || cov_core1_grant == 0 || cov_backpressure == 0)
            $fatal(1, "Arbiter functional coverage is incomplete");

        @(negedge clk);
        grant_ready = 1'b0;
        request_valid = 2'b10;
        request_cmd[1] = 2'b10;
        #1;
        if (!grant_valid || grant_core !== 1'b1)
            $fatal(1, "Core 1 must be selected when it is the only requester");
        @(posedge clk);
        #1;
        @(negedge clk);
        request_valid = 2'b11;
        request_cmd[0] = 2'b01;
        #1;
        if (!grant_valid || grant_core !== 1'b1 || grant_cmd !== 2'b10)
            $fatal(1, "A new higher-priority request changed a stalled grant");
        cov_backpressure = cov_backpressure + 1;
        grant_ready = 1'b1;
        @(posedge clk);
        #1;
        if (!grant_valid || grant_core !== 1'b0 || grant_cmd !== 2'b01)
            $fatal(1, "Arbiter did not rotate priority after accepting a stalled grant");
        @(posedge clk);
        #1;
        @(negedge clk);
        request_valid = '0;
        grant_ready = 1'b0;

        $display("PASS: round-robin bus arbitration and backpressure tests");
        $finish;
    end
endmodule
