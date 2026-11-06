`timescale 1ns/1ps

module mesi_cache_system_tb;
    localparam integer ADDRESS_WIDTH = 32;
    localparam integer DATA_WIDTH = 32;
    localparam integer LINE_BITS = 128;
    localparam integer MEMORY_LINES = 65536;

    logic clk = 1'b0;
    logic rst_n = 1'b0;
    logic [1:0] cpu_req_valid;
    logic [1:0] cpu_req_ready;
    logic [1:0] cpu_req_write;
    logic [1:0][ADDRESS_WIDTH-1:0] cpu_req_addr;
    logic [1:0][1:0] cpu_req_size;
    logic [1:0][DATA_WIDTH-1:0] cpu_req_wdata;
    logic [1:0] cpu_rsp_valid;
    logic [1:0] cpu_rsp_ready;
    logic [1:0][DATA_WIDTH-1:0] cpu_rsp_rdata;
    logic [1:0] cpu_rsp_error;

    logic mem_req_valid;
    logic mem_req_ready;
    logic mem_req_write;
    logic [ADDRESS_WIDTH-1:0] mem_req_addr;
    logic [LINE_BITS-1:0] mem_req_wdata;
    logic mem_rsp_valid;
    logic mem_rsp_ready;
    logic [LINE_BITS-1:0] mem_rsp_rdata;
    logic force_mem_stall;

    logic [LINE_BITS-1:0] backing_memory [0:MEMORY_LINES-1];
    logic [LINE_BITS-1:0] reference_memory [0:MEMORY_LINES-1];
    logic memory_pending;
    logic pending_write;
    logic [ADDRESS_WIDTH-1:0] pending_addr;
    logic [LINE_BITS-1:0] pending_wdata;
    logic [LINE_BITS-1:0] pending_rdata;
    integer response_delay;
    integer cycle_count;
    integer memory_write_count;
    integer transaction_count;
    integer coverage_l1_hit;
    integer coverage_l1_miss;
    integer coverage_l2_hit;
    integer coverage_l2_miss;
    integer coverage_dirty_eviction;
    integer coverage_clean_eviction;
    integer coverage_l1_dirty_writeback;
    integer coverage_l2_backinvalidate;
    integer coverage_writeback;
    integer coverage_invalidation;
    integer coverage_intervention;
    integer coverage_modified_forward;
    integer coverage_upgrade;
    integer coverage_simultaneous;
    integer coverage_same_line_rr;
    integer coverage_same_line_rw;
    integer coverage_same_line_ww;
    integer coverage_independent_pair;
    integer coverage_independent_overlap;
    integer coverage_arbiter_contention;
    integer coverage_memory_stall_cycles;
    integer coverage_request_stall_cycles;
    integer coverage_response_stall_cycles;
    integer coverage_response_completions;
    integer coverage_reset_pending;
    integer coverage_idle_reset;
    integer accepted_request_count;
    integer completed_request_count;
    integer reset_aborted_request_count;
    integer outstanding_requests [0:1];
    integer coverage_misaligned;
    integer coverage_access_size [0:2];
    integer transition_coverage [0:3][0:3];
    logic previous_valid [0:1][0:31][0:1];
    logic [1:0] previous_state [0:1][0:31][0:1];
    logic [31:0] previous_tag [0:1][0:31][0:1];
    integer random_operations;
    integer random_seed;
    logic [31:0] random_state;
    logic [31:0] random_value;
    logic [31:0] random_address;
    logic [31:0] random_data;
    logic [1:0] random_size;
    logic random_write;
    integer random_core;
    integer random_offset;
    integer request_transaction_id;
    string waveform_path;
    integer selected_case;
    logic [3:0] wave_l1_state_core0_set0;
    logic [3:0] wave_l1_state_core1_set0;
    logic [1:0] wave_l1_valid_core0_set0;
    logic [1:0] wave_l1_valid_core1_set0;

    always #5 clk = ~clk;

    always @(posedge clk) begin
        wave_l1_state_core0_set0 <= {
            dut.l1_state[0][0][1], dut.l1_state[0][0][0]
        };
        wave_l1_state_core1_set0 <= {
            dut.l1_state[1][0][1], dut.l1_state[1][0][0]
        };
        wave_l1_valid_core0_set0 <= {
            dut.l1_valid[0][0][1], dut.l1_valid[0][0][0]
        };
        wave_l1_valid_core1_set0 <= {
            dut.l1_valid[1][0][1], dut.l1_valid[1][0][0]
        };
    end

    mesi_cache_system dut (
        .clk(clk),
        .rst_n(rst_n),
        .cpu_req_valid(cpu_req_valid),
        .cpu_req_ready(cpu_req_ready),
        .cpu_req_write(cpu_req_write),
        .cpu_req_addr(cpu_req_addr),
        .cpu_req_size(cpu_req_size),
        .cpu_req_wdata(cpu_req_wdata),
        .cpu_rsp_valid(cpu_rsp_valid),
        .cpu_rsp_ready(cpu_rsp_ready),
        .cpu_rsp_rdata(cpu_rsp_rdata),
        .cpu_rsp_error(cpu_rsp_error),
        .mem_req_valid(mem_req_valid),
        .mem_req_ready(mem_req_ready),
        .mem_req_write(mem_req_write),
        .mem_req_addr(mem_req_addr),
        .mem_req_wdata(mem_req_wdata),
        .mem_rsp_valid(mem_rsp_valid),
        .mem_rsp_ready(mem_rsp_ready),
        .mem_rsp_rdata(mem_rsp_rdata)
    );

    function automatic [LINE_BITS-1:0] merge_reference(
        input logic [LINE_BITS-1:0] line,
        input logic [ADDRESS_WIDTH-1:0] address,
        input logic [1:0] size,
        input logic [DATA_WIDTH-1:0] data
    );
        logic [LINE_BITS-1:0] updated;
        integer count;
        integer base;
        begin
            updated = line;
            base = address[3:0];
            case (size)
                2'b00: count = 1;
                2'b01: count = 2;
                2'b10: count = 4;
                default: count = 0;
            endcase
            for (integer b = 0; b < count; b = b + 1)
                updated[(base + b) * 8 +: 8] = data[b * 8 +: 8];
            merge_reference = updated;
        end
    endfunction

    function automatic [DATA_WIDTH-1:0] load_reference(
        input logic [LINE_BITS-1:0] line,
        input logic [ADDRESS_WIDTH-1:0] address,
        input logic [1:0] size
    );
        logic [DATA_WIDTH-1:0] value;
        integer count;
        integer base;
        begin
            value = '0;
            base = address[3:0];
            case (size)
                2'b00: count = 1;
                2'b01: count = 2;
                2'b10: count = 4;
                default: count = 0;
            endcase
            for (integer b = 0; b < count; b = b + 1)
                value[b * 8 +: 8] = line[(base + b) * 8 +: 8];
            load_reference = value;
        end
    endfunction

    function automatic integer memory_index(input logic [ADDRESS_WIDTH-1:0] address);
        memory_index = address >> 4;
    endfunction

    always @(negedge clk) begin
        cycle_count = cycle_count + 1;
        mem_req_ready = rst_n && !force_mem_stall && !memory_pending
            && !mem_rsp_valid && (cycle_count % 4 != 0);
        if (mem_req_valid && !mem_req_ready)
            coverage_memory_stall_cycles = coverage_memory_stall_cycles + 1;
    end

    always @(posedge clk) begin
        if (!rst_n) begin
            memory_pending <= 1'b0;
            mem_rsp_valid <= 1'b0;
            mem_rsp_rdata <= '0;
            response_delay <= 0;
            pending_write <= 1'b0;
            pending_addr <= '0;
            pending_wdata <= '0;
            pending_rdata <= '0;
        end else begin
            if (mem_rsp_valid && mem_rsp_ready) begin
                mem_rsp_valid <= 1'b0;
                memory_pending <= 1'b0;
            end

            if (!memory_pending && !mem_rsp_valid
                && mem_req_valid && mem_req_ready) begin
                if (memory_index(mem_req_addr) >= MEMORY_LINES)
                    $fatal(1, "Memory address is outside testbench backing store");
                memory_pending <= 1'b1;
                pending_write <= mem_req_write;
                pending_addr <= mem_req_addr;
                pending_wdata <= mem_req_wdata;
                pending_rdata <= backing_memory[memory_index(mem_req_addr)];
                response_delay <= 2;
                if (mem_req_write) begin
                    backing_memory[memory_index(mem_req_addr)] <= mem_req_wdata;
                    reference_memory[memory_index(mem_req_addr)] <= mem_req_wdata;
                    memory_write_count <= memory_write_count + 1;
                end
            end else if (memory_pending && !mem_rsp_valid) begin
                if (response_delay != 0)
                    response_delay <= response_delay - 1;
                else begin
                    mem_rsp_valid <= 1'b1;
                    mem_rsp_rdata <= pending_write ? '0 : pending_rdata;
                end
            end
        end
    end

    always @(posedge clk) begin
        if (!rst_n) begin
            for (integer core = 0; core < 2; core = core + 1) begin
                reset_aborted_request_count =
                    reset_aborted_request_count + outstanding_requests[core];
                outstanding_requests[core] = 0;
            end
            for (integer core = 0; core < 2; core = core + 1)
                for (integer set_number = 0; set_number < 32; set_number = set_number + 1)
                    for (integer way = 0; way < 2; way = way + 1)
                        previous_valid[core][set_number][way] = 1'b0;
        end else begin
            if (dut.state == 4'd1) begin
                if (dut.l1_lookup_hit)
                    coverage_l1_hit = coverage_l1_hit + 1;
                else
                    coverage_l1_miss = coverage_l1_miss + 1;
            end
            if (dut.state == 4'd3) begin
                if (dut.l2_lookup_hit)
                    coverage_l2_hit = coverage_l2_hit + 1;
                else
                    coverage_l2_miss = coverage_l2_miss + 1;
            end
            if (dut.state == 4'd4) begin
                if (dut.victim_dirty || dut.victim_owner_found)
                    coverage_dirty_eviction = coverage_dirty_eviction + 1;
                else
                    coverage_clean_eviction = coverage_clean_eviction + 1;
                for (integer core = 0; core < 2; core = core + 1)
                    for (integer way = 0; way < 2; way = way + 1)
                        if (dut.l1_valid[core][dut.victim_l1_set][way]
                            && dut.l1_tag[core][dut.victim_l1_set][way]
                                == (dut.victim_line_addr >> 9))
                            coverage_l2_backinvalidate =
                                coverage_l2_backinvalidate + 1;
            end
            if (dut.state == 4'd9 && dut.install_victim_l2_hit
                && dut.l1_valid[dut.active_core][dut.active_l1_set][dut.install_way]
                && dut.l1_state[dut.active_core][dut.active_l1_set][dut.install_way] == 2'b11)
                coverage_l1_dirty_writeback = coverage_l1_dirty_writeback + 1;
            if (dut.state == 4'd0 && dut.mshr_valid == 2'b11)
                coverage_arbiter_contention = coverage_arbiter_contention + 1;
            if (dut.state == 4'd2 && dut.peer_lookup_hit) begin
                if (dut.active_write) begin
                    coverage_invalidation = coverage_invalidation + 1;
                    if (dut.active_l1_hit
                        && dut.l1_state[dut.active_core][dut.active_l1_set]
                            [dut.active_l1_way] == 2'b01)
                        coverage_upgrade = coverage_upgrade + 1;
                end else if (dut.l1_state[1-dut.active_core][dut.active_l1_set]
                                 [dut.peer_lookup_way] == 2'b11) begin
                    coverage_intervention = coverage_intervention + 1;
                    coverage_modified_forward = coverage_modified_forward + 1;
                end
            end
            if (mem_req_valid && mem_req_ready && mem_req_write)
                coverage_writeback = coverage_writeback + 1;
            for (integer core = 0; core < 2; core = core + 1) begin
                if (cpu_req_valid[core] && cpu_req_ready[core]) begin
                    accepted_request_count = accepted_request_count + 1;
                    outstanding_requests[core] = outstanding_requests[core] + 1;
                end
                if (cpu_req_valid[core] && !cpu_req_ready[core])
                    coverage_request_stall_cycles = coverage_request_stall_cycles + 1;
                if (cpu_rsp_valid[core] && !cpu_rsp_ready[core])
                    coverage_response_stall_cycles = coverage_response_stall_cycles + 1;
                if (cpu_rsp_valid[core] && cpu_rsp_ready[core]) begin
                    if (outstanding_requests[core] == 0)
                        $fatal(1, "Response without an outstanding request core=%0d", core);
                    outstanding_requests[core] = outstanding_requests[core] - 1;
                    completed_request_count = completed_request_count + 1;
                    coverage_response_completions = coverage_response_completions + 1;
                end
                for (integer set_number = 0; set_number < 32; set_number = set_number + 1) begin
                    for (integer way = 0; way < 2; way = way + 1) begin
                        if (previous_valid[core][set_number][way]) begin
                            if (!dut.l1_valid[core][set_number][way]) begin
                                transition_coverage
                                    [previous_state[core][set_number][way]][0] =
                                    transition_coverage
                                    [previous_state[core][set_number][way]][0] + 1;
                            end else if (previous_tag[core][set_number][way]
                                         != dut.l1_tag[core][set_number][way]) begin
                                transition_coverage
                                    [previous_state[core][set_number][way]][0] =
                                    transition_coverage
                                    [previous_state[core][set_number][way]][0] + 1;
                                transition_coverage[0]
                                    [dut.l1_state[core][set_number][way]] =
                                    transition_coverage[0]
                                    [dut.l1_state[core][set_number][way]] + 1;
                            end else if (previous_state[core][set_number][way]
                                         != dut.l1_state[core][set_number][way]) begin
                                transition_coverage
                                    [previous_state[core][set_number][way]]
                                    [dut.l1_state[core][set_number][way]] =
                                    transition_coverage
                                    [previous_state[core][set_number][way]]
                                    [dut.l1_state[core][set_number][way]] + 1;
                            end
                        end else if (dut.l1_valid[core][set_number][way]) begin
                            transition_coverage[0][dut.l1_state[core][set_number][way]] =
                                transition_coverage[0][dut.l1_state[core][set_number][way]] + 1;
                        end
                        previous_valid[core][set_number][way] =
                            dut.l1_valid[core][set_number][way];
                        previous_state[core][set_number][way] =
                            dut.l1_state[core][set_number][way];
                        previous_tag[core][set_number][way] =
                            dut.l1_tag[core][set_number][way];
                    end
                end
            end
        end
    end

    task automatic check_invariants;
        integer l1_set;
        integer l2_set;
        logic [ADDRESS_WIDTH-1:0] address;
        logic [31:0] tag;
        logic found;
        begin
            for (integer core = 0; core < 2; core = core + 1) begin
                for (integer set_number = 0; set_number < 32; set_number = set_number + 1) begin
                    for (integer way = 0; way < 2; way = way + 1) begin
                        if (dut.l1_valid[core][set_number][way]) begin
                            address = ((dut.l1_tag[core][set_number][way] << 5)
                                | set_number) << 4;
                            l1_set = (address >> 4) & 31;
                            l2_set = (address >> 4) & 127;
                            tag = address >> 11;
                            found = 1'b0;
                            for (integer l2_way = 0; l2_way < 2; l2_way = l2_way + 1)
                                if (dut.l2_valid[l2_set][l2_way]
                                    && dut.l2_tag[l2_set][l2_way] == tag)
                                    found = 1'b1;
                            if (!found)
                                $fatal(1, "Inclusive L2 missing L1 line core=%0d set=%0d way=%0d",
                                       core, l1_set, way);
                            if (dut.l1_state[core][set_number][way] == 2'b00)
                                $fatal(1, "Valid L1 line is in MESI I");
                            for (integer peer_way = 0; peer_way < 2; peer_way = peer_way + 1) begin
                                if (dut.l1_valid[1-core][set_number][peer_way]
                                    && dut.l1_tag[1-core][set_number][peer_way]
                                        == dut.l1_tag[core][set_number][way]) begin
                                    if (dut.l1_state[core][set_number][way] == 2'b10
                                        || dut.l1_state[core][set_number][way] == 2'b11
                                        || dut.l1_state[1-core][set_number][peer_way] == 2'b10
                                        || dut.l1_state[1-core][set_number][peer_way] == 2'b11)
                                        $fatal(1, "Exclusive MESI state has a peer copy");
                                    if (dut.l1_data[core][set_number][way]
                                        !== dut.l1_data[1-core][set_number][peer_way])
                                        $fatal(1, "Shared cache copies differ");
                                end
                            end
                        end
                    end
                end
            end
        end
    endtask

    task automatic access_one(
        input integer core,
        input logic is_write,
        input logic [31:0] address,
        input logic [1:0] size,
        input logic [31:0] write_data
    );
        logic [31:0] expected;
        integer line_number;
        begin
            line_number = memory_index(address);
            expected = load_reference(reference_memory[line_number], address, size);
            @(negedge clk);
            while (!cpu_req_ready[core])
                @(negedge clk);
            cpu_req_valid[core] = 1'b1;
            cpu_req_write[core] = is_write;
            cpu_req_addr[core] = address;
            cpu_req_size[core] = size;
            cpu_req_wdata[core] = write_data;
            do @(posedge clk); while (!cpu_req_ready[core]);
            transaction_count = transaction_count + 1;
            request_transaction_id = transaction_count;
            if (size <= 2'b10)
                coverage_access_size[size] = coverage_access_size[size] + 1;
            if (is_write)
                reference_memory[line_number] =
                    merge_reference(reference_memory[line_number], address, size, write_data);
            @(negedge clk);
            cpu_req_valid[core] = 1'b0;

            wait (cpu_rsp_valid[core]);
            #1;
            if (cpu_rsp_error[core])
                $fatal(1, "Unexpected access error core=%0d address=%h", core, address);
            if (!is_write && cpu_rsp_rdata[core] !== expected)
                $fatal(1, "Read mismatch transaction=%0d core=%0d address=%h expected=%h actual=%h",
                       request_transaction_id, core, address, expected, cpu_rsp_rdata[core]);
            @(negedge clk);
            cpu_rsp_ready[core] = 1'b1;
            @(posedge clk);
            #1;
            @(negedge clk);
            cpu_rsp_ready[core] = 1'b0;
            check_invariants();
        end
    endtask

    task automatic access_pair(
        input logic write0,
        input logic [31:0] address0,
        input logic [1:0] size0,
        input logic [31:0] data0,
        input logic write1,
        input logic [31:0] address1,
        input logic [1:0] size1,
        input logic [31:0] data1
    );
        logic [31:0] expected0;
        logic [31:0] expected1;
        integer line0;
        integer line1;
        begin
            line0 = memory_index(address0);
            line1 = memory_index(address1);
            expected0 = load_reference(reference_memory[line0], address0, size0);
            if (write0)
                reference_memory[line0] =
                    merge_reference(reference_memory[line0], address0, size0, data0);
            expected1 = load_reference(reference_memory[line1], address1, size1);
            if (write1)
                reference_memory[line1] =
                    merge_reference(reference_memory[line1], address1, size1, data1);

            @(negedge clk);
            while (cpu_req_ready !== 2'b11)
                @(negedge clk);
            cpu_req_valid = 2'b11;
            cpu_req_write = {write1, write0};
            cpu_req_addr[0] = address0;
            cpu_req_addr[1] = address1;
            cpu_req_size[0] = size0;
            cpu_req_size[1] = size1;
            cpu_req_wdata[0] = data0;
            cpu_req_wdata[1] = data1;
            do @(posedge clk); while (cpu_req_ready !== 2'b11);
            transaction_count = transaction_count + 2;
            request_transaction_id = transaction_count - 1;
            coverage_simultaneous = coverage_simultaneous + 1;
            if (size0 <= 2'b10)
                coverage_access_size[size0] = coverage_access_size[size0] + 1;
            if (size1 <= 2'b10)
                coverage_access_size[size1] = coverage_access_size[size1] + 1;
            if (line0 == line1) begin
                if (!write0 && !write1)
                    coverage_same_line_rr = coverage_same_line_rr + 1;
                else if (write0 && write1)
                    coverage_same_line_ww = coverage_same_line_ww + 1;
                else
                    coverage_same_line_rw = coverage_same_line_rw + 1;
            end else
                coverage_independent_pair = coverage_independent_pair + 1;
            @(negedge clk);
            cpu_req_valid = '0;
            wait (cpu_rsp_valid === 2'b11);
            #1;
            if (cpu_rsp_error != 0)
                $fatal(1, "Unexpected error in concurrent pair");
            if (!write0 && cpu_rsp_rdata[0] !== expected0)
                $fatal(1, "Core 0 pair read mismatch transactions=%0d/%0d address=%h expected=%h actual=%h",
                       request_transaction_id, request_transaction_id + 1,
                       address0, expected0, cpu_rsp_rdata[0]);
            if (!write1 && cpu_rsp_rdata[1] !== expected1)
                $fatal(1, "Core 1 pair read mismatch transactions=%0d/%0d address=%h expected=%h actual=%h",
                       request_transaction_id, request_transaction_id + 1,
                       address1, expected1, cpu_rsp_rdata[1]);
            @(negedge clk);
            cpu_rsp_ready = 2'b11;
            @(posedge clk);
            #1;
            @(negedge clk);
            cpu_rsp_ready = '0;
            check_invariants();
        end
    endtask

    task automatic reset_with_stalled_memory_request(input logic [31:0] address);
        begin
            force_mem_stall = 1'b1;
            @(negedge clk);
            while (!cpu_req_ready[0])
                @(negedge clk);
            cpu_req_valid[0] = 1'b1;
            cpu_req_write[0] = 1'b0;
            cpu_req_addr[0] = address;
            cpu_req_size[0] = 2'b10;
            cpu_req_wdata[0] = '0;
            do @(posedge clk); while (!cpu_req_ready[0]);
            @(negedge clk);
            cpu_req_valid[0] = 1'b0;
            wait (mem_req_valid);
            repeat (3) begin
                @(posedge clk);
                #1;
                if (!mem_req_valid || mem_req_ready)
                    $fatal(1, "Expected memory request to remain unaccepted during reset test");
            end
            @(negedge clk);
            rst_n = 1'b0;
            force_mem_stall = 1'b0;
            cpu_req_valid = '0;
            cpu_rsp_ready = '0;
            repeat (2) @(posedge clk);
            #1;
            if (cpu_rsp_valid != 0 || mem_req_valid != 0)
                $fatal(1, "Reset did not clear the stalled unaccepted transaction");
            coverage_reset_pending = coverage_reset_pending + 1;
            @(negedge clk);
            rst_n = 1'b1;
            repeat (2) @(posedge clk);
            access_one(0, 1'b0, address, 2'b10, '0);
        end
    endtask

    task automatic access_core1_during_stall(
        input logic is_write,
        input logic [31:0] address,
        input logic [1:0] size,
        input logic [31:0] write_data,
        input logic [31:0] expected_read_data
    );
        begin
            @(negedge clk);
            while (!cpu_req_ready[1])
                @(negedge clk);
            cpu_req_valid[1] = 1'b1;
            cpu_req_write[1] = is_write;
            cpu_req_addr[1] = address;
            cpu_req_size[1] = size;
            cpu_req_wdata[1] = write_data;
            do @(posedge clk); while (!cpu_req_ready[1]);
            transaction_count = transaction_count + 1;
            @(negedge clk);
            cpu_req_valid[1] = 1'b0;

            wait (cpu_rsp_valid[1]);
            #1;
            if (cpu_rsp_error[1])
                $fatal(1, "Independent-line L1 hit returned an error");
            if (!is_write && cpu_rsp_rdata[1] !== expected_read_data)
                $fatal(1, "Independent-line read returned stale data expected=%h actual=%h",
                       expected_read_data, cpu_rsp_rdata[1]);
            if (!force_mem_stall || !mem_req_valid || mem_req_ready)
                $fatal(1, "Independent-line hit did not complete during the stalled miss");
            @(negedge clk);
            cpu_rsp_ready[1] = 1'b1;
            @(posedge clk);
            #1;
            @(negedge clk);
            cpu_rsp_ready[1] = 1'b0;
        end
    endtask

    task automatic independent_line_overlap;
        logic [31:0] address;
        logic [31:0] original_data;
        integer line_number;
        integer start_cycle;
        integer completion_cycle;
        begin
            address = 32'h0000A000;
            line_number = memory_index(address);
            access_one(1, 1'b0, address, 2'b10, '0);
            original_data = load_reference(reference_memory[line_number], address, 2'b10);

            force_mem_stall = 1'b1;
            fork
                access_one(0, 1'b0, 32'h0000C000, 2'b10, '0);
                begin
                    wait (mem_req_valid && !mem_req_ready);
                    start_cycle = cycle_count;
                    access_core1_during_stall(
                        1'b0, address, 2'b10, '0, original_data);
                    reference_memory[line_number] = merge_reference(
                        reference_memory[line_number], address, 2'b10, 32'hCAFE1234);
                    access_core1_during_stall(
                        1'b1, address, 2'b10, 32'hCAFE1234, '0);
                    completion_cycle = cycle_count;
                    force_mem_stall = 1'b0;
                end
            join

            if (completion_cycle <= start_cycle)
                $fatal(1, "Independent-line completion was not observed after the stalled miss");
            coverage_independent_overlap = coverage_independent_overlap + 1;
            $display("PASS: independent-line L1 read/write completed during memory backpressure cycles=%0d",
                     completion_cycle - start_cycle);
            access_one(0, 1'b0, address, 2'b10, '0);
        end
    endtask

    task automatic request_stall_with_full_mshr;
        logic [31:0] first_expected;
        logic [31:0] second_expected;
        logic [31:0] first_address;
        logic [31:0] second_address;
        begin
            first_address = 32'h0000D000;
            second_address = 32'h0000D010;
            first_expected = load_reference(
                reference_memory[memory_index(first_address)], first_address, 2'b10);
            second_expected = load_reference(
                reference_memory[memory_index(second_address)], second_address, 2'b10);
            force_mem_stall = 1'b1;
            @(negedge clk);
            while (!cpu_req_ready[0])
                @(negedge clk);
            cpu_req_valid[0] = 1'b1;
            cpu_req_write[0] = 1'b0;
            cpu_req_addr[0] = first_address;
            cpu_req_size[0] = 2'b10;
            cpu_req_wdata[0] = '0;
            do @(posedge clk); while (!cpu_req_ready[0]);
            transaction_count = transaction_count + 1;
            @(negedge clk);
            cpu_req_valid[0] = 1'b0;
            wait (mem_req_valid && !mem_req_ready);

            @(negedge clk);
            cpu_req_valid[0] = 1'b1;
            cpu_req_write[0] = 1'b0;
            cpu_req_addr[0] = second_address;
            cpu_req_size[0] = 2'b10;
            cpu_req_wdata[0] = '0;
            repeat (4) begin
                @(posedge clk);
                #1;
                if (cpu_req_ready[0])
                    $fatal(1, "Full MSHR failed to backpressure a second request");
                if (cpu_req_addr[0] != second_address || cpu_req_write[0]
                    || cpu_req_size[0] != 2'b10 || cpu_req_wdata[0] != '0)
                    $fatal(1, "Stalled CPU request payload changed");
            end

            @(negedge clk);
            force_mem_stall = 1'b0;
            wait (cpu_rsp_valid[0]);
            #1;
            if (cpu_rsp_rdata[0] !== first_expected)
                $fatal(1, "First request response mismatch during MSHR backpressure");
            @(negedge clk);
            cpu_rsp_ready[0] = 1'b1;
            @(posedge clk);
            #1;
            @(negedge clk);
            while (!cpu_req_ready[0])
                @(negedge clk);
            do @(posedge clk); while (!cpu_req_ready[0]);
            transaction_count = transaction_count + 1;
            @(negedge clk);
            cpu_req_valid[0] = 1'b0;
            cpu_rsp_ready[0] = 1'b0;
            wait (cpu_rsp_valid[0]);
            #1;
            if (cpu_rsp_rdata[0] !== second_expected)
                $fatal(1, "Second request response mismatch after backpressure");
            @(negedge clk);
            cpu_rsp_ready[0] = 1'b1;
            @(posedge clk);
            #1;
            @(negedge clk);
            cpu_rsp_ready[0] = 1'b0;
            check_invariants();
        end
    endtask

    task automatic reset_while_idle;
        begin
            if (outstanding_requests[0] != 0 || outstanding_requests[1] != 0
                || cpu_rsp_valid != 0 || cpu_req_valid != 0)
                $fatal(1, "Idle reset requested with outstanding work");
            @(negedge clk);
            rst_n = 1'b0;
            repeat (2) @(posedge clk);
            #1;
            if (dut.mshr_valid != 0 || cpu_rsp_valid != 0 || mem_req_valid != 0)
                $fatal(1, "Idle reset did not clear system control state");
            coverage_idle_reset = coverage_idle_reset + 1;
            @(negedge clk);
            rst_n = 1'b1;
            repeat (2) @(posedge clk);
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

    task automatic check_alignment_error;
        begin
            @(negedge clk);
            while (!cpu_req_ready[0])
                @(negedge clk);
            cpu_req_valid[0] = 1'b1;
            cpu_req_write[0] = 1'b0;
            cpu_req_addr[0] = 32'h00009001;
            cpu_req_size[0] = 2'b01;
            cpu_req_wdata[0] = '0;
            do @(posedge clk); while (!cpu_req_ready[0]);
            @(negedge clk);
            cpu_req_valid[0] = 1'b0;
            wait (cpu_rsp_valid[0]);
            #1;
            if (!cpu_rsp_error[0])
                $fatal(1, "Misaligned halfword access must report an error");
            coverage_misaligned = coverage_misaligned + 1;
            @(negedge clk);
            cpu_rsp_ready[0] = 1'b1;
            @(posedge clk);
            #1;
            @(negedge clk);
            cpu_rsp_ready[0] = 1'b0;
        end
    endtask

    task automatic report_functional_coverage;
        begin
            $display("CACHE_EVENT_COVERAGE l1_hit=%0d l1_miss=%0d l2_hit=%0d l2_miss=%0d clean_eviction=%0d dirty_eviction=%0d l1_dirty_writeback=%0d l2_backinvalidated_copies=%0d writeback=%0d invalidation=%0d intervention=%0d modified_forward=%0d upgrade=%0d",
                     coverage_l1_hit, coverage_l1_miss, coverage_l2_hit,
                     coverage_l2_miss, coverage_clean_eviction,
                     coverage_dirty_eviction, coverage_l1_dirty_writeback,
                     coverage_l2_backinvalidate, coverage_writeback,
                     coverage_invalidation, coverage_intervention,
                     coverage_modified_forward, coverage_upgrade);
            $display("CONCURRENCY_COVERAGE simultaneous=%0d same_line_RR=%0d same_line_RW=%0d same_line_WW=%0d independent_pairs=%0d independent_overlap=%0d arbiter_contention=%0d memory_stall_cycles=%0d request_stall_cycles=%0d response_stall_cycles=%0d completions=%0d idle_reset=%0d pending_reset=%0d",
                     coverage_simultaneous, coverage_same_line_rr,
                     coverage_same_line_rw, coverage_same_line_ww,
                     coverage_independent_pair, coverage_independent_overlap,
                     coverage_arbiter_contention, coverage_memory_stall_cycles,
                     coverage_request_stall_cycles, coverage_response_stall_cycles,
                     coverage_response_completions, coverage_idle_reset,
                     coverage_reset_pending);
            $display("ACCESS_SIZE_COVERAGE byte=%0d halfword=%0d word=%0d misaligned=%0d",
                     coverage_access_size[0], coverage_access_size[1],
                     coverage_access_size[2], coverage_misaligned);
            $display("MESI_TRANSITION_COVERAGE I>S=%0d I>E=%0d I>M=%0d S>I=%0d S>M=%0d E>I=%0d E>M=%0d M>I=%0d M>S=%0d",
                     transition_coverage[0][1], transition_coverage[0][2],
                     transition_coverage[0][3], transition_coverage[1][0],
                     transition_coverage[1][3], transition_coverage[2][0],
                     transition_coverage[2][3], transition_coverage[3][0],
                     transition_coverage[3][1]);
            if (coverage_clean_eviction == 0)
                $display("COVERAGE_GAP: clean eviction");
            if (coverage_dirty_eviction == 0)
                $display("COVERAGE_GAP: dirty eviction");
            if (coverage_l1_dirty_writeback == 0)
                $display("COVERAGE_GAP: dirty L1 victim writeback to L2");
            if (coverage_l2_backinvalidate == 0)
                $display("COVERAGE_GAP: L2 eviction back-invalidation");
            if (coverage_l1_hit == 0)
                $display("COVERAGE_GAP: L1 hit");
            if (coverage_l1_miss == 0)
                $display("COVERAGE_GAP: L1 miss");
            if (coverage_l2_hit == 0)
                $display("COVERAGE_GAP: L2 hit");
            if (coverage_l2_miss == 0)
                $display("COVERAGE_GAP: L2 miss");
            if (coverage_writeback == 0)
                $display("COVERAGE_GAP: writeback");
            if (coverage_invalidation == 0)
                $display("COVERAGE_GAP: invalidation");
            if (coverage_intervention == 0)
                $display("COVERAGE_GAP: modified-owner intervention/forwarding");
            if (coverage_upgrade == 0)
                $display("COVERAGE_GAP: upgrade request");
            if (coverage_simultaneous == 0)
                $display("COVERAGE_GAP: simultaneous requests");
            if (coverage_same_line_rr == 0)
                $display("COVERAGE_GAP: same-line read/read");
            if (coverage_same_line_rw == 0)
                $display("COVERAGE_GAP: same-line read/write");
            if (coverage_same_line_ww == 0)
                $display("COVERAGE_GAP: simultaneous same-line write/write");
            if (coverage_independent_pair == 0)
                $display("COVERAGE_GAP: independent-line simultaneous requests");
            if (coverage_independent_overlap == 0)
                $display("COVERAGE_GAP: independent-line overlap");
            if (coverage_arbiter_contention == 0)
                $display("COVERAGE_GAP: arbitration contention");
            if (coverage_memory_stall_cycles == 0)
                $display("COVERAGE_GAP: memory backpressure");
            if (coverage_request_stall_cycles == 0)
                $display("COVERAGE_GAP: request backpressure");
            if (coverage_response_stall_cycles == 0)
                $display("COVERAGE_GAP: response backpressure");
            if (coverage_response_completions == 0)
                $display("COVERAGE_GAP: response completion");
            if (coverage_idle_reset == 0)
                $display("COVERAGE_GAP: idle reset");
            if (coverage_reset_pending == 0)
                $display("COVERAGE_GAP: pending-request reset recovery");
            if (coverage_misaligned == 0)
                $display("COVERAGE_GAP: misaligned access");
            if (coverage_access_size[0] == 0 || coverage_access_size[1] == 0
                || coverage_access_size[2] == 0)
                $display("COVERAGE_GAP: one or more byte/halfword/word accesses");
            if (transition_coverage[0][1] == 0)
                $display("COVERAGE_GAP: MESI I-to-S transition");
            if (transition_coverage[0][2] == 0)
                $display("COVERAGE_GAP: MESI I-to-E transition");
            if (transition_coverage[0][3] == 0)
                $display("COVERAGE_GAP: MESI I-to-M transition");
            if (transition_coverage[1][0] == 0)
                $display("COVERAGE_GAP: MESI S-to-I transition");
            if (transition_coverage[1][3] == 0)
                $display("COVERAGE_GAP: MESI S-to-M transition");
            if (transition_coverage[2][0] == 0)
                $display("COVERAGE_GAP: MESI E-to-I transition");
            if (transition_coverage[2][3] == 0)
                $display("COVERAGE_GAP: MESI E-to-M transition");
            if (transition_coverage[3][0] == 0)
                $display("COVERAGE_GAP: MESI M-to-I transition");
            if (transition_coverage[3][1] == 0)
                $display("COVERAGE_GAP: MESI M-to-S transition");
        end
    endtask

    initial begin
        cpu_req_valid = '0;
        cpu_req_write = '0;
        cpu_req_addr = '0;
        cpu_req_size = '0;
        cpu_req_wdata = '0;
        cpu_rsp_ready = '0;
        mem_req_ready = 1'b0;
        mem_rsp_valid = 1'b0;
        mem_rsp_rdata = '0;
        memory_pending = 1'b0;
        pending_write = 1'b0;
        pending_addr = '0;
        pending_wdata = '0;
        pending_rdata = '0;
        response_delay = 0;
        cycle_count = 0;
        memory_write_count = 0;
        transaction_count = 0;
        coverage_l1_hit = 0;
        coverage_l1_miss = 0;
        coverage_l2_hit = 0;
        coverage_l2_miss = 0;
        coverage_dirty_eviction = 0;
        coverage_clean_eviction = 0;
        coverage_l1_dirty_writeback = 0;
        coverage_l2_backinvalidate = 0;
        coverage_writeback = 0;
        coverage_invalidation = 0;
        coverage_intervention = 0;
        coverage_modified_forward = 0;
        coverage_upgrade = 0;
        coverage_simultaneous = 0;
        coverage_same_line_rr = 0;
        coverage_same_line_rw = 0;
        coverage_same_line_ww = 0;
        coverage_independent_pair = 0;
        coverage_independent_overlap = 0;
        coverage_arbiter_contention = 0;
        coverage_memory_stall_cycles = 0;
        coverage_request_stall_cycles = 0;
        coverage_response_stall_cycles = 0;
        coverage_response_completions = 0;
        coverage_reset_pending = 0;
        coverage_idle_reset = 0;
        accepted_request_count = 0;
        completed_request_count = 0;
        reset_aborted_request_count = 0;
        outstanding_requests[0] = 0;
        outstanding_requests[1] = 0;
        coverage_misaligned = 0;
        for (integer size_index = 0; size_index < 3; size_index = size_index + 1)
            coverage_access_size[size_index] = 0;
        for (integer old_state = 0; old_state < 4; old_state = old_state + 1)
            for (integer new_state = 0; new_state < 4; new_state = new_state + 1)
                transition_coverage[old_state][new_state] = 0;
        force_mem_stall = 1'b0;
        random_operations = 100;
        random_seed = 1592594996;
        request_transaction_id = 0;
        selected_case = 0;
        if ($value$plusargs("CASE=%d", selected_case)) begin
        end
        if ($value$plusargs("OPS=%d", random_operations)) begin
        end
        if ($value$plusargs("SEED=%d", random_seed)) begin
        end
        random_state = random_seed;
        if (random_state == 0)
            random_state = 32'h1;
        random_value = random_state;
        for (integer line = 0; line < MEMORY_LINES; line = line + 1) begin
            backing_memory[line] = {
                32'hA0000000 | line,
                32'hB0000000 | line,
                32'hC0000000 | line,
                32'hD0000000 | line
            };
            reference_memory[line] = backing_memory[line];
        end

        repeat (3) @(posedge clk);
        @(negedge clk);
        rst_n = 1'b1;
        repeat (2) @(posedge clk);
        if (selected_case == 0) begin
        check_alignment_error();

        access_one(0, 1'b0, 32'h00001000, 2'b10, '0);
        access_one(0, 1'b1, 32'h00001001, 2'b00, 32'h0000005A);
        access_one(0, 1'b0, 32'h00001000, 2'b10, '0);
        access_one(0, 1'b1, 32'h00001002, 2'b01, 32'h0000BEEF);
        access_one(0, 1'b0, 32'h00001002, 2'b01, '0);
        access_one(0, 1'b1, 32'h00001004, 2'b10, 32'h12345678);
        access_one(0, 1'b0, 32'h00001004, 2'b10, '0);
        access_one(1, 1'b0, 32'h00001000, 2'b10, '0);
        access_one(1, 1'b1, 32'h00001000, 2'b10, 32'h87654321);
        access_one(0, 1'b0, 32'h00001000, 2'b10, '0);
        access_one(1, 1'b0, 32'h00006000, 2'b10, '0);

        access_pair(1'b0, 32'h00002000, 2'b10, '0,
                    1'b0, 32'h00002000, 2'b10, '0);
        access_pair(1'b1, 32'h00003000, 2'b10, 32'hFACE0001,
                    1'b0, 32'h00003000, 2'b10, '0);
        access_pair(1'b1, 32'h00003000, 2'b10, 32'hDEAD1234,
                    1'b1, 32'h00003000, 2'b10, 32'hDEAD1234);
        access_pair(1'b0, 32'h00004000, 2'b10, '0,
                    1'b0, 32'h00005000, 2'b10, '0);

        for (integer conflict = 0; conflict < 3; conflict = conflict + 1)
            access_one(0, 1'b1, 32'h00010000 + conflict * 512, 2'b10,
                       32'h11000000 + conflict);
        access_one(0, 1'b0, 32'h00010000, 2'b10, '0);

        for (integer l2_conflict = 0; l2_conflict < 3; l2_conflict = l2_conflict + 1)
            access_one(0, 1'b1, 32'h00020000 + l2_conflict * 2048, 2'b10,
                       32'h22000000 + l2_conflict);
        if (memory_write_count == 0)
            $fatal(1, "Expected dirty inclusive L2 eviction to write a line to memory");
        access_one(1, 1'b0, 32'h00020000, 2'b10, '0);

        access_one(0, 1'b0, 32'h00070010, 2'b10, '0);
        access_one(0, 1'b0, 32'h00070810, 2'b10, '0);
        access_one(0, 1'b0, 32'h00070210, 2'b10, '0);
        access_one(0, 1'b0, 32'h00071010, 2'b10, '0);

        force_mem_stall = 1'b1;
        fork
            access_one(1, 1'b0, 32'h00008000, 2'b10, '0);
            begin
                wait (mem_req_valid);
                repeat (4) begin
                    @(posedge clk);
                    #1;
                    if (!mem_req_valid || mem_req_ready)
                        $fatal(1, "Memory request was not held during backpressure");
                end
                @(negedge clk);
                force_mem_stall = 1'b0;
            end
        join

        independent_line_overlap();
        request_stall_with_full_mshr();

        for (integer operation = 0; operation < random_operations; operation = operation + 1) begin
            advance_random();
            random_core = random_value[0];
            random_write = random_value[1];
            random_size = random_value[3:2] % 3;
            random_address = 32'h00030000 + ((random_value >> 8) % 256) * 16;
            advance_random();
            random_offset = random_value[3:0];
            if (random_size == 2'b01)
                random_offset = (random_offset / 2) * 2;
            else if (random_size == 2'b10)
                random_offset = (random_offset / 4) * 4;
            random_address = random_address + random_offset;
            random_data = random_value;
            access_one(random_core, random_write, random_address,
                       random_size, random_data);
        end

        reset_while_idle();
        reset_with_stalled_memory_request(32'h00007000);
        end else begin
            case (selected_case)
                1: begin
                    for (integer conflict = 0; conflict < 3; conflict = conflict + 1)
                        access_one(0, 1'b1, 32'h00010000 + conflict * 512, 2'b10,
                                   32'h11000000 + conflict);
                    access_one(0, 1'b0, 32'h00010000, 2'b10, '0);

                    for (integer l2_conflict = 0; l2_conflict < 3;
                         l2_conflict = l2_conflict + 1)
                        access_one(0, 1'b1, 32'h00020000 + l2_conflict * 2048,
                                   2'b10, 32'h22000000 + l2_conflict);
                    if (memory_write_count == 0)
                        $fatal(1, "Dirty L2 eviction did not write back to memory");
                    access_one(1, 1'b0, 32'h00020000, 2'b10, '0);
                end
                2: begin
                    access_one(0, 1'b1, 32'h00001000, 2'b10, 32'h87654321);
                    access_one(1, 1'b0, 32'h00001000, 2'b10, '0);
                    access_one(0, 1'b0, 32'h00001000, 2'b10, '0);
                end
                3:
                    request_stall_with_full_mshr();
                4:
                    reset_with_stalled_memory_request(32'h00007000);
                default:
                    $fatal(1, "Unknown cache-system scenario id: %0d", selected_case);
            endcase
        end

        if (outstanding_requests[0] != 0 || outstanding_requests[1] != 0)
            $fatal(1, "Requests remained outstanding at test completion");
        if (accepted_request_count
            != completed_request_count + reset_aborted_request_count)
            $fatal(1, "Accepted/completed/aborted request totals disagree accepted=%0d completed=%0d aborted=%0d",
                   accepted_request_count, completed_request_count,
                   reset_aborted_request_count);
        if (selected_case == 0)
            report_functional_coverage();
        $display("REQUEST_SCOREBOARD accepted=%0d completed=%0d reset_aborted=%0d outstanding=%0d",
                 accepted_request_count, completed_request_count,
                 reset_aborted_request_count,
                 outstanding_requests[0] + outstanding_requests[1]);
        if (selected_case == 0)
            $display("PASS: cache hierarchy tests seed=%0d random_ops=%0d transactions=%0d memory_writebacks=%0d",
                     random_seed, random_operations, transaction_count, memory_write_count);
        else
            $display("PASS: cache hierarchy CASE=%0d transactions=%0d memory_writebacks=%0d",
                     selected_case, transaction_count, memory_write_count);
        $finish;
    end

    initial begin
        if ($value$plusargs("WAVE=%s", waveform_path)) begin
            $dumpfile(waveform_path);
            $dumpvars(0, clk, rst_n, cpu_req_valid, cpu_req_ready, cpu_req_write,
                      cpu_req_addr, cpu_rsp_valid, cpu_rsp_ready, cpu_rsp_rdata,
                      mem_req_valid, mem_req_ready, mem_req_write, mem_req_addr,
                      mem_rsp_valid, mem_rsp_ready, dut.state, dut.active_core,
                      dut.active_write, dut.active_addr, dut.active_peer_state,
                      dut.active_source_valid, dut.active_source_data, dut.fill_data,
                      dut.victim_line_addr, dut.victim_line_data, dut.victim_dirty,
                      dut.victim_owner_found, dut.mshr_valid, dut.fast_path_valid,
                      dut.fast_l1_hit, wave_l1_state_core0_set0,
                      wave_l1_state_core1_set0, wave_l1_valid_core0_set0,
                      wave_l1_valid_core1_set0);
        end
    end

    initial begin
        #20000000;
        $fatal(1, "Cache hierarchy test timed out");
    end
endmodule
