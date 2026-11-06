`timescale 1ns/1ps

module mesi_2core_concurrent_tb;
    localparam logic [1:0] MESI_I = 2'b00;
    localparam logic [1:0] MESI_S = 2'b01;
    localparam logic [1:0] MESI_E = 2'b10;
    localparam logic [1:0] MESI_M = 2'b11;
    localparam logic [1:0] BUS_NONE = 2'b00;
    localparam logic [1:0] BUS_RD = 2'b01;
    localparam logic [1:0] BUS_RDX = 2'b10;
    localparam logic [1:0] BUS_UPGR = 2'b11;
    localparam integer MAX_TRANSACTIONS = 1024;
    localparam integer MAX_GRANTS = 4096;

    logic clk = 1'b0;
    logic rst_n = 1'b0;
    logic [1:0] req_valid;
    logic [1:0] req_read;
    logic [1:0] req_write;
    logic [1:0] req_done;
    logic [1:0] req_line;
    logic [63:0] req_write_data [0:1];
    logic [1:0] state [0:1][0:1];
    logic line_bus_req [0:1][0:1];
    logic [1:0] line_bus_cmd [0:1][0:1];
    logic line_bus_grant [0:1][0:1];
    logic line_bus_shared [0:1][0:1];
    logic snoop_valid [0:1][0:1];
    logic [1:0] snoop_cmd [0:1][0:1];

    logic [1:0] bus_request;
    logic [1:0][1:0] bus_request_cmd;
    logic grant_ready;
    logic grant_valid;
    logic grant_core;
    logic [1:0] grant_cmd;
    logic [3:0] wave_controller_bus_request;
    logic [3:0] wave_controller_bus_grant;
    logic [7:0] wave_controller_bus_command;
    logic [3:0] wave_snoop_valid;
    logic [7:0] wave_snoop_command;
    logic [7:0] wave_cache_state;

    logic [63:0] line_data [0:1][0:1];
    logic [1:0][63:0] backing_memory;
    logic [1:0][63:0] reference_memory;
    logic [1:0] reference_state [0:1][0:1];
    logic [63:0] reference_data [0:1][0:1];
    logic [63:0] response_data [0:1];
    logic response_shared [0:1];

    integer request_id [0:1];
    integer expected_command [0:1];
    integer accepted_for_transaction [0:MAX_TRANSACTIONS-1];
    integer completed [0:MAX_TRANSACTIONS-1];
    logic [63:0] result_data [0:MAX_TRANSACTIONS-1];
    logic [1:0] result_state [0:MAX_TRANSACTIONS-1];
    integer grant_order [0:MAX_GRANTS-1];
    integer grant_line_order [0:MAX_GRANTS-1];

    integer accepted_count [0:1];
    integer grant_log_count;
    integer issue_count;
    integer completion_count;
    integer expected_bus_count;
    integer invalidation_count;
    integer intervention_count;
    integer transaction_sequence;
    integer snoop_generation [0:1][0:1];
    integer cov_same_line_read_read;
    integer cov_same_line_read_write;
    integer cov_same_line_write_write;
    integer cov_different_line_pairs;
    integer cov_backpressure_cycles;
    integer cov_local_snoop_completion;
    integer cov_pending_reset_recovery;
    integer active_core;
    integer active_line;
    logic bus_active;
    logic hold_backpressure;
    integer log_file;
    logic [8*512-1:0] log_path;
    logic [8*512-1:0] wave_path;
    logic [8*24-1:0] selected_case;
    integer seed;
    integer random_pairs;
    logic [31:0] random_state;
    logic [31:0] random_value;
    integer core_index;
    integer line_index;
    integer peer_index;
    integer grant_base;
    integer transaction_id0;
    integer transaction_id1;
    integer random_line0;
    integer random_line1;
    integer random_write0;
    integer random_write1;
    logic [63:0] random_data0;
    logic [63:0] random_data1;

    always #5 clk = ~clk;

    mesi_controller core0_line0 (
        .clk(clk), .rst_n(rst_n),
        .req_valid(req_valid[0] && req_line[0] == 0),
        .req_read(req_read[0]), .req_write(req_write[0]),
        .req_done(req_done[0] && req_line[0] == 0),
        .bus_shared(line_bus_shared[0][0]), .bus_grant(line_bus_grant[0][0]),
        .bus_valid(snoop_valid[0][0]), .bus_cmd(snoop_cmd[0][0]),
        .bus_req(line_bus_req[0][0]), .bus_cmd_out(line_bus_cmd[0][0]),
        .state(state[0][0])
    );
    mesi_controller core1_line0 (
        .clk(clk), .rst_n(rst_n),
        .req_valid(req_valid[1] && req_line[1] == 0),
        .req_read(req_read[1]), .req_write(req_write[1]),
        .req_done(req_done[1] && req_line[1] == 0),
        .bus_shared(line_bus_shared[0][1]), .bus_grant(line_bus_grant[0][1]),
        .bus_valid(snoop_valid[0][1]), .bus_cmd(snoop_cmd[0][1]),
        .bus_req(line_bus_req[0][1]), .bus_cmd_out(line_bus_cmd[0][1]),
        .state(state[0][1])
    );
    mesi_controller core0_line1 (
        .clk(clk), .rst_n(rst_n),
        .req_valid(req_valid[0] && req_line[0] == 1),
        .req_read(req_read[0]), .req_write(req_write[0]),
        .req_done(req_done[0] && req_line[0] == 1),
        .bus_shared(line_bus_shared[1][0]), .bus_grant(line_bus_grant[1][0]),
        .bus_valid(snoop_valid[1][0]), .bus_cmd(snoop_cmd[1][0]),
        .bus_req(line_bus_req[1][0]), .bus_cmd_out(line_bus_cmd[1][0]),
        .state(state[1][0])
    );
    mesi_controller core1_line1 (
        .clk(clk), .rst_n(rst_n),
        .req_valid(req_valid[1] && req_line[1] == 1),
        .req_read(req_read[1]), .req_write(req_write[1]),
        .req_done(req_done[1] && req_line[1] == 1),
        .bus_shared(line_bus_shared[1][1]), .bus_grant(line_bus_grant[1][1]),
        .bus_valid(snoop_valid[1][1]), .bus_cmd(snoop_cmd[1][1]),
        .bus_req(line_bus_req[1][1]), .bus_cmd_out(line_bus_cmd[1][1]),
        .state(state[1][1])
    );

    mesi_bus_arbiter #(.CORE_COUNT(2)) shared_bus (
        .clk(clk),
        .rst_n(rst_n),
        .request_valid(bus_request),
        .request_cmd(bus_request_cmd),
        .grant_ready(grant_ready),
        .grant_valid(grant_valid),
        .grant_core(grant_core),
        .grant_cmd(grant_cmd)
    );

    always_comb begin
        bus_request = '0;
        bus_request_cmd = '0;
        for (integer c = 0; c < 2; c = c + 1) begin
            if (req_valid[c]) begin
                bus_request[c] = line_bus_req[req_line[c]][c];
                bus_request_cmd[c] = line_bus_cmd[req_line[c]][c];
            end
        end
    end

    always_comb begin
        for (integer line = 0; line < 2; line = line + 1) begin
            for (integer core = 0; core < 2; core = core + 1) begin
                line_bus_grant[line][core] = 1'b0;
                line_bus_shared[line][core] = 1'b0;
                snoop_valid[line][core] = 1'b0;
                snoop_cmd[line][core] = BUS_NONE;
                wave_controller_bus_request[line * 2 + core] =
                    line_bus_req[line][core];
                wave_controller_bus_grant[line * 2 + core] =
                    line_bus_grant[line][core];
                wave_controller_bus_command[(line * 2 + core) * 2 +: 2] =
                    line_bus_cmd[line][core];
                wave_snoop_valid[line * 2 + core] = snoop_valid[line][core];
                wave_snoop_command[(line * 2 + core) * 2 +: 2] =
                    snoop_cmd[line][core];
                wave_cache_state[(line * 2 + core) * 2 +: 2] =
                    state[line][core];
            end
        end
        if (grant_valid && grant_ready) begin
            line_bus_grant[req_line[grant_core]][grant_core] = 1'b1;
            line_bus_shared[req_line[grant_core]][grant_core] =
                state[req_line[grant_core]][1 - grant_core] != MESI_I;
            snoop_valid[req_line[grant_core]][1 - grant_core] = 1'b1;
            snoop_cmd[req_line[grant_core]][1 - grant_core] = grant_cmd;
        end
    end

    always @(negedge clk) begin
        grant_ready = rst_n && !bus_active && !hold_backpressure;
    end

    always @(negedge clk) begin
        if (rst_n) begin
            for (integer line = 0; line < 2; line = line + 1) begin
                assert (!(state[line][0] == MESI_M && state[line][1] != MESI_I))
                    else $fatal(1, "M ownership is not exclusive on line=%0d", line);
                assert (!(state[line][1] == MESI_M && state[line][0] != MESI_I))
                    else $fatal(1, "M ownership is not exclusive on line=%0d", line);
                assert (!(state[line][0] == MESI_E && state[line][1] != MESI_I))
                    else $fatal(1, "E ownership is not exclusive on line=%0d", line);
                assert (!(state[line][1] == MESI_E && state[line][0] != MESI_I))
                    else $fatal(1, "E ownership is not exclusive on line=%0d", line);
                if (state[line][0] != MESI_I && state[line][1] != MESI_I)
                    assert (line_data[line][0] === line_data[line][1])
                        else $fatal(1, "Shared data diverged on line=%0d", line);
            end
        end
    end

    function automatic integer command_for(
        input logic [1:0] mesi_state,
        input logic is_read
    );
        begin
            if (is_read)
                command_for = mesi_state == MESI_I ? BUS_RD : BUS_NONE;
            else if (mesi_state == MESI_I)
                command_for = BUS_RDX;
            else if (mesi_state == MESI_S)
                command_for = BUS_UPGR;
            else
                command_for = BUS_NONE;
        end
    endfunction

    function automatic [7:0] state_name(input logic [1:0] value);
        case (value)
            MESI_I: state_name = "I";
            MESI_S: state_name = "S";
            MESI_E: state_name = "E";
            MESI_M: state_name = "M";
            default: state_name = "?";
        endcase
    endfunction

    task automatic check_invariants;
        integer l;
        integer c;
        integer valid_count;
        begin
            for (l = 0; l < 2; l = l + 1) begin
                valid_count = 0;
                for (c = 0; c < 2; c = c + 1) begin
                    if (state[l][c] !== reference_state[l][c])
                        $fatal(1, "State scoreboard mismatch line=%0d core=%0d expected=%s actual=%s",
                               l, c, state_name(reference_state[l][c]), state_name(state[l][c]));
                    if (state[l][c] != MESI_I) begin
                        valid_count = valid_count + 1;
                        if (line_data[l][c] !== reference_data[l][c])
                            $fatal(1, "Data scoreboard mismatch line=%0d core=%0d expected=%h actual=%h",
                                   l, c, reference_data[l][c], line_data[l][c]);
                    end
                end
                if (state[l][0] == MESI_M && valid_count != 1)
                    $fatal(1, "Modified ownership invariant failed on line %0d", l);
                if (state[l][1] == MESI_M && valid_count != 1)
                    $fatal(1, "Modified ownership invariant failed on line %0d", l);
                if ((state[l][0] == MESI_E && valid_count != 1)
                    || (state[l][1] == MESI_E && valid_count != 1))
                    $fatal(1, "Exclusive ownership invariant failed on line %0d", l);
                if (state[l][0] != MESI_I && state[l][1] != MESI_I
                    && line_data[l][0] !== line_data[l][1])
                    $fatal(1, "Shared-copy data mismatch on line %0d", l);
            end
        end
    endtask

    always @(posedge clk) begin
        if (!rst_n) begin
            bus_active = 1'b0;
        end else begin
            if (grant_valid && grant_ready) begin
                if (bus_active)
                    $fatal(1, "Arbiter accepted a second bus request while one was active");
                core_index = grant_core;
                line_index = req_line[core_index];
                peer_index = 1 - core_index;
                if (!req_valid[core_index] || !bus_request[core_index])
                    $fatal(1, "Accepted a grant without a live core request");
                if (req_valid[peer_index] && req_done[peer_index]
                    && req_line[peer_index] == line_index)
                    cov_local_snoop_completion = cov_local_snoop_completion + 1;
                if (line_bus_cmd[line_index][core_index] != expected_command[core_index])
                    $fatal(1, "Wrong command txn=%0d core=%0d line=%0d expected=%0d actual=%0d",
                           request_id[core_index], core_index, line_index,
                           expected_command[core_index], line_bus_cmd[line_index][core_index]);
                if (line_bus_shared[line_index][core_index]
                    !== (reference_state[line_index][peer_index] != MESI_I))
                    $fatal(1, "Shared response disagrees with reference model txn=%0d",
                           request_id[core_index]);

                if (req_valid[peer_index] && req_done[peer_index]
                    && req_write[peer_index] && req_line[peer_index] == line_index) begin
                    response_data[core_index] = req_write_data[peer_index];
                    reference_data[line_index][peer_index] = req_write_data[peer_index];
                end else if (reference_state[line_index][peer_index] != MESI_I) begin
                    response_data[core_index] = reference_data[line_index][peer_index];
                end
                else
                    response_data[core_index] = reference_memory[line_index];
                response_shared[core_index] =
                    reference_state[line_index][peer_index] != MESI_I;
                snoop_generation[line_index][peer_index] =
                    snoop_generation[line_index][peer_index] + 1;

                if (grant_cmd == BUS_RD) begin
                    if (reference_state[line_index][peer_index] == MESI_M)
                        intervention_count = intervention_count + 1;
                    if (reference_state[line_index][peer_index] == MESI_M
                        || reference_state[line_index][peer_index] == MESI_E)
                        reference_state[line_index][peer_index] = MESI_S;
                end else if (grant_cmd == BUS_RDX || grant_cmd == BUS_UPGR) begin
                    if (reference_state[line_index][peer_index] != MESI_I)
                        invalidation_count = invalidation_count + 1;
                    reference_state[line_index][peer_index] = MESI_I;
                    if (req_valid[peer_index] && req_line[peer_index] == line_index
                        && expected_command[peer_index] == BUS_UPGR)
                        expected_command[peer_index] = BUS_RDX;
                end

                if (accepted_for_transaction[request_id[core_index]] != 0)
                    $fatal(1, "Duplicate bus grant for transaction %0d",
                           request_id[core_index]);
                accepted_for_transaction[request_id[core_index]] =
                    accepted_for_transaction[request_id[core_index]] + 1;
                accepted_count[core_index] = accepted_count[core_index] + 1;
                grant_order[grant_log_count] = core_index;
                grant_line_order[grant_log_count] = line_index;
                grant_log_count = grant_log_count + 1;
                bus_active = 1'b1;
                active_core = core_index;
                active_line = line_index;
                if (log_file != 0)
                    $fdisplay(log_file,
                              "BUS_ACCEPT grant=%0d txn=%0d core=%0d line=%0d cmd=%0d shared=%0d response=%016h",
                              grant_log_count - 1, request_id[core_index], core_index,
                              line_index, grant_cmd, response_shared[core_index],
                              response_data[core_index]);
            end

            if (bus_active && req_valid[active_core] && req_done[active_core])
                bus_active = 1'b0;
        end
    end

    task automatic perform_request(
        input integer txn_id,
        input integer core,
        input integer line,
        input integer is_write,
        input logic [63:0] write_value
    );
        integer grants_before;
        integer waits;
        integer required_command;
        integer snoops_before_completion;
        logic [63:0] read_value;
        logic [1:0] expected_final_state;
        begin
            if (txn_id < 0 || txn_id >= MAX_TRANSACTIONS)
                $fatal(1, "Transaction id outside supported range");
            if (completed[txn_id] != 0 || accepted_for_transaction[txn_id] != 0)
                $fatal(1, "Transaction id %0d was reused", txn_id);
            if (req_valid[core])
                $fatal(1, "Core %0d was issued a second outstanding request", core);

            required_command = command_for(reference_state[line][core], !is_write);
            expected_command[core] = required_command;
            grants_before = accepted_count[core];
            request_id[core] = txn_id;
            req_line[core] = line;
            req_read[core] = !is_write;
            req_write[core] = is_write;
            req_write_data[core] = write_value;
            req_done[core] = 1'b0;

            @(negedge clk);
            req_valid[core] = 1'b1;
            issue_count = issue_count + 1;
            if (required_command != BUS_NONE)
                expected_bus_count = expected_bus_count + 1;
            if (log_file != 0)
                $fdisplay(log_file,
                          "TXN_ISSUE txn=%0d core=%0d line=%0d op=%s write_data=%016h state=%s",
                          txn_id, core, line, is_write ? "W" : "R", write_value,
                          state_name(reference_state[line][core]));

            if (required_command != BUS_NONE) begin
                waits = 0;
                while (accepted_count[core] == grants_before && waits < 200) begin
                    @(posedge clk);
                    #1;
                    waits = waits + 1;
                end
                if (accepted_count[core] == grants_before)
                    $fatal(1, "Timed out waiting for grant txn=%0d core=%0d line=%0d",
                           txn_id, core, line);
                @(negedge clk);
            end
            read_value = is_write ? write_value
                : (required_command != BUS_NONE
                    ? response_data[core] : reference_data[line][core]);
            snoops_before_completion = snoop_generation[line][core];
            req_done[core] = 1'b1;
            @(posedge clk);
            #1;

            if (is_write) begin
                if (snoop_generation[line][core] == snoops_before_completion)
                    reference_state[line][core] = MESI_M;
                reference_data[line][core] = write_value;
                line_data[line][core] = write_value;
                expected_final_state = reference_state[line][core];
            end else begin
                if (required_command != BUS_NONE) begin
                    reference_state[line][core] =
                        response_shared[core] ? MESI_S : MESI_E;
                    reference_data[line][core] = response_data[core];
                    line_data[line][core] = response_data[core];
                end
                read_value = line_data[line][core];
                expected_final_state = reference_state[line][core];
            end

            if (state[line][core] !== expected_final_state)
                $fatal(1, "Completion state mismatch txn=%0d core=%0d line=%0d expected=%s actual=%s",
                       txn_id, core, line, state_name(expected_final_state),
                       state_name(state[line][core]));
            if (!is_write && line_data[line][core] !== reference_data[line][core])
                $fatal(1, "Read data mismatch txn=%0d core=%0d line=%0d expected=%h actual=%h",
                       txn_id, core, line, reference_data[line][core], line_data[line][core]);
            if (required_command == BUS_NONE
                && accepted_count[core] != grants_before)
                $fatal(1, "Local hit incorrectly consumed a bus grant txn=%0d", txn_id);
            if (required_command != BUS_NONE
                && accepted_for_transaction[txn_id] != 1)
                $fatal(1, "Request was lost or granted more than once txn=%0d", txn_id);

            result_data[txn_id] = read_value;
            result_state[txn_id] = state[line][core];
            completed[txn_id] = completed[txn_id] + 1;
            completion_count = completion_count + 1;
            if (log_file != 0)
                $fdisplay(log_file,
                          "TXN_DONE txn=%0d core=%0d line=%0d op=%s state=%s data=%016h",
                          txn_id, core, line, is_write ? "W" : "R",
                          state_name(result_state[txn_id]), result_data[txn_id]);
            if (completed[txn_id] != 1)
                $fatal(1, "Transaction %0d completed more than once", txn_id);

            @(negedge clk);
            req_valid[core] = 1'b0;
            req_read[core] = 1'b0;
            req_write[core] = 1'b0;
            req_done[core] = 1'b0;
            #1;
            check_invariants();
        end
    endtask

    task automatic reset_case(
        input logic [63:0] initial_line0,
        input logic [63:0] initial_line1
    );
        begin
            @(negedge clk);
            rst_n = 1'b0;
            req_valid = '0;
            req_read = '0;
            req_write = '0;
            req_done = '0;
            hold_backpressure = 1'b0;
            backing_memory[0] = initial_line0;
            backing_memory[1] = initial_line1;
            reference_memory[0] = initial_line0;
            reference_memory[1] = initial_line1;
            for (integer l = 0; l < 2; l = l + 1) begin
                for (integer c = 0; c < 2; c = c + 1) begin
                    reference_state[l][c] = MESI_I;
                    reference_data[l][c] = l == 0 ? initial_line0 : initial_line1;
                    line_data[l][c] = l == 0 ? initial_line0 : initial_line1;
                    snoop_generation[l][c] = 0;
                end
            end
            repeat (2) @(posedge clk);
            #1;
            for (integer l = 0; l < 2; l = l + 1)
                for (integer c = 0; c < 2; c = c + 1)
                    if (state[l][c] !== MESI_I)
                        $fatal(1, "Reset did not invalidate line=%0d core=%0d", l, c);
            @(negedge clk);
            rst_n = 1'b1;
            @(posedge clk);
            #1;
        end
    endtask

    task automatic run_pair(
        input integer line0,
        input integer write0,
        input logic [63:0] value0,
        input integer line1,
        input integer write1,
        input logic [63:0] value1,
        input integer stall_cycles
    );
        integer id0;
        integer id1;
        integer stable_core;
        logic [1:0] stable_command;
        begin
            id0 = transaction_sequence;
            id1 = transaction_sequence + 1;
            transaction_sequence = transaction_sequence + 2;
            if (line0 != line1)
                cov_different_line_pairs = cov_different_line_pairs + 1;
            else if (!write0 && !write1)
                cov_same_line_read_read = cov_same_line_read_read + 1;
            else if (write0 && write1)
                cov_same_line_write_write = cov_same_line_write_write + 1;
            else
                cov_same_line_read_write = cov_same_line_read_write + 1;
            if (stall_cycles > 0)
                cov_backpressure_cycles = cov_backpressure_cycles + stall_cycles;
            if (stall_cycles > 0) begin
                hold_backpressure = 1'b1;
                fork
                    perform_request(id0, 0, line0, write0, value0);
                    perform_request(id1, 1, line1, write1, value1);
                    begin
                        waits_for_grant: begin
                            integer guard;
                            guard = 0;
                            while (!grant_valid && guard < 100) begin
                                @(posedge clk);
                                #1;
                                guard = guard + 1;
                            end
                            if (!grant_valid)
                                $fatal(1, "No grant became visible during backpressure test");
                            stable_core = grant_core;
                            stable_command = grant_cmd;
                            repeat (stall_cycles) begin
                                @(posedge clk);
                                #1;
                                if (!grant_valid || grant_core != stable_core
                                    || grant_cmd != stable_command)
                                    $fatal(1, "Grant changed while backpressured");
                            end
                            hold_backpressure = 1'b0;
                        end
                    end
                join
            end else begin
                fork
                    perform_request(id0, 0, line0, write0, value0);
                    perform_request(id1, 1, line1, write1, value1);
                join
            end
            if (completed[id0] != 1 || completed[id1] != 1)
                $fatal(1, "Concurrent pair lost a completion id0=%0d id1=%0d", id0, id1);
        end
    endtask

    task automatic run_single(
        input integer core,
        input integer line,
        input integer is_write,
        input logic [63:0] value
    );
        integer id;
        begin
            id = transaction_sequence;
            transaction_sequence = transaction_sequence + 1;
            perform_request(id, core, line, is_write, value);
            if (completed[id] != 1)
                $fatal(1, "Single request did not complete id=%0d", id);
        end
    endtask

    task automatic run_reset_pending;
        integer txn_id;
        integer grants_before;
        integer waits;
        begin
            reset_case(64'h0, 64'h0);
            txn_id = transaction_sequence;
            request_id[0] = txn_id;
            expected_command[0] = BUS_RD;
            req_line[0] = 0;
            req_read[0] = 1'b1;
            req_write[0] = 1'b0;
            req_done[0] = 1'b0;
            grants_before = grant_log_count;
            hold_backpressure = 1'b1;

            @(negedge clk);
            req_valid[0] = 1'b1;
            waits = 0;
            while ((!grant_valid || !bus_request[0]) && waits < 50) begin
                @(posedge clk);
                #1;
                waits = waits + 1;
            end
            if (!grant_valid || !bus_request[0] || grant_ready)
                $fatal(1, "Reset test did not reach a stalled, unaccepted request");
            repeat (2) begin
                @(posedge clk);
                #1;
                if (!grant_valid || grant_ready || grant_log_count != grants_before)
                    $fatal(1, "Stalled request was accepted before reset");
            end

            if (log_file != 0)
                $fdisplay(log_file, "RESET_ABORT txn=%0d core=0 line=0 accepted=0", txn_id);
            @(negedge clk);
            rst_n = 1'b0;
            req_valid[0] = 1'b0;
            req_read[0] = 1'b0;
            req_write[0] = 1'b0;
            req_done[0] = 1'b0;
            hold_backpressure = 1'b0;
            #1;
            if (bus_request != '0 || grant_valid || bus_active)
                $fatal(1, "Reset did not cancel the unaccepted request");
            repeat (2) @(posedge clk);
            #1;
            for (integer line = 0; line < 2; line = line + 1)
                for (integer core = 0; core < 2; core = core + 1)
                    if (state[line][core] !== MESI_I)
                        $fatal(1, "Reset recovery left a valid line=%0d core=%0d",
                               line, core);
            if (grant_log_count != grants_before)
                $fatal(1, "Reset test unexpectedly observed an accepted grant");

            @(negedge clk);
            rst_n = 1'b1;
            @(posedge clk);
            #1;
            cov_pending_reset_recovery = cov_pending_reset_recovery + 1;
            run_single(0, 0, 0, 64'h0);
        end
    endtask

    task automatic advance_random;
        begin
            random_state = random_state ^ (random_state << 13);
            random_state = random_state ^ (random_state >> 17);
            random_state = random_state ^ (random_state << 5);
            random_value = random_state;
        end
    endtask

    initial begin
        req_valid = '0;
        req_read = '0;
        req_write = '0;
        req_done = '0;
        req_line = '0;
        req_write_data[0] = '0;
        req_write_data[1] = '0;
        for (line_index = 0; line_index < 2; line_index = line_index + 1) begin
            for (core_index = 0; core_index < 2; core_index = core_index + 1) begin
                line_data[line_index][core_index] = '0;
                reference_state[line_index][core_index] = MESI_I;
                reference_data[line_index][core_index] = '0;
                snoop_generation[line_index][core_index] = 0;
            end
        end
        backing_memory = '0;
        reference_memory = '0;
        accepted_count[0] = 0;
        accepted_count[1] = 0;
        grant_log_count = 0;
        issue_count = 0;
        completion_count = 0;
        expected_bus_count = 0;
        invalidation_count = 0;
        intervention_count = 0;
        transaction_sequence = 0;
        cov_same_line_read_read = 0;
        cov_same_line_read_write = 0;
        cov_same_line_write_write = 0;
        cov_different_line_pairs = 0;
        cov_backpressure_cycles = 0;
        cov_local_snoop_completion = 0;
        cov_pending_reset_recovery = 0;
        bus_active = 1'b0;
        hold_backpressure = 1'b0;
        grant_ready = 1'b0;
        log_file = 0;
        seed = 32'h5EED1234;
        random_pairs = 100;
        selected_case = "all";
        log_path = '0;
        wave_path = '0;
        if ($value$plusargs("SEED=%d", seed)) begin
        end
        if ($value$plusargs("PAIRS=%d", random_pairs)) begin
        end
        if ($value$plusargs("CASE=%s", selected_case)) begin
        end
        if ($value$plusargs("LOG=%s", log_path)) begin
            log_file = $fopen(log_path, "w");
            if (log_file == 0)
                $fatal(1, "Could not open requested transaction log");
        end
        if ($value$plusargs("WAVE=%s", wave_path)) begin
            $dumpfile(wave_path);
            $dumpvars(0, mesi_2core_concurrent_tb);
        end
        if (seed == 0)
            seed = 32'h1;
        random_state = seed;
        for (integer id = 0; id < MAX_TRANSACTIONS; id = id + 1) begin
            accepted_for_transaction[id] = 0;
            completed[id] = 0;
            result_data[id] = '0;
            result_state[id] = MESI_I;
        end

        if (selected_case == "read_miss") begin
            reset_case(64'h0, 64'h0);
            run_single(0, 0, 0, 64'h0);
        end else if (selected_case == "write_invalidation") begin
            reset_case(64'h0, 64'h0);
            run_pair(0, 0, 64'h0, 0, 0, 64'h0, 0);
            run_single(1, 0, 1, 64'hCAFE0001);
        end else if (selected_case == "modified_intervention") begin
            reset_case(64'h0, 64'h0);
            run_single(0, 0, 1, 64'hCAFE0002);
            run_single(1, 0, 0, 64'h0);
            if (state[0][0] != MESI_S || state[0][1] != MESI_S
                || line_data[0][0] != 64'hCAFE0002
                || line_data[0][1] != 64'hCAFE0002
                || intervention_count != 1)
                $fatal(1, "Modified-owner intervention failed to forward the latest data");
        end else if (selected_case == "simultaneous") begin
            reset_case(64'h0, 64'h0);
            run_pair(0, 0, 64'h0, 0, 0, 64'h0, 0);
        end else if (selected_case == "backpressure") begin
            reset_case(64'h0, 64'h0);
            run_pair(0, 0, 64'h0, 1, 0, 64'h0, 4);
        end else if (selected_case == "completion") begin
            reset_case(64'h0, 64'h0);
            run_single(0, 0, 0, 64'h0);
            run_single(0, 0, 1, 64'hBEEF0002);
        end else if (selected_case == "reset_pending") begin
            run_reset_pending();
        end else if (selected_case == "all") begin
            reset_case(64'h0, 64'h0);
            grant_base = grant_log_count;
            run_pair(0, 0, 64'h0, 0, 0, 64'h0, 0);
            if (grant_order[grant_base] != 0 || grant_order[grant_base + 1] != 1)
                $fatal(1, "Round-robin fairness failed for simultaneous same-line readers");
            if (state[0][0] != MESI_S || state[0][1] != MESI_S)
                $fatal(1, "Concurrent Read/Read did not establish two shared copies");

            reset_case(64'h0, 64'h0);
            run_pair(0, 0, 64'h0, 0, 1, 64'hA11CE001, 0);
            check_invariants();

            reset_case(64'h0, 64'h0);
            run_pair(0, 1, 64'h11110001, 0, 1, 64'h22220002, 0);
            if (state[0][1] != MESI_M || line_data[0][1] != 64'h22220002)
                $fatal(1, "Concurrent Write/Write did not serialize to the latest owner");

            reset_case(64'h0, 64'h0);
            run_pair(0, 0, 64'h0, 1, 0, 64'h0, 0);
            if (state[0][0] != MESI_E || state[1][1] != MESI_E)
                $fatal(1, "Different-line simultaneous reads should acquire E independently");

            reset_case(64'h0, 64'h0);
            run_pair(0, 0, 64'h0, 1, 0, 64'h0, 4);

            reset_case(64'h0, 64'h0);
            run_single(0, 0, 1, 64'hCAFE1000);
            run_pair(0, 1, 64'hCAFE2000, 0, 0, 64'h0, 0);
            if (state[0][0] != MESI_S || state[0][1] != MESI_S
                || line_data[0][0] != 64'hCAFE2000
                || line_data[0][1] != 64'hCAFE2000)
                $fatal(1, "Simultaneous local write and BusRd did not forward new data");

            run_reset_pending();
            random_state = seed;
            for (integer pair_index = 0; pair_index < random_pairs; pair_index = pair_index + 1) begin
                advance_random();
                random_line0 = random_value[0];
                random_write0 = random_value[1];
                random_data0 = {32'hA5A50000 | pair_index[31:0], random_value};
                advance_random();
                random_line1 = random_value[0];
                random_write1 = random_value[1];
                random_data1 = {32'h5A5A0000 | pair_index[31:0], random_value};
                run_pair(random_line0, random_write0, random_data0,
                         random_line1, random_write1, random_data1, 0);
            end
        end else begin
            $fatal(1, "Unknown CASE=%s", selected_case);
        end

        if (issue_count != completion_count)
            $fatal(1, "Lost request: issued=%0d completed=%0d", issue_count, completion_count);
        if (grant_log_count < expected_bus_count)
            $fatal(1, "Lost accepted bus request: accepted=%0d expected=%0d",
                   grant_log_count, expected_bus_count);
        $display("COVERAGE same_line_RR=%0d same_line_RW=%0d same_line_WW=%0d different_line_pairs=%0d backpressure_cycles=%0d snoop_local_completion=%0d pending_reset_recovery=%0d",
                 cov_same_line_read_read, cov_same_line_read_write,
                 cov_same_line_write_write, cov_different_line_pairs,
                 cov_backpressure_cycles, cov_local_snoop_completion,
                 cov_pending_reset_recovery);
        if (selected_case == "all") begin
            if (cov_same_line_read_read == 0 || cov_same_line_read_write == 0
                || cov_same_line_write_write == 0 || cov_different_line_pairs == 0
                || cov_backpressure_cycles == 0 || cov_local_snoop_completion == 0
                || cov_pending_reset_recovery == 0)
                $fatal(1, "Directed concurrent functional coverage has gaps");
            $display("COVERAGE_GAPS: none for directed concurrent coverage objectives");
        end else begin
            $display("COVERAGE_GAPS: full-suite objectives not selected in CASE=%s",
                     selected_case);
        end
        check_invariants();
        if (log_file != 0) begin
            $fdisplay(log_file,
                      "SUMMARY seed=%0d issued=%0d completed=%0d grants=%0d invalidations=%0d interventions=%0d",
                      seed, issue_count, completion_count, grant_log_count,
                      invalidation_count, intervention_count);
            $fclose(log_file);
        end
        $display("PASS: concurrent MESI CASE=%s seed=%0d issued=%0d completed=%0d grants=%0d invalidations=%0d interventions=%0d",
                 selected_case, seed, issue_count, completion_count, grant_log_count,
                 invalidation_count, intervention_count);
        $finish;
    end

    initial begin
        #1000000;
        $fatal(1, "Concurrent verification watchdog expired");
    end
endmodule
