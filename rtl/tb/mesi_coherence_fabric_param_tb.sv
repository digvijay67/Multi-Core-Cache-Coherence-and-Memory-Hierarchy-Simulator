`timescale 1ns/1ps

module mesi_coherence_fabric_param_tb #(
    parameter int CORE_COUNT = 2,
    localparam int CORE_ID_WIDTH = (CORE_COUNT > 1) ? $clog2(CORE_COUNT) : 1
);
    localparam logic [1:0] MESI_I = 2'b00;
    localparam logic [1:0] MESI_S = 2'b01;
    localparam logic [1:0] MESI_E = 2'b10;
    localparam logic [1:0] MESI_M = 2'b11;
    localparam logic [1:0] BUS_RD = 2'b01;
    localparam logic [1:0] BUS_RDX = 2'b10;
    localparam logic [1:0] BUS_UPGR = 2'b11;

    logic clk = 1'b0;
    logic rst_n = 1'b0;
    logic [CORE_COUNT-1:0] req_valid;
    logic [CORE_COUNT-1:0] req_read;
    logic [CORE_COUNT-1:0] req_write;
    logic [CORE_COUNT-1:0] req_done;
    logic bus_ready;
    logic [CORE_COUNT-1:0] bus_req;
    logic [CORE_COUNT-1:0][1:0] bus_cmd_out;
    logic [CORE_COUNT-1:0][1:0] state;
    logic [CORE_COUNT-1:0] bus_grant;
    logic [CORE_COUNT-1:0] bus_shared;
    logic [CORE_COUNT-1:0] snoop_valid;
    logic [CORE_COUNT-1:0][1:0] snoop_cmd;
    logic grant_valid;
    logic [CORE_ID_WIDTH-1:0] grant_core;
    logic [1:0] grant_cmd;

    integer active_core;
    integer grant_count;
    integer grants_before;
    integer expected_command;
    integer waits;
    logic [1:0] state_before_access;
    logic bus_active;
    logic shared_before_grant;

    always #5 clk = ~clk;

    mesi_coherence_fabric #(.CORE_COUNT(CORE_COUNT)) dut (
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

    always @(negedge clk)
        bus_ready = rst_n && !bus_active;

    always @(posedge clk) begin
        if (!rst_n) begin
            bus_active = 1'b0;
        end else begin
            if (grant_valid && bus_ready) begin
                if (bus_active || !req_valid[grant_core])
                    $fatal(1, "CORE_COUNT=%0d invalid or overlapping grant", CORE_COUNT);
                active_core = grant_core;
                bus_active = 1'b1;
                grant_count = grant_count + 1;
                if (snoop_valid[active_core] || !bus_grant[active_core])
                    $fatal(1, "CORE_COUNT=%0d grant/snoop routing failed", CORE_COUNT);
                for (integer peer = 0; peer < CORE_COUNT; peer = peer + 1)
                    if (peer != active_core
                        && (!snoop_valid[peer] || snoop_cmd[peer] != grant_cmd))
                        $fatal(1, "CORE_COUNT=%0d snoop was not broadcast to peer %0d",
                               CORE_COUNT, peer);
            end
            if (bus_active && req_done[active_core])
                bus_active = 1'b0;
        end
    end

    task automatic access_line(input integer core, input logic is_write);
        begin
            if (req_valid[core])
                $fatal(1, "CORE_COUNT=%0d core %0d already has a request", CORE_COUNT, core);
            expected_command = 0;
            state_before_access = state[core];
            if (!is_write && state[core] == MESI_I)
                expected_command = BUS_RD;
            else if (is_write && state[core] == MESI_I)
                expected_command = BUS_RDX;
            else if (is_write && state[core] == MESI_S)
                expected_command = BUS_UPGR;

            grants_before = grant_count;
            req_read[core] = !is_write;
            req_write[core] = is_write;
            req_done[core] = 1'b0;
            @(negedge clk);
            req_valid[core] = 1'b1;

            if (expected_command != 0) begin
                waits = 0;
                while (grant_count == grants_before && waits < 100) begin
                    @(posedge clk);
                    #1;
                    waits = waits + 1;
                end
                if (grant_count == grants_before)
                    $fatal(1, "CORE_COUNT=%0d request did not receive a grant", CORE_COUNT);
                if (bus_cmd_out[core] != expected_command)
                    $fatal(1, "CORE_COUNT=%0d expected command=%0d actual=%0d",
                           CORE_COUNT, expected_command, bus_cmd_out[core]);
                if (!is_write)
                    shared_before_grant = bus_shared[core];
            end else begin
                shared_before_grant = 1'b0;
            end

            @(negedge clk);
            req_done[core] = 1'b1;
            @(posedge clk);
            #1;

            if (is_write)
                expected_command = MESI_M;
            else if (state_before_access == MESI_I)
                expected_command = shared_before_grant ? MESI_S : MESI_E;
            else
                expected_command = state_before_access;
            if (state[core] !== expected_command[1:0])
                $fatal(1, "CORE_COUNT=%0d completion state mismatch core=%0d expected=%0d actual=%0d",
                       CORE_COUNT, core, expected_command, state[core]);

            @(negedge clk);
            req_valid[core] = 1'b0;
            req_read[core] = 1'b0;
            req_write[core] = 1'b0;
            req_done[core] = 1'b0;
            #1;
        end
    endtask

    initial begin
        req_valid = '0;
        req_read = '0;
        req_write = '0;
        req_done = '0;
        bus_ready = 1'b0;
        bus_active = 1'b0;
        active_core = 0;
        grant_count = 0;
        grants_before = 0;
        expected_command = 0;
        waits = 0;
        state_before_access = MESI_I;
        shared_before_grant = 1'b0;

        repeat (2) @(posedge clk);
        @(negedge clk);
        rst_n = 1'b1;
        for (integer core = 0; core < CORE_COUNT; core = core + 1)
            access_line(core, 1'b0);

        if (CORE_COUNT == 1) begin
            if (state[0] != MESI_E)
                $fatal(1, "Single-core read should establish E");
        end else begin
            for (integer core = 0; core < CORE_COUNT; core = core + 1)
                if (state[core] != MESI_S)
                    $fatal(1, "CORE_COUNT=%0d core=%0d should hold S", CORE_COUNT, core);
        end

        access_line(CORE_COUNT - 1, 1'b1);
        if (state[CORE_COUNT-1] != MESI_M)
            $fatal(1, "CORE_COUNT=%0d final writer must hold M", CORE_COUNT);
        for (integer core = 0; core < CORE_COUNT - 1; core = core + 1)
            if (state[core] != MESI_I)
                $fatal(1, "CORE_COUNT=%0d writer failed to invalidate core=%0d",
                       CORE_COUNT, core);

        if (grant_count != (CORE_COUNT == 1 ? 1 : CORE_COUNT + 1))
            $fatal(1, "CORE_COUNT=%0d unexpected bus grant count=%0d",
                   CORE_COUNT, grant_count);
        $display("PASS: parameterized MESI fabric CORE_COUNT=%0d grants=%0d",
                 CORE_COUNT, grant_count);
        $finish;
    end

    initial begin
        #200000;
        $fatal(1, "CORE_COUNT=%0d fabric test timed out", CORE_COUNT);
    end
endmodule
