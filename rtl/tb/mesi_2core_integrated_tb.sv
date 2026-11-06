`timescale 1ns/1ps

module mesi_2core_integrated_tb;
    localparam logic [1:0] MESI_I = 2'b00;
    localparam logic [1:0] MESI_S = 2'b01;
    localparam logic [1:0] MESI_E = 2'b10;
    localparam logic [1:0] MESI_M = 2'b11;

    localparam logic [1:0] BUS_NONE = 2'b00;
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
    logic [1:0] bus_valid;
    logic [1:0][1:0] bus_cmd;
    logic [1:0] bus_req;
    logic [1:0][1:0] bus_cmd_out;
    logic [1:0][1:0] state;
    logic grant_valid;
    logic grant_ready;
    logic grant_core;
    logic [1:0] grant_cmd;

    logic [1:0][63:0] line_data;
    logic [63:0] backing_memory;
    logic [63:0] reference_value;
    logic [63:0] response_data;
    logic [63:0] last_read_value;
    logic [63:0] write_value;
    logic [63:0] rng_state;
    logic peer_shared;
    integer peer;
    integer current_core;
    integer operation_is_write;
    integer transaction_count;
    integer invalidation_count;
    integer intervention_count;
    integer grant_count [0:1];
    integer state_coverage [0:1][0:3];
    integer transition_coverage [0:3][0:3];
    integer cycle_count;
    integer trace_file;
    integer scan_status;
    integer trace_core;
    integer trace_index;
    logic [7:0] trace_operation;
    logic [8*256-1:0] trace_line;
    logic [8*512-1:0] trace_path;
    integer trace_address;
    logic [63:0] trace_value;
    logic [1:0] old_state [0:1];
    logic [1:0] final_state;
    logic [63:0] final_value;
    integer core_index;
    integer seed;

    always #5 clk = ~clk;

    mesi_coherence_fabric #(.CORE_COUNT(2)) shared_fabric (
        .clk(clk),
        .rst_n(rst_n),
        .req_valid(req_valid),
        .req_read(req_read),
        .req_write(req_write),
        .req_done(req_done),
        .bus_ready(grant_ready),
        .bus_req(bus_req),
        .bus_cmd_out(bus_cmd_out),
        .state(state),
        .bus_grant(bus_grant),
        .bus_shared(bus_shared),
        .snoop_valid(bus_valid),
        .snoop_cmd(bus_cmd),
        .grant_valid(grant_valid),
        .grant_core(grant_core),
        .grant_cmd(grant_cmd)
    );

    task automatic check_invariants;
        if ((state[0] == MESI_M && state[1] != MESI_I)
            || (state[1] == MESI_M && state[0] != MESI_I))
            $fatal(1, "MESI invariant: M must be the only valid copy");
        if ((state[0] == MESI_E && state[1] != MESI_I)
            || (state[1] == MESI_E && state[0] != MESI_I))
            $fatal(1, "MESI invariant: E must be the only valid copy");
        if (state[0] != MESI_I && state[1] != MESI_I
            && line_data[0] !== line_data[1])
            $fatal(1, "MESI invariant: shared copies contain different data");
    endtask

    task automatic reset_pair(input logic [63:0] initial_memory);
        @(negedge clk);
        rst_n = 1'b0;
        req_valid = '0;
        req_read = '0;
        req_write = '0;
        req_done = '0;
        grant_ready = 1'b0;
        line_data[0] = initial_memory;
        line_data[1] = initial_memory;
        backing_memory = initial_memory;
        reference_value = initial_memory;
        repeat (2) @(posedge clk);
        #1;
        if (state[0] !== MESI_I || state[1] !== MESI_I)
            $fatal(1, "Reset failed to invalidate both private caches");
        @(negedge clk);
        rst_n = 1'b1;
        @(posedge clk);
        #1;
    endtask

    task automatic transact(
        input integer core_id,
        input integer is_write,
        input logic [63:0] store_value,
        input integer check_scoreboard,
        output logic [63:0] returned_value
    );
        integer peer_id;
        integer wait_cycles;
        logic needs_bus;
        logic [63:0] data_response;
        logic [1:0] command;
        begin
            if (core_id < 0 || core_id > 1)
                $fatal(1, "Invalid core id %0d", core_id);
            peer_id = 1 - core_id;
            old_state[0] = state[0];
            old_state[1] = state[1];
            operation_is_write = is_write;
            write_value = store_value;
            returned_value = 64'b0;

            @(negedge clk);
            req_valid[core_id] = 1'b1;
            req_read[core_id] = !is_write;
            req_write[core_id] = is_write;
            req_done[core_id] = 1'b0;
            grant_ready = 1'b0;

            needs_bus = (!is_write && state[core_id] == MESI_I)
                || (is_write && (state[core_id] == MESI_I || state[core_id] == MESI_S));
            if (needs_bus) begin
                wait_cycles = 0;
                while (bus_req[core_id] !== 1'b1 && wait_cycles < 20) begin
                    @(posedge clk);
                    #1;
                    wait_cycles = wait_cycles + 1;
                end
                if (wait_cycles >= 20)
                    $fatal(1, "Core %0d did not issue expected bus request", core_id);
                wait_cycles = 0;
                while ((!grant_valid || grant_core != core_id) && wait_cycles < 20) begin
                    @(posedge clk);
                    #1;
                    wait_cycles = wait_cycles + 1;
                end
                if (wait_cycles >= 20)
                    $fatal(1, "Core %0d was not granted the shared bus", core_id);

                command = grant_cmd;
                if (command == BUS_NONE)
                    $fatal(1, "Granted coherence request has no bus command");
                if ((!is_write && command != BUS_RD)
                    || (is_write && state[core_id] == MESI_I && command != BUS_RDX)
                    || (is_write && state[core_id] == MESI_S && command != BUS_UPGR))
                    $fatal(1, "Controller requested the wrong command for its MESI state");
                peer_shared = state[peer_id] != MESI_I;
                if (state[peer_id] == MESI_M) begin
                    data_response = line_data[peer_id];
                    intervention_count = intervention_count + 1;
                end else begin
                    data_response = backing_memory;
                end

                @(negedge clk);
                grant_ready = 1'b1;
                @(posedge clk);
                if (bus_grant[core_id] !== 1'b1)
                    $fatal(1, "Arbiter handshake did not grant core %0d", core_id);
                grant_count[core_id] = grant_count[core_id] + 1;
                if ((command == BUS_RDX || command == BUS_UPGR) && peer_shared)
                    invalidation_count = invalidation_count + 1;
                @(negedge clk);
                grant_ready = 1'b0;
            end else if (!is_write && state[core_id] != MESI_I) begin
                data_response = line_data[core_id];
            end else begin
                data_response = backing_memory;
            end

            if (!is_write)
                line_data[core_id] = data_response;
            else
                line_data[core_id] = store_value;
            req_done[core_id] = 1'b1;
            @(posedge clk);
            #1;
            returned_value = is_write ? store_value : line_data[core_id];

            if (is_write)
                reference_value = store_value;
            else if (check_scoreboard && returned_value !== reference_value)
                $fatal(1, "Scoreboard mismatch core=%0d expected=%h got=%h",
                       core_id, reference_value, returned_value);

            @(negedge clk);
            req_valid[core_id] = 1'b0;
            req_read[core_id] = 1'b0;
            req_write[core_id] = 1'b0;
            req_done[core_id] = 1'b0;
            transaction_count = transaction_count + 1;
            for (integer state_core = 0; state_core < 2; state_core = state_core + 1) begin
                state_coverage[state_core][state[state_core]] =
                    state_coverage[state_core][state[state_core]] + 1;
                if (old_state[state_core] != state[state_core]) begin
                    if (!legal_transition(old_state[state_core], state[state_core]))
                        $fatal(1, "Illegal MESI transition %s->%s on core %0d",
                               state_name(old_state[state_core]),
                               state_name(state[state_core]), state_core);
                    transition_coverage[old_state[state_core]][state[state_core]] =
                        transition_coverage[old_state[state_core]][state[state_core]] + 1;
                end
            end
            check_invariants();
        end
    endtask

    task automatic run_cross_model_trace;
        logic [63:0] result_value;
        logic [7:0] operation_char;
        begin
            reset_pair(64'b0);
            trace_file = $fopen(trace_path, "r");
            if (trace_file == 0)
                $fatal(1, "Could not open cross-model trace: %s", trace_path);
            trace_index = 0;
            while (!$feof(trace_file)) begin
                scan_status = $fgets(trace_line, trace_file);
                if (scan_status != 0) begin
                    scan_status = $sscanf(trace_line, "%s %d %d %h",
                                          trace_operation, trace_core, trace_address, trace_value);
                    operation_char = trace_operation;
                    if (trace_core < 0 || trace_core > 1)
                        $fatal(1, "Cross-model trace only supports cores 0 and 1");
                    if (trace_address / 64 != 64)
                        $fatal(1, "Cross-model trace addresses must map to block 0x1000");
                    if (operation_char == "W" && scan_status == 4)
                        transact(trace_core, 1, trace_value, 1, result_value);
                    else if (operation_char == "R" && scan_status >= 3)
                        transact(trace_core, 0, 64'b0, 1, result_value);
                    else
                        $fatal(1, "Malformed cross-model trace record: %s", trace_line);
                    $display("RESULT %0d %0d %s %s 0x%016h",
                             trace_index, trace_core, operation_char,
                             state_name(state[trace_core]), result_value);
                    trace_index = trace_index + 1;
                end
            end
            $fclose(trace_file);
            for (core_index = 0; core_index < 2; core_index = core_index + 1) begin
                final_state = state[core_index];
                final_value = final_state == MESI_I ? 64'b0 : line_data[core_index];
                $display("FINAL %0d %0d %s 0x%016h",
                         64, core_index,
                         state_name(final_state), final_value);
            end
            $display("MEMORY %0d 0x%016h", 64, backing_memory);
            $display("COHERENCE invalidations=%0d interventions=%0d cache_to_cache_transfers=%0d grants=[%0d,%0d]",
                     invalidation_count, intervention_count, intervention_count,
                     grant_count[0], grant_count[1]);
        end
    endtask

    function automatic [7:0] state_name(input logic [1:0] value);
        case (value)
            MESI_I: state_name = "I";
            MESI_S: state_name = "S";
            MESI_E: state_name = "E";
            MESI_M: state_name = "M";
            default: state_name = "?";
        endcase
    endfunction

    function automatic legal_transition(
        input logic [1:0] previous,
        input logic [1:0] next_state
    );
        begin
            legal_transition = (previous == next_state)
                || (previous == MESI_I && (next_state == MESI_S
                    || next_state == MESI_E || next_state == MESI_M))
                || (previous == MESI_S && (next_state == MESI_I
                    || next_state == MESI_M))
                || (previous == MESI_E && (next_state == MESI_S
                    || next_state == MESI_M || next_state == MESI_I))
                || (previous == MESI_M && (next_state == MESI_I
                    || next_state == MESI_S));
        end
    endfunction

    initial begin
        req_valid = '0;
        req_read = '0;
        req_write = '0;
        req_done = '0;
        grant_ready = 1'b0;
        line_data = '0;
        backing_memory = '0;
        reference_value = '0;
        transaction_count = 0;
        invalidation_count = 0;
        intervention_count = 0;
        grant_count[0] = 0;
        grant_count[1] = 0;
        for (integer c = 0; c < 2; c = c + 1)
            for (integer s = 0; s < 4; s = s + 1)
                state_coverage[c][s] = 0;
        for (integer from_state = 0; from_state < 4; from_state = from_state + 1)
            for (integer to_state = 0; to_state < 4; to_state = to_state + 1)
                transition_coverage[from_state][to_state] = 0;
        trace_path = "examples/cross_model.trace";
        if ($value$plusargs("TRACE=%s", trace_path)) begin
        end

        if ($test$plusargs("CROSS_MODEL")) begin
            run_cross_model_trace();
            $display("PASS: shared C++/RTL cross-model trace");
            $finish;
        end

        reset_pair(64'b0);
        transact(0, 0, 64'b0, 1, last_read_value);
        if (state[0] != MESI_E) $fatal(1, "Read/Read: first reader must enter E");
        transact(1, 0, 64'b0, 1, last_read_value);
        if (state[0] != MESI_S || state[1] != MESI_S)
            $fatal(1, "Read/Read: both readers must end in S");

        reset_pair(64'b0);
        transact(0, 0, 64'b0, 1, last_read_value);
        transact(1, 1, 64'hA11CE001, 1, last_read_value);
        if (state[0] != MESI_I || state[1] != MESI_M)
            $fatal(1, "Read/Write: writer must invalidate prior reader");

        reset_pair(64'b0);
        transact(0, 1, 64'hB0B00002, 1, last_read_value);
        transact(1, 0, 64'b0, 1, last_read_value);
        if (last_read_value != 64'hB0B00002 || state[0] != MESI_S || state[1] != MESI_S)
            $fatal(1, "Write/Read: BusRd must forward modified owner's value");

        reset_pair(64'b0);
        transact(0, 1, 64'hCA5E0003, 1, last_read_value);
        transact(1, 1, 64'hCA5E0004, 1, last_read_value);
        if (state[0] != MESI_I || state[1] != MESI_M
            || line_data[1] != 64'hCA5E0004)
            $fatal(1, "Write/Write: final writer must own M with latest value");

        reset_pair(64'b0);
        transact(1, 0, 64'b0, 1, last_read_value);
        if (state[1] != MESI_E)
            $fatal(1, "Core 1 must exercise the exclusive state");
        transact(1, 1, 64'hE0000005, 1, last_read_value);
        if (state[1] != MESI_M)
            $fatal(1, "E-state write must silently transition to M");

        reset_pair(64'b0);
        seed = 32'h5EED1234;
        rng_state = seed;
        $display("RANDOM_SEED=0x5EED1234");
        for (integer random_index = 0; random_index < 200; random_index = random_index + 1) begin
            rng_state = rng_state ^ (rng_state << 13);
            rng_state = rng_state ^ (rng_state >> 7);
            rng_state = rng_state ^ (rng_state << 17);
            current_core = rng_state[0];
            operation_is_write = rng_state[1];
            write_value = rng_state ^ (64'h9E3779B97F4A7C15 * (random_index + 1));
            transact(current_core, operation_is_write, write_value, 1, last_read_value);
            cycle_count = cycle_count + 1;
        end
        check_invariants();
        if (transaction_count < 200 || intervention_count == 0 || invalidation_count == 0)
            $fatal(1, "Randomized test did not cover required coherence events");
        if (grant_count[0] == 0 || grant_count[1] == 0)
            $fatal(1, "Randomized test did not grant both cores");
        for (integer s = 0; s < 4; s = s + 1)
            if (state_coverage[0][s] == 0 || state_coverage[1][s] == 0)
                $fatal(1, "Both cores must cover MESI state %0d", s);
        if (transition_coverage[MESI_I][MESI_E] == 0
            || transition_coverage[MESI_I][MESI_S] == 0
            || transition_coverage[MESI_I][MESI_M] == 0
            || transition_coverage[MESI_S][MESI_I] == 0
            || transition_coverage[MESI_S][MESI_M] == 0
            || transition_coverage[MESI_E][MESI_S] == 0
            || transition_coverage[MESI_E][MESI_M] == 0
            || transition_coverage[MESI_E][MESI_I] == 0
            || transition_coverage[MESI_M][MESI_I] == 0
            || transition_coverage[MESI_M][MESI_S] == 0)
            $fatal(1, "Functional coverage missed a legal MESI transition");

        $display("COVERAGE transactions=%0d invalidations=%0d interventions=%0d grants=[%0d,%0d]",
                 transaction_count, invalidation_count, intervention_count,
                 grant_count[0], grant_count[1]);
        for (integer c = 0; c < 2; c = c + 1)
            $display("STATE_COVERAGE core=%0d I=%0d S=%0d E=%0d M=%0d",
                     c, state_coverage[c][MESI_I], state_coverage[c][MESI_S],
                     state_coverage[c][MESI_E], state_coverage[c][MESI_M]);
        for (integer from_state = 0; from_state < 4; from_state = from_state + 1)
            $display("TRANSITION_COVERAGE from=%s I=%0d S=%0d E=%0d M=%0d",
                     state_name(from_state[1:0]),
                     transition_coverage[from_state][MESI_I],
                     transition_coverage[from_state][MESI_S],
                     transition_coverage[from_state][MESI_E],
                     transition_coverage[from_state][MESI_M]);
        $display("PASS: integrated two-core MESI directed and randomized tests");
        $finish;
    end
endmodule
