`timescale 1ns/1ps

module mesi_controller_tb;
    localparam logic [1:0] MESI_I = 2'b00;
    localparam logic [1:0] MESI_S = 2'b01;
    localparam logic [1:0] MESI_E = 2'b10;
    localparam logic [1:0] MESI_M = 2'b11;

    localparam logic [1:0] BUS_RD   = 2'b01;
    localparam logic [1:0] BUS_RDX  = 2'b10;
    localparam logic [1:0] BUS_UPGR = 2'b11;

    logic clk = 1'b0;
    logic rst_n = 1'b0;

    logic [1:0] req_valid;
    logic [1:0] req_read;
    logic [1:0] req_write;
    logic [1:0] req_done;
    logic [1:0] bus_shared;
    logic [1:0] bus_grant;
    logic [1:0] bus_req;
    logic [1:0][1:0] bus_cmd_out;
    logic [1:0] bus_valid;
    logic [1:0][1:0] bus_cmd;
    logic [1:0][1:0] state;
    integer cov_i_to_e;
    integer cov_i_to_s;
    integer cov_e_to_s;
    integer cov_s_to_m;
    integer cov_s_to_i;
    integer cov_i_to_m;
    integer cov_m_to_i;
    integer cov_m_to_s;

    always #5 clk = ~clk;

    mesi_controller core0 (
        .clk, .rst_n,
        .req_valid(req_valid[0]), .req_read(req_read[0]),
        .req_write(req_write[0]), .req_done(req_done[0]),
        .bus_shared(bus_shared[0]), .bus_grant(bus_grant[0]),
        .bus_valid(bus_valid[0]),
        .bus_cmd(bus_cmd[0]), .bus_req(bus_req[0]),
        .bus_cmd_out(bus_cmd_out[0]), .state(state[0])
    );

    mesi_controller core1 (
        .clk, .rst_n,
        .req_valid(req_valid[1]), .req_read(req_read[1]),
        .req_write(req_write[1]), .req_done(req_done[1]),
        .bus_shared(bus_shared[1]), .bus_grant(bus_grant[1]),
        .bus_valid(bus_valid[1]),
        .bus_cmd(bus_cmd[1]), .bus_req(bus_req[1]),
        .bus_cmd_out(bus_cmd_out[1]), .state(state[1])
    );

    task automatic tick;
        @(posedge clk);
        #1;
    endtask

    task automatic check_mesi_invariants;
        if ((state[0] == MESI_M && state[1] != MESI_I)
            || (state[1] == MESI_M && state[0] != MESI_I))
            $fatal(1, "MESI invariant failed: M must be the only valid copy");
        if ((state[0] == MESI_E && state[1] != MESI_I)
            || (state[1] == MESI_E && state[0] != MESI_I))
            $fatal(1, "MESI invariant failed: E must be the only valid copy");
    endtask

    task automatic clear_inputs;
        req_valid = '0;
        req_read = '0;
        req_write = '0;
        req_done = '0;
        bus_shared = '0;
        bus_grant = '0;
        bus_valid = '0;
        bus_cmd = '0;
    endtask

    initial begin
        cov_i_to_e = 0;
        cov_i_to_s = 0;
        cov_e_to_s = 0;
        cov_s_to_m = 0;
        cov_s_to_i = 0;
        cov_i_to_m = 0;
        cov_m_to_i = 0;
        cov_m_to_s = 0;
        clear_inputs();
        tick();
        if (state[0] !== MESI_I || state[1] !== MESI_I)
            $fatal(1, "Reset must initialize both lines to I");

        @(negedge clk);
        rst_n = 1'b1;
        req_valid[0] = 1'b1;
        req_read[0] = 1'b1;
        #1;
        if (!bus_req[0] || bus_cmd_out[0] !== BUS_RD)
            $fatal(1, "I-state read must request BusRd");
        bus_grant[0] = 1'b1;
        tick();
        if (state[0] !== MESI_I)
            $fatal(1, "A granted BusRd must wait for its data response");
        @(negedge clk);
        bus_grant[0] = 1'b0;
        #1;
        if (bus_req[0])
            $fatal(1, "A granted bus request must not be reissued while data is pending");
        req_done[0] = 1'b1;
        bus_shared[0] = 1'b0;
        tick();
        if (state[0] !== MESI_E)
            $fatal(1, "Unshared BusRd must enter E");
        check_mesi_invariants();
        cov_i_to_e = cov_i_to_e + 1;

        @(negedge clk);
        clear_inputs();
        req_valid[1] = 1'b1;
        req_read[1] = 1'b1;
        #1;
        if (!bus_req[1] || bus_cmd_out[1] !== BUS_RD)
            $fatal(1, "Second I-state read must request BusRd");
        bus_valid[0] = 1'b1;
        bus_cmd[0] = BUS_RD;
        bus_grant[1] = 1'b1;
        bus_shared[1] = 1'b1;
        tick();
        if (state[1] !== MESI_I)
            $fatal(1, "A shared BusRd must wait for its data response");
        @(negedge clk);
        bus_grant[1] = 1'b0;
        bus_shared[1] = 1'b0;
        bus_valid[0] = 1'b0;
        bus_cmd[0] = 2'b00;
        req_done[1] = 1'b1;
        tick();
        if (state[0] !== MESI_S || state[1] !== MESI_S)
            $fatal(1, "Shared BusRd must downgrade E and install S");
        check_mesi_invariants();
        cov_i_to_s = cov_i_to_s + 1;
        cov_e_to_s = cov_e_to_s + 1;

        @(negedge clk);
        clear_inputs();
        req_valid[0] = 1'b1;
        req_write[0] = 1'b1;
        #1;
        if (!bus_req[0] || bus_cmd_out[0] !== BUS_UPGR)
            $fatal(1, "S-state write must request BusUpgr");
        bus_valid[1] = 1'b1;
        bus_cmd[1] = BUS_UPGR;
        bus_grant[0] = 1'b1;
        req_done[0] = 1'b1;
        tick();
        if (state[0] !== MESI_M || state[1] !== MESI_I)
            $fatal(1, "BusUpgr must grant M and invalidate peer S");
        check_mesi_invariants();
        cov_s_to_m = cov_s_to_m + 1;
        cov_s_to_i = cov_s_to_i + 1;

        @(negedge clk);
        clear_inputs();
        req_valid[1] = 1'b1;
        req_write[1] = 1'b1;
        #1;
        if (!bus_req[1] || bus_cmd_out[1] !== BUS_RDX)
            $fatal(1, "I-state write must request BusRdX");
        bus_valid[0] = 1'b1;
        bus_cmd[0] = BUS_RDX;
        bus_grant[1] = 1'b1;
        req_done[1] = 1'b1;
        tick();
        if (state[0] !== MESI_I || state[1] !== MESI_M)
            $fatal(1, "BusRdX must transfer exclusive ownership to M");
        check_mesi_invariants();
        cov_i_to_m = cov_i_to_m + 1;
        cov_m_to_i = cov_m_to_i + 1;

        @(negedge clk);
        clear_inputs();
        req_valid[0] = 1'b1;
        req_read[0] = 1'b1;
        #1;
        if (!bus_req[0] || bus_cmd_out[0] !== BUS_RD)
            $fatal(1, "I-state read after write must request BusRd");
        bus_valid[1] = 1'b1;
        bus_cmd[1] = BUS_RD;
        bus_grant[0] = 1'b1;
        req_done[0] = 1'b1;
        bus_shared[0] = 1'b1;
        tick();
        if (state[0] !== MESI_S || state[1] !== MESI_S)
            $fatal(1, "BusRd must downgrade modified owner and grant S");
        check_mesi_invariants();
        cov_m_to_s = cov_m_to_s + 1;

        @(negedge clk);
        clear_inputs();
        req_valid[1] = 1'b1;
        req_write[1] = 1'b1;
        #1;
        if (!bus_req[1] || bus_cmd_out[1] !== BUS_UPGR)
            $fatal(1, "S-state write after downgrade must request BusUpgr");
        bus_grant[1] = 1'b1;
        req_done[1] = 1'b1;
        bus_valid[0] = 1'b1;
        bus_cmd[0] = BUS_UPGR;
        tick();
        if (state[1] !== MESI_M || state[0] !== MESI_I)
            $fatal(1, "BusUpgr must restore modified ownership before overlap test");

        @(negedge clk);
        clear_inputs();
        req_valid[1] = 1'b1;
        req_write[1] = 1'b1;
        req_done[1] = 1'b1;
        bus_valid[1] = 1'b1;
        bus_cmd[1] = BUS_RD;
        tick();
        if (state[1] !== MESI_S)
            $fatal(1, "A concurrent BusRd snoop must downgrade a completing M write");
        check_mesi_invariants();

        if (cov_i_to_e == 0 || cov_i_to_s == 0 || cov_e_to_s == 0
            || cov_s_to_m == 0 || cov_s_to_i == 0 || cov_i_to_m == 0
            || cov_m_to_i == 0 || cov_m_to_s == 0)
            $fatal(1, "MESI transition functional coverage is incomplete");
        $display("PASS: MESI reset, grant/response, snoop-overlap, and transition tests");
        $finish;
    end
endmodule
