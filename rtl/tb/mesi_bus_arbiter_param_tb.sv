`timescale 1ns/1ps

module mesi_bus_arbiter_param_tb #(
    parameter int CORE_COUNT = 2,
    localparam int CORE_ID_WIDTH = (CORE_COUNT > 1) ? $clog2(CORE_COUNT) : 1
);
    logic clk = 1'b0;
    logic rst_n = 1'b0;
    logic [CORE_COUNT-1:0] request_valid;
    logic [CORE_COUNT-1:0][1:0] request_cmd;
    logic grant_ready;
    logic grant_valid;
    logic [CORE_ID_WIDTH-1:0] grant_core;
    logic [1:0] grant_cmd;

    integer expected_core;
    integer accepted_count;
    integer guard_cycles;
    logic [CORE_ID_WIDTH-1:0] stalled_core;
    logic [1:0] stalled_command;

    always #5 clk = ~clk;

    mesi_bus_arbiter #(.CORE_COUNT(CORE_COUNT)) dut (
        .clk(clk),
        .rst_n(rst_n),
        .request_valid(request_valid),
        .request_cmd(request_cmd),
        .grant_ready(grant_ready),
        .grant_valid(grant_valid),
        .grant_core(grant_core),
        .grant_cmd(grant_cmd)
    );

    initial begin
        if (CORE_COUNT < 1)
            $fatal(1, "CORE_COUNT must be positive");

        request_valid = '0;
        request_cmd = '0;
        grant_ready = 1'b0;
        accepted_count = 0;
        repeat (2) @(posedge clk);
        @(negedge clk);
        rst_n = 1'b1;
        request_valid = '1;
        for (integer core = 0; core < CORE_COUNT; core = core + 1)
            request_cmd[core] = (core % 3) + 1;
        #1;

        if (!grant_valid || grant_core !== '0)
            $fatal(1, "CORE_COUNT=%0d reset must prioritize core 0", CORE_COUNT);
        stalled_core = grant_core;
        stalled_command = grant_cmd;
        repeat (3) begin
            @(posedge clk);
            #1;
            if (!grant_valid || grant_core !== stalled_core
                || grant_cmd !== stalled_command)
                $fatal(1, "CORE_COUNT=%0d grant changed under backpressure", CORE_COUNT);
        end

        for (integer round = 0; round < 2; round = round + 1) begin
            for (integer position = 0; position < CORE_COUNT; position = position + 1) begin
                expected_core = position;
                @(negedge clk);
                grant_ready = 1'b1;
                #1;
                if (!grant_valid || grant_core !== expected_core[CORE_ID_WIDTH-1:0]
                    || grant_cmd !== request_cmd[expected_core])
                    $fatal(1,
                           "CORE_COUNT=%0d round=%0d expected core=%0d command=%0d actual core=%0d command=%0d",
                           CORE_COUNT, round, expected_core,
                           request_cmd[expected_core], grant_core, grant_cmd);
                @(posedge clk);
                #1;
                accepted_count = accepted_count + 1;
                grant_ready = 1'b0;
                if (position + 1 < CORE_COUNT) begin
                    #1;
                    if (!grant_valid
                        || grant_core !== (position + 1) % CORE_COUNT)
                        $fatal(1, "CORE_COUNT=%0d lost round-robin progress", CORE_COUNT);
                end
            end
        end

        @(negedge clk);
        request_valid = '0;
        #1;
        if (grant_valid)
            $fatal(1, "CORE_COUNT=%0d arbiter granted with no requests", CORE_COUNT);

        if (CORE_COUNT > 1) begin
            @(negedge clk);
            request_valid[CORE_COUNT-1] = 1'b1;
            request_cmd[CORE_COUNT-1] = 2'b10;
            grant_ready = 1'b0;
            #1;
            if (!grant_valid
                || grant_core !== (CORE_COUNT-1) % CORE_COUNT)
                $fatal(1, "CORE_COUNT=%0d failed to select the only requester", CORE_COUNT);
            @(posedge clk);
            #1;
            @(negedge clk);
            request_valid[0] = 1'b1;
            request_cmd[0] = 2'b01;
            #1;
            if (!grant_valid || grant_core !== (CORE_COUNT-1) % CORE_COUNT
                || grant_cmd !== 2'b10)
                $fatal(1, "CORE_COUNT=%0d new request changed a stalled grant", CORE_COUNT);
            grant_ready = 1'b1;
            @(posedge clk);
            #1;
            accepted_count = accepted_count + 1;
            if (!grant_valid || grant_core !== '0 || grant_cmd !== 2'b01)
                $fatal(1, "CORE_COUNT=%0d did not rotate after the locked grant", CORE_COUNT);
            @(posedge clk);
            #1;
            accepted_count = accepted_count + 1;
            @(negedge clk);
            request_valid = '0;
            grant_ready = 1'b0;
            #1;
            if (grant_valid)
                $fatal(1, "CORE_COUNT=%0d grant remained valid after all requests completed",
                       CORE_COUNT);
        end

        if (accepted_count != 2 * CORE_COUNT + (CORE_COUNT > 1 ? 2 : 0))
            $fatal(1, "CORE_COUNT=%0d unexpected grant total=%0d",
                   CORE_COUNT, accepted_count);

        $display("PASS: parameterized arbiter CORE_COUNT=%0d grants=%0d",
                 CORE_COUNT, accepted_count);
        $finish;
    end

    initial begin
        guard_cycles = 0;
        while (guard_cycles < 1000) begin
            @(posedge clk);
            guard_cycles = guard_cycles + 1;
        end
        $fatal(1, "CORE_COUNT=%0d arbiter test timed out", CORE_COUNT);
    end
endmodule
