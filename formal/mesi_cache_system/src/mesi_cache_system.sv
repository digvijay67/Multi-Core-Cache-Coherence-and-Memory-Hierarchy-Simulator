`timescale 1ns/1ps

module mesi_cache_system #(
    parameter int CORE_COUNT = 2,
    parameter int ADDRESS_WIDTH = 32,
    parameter int DATA_WIDTH = 32,
    parameter int LINE_BYTES = 16,
    parameter int L1_CAPACITY_BYTES = 1024,
    parameter int L1_WAYS = 2,
    parameter int L2_CAPACITY_BYTES = 4096,
    parameter int L2_WAYS = 2,
    localparam int LINE_BITS = LINE_BYTES * 8,
    localparam int LINE_OFFSET_BITS = $clog2(LINE_BYTES),
    localparam int L1_SET_COUNT = L1_CAPACITY_BYTES / (LINE_BYTES * L1_WAYS),
    localparam int L2_SET_COUNT = L2_CAPACITY_BYTES / (LINE_BYTES * L2_WAYS),
    localparam int L1_INDEX_BITS = $clog2(L1_SET_COUNT),
    localparam int L2_INDEX_BITS = $clog2(L2_SET_COUNT),
    localparam int L1_WAY_BITS = (L1_WAYS > 1) ? $clog2(L1_WAYS) : 1,
    localparam int L2_WAY_BITS = (L2_WAYS > 1) ? $clog2(L2_WAYS) : 1,
    localparam int L1_INDEX_WIDTH = (L1_INDEX_BITS > 0) ? L1_INDEX_BITS : 1,
    localparam int L2_INDEX_WIDTH = (L2_INDEX_BITS > 0) ? L2_INDEX_BITS : 1,
    localparam int L1_TAG_WIDTH = ADDRESS_WIDTH - LINE_OFFSET_BITS - L1_INDEX_BITS,
    localparam int L2_TAG_WIDTH = ADDRESS_WIDTH - LINE_OFFSET_BITS - L2_INDEX_BITS
) (
    input  logic                                      clk,
    input  logic                                      rst_n,

    input  logic [CORE_COUNT-1:0]                     cpu_req_valid,
    output logic [CORE_COUNT-1:0]                     cpu_req_ready,
    input  logic [CORE_COUNT-1:0]                     cpu_req_write,
    input  logic [CORE_COUNT-1:0][ADDRESS_WIDTH-1:0]  cpu_req_addr,
    input  logic [CORE_COUNT-1:0][1:0]                cpu_req_size,
    input  logic [CORE_COUNT-1:0][DATA_WIDTH-1:0]     cpu_req_wdata,
    output logic [CORE_COUNT-1:0]                     cpu_rsp_valid,
    input  logic [CORE_COUNT-1:0]                     cpu_rsp_ready,
    output logic [CORE_COUNT-1:0][DATA_WIDTH-1:0]     cpu_rsp_rdata,
    output logic [CORE_COUNT-1:0]                     cpu_rsp_error,

    output logic                                      mem_req_valid,
    input  logic                                      mem_req_ready,
    output logic                                      mem_req_write,
    output logic [ADDRESS_WIDTH-1:0]                  mem_req_addr,
    output logic [LINE_BITS-1:0]                      mem_req_wdata,
    input  logic                                      mem_rsp_valid,
    output logic                                      mem_rsp_ready,
    input  logic [LINE_BITS-1:0]                      mem_rsp_rdata
);
    localparam logic [1:0] MESI_I = 2'b00;
    localparam logic [1:0] MESI_S = 2'b01;
    localparam logic [1:0] MESI_E = 2'b10;
    localparam logic [1:0] MESI_M = 2'b11;

    typedef enum logic [3:0] {
        ST_IDLE,
        ST_LOOKUP_L1,
        ST_CHECK_PEER,
        ST_LOOKUP_L2,
        ST_EVICT_L2,
        ST_MEM_WRITE_REQ,
        ST_MEM_WRITE_RSP,
        ST_MEM_READ_REQ,
        ST_MEM_READ_RSP,
        ST_INSTALL
    } state_t;

    state_t state;

    logic [CORE_COUNT-1:0] mshr_valid;
    logic [CORE_COUNT-1:0] mshr_write;
    logic [CORE_COUNT-1:0][ADDRESS_WIDTH-1:0] mshr_addr;
    logic [CORE_COUNT-1:0][1:0] mshr_size;
    logic [CORE_COUNT-1:0][DATA_WIDTH-1:0] mshr_wdata;

    logic l1_valid [0:CORE_COUNT-1][0:L1_SET_COUNT-1][0:L1_WAYS-1];
    logic [1:0] l1_state [0:CORE_COUNT-1][0:L1_SET_COUNT-1][0:L1_WAYS-1];
    logic [L1_TAG_WIDTH-1:0] l1_tag [0:CORE_COUNT-1][0:L1_SET_COUNT-1][0:L1_WAYS-1];
    logic [LINE_BITS-1:0] l1_data [0:CORE_COUNT-1][0:L1_SET_COUNT-1][0:L1_WAYS-1];
    logic l1_lru_victim [0:CORE_COUNT-1][0:L1_SET_COUNT-1];

    logic l2_valid [0:L2_SET_COUNT-1][0:L2_WAYS-1];
    logic l2_dirty [0:L2_SET_COUNT-1][0:L2_WAYS-1];
    logic [L2_TAG_WIDTH-1:0] l2_tag [0:L2_SET_COUNT-1][0:L2_WAYS-1];
    logic [LINE_BITS-1:0] l2_data [0:L2_SET_COUNT-1][0:L2_WAYS-1];
    logic l2_lru_victim [0:L2_SET_COUNT-1];

    logic rr_core;
    logic pending_found;
    logic selected_core;
    logic active_core;
    logic active_write;
    logic [ADDRESS_WIDTH-1:0] active_addr;
    logic [1:0] active_size;
    logic [DATA_WIDTH-1:0] active_wdata;
    logic active_l1_hit;
    logic active_source_valid;
    logic active_peer_shared;
    logic [1:0] active_peer_state;
    logic [L1_TAG_WIDTH-1:0] active_l1_tag;
    logic [L2_TAG_WIDTH-1:0] active_l2_tag;
    integer active_l1_set;
    integer active_l2_set;
    logic [L1_WAY_BITS-1:0] active_l1_way;
    logic [L2_WAY_BITS-1:0] active_l2_way;
    logic [LINE_BITS-1:0] active_source_data;
    logic [LINE_BITS-1:0] fill_data;

    logic [ADDRESS_WIDTH-1:0] victim_line_addr;
    logic [LINE_BITS-1:0] victim_line_data;
    logic victim_dirty;
    integer victim_l2_set;
    logic [L2_WAY_BITS-1:0] victim_l2_way;
    logic [L2_WAY_BITS-1:0] l2_victim_way;
    logic [L1_INDEX_WIDTH-1:0] victim_l1_set;
    logic [L2_INDEX_WIDTH-1:0] install_victim_l2_set;

    logic [L1_WAY_BITS-1:0] l1_lookup_way;
    logic [L1_WAY_BITS-1:0] peer_lookup_way;
    logic [L2_WAY_BITS-1:0] l2_lookup_way;
    logic [L1_WAY_BITS-1:0] install_way;
    logic [CORE_COUNT-1:0] fast_path_valid;
    logic [CORE_COUNT-1:0] fast_l1_hit;
    logic [CORE_COUNT-1:0] fast_access_aligned;
    logic [CORE_COUNT-1:0][L1_TAG_WIDTH-1:0] fast_l1_tag;
    logic [CORE_COUNT-1:0][L1_INDEX_WIDTH-1:0] fast_l1_set;
    logic [CORE_COUNT-1:0][L1_WAY_BITS-1:0] fast_l1_way;
    logic l1_lookup_hit;
    logic peer_lookup_hit;
    logic l2_lookup_hit;
    logic victim_owner_found;
    logic [LINE_BITS-1:0] victim_owner_data;
    logic install_victim_l2_hit;
    logic [L2_WAY_BITS-1:0] install_victim_l2_way;
    logic [ADDRESS_WIDTH-1:0] install_victim_addr;

    integer candidate;
    integer core;
    integer way;
    integer set_index;
    logic peer_core;

    function automatic logic access_is_aligned(
        input logic [1:0] byte_offset,
        input logic [1:0] size
    );
        begin
            case (size)
                2'b00: access_is_aligned = 1'b1;
                2'b01: access_is_aligned = !byte_offset[0];
                2'b10: access_is_aligned = (byte_offset == 2'b00);
                default: access_is_aligned = 1'b0;
            endcase
        end
    endfunction

    generate
        for (genvar aligned_core = 0; aligned_core < CORE_COUNT;
             aligned_core = aligned_core + 1) begin : g_fast_access_alignment
            assign fast_access_aligned[aligned_core] =
                 access_is_aligned(mshr_addr[aligned_core][1:0], mshr_size[aligned_core]);
        end
    endgenerate

    function automatic [LINE_BITS-1:0] merge_store(
        input logic [LINE_BITS-1:0] line,
        input logic [LINE_OFFSET_BITS-1:0] byte_offset,
        input logic [1:0] size,
        input logic [DATA_WIDTH-1:0] data
    );
        logic [LINE_BITS-1:0] updated;
        integer byte_count;
        integer byte_index;
        integer base_byte;
        begin
            updated = line;
            base_byte = int'(byte_offset);
            case (size)
                2'b00: byte_count = 1;
                2'b01: byte_count = 2;
                2'b10: byte_count = DATA_WIDTH / 8;
                default: byte_count = 0;
            endcase
            for (byte_index = 0; byte_index < DATA_WIDTH / 8;
                 byte_index = byte_index + 1) begin
                if (byte_index < byte_count)
                    updated[(base_byte + byte_index) * 8 +: 8] =
                        data[byte_index * 8 +: 8];
            end
            merge_store = updated;
        end
    endfunction

    function automatic [DATA_WIDTH-1:0] extract_load(
        input logic [LINE_BITS-1:0] line,
        input logic [LINE_OFFSET_BITS-1:0] byte_offset,
        input logic [1:0] size
    );
        logic [DATA_WIDTH-1:0] value;
        integer byte_count;
        integer byte_index;
        integer base_byte;
        begin
            value = '0;
            base_byte = int'(byte_offset);
            case (size)
                2'b00: byte_count = 1;
                2'b01: byte_count = 2;
                2'b10: byte_count = DATA_WIDTH / 8;
                default: byte_count = 0;
            endcase
            for (byte_index = 0; byte_index < DATA_WIDTH / 8;
                 byte_index = byte_index + 1) begin
                if (byte_index < byte_count)
                    value[byte_index * 8 +: 8] =
                        line[(base_byte + byte_index) * 8 +: 8];
            end
            extract_load = value;
        end
    endfunction

    function automatic [ADDRESS_WIDTH-1:0] make_l1_line_address(
        input logic [L1_TAG_WIDTH-1:0] tag_value,
        input integer set_value
    );
        begin
            make_l1_line_address =
                (ADDRESS_WIDTH'(tag_value) << (L1_INDEX_BITS + LINE_OFFSET_BITS))
                | (ADDRESS_WIDTH'(set_value) << LINE_OFFSET_BITS);
        end
    endfunction

    function automatic [ADDRESS_WIDTH-1:0] make_l2_line_address(
        input logic [L2_TAG_WIDTH-1:0] tag_value,
        input integer set_value
    );
        begin
            make_l2_line_address =
                (ADDRESS_WIDTH'(tag_value) << (L2_INDEX_BITS + LINE_OFFSET_BITS))
                | (ADDRESS_WIDTH'(set_value) << LINE_OFFSET_BITS);
        end
    endfunction

    always_comb begin
        cpu_req_ready = '0;
        for (integer request_core = 0; request_core < CORE_COUNT; request_core = request_core + 1)
            cpu_req_ready[request_core] =
                rst_n && !mshr_valid[request_core] && !cpu_rsp_valid[request_core];

        mem_req_valid = (state == ST_MEM_WRITE_REQ) || (state == ST_MEM_READ_REQ);
        mem_req_write = (state == ST_MEM_WRITE_REQ);
        mem_req_addr = (state == ST_MEM_WRITE_REQ || state == ST_MEM_WRITE_RSP)
            ? victim_line_addr : ((active_addr >> LINE_OFFSET_BITS) << LINE_OFFSET_BITS);
        mem_req_wdata = victim_line_data;
        mem_rsp_ready = (state == ST_MEM_WRITE_RSP) || (state == ST_MEM_READ_RSP);
    end

    always_comb begin
        pending_found = 1'b0;
        selected_core = rr_core;
        for (integer scan_offset = 0; scan_offset < CORE_COUNT; scan_offset = scan_offset + 1) begin
            candidate = (rr_core + scan_offset) % CORE_COUNT;
            if (!pending_found && mshr_valid[candidate]) begin
                pending_found = 1'b1;
                selected_core = candidate != 0;
            end
        end
    end

    always_comb begin
        active_l1_set = (active_addr >> LINE_OFFSET_BITS) & (L1_SET_COUNT - 1);
        active_l2_set = (active_addr >> LINE_OFFSET_BITS) & (L2_SET_COUNT - 1);
        active_l1_tag = active_addr[ADDRESS_WIDTH-1 -: L1_TAG_WIDTH];
        active_l2_tag = active_addr[ADDRESS_WIDTH-1 -: L2_TAG_WIDTH];

        l1_lookup_hit = 1'b0;
        l1_lookup_way = 0;
        for (integer lookup_way = 0; lookup_way < L1_WAYS; lookup_way = lookup_way + 1) begin
            if (!l1_lookup_hit
                && l1_valid[active_core][active_l1_set][lookup_way]
                && l1_tag[active_core][active_l1_set][lookup_way] == active_l1_tag) begin
                l1_lookup_hit = 1'b1;
                l1_lookup_way = L1_WAY_BITS'(lookup_way);
            end
        end

        peer_core = active_core ? 0 : 1;
        peer_lookup_hit = 1'b0;
        peer_lookup_way = 0;
        for (integer lookup_peer_way = 0; lookup_peer_way < L1_WAYS;
             lookup_peer_way = lookup_peer_way + 1) begin
            if (!peer_lookup_hit
                && l1_valid[peer_core][active_l1_set][lookup_peer_way]
                && l1_tag[peer_core][active_l1_set][lookup_peer_way] == active_l1_tag) begin
                peer_lookup_hit = 1'b1;
                peer_lookup_way = L1_WAY_BITS'(lookup_peer_way);
            end
        end

        l2_lookup_hit = 1'b0;
        l2_lookup_way = 0;
        for (integer lookup_l2_way = 0; lookup_l2_way < L2_WAYS;
             lookup_l2_way = lookup_l2_way + 1) begin
            if (!l2_lookup_hit
                && l2_valid[active_l2_set][lookup_l2_way]
                && l2_tag[active_l2_set][lookup_l2_way] == active_l2_tag) begin
                l2_lookup_hit = 1'b1;
                l2_lookup_way = L2_WAY_BITS'(lookup_l2_way);
            end
        end

        install_way = 0;
        if (l1_valid[active_core][active_l1_set][0])
            install_way = L1_WAY_BITS'(l1_lru_victim[active_core][active_l1_set]);
        for (integer find_invalid_way = 0; find_invalid_way < L1_WAYS;
             find_invalid_way = find_invalid_way + 1) begin
            if (!l1_valid[active_core][active_l1_set][find_invalid_way]) begin
                install_way = L1_WAY_BITS'(find_invalid_way);
                find_invalid_way = L1_WAYS;
            end
        end

        victim_line_addr = make_l2_line_address(
            l2_tag[victim_l2_set][victim_l2_way], victim_l2_set);
        victim_l1_set = L1_INDEX_WIDTH'(
            (victim_line_addr >> LINE_OFFSET_BITS) & (L1_SET_COUNT - 1));
        victim_owner_found = 1'b0;
        victim_owner_data = victim_line_data;
        for (integer scan_core = 0; scan_core < CORE_COUNT; scan_core = scan_core + 1) begin
            for (integer scan_way = 0; scan_way < L1_WAYS; scan_way = scan_way + 1) begin
                if (l1_valid[scan_core][victim_l1_set][scan_way]
                    && l1_tag[scan_core][victim_l1_set][scan_way]
                        == victim_line_addr[ADDRESS_WIDTH-1 -: L1_TAG_WIDTH]) begin
                    if (l1_state[scan_core][victim_l1_set][scan_way] == MESI_M) begin
                        victim_owner_found = 1'b1;
                        victim_owner_data = l1_data[scan_core][victim_l1_set][scan_way];
                    end
                end
            end
        end

        install_victim_l2_hit = 1'b0;
        install_victim_l2_way = 0;
        install_victim_addr = make_l1_line_address(
            l1_tag[active_core][active_l1_set][install_way], active_l1_set);
        install_victim_l2_set = L2_INDEX_WIDTH'(
            (install_victim_addr >> LINE_OFFSET_BITS) & (L2_SET_COUNT - 1));
        for (integer find_victim_l2_way = 0; find_victim_l2_way < L2_WAYS;
             find_victim_l2_way = find_victim_l2_way + 1) begin
            if (!install_victim_l2_hit
                && l2_valid[install_victim_l2_set][find_victim_l2_way]
                && l2_tag[install_victim_l2_set][find_victim_l2_way]
                    == install_victim_addr[ADDRESS_WIDTH-1 -: L2_TAG_WIDTH]) begin
                install_victim_l2_hit = 1'b1;
                install_victim_l2_way = L2_WAY_BITS'(find_victim_l2_way);
            end
        end
        l2_victim_way = !l2_valid[active_l2_set][0] ? L2_WAY_BITS'(0)
            : (!l2_valid[active_l2_set][1] ? L2_WAY_BITS'(1)
               : L2_WAY_BITS'(l2_lru_victim[active_l2_set]));
    end

    always_comb begin
        fast_path_valid = '0;
        fast_l1_hit = '0;
        for (integer fast_core = 0; fast_core < CORE_COUNT; fast_core = fast_core + 1) begin
            fast_l1_set[fast_core] =
                L1_INDEX_WIDTH'(
                    (mshr_addr[fast_core] >> LINE_OFFSET_BITS) & (L1_SET_COUNT - 1));
            fast_l1_tag[fast_core] =
                L1_TAG_WIDTH'(mshr_addr[fast_core] >> (ADDRESS_WIDTH - L1_TAG_WIDTH));
            fast_l1_way[fast_core] = 0;
            for (integer fast_way = 0; fast_way < L1_WAYS; fast_way = fast_way + 1) begin
                if (!fast_l1_hit[fast_core]
                    && l1_valid[fast_core][fast_l1_set[fast_core]][fast_way]
                    && l1_tag[fast_core][fast_l1_set[fast_core]][fast_way]
                        == fast_l1_tag[fast_core]) begin
                    fast_l1_hit[fast_core] = 1'b1;
                    fast_l1_way[fast_core] = L1_WAY_BITS'(fast_way);
                end
            end
            fast_path_valid[fast_core] = state != ST_IDLE
                && state != ST_CHECK_PEER
                && state != ST_EVICT_L2
                && fast_core != int'(active_core)
                && mshr_valid[fast_core]
                && !cpu_rsp_valid[fast_core]
                && fast_l1_hit[fast_core]
                && (mshr_addr[fast_core] >> LINE_OFFSET_BITS)
                    != (active_addr >> LINE_OFFSET_BITS)
                && fast_access_aligned[fast_core]
                && (!mshr_write[fast_core]
                    || l1_state[fast_core][fast_l1_set[fast_core]][fast_l1_way[fast_core]]
                        == MESI_E
                    || l1_state[fast_core][fast_l1_set[fast_core]][fast_l1_way[fast_core]]
                        == MESI_M);
        end
    end

    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            state <= ST_IDLE;
            rr_core <= 1'b0;
            mshr_valid <= '0;
            mshr_write <= '0;
            mshr_addr <= '0;
            mshr_size <= '0;
            mshr_wdata <= '0;
            cpu_rsp_valid <= '0;
            cpu_rsp_rdata <= '0;
            cpu_rsp_error <= '0;
            active_core <= 1'b0;
            active_write <= 1'b0;
            active_addr <= '0;
            active_size <= '0;
            active_wdata <= '0;
            active_l1_hit <= 1'b0;
            active_source_valid <= 1'b0;
            active_peer_shared <= 1'b0;
            active_peer_state <= MESI_I;
            active_l1_way <= 0;
            active_l2_way <= 0;
            active_source_data <= '0;
            fill_data <= '0;
            victim_l2_set <= 0;
            victim_l2_way <= 0;
            victim_line_data <= '0;
            victim_dirty <= 1'b0;
            for (core = 0; core < CORE_COUNT; core = core + 1) begin
                for (set_index = 0; set_index < L1_SET_COUNT; set_index = set_index + 1) begin
                    l1_lru_victim[core][set_index] <= 1'b0;
                    for (way = 0; way < L1_WAYS; way = way + 1) begin
                        l1_valid[core][set_index][way] <= 1'b0;
                        l1_state[core][set_index][way] <= MESI_I;
                        l1_tag[core][set_index][way] <= '0;
                        l1_data[core][set_index][way] <= '0;
                    end
                end
            end
            for (set_index = 0; set_index < L2_SET_COUNT; set_index = set_index + 1) begin
                l2_lru_victim[set_index] <= 1'b0;
                for (way = 0; way < L2_WAYS; way = way + 1) begin
                    l2_valid[set_index][way] <= 1'b0;
                    l2_dirty[set_index][way] <= 1'b0;
                    l2_tag[set_index][way] <= '0;
                    l2_data[set_index][way] <= '0;
                end
            end
        end else begin
            for (core = 0; core < CORE_COUNT; core = core + 1) begin
                if (cpu_rsp_valid[core] && cpu_rsp_ready[core])
                    cpu_rsp_valid[core] <= 1'b0;
                if (cpu_req_valid[core] && cpu_req_ready[core]) begin
                    mshr_valid[core] <= 1'b1;
                    mshr_write[core] <= cpu_req_write[core];
                    mshr_addr[core] <= cpu_req_addr[core];
                    mshr_size[core] <= cpu_req_size[core];
                    mshr_wdata[core] <= cpu_req_wdata[core];
                end
            end

            for (core = 0; core < CORE_COUNT; core = core + 1) begin
                if (fast_path_valid[core]) begin
                    if (mshr_write[core]) begin
                        l1_data[core][fast_l1_set[core]][fast_l1_way[core]] <= merge_store(
                            l1_data[core][fast_l1_set[core]][fast_l1_way[core]],
                            LINE_OFFSET_BITS'(mshr_addr[core]),
                            mshr_size[core], mshr_wdata[core]);
                        l1_state[core][fast_l1_set[core]][fast_l1_way[core]] <= MESI_M;
                        cpu_rsp_rdata[core] <= '0;
                    end else begin
                        cpu_rsp_rdata[core] <= extract_load(
                            l1_data[core][fast_l1_set[core]][fast_l1_way[core]],
                            LINE_OFFSET_BITS'(mshr_addr[core]), mshr_size[core]);
                    end
                    l1_lru_victim[core][fast_l1_set[core]] <= fast_l1_way[core] == 0;
                    cpu_rsp_valid[core] <= 1'b1;
                    cpu_rsp_error[core] <= 1'b0;
                    mshr_valid[core] <= 1'b0;
                end
            end

            case (state)
                ST_IDLE: begin
                    if (pending_found) begin
                        active_core <= selected_core;
                        active_write <= mshr_write[selected_core];
                        active_addr <= mshr_addr[selected_core];
                        active_size <= mshr_size[selected_core];
                        active_wdata <= mshr_wdata[selected_core];
                        active_l1_hit <= 1'b0;
                        active_source_valid <= 1'b0;
                        active_peer_shared <= 1'b0;
                        state <= ST_LOOKUP_L1;
                    end
                end

                ST_LOOKUP_L1: begin
                    active_l1_hit <= l1_lookup_hit;
                    active_l1_way <= L1_WAY_BITS'(l1_lookup_way);
                    if (!access_is_aligned(active_addr[1:0], active_size)) begin
                        cpu_rsp_valid[active_core] <= 1'b1;
                        cpu_rsp_error[active_core] <= 1'b1;
                        cpu_rsp_rdata[active_core] <= '0;
                        mshr_valid[active_core] <= 1'b0;
                        rr_core <= !active_core;
                        state <= ST_IDLE;
                    end else if (l1_lookup_hit && !active_write) begin
                        cpu_rsp_valid[active_core] <= 1'b1;
                        cpu_rsp_error[active_core] <= 1'b0;
                        cpu_rsp_rdata[active_core] <= extract_load(
                            l1_data[active_core][active_l1_set][l1_lookup_way],
                            active_addr[LINE_OFFSET_BITS-1:0], active_size);
                        l1_lru_victim[active_core][active_l1_set] <= !l1_lookup_way[0];
                        mshr_valid[active_core] <= 1'b0;
                        rr_core <= !active_core;
                        state <= ST_IDLE;
                    end else if (l1_lookup_hit && active_write
                                 && l1_state[active_core][active_l1_set][l1_lookup_way]
                                    != MESI_S) begin
                        l1_data[active_core][active_l1_set][l1_lookup_way] <= merge_store(
                            l1_data[active_core][active_l1_set][l1_lookup_way],
                            active_addr[LINE_OFFSET_BITS-1:0], active_size, active_wdata);
                        l1_state[active_core][active_l1_set][l1_lookup_way] <= MESI_M;
                        l1_lru_victim[active_core][active_l1_set] <= !l1_lookup_way[0];
                        cpu_rsp_valid[active_core] <= 1'b1;
                        cpu_rsp_error[active_core] <= 1'b0;
                        cpu_rsp_rdata[active_core] <= '0;
                        mshr_valid[active_core] <= 1'b0;
                        rr_core <= !active_core;
                        state <= ST_IDLE;
                    end else begin
                        if (l1_lookup_hit) begin
                            active_source_valid <= 1'b1;
                            active_source_data <=
                                l1_data[active_core][active_l1_set][l1_lookup_way];
                        end
                        state <= ST_CHECK_PEER;
                    end
                end

                ST_CHECK_PEER: begin
                    active_peer_state <= peer_lookup_hit
                        ? l1_state[peer_core][active_l1_set][peer_lookup_way] : MESI_I;
                    if (active_write) begin
                        if (peer_lookup_hit) begin
                            if (!active_source_valid)
                                active_source_data <=
                                    l1_data[peer_core][active_l1_set][peer_lookup_way];
                            active_source_valid <= 1'b1;
                            l1_state[peer_core][active_l1_set][peer_lookup_way] <= MESI_I;
                            l1_valid[peer_core][active_l1_set][peer_lookup_way] <= 1'b0;
                        end
                        if (active_l1_hit) begin
                            l1_data[active_core][active_l1_set][active_l1_way] <= merge_store(
                                active_source_data, active_addr[LINE_OFFSET_BITS-1:0],
                                active_size, active_wdata);
                            l1_state[active_core][active_l1_set][active_l1_way] <= MESI_M;
                            l1_lru_victim[active_core][active_l1_set] <= !active_l1_way[0];
                            cpu_rsp_valid[active_core] <= 1'b1;
                            cpu_rsp_error[active_core] <= 1'b0;
                            cpu_rsp_rdata[active_core] <= '0;
                            mshr_valid[active_core] <= 1'b0;
                            rr_core <= !active_core;
                            state <= ST_IDLE;
                        end else begin
                            active_peer_shared <= peer_lookup_hit;
                            state <= ST_LOOKUP_L2;
                        end
                    end else begin
                        if (peer_lookup_hit) begin
                            active_source_valid <= 1'b1;
                            active_source_data <=
                                l1_data[peer_core][active_l1_set][peer_lookup_way];
                            active_peer_shared <= 1'b1;
                            if (l1_state[peer_core][active_l1_set][peer_lookup_way]
                                    == MESI_M
                                || l1_state[peer_core][active_l1_set][peer_lookup_way]
                                    == MESI_E)
                                l1_state[peer_core][active_l1_set][peer_lookup_way] <= MESI_S;
                        end
                        state <= ST_LOOKUP_L2;
                    end
                end

                ST_LOOKUP_L2: begin
                    if (l2_lookup_hit) begin
                        active_l2_way <= L2_WAY_BITS'(l2_lookup_way);
                        fill_data <= active_source_valid
                            ? active_source_data
                            : l2_data[active_l2_set][l2_lookup_way];
                        if (active_source_valid && !active_write
                            && active_peer_state == MESI_M) begin
                            l2_data[active_l2_set][l2_lookup_way] <= active_source_data;
                            l2_dirty[active_l2_set][l2_lookup_way] <= 1'b1;
                        end
                        l2_lru_victim[active_l2_set] <= !l2_lookup_way[0];
                        state <= ST_INSTALL;
                    end else begin
                        victim_l2_set <= active_l2_set;
                        victim_l2_way <= l2_victim_way;
                        active_l2_way <= l2_victim_way;
                        if (l2_valid[active_l2_set][l2_victim_way]) begin
                            victim_dirty <= l2_dirty[active_l2_set][l2_victim_way];
                            victim_line_data <= l2_data[active_l2_set][l2_victim_way];
                        end else begin
                            victim_dirty <= 1'b0;
                            victim_line_data <= '0;
                        end
                        if (l2_valid[active_l2_set][l2_victim_way])
                            state <= ST_EVICT_L2;
                        else if (active_source_valid) begin
                            fill_data <= active_source_data;
                            state <= ST_INSTALL;
                        end else
                            state <= ST_MEM_READ_REQ;
                    end
                end

                ST_EVICT_L2: begin
                    for (core = 0; core < CORE_COUNT; core = core + 1) begin
                        for (way = 0; way < L1_WAYS; way = way + 1) begin
                            if (l1_valid[core][victim_l1_set][way]
                                && l1_tag[core][victim_l1_set][way]
                                    == victim_line_addr[ADDRESS_WIDTH-1 -: L1_TAG_WIDTH]) begin
                                l1_valid[core][victim_l1_set][way] <= 1'b0;
                                l1_state[core][victim_l1_set][way] <= MESI_I;
                            end
                        end
                    end
                    l2_valid[victim_l2_set][victim_l2_way] <= 1'b0;
                    if (victim_owner_found) begin
                        victim_line_data <= victim_owner_data;
                        victim_dirty <= 1'b1;
                    end
                    if (victim_dirty || victim_owner_found)
                        state <= ST_MEM_WRITE_REQ;
                    else if (active_source_valid) begin
                        fill_data <= active_source_data;
                        state <= ST_INSTALL;
                    end else
                        state <= ST_MEM_READ_REQ;
                end

                ST_MEM_WRITE_REQ: begin
                    if (mem_req_valid && mem_req_ready)
                        state <= ST_MEM_WRITE_RSP;
                end

                ST_MEM_WRITE_RSP: begin
                    if (mem_rsp_valid && mem_rsp_ready) begin
                        if (active_source_valid) begin
                            fill_data <= active_source_data;
                            state <= ST_INSTALL;
                        end else
                            state <= ST_MEM_READ_REQ;
                    end
                end

                ST_MEM_READ_REQ: begin
                    if (mem_req_valid && mem_req_ready)
                        state <= ST_MEM_READ_RSP;
                end

                ST_MEM_READ_RSP: begin
                    if (mem_rsp_valid && mem_rsp_ready) begin
                        fill_data <= mem_rsp_rdata;
                        state <= ST_INSTALL;
                    end
                end

                ST_INSTALL: begin
                    if (install_victim_l2_hit
                        && l1_valid[active_core][active_l1_set][install_way]
                        && l1_state[active_core][active_l1_set][install_way] == MESI_M) begin
                        l2_data[install_victim_l2_set][install_victim_l2_way] <=
                            l1_data[active_core][active_l1_set][install_way];
                        l2_dirty[install_victim_l2_set][install_victim_l2_way] <= 1'b1;
                    end

                    if (!l2_lookup_hit) begin
                        l2_valid[active_l2_set][active_l2_way] <= 1'b1;
                        l2_dirty[active_l2_set][active_l2_way] <=
                            active_source_valid && !active_write
                            && active_peer_state == MESI_M;
                        l2_tag[active_l2_set][active_l2_way] <= active_l2_tag;
                        l2_data[active_l2_set][active_l2_way] <= fill_data;
                        l2_lru_victim[active_l2_set] <= !active_l2_way[0];
                    end

                    l1_valid[active_core][active_l1_set][install_way] <= 1'b1;
                    l1_tag[active_core][active_l1_set][install_way] <= active_l1_tag;
                    l1_data[active_core][active_l1_set][install_way] <= active_write
                        ? merge_store(fill_data, active_addr[LINE_OFFSET_BITS-1:0],
                                      active_size, active_wdata)
                        : fill_data;
                    l1_state[active_core][active_l1_set][install_way] <= active_write
                        ? MESI_M : (active_peer_shared ? MESI_S : MESI_E);
                    l1_lru_victim[active_core][active_l1_set] <= !install_way[0];
                    cpu_rsp_valid[active_core] <= 1'b1;
                    cpu_rsp_error[active_core] <= 1'b0;
                    cpu_rsp_rdata[active_core] <= active_write ? '0
                        : extract_load(fill_data, active_addr[LINE_OFFSET_BITS-1:0], active_size);
                    mshr_valid[active_core] <= 1'b0;
                    rr_core <= !active_core;
                    state <= ST_IDLE;
                end

                default: state <= ST_IDLE;
            endcase
        end
    end

`ifndef SYNTHESIS
    logic stalled_mem_request;
    logic stalled_mem_write;
    logic [ADDRESS_WIDTH-1:0] stalled_mem_addr;
    logic [LINE_BITS-1:0] stalled_mem_data;
    logic [CORE_COUNT-1:0] stalled_cpu_request;
    logic [CORE_COUNT-1:0][ADDRESS_WIDTH-1:0] stalled_cpu_addr;
    logic [CORE_COUNT-1:0] stalled_cpu_write;
    logic [CORE_COUNT-1:0][1:0] stalled_cpu_size;
    logic [CORE_COUNT-1:0][DATA_WIDTH-1:0] stalled_cpu_wdata;
    logic [CORE_COUNT-1:0] stalled_cpu_response;
    logic [CORE_COUNT-1:0][DATA_WIDTH-1:0] stalled_cpu_rdata;
    logic [CORE_COUNT-1:0] stalled_cpu_error;
    logic history_valid;
    logic [1:0] previous_l1_state [0:CORE_COUNT-1][0:L1_SET_COUNT-1][0:L1_WAYS-1];
    logic previous_l1_valid [0:CORE_COUNT-1][0:L1_SET_COUNT-1][0:L1_WAYS-1];
    logic [L1_TAG_WIDTH-1:0] previous_l1_tag [0:CORE_COUNT-1][0:L1_SET_COUNT-1][0:L1_WAYS-1];

    function automatic logic legal_cache_transition(
        input logic [1:0] prior,
        input logic [1:0] current
    );
        begin
            legal_cache_transition = prior == current
                || (prior == MESI_I
                    && (current == MESI_S || current == MESI_E || current == MESI_M))
                || (prior == MESI_S && (current == MESI_I || current == MESI_M))
                || (prior == MESI_E
                    && (current == MESI_I || current == MESI_S || current == MESI_M))
                || (prior == MESI_M && (current == MESI_I || current == MESI_S));
        end
    endfunction

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            stalled_mem_request <= 1'b0;
            stalled_mem_write <= 1'b0;
            stalled_mem_addr <= '0;
            stalled_mem_data <= '0;
            stalled_cpu_request <= '0;
            stalled_cpu_addr <= '0;
            stalled_cpu_write <= '0;
            stalled_cpu_size <= '0;
            stalled_cpu_wdata <= '0;
            stalled_cpu_response <= '0;
            stalled_cpu_rdata <= '0;
            stalled_cpu_error <= '0;
            history_valid <= 1'b0;
            for (integer reset_core = 0; reset_core < CORE_COUNT; reset_core = reset_core + 1)
                for (integer reset_set = 0; reset_set < L1_SET_COUNT; reset_set = reset_set + 1)
                    for (integer reset_way = 0; reset_way < L1_WAYS; reset_way = reset_way + 1) begin
                        previous_l1_state[reset_core][reset_set][reset_way] <= MESI_I;
                        previous_l1_valid[reset_core][reset_set][reset_way] <= 1'b0;
                        previous_l1_tag[reset_core][reset_set][reset_way] <= '0;
                    end
        end else begin
            for (integer reset_core = 0; reset_core < CORE_COUNT; reset_core = reset_core + 1)
                for (integer reset_set = 0; reset_set < L1_SET_COUNT; reset_set = reset_set + 1)
                    for (integer reset_way = 0; reset_way < L1_WAYS; reset_way = reset_way + 1) begin
                        previous_l1_valid[reset_core][reset_set][reset_way] <=
                            l1_valid[reset_core][reset_set][reset_way];
                        previous_l1_tag[reset_core][reset_set][reset_way] <=
                            l1_tag[reset_core][reset_set][reset_way];
                    end
            if (stalled_mem_request)
                assert (mem_req_valid && mem_req_write == stalled_mem_write
                        && mem_req_addr == stalled_mem_addr
                        && mem_req_wdata == stalled_mem_data)
                    else $fatal(1, "Memory request changed while backpressured");
            stalled_mem_request <= mem_req_valid && !mem_req_ready;
            if (mem_req_valid && !mem_req_ready) begin
                stalled_mem_write <= mem_req_write;
                stalled_mem_addr <= mem_req_addr;
                stalled_mem_data <= mem_req_wdata;
            end
            for (integer check_core = 0; check_core < CORE_COUNT; check_core = check_core + 1) begin
                if (stalled_cpu_request[check_core])
                    assert (cpu_req_valid[check_core]
                            && cpu_req_addr[check_core] == stalled_cpu_addr[check_core]
                            && cpu_req_write[check_core] == stalled_cpu_write[check_core]
                            && cpu_req_size[check_core] == stalled_cpu_size[check_core]
                            && cpu_req_wdata[check_core] == stalled_cpu_wdata[check_core])
                        else $fatal(1, "CPU request changed while not ready");
                if (stalled_cpu_response[check_core])
                    assert (cpu_rsp_valid[check_core]
                            && cpu_rsp_rdata[check_core] == stalled_cpu_rdata[check_core]
                            && cpu_rsp_error[check_core] == stalled_cpu_error[check_core])
                        else $fatal(1, "CPU response changed while backpressured");
                stalled_cpu_request[check_core] <=
                    cpu_req_valid[check_core] && !cpu_req_ready[check_core];
                stalled_cpu_response[check_core] <=
                    cpu_rsp_valid[check_core] && !cpu_rsp_ready[check_core];
                if (cpu_req_valid[check_core] && !cpu_req_ready[check_core]) begin
                    stalled_cpu_addr[check_core] <= cpu_req_addr[check_core];
                    stalled_cpu_write[check_core] <= cpu_req_write[check_core];
                    stalled_cpu_size[check_core] <= cpu_req_size[check_core];
                    stalled_cpu_wdata[check_core] <= cpu_req_wdata[check_core];
                end
                if (cpu_rsp_valid[check_core] && !cpu_rsp_ready[check_core]) begin
                    stalled_cpu_rdata[check_core] <= cpu_rsp_rdata[check_core];
                    stalled_cpu_error[check_core] <= cpu_rsp_error[check_core];
                end
            end
            history_valid <= 1'b1;
        end
    end

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            for (integer reset_core = 0; reset_core < CORE_COUNT; reset_core = reset_core + 1)
                for (integer reset_set = 0; reset_set < L1_SET_COUNT; reset_set = reset_set + 1)
                    for (integer reset_way = 0; reset_way < L1_WAYS; reset_way = reset_way + 1)
                        previous_l1_state[reset_core][reset_set][reset_way] <= MESI_I;
        end else begin
            for (integer transition_core = 0; transition_core < CORE_COUNT;
                 transition_core = transition_core + 1) begin
                for (integer transition_set = 0; transition_set < L1_SET_COUNT;
                     transition_set = transition_set + 1) begin
                    for (integer transition_way = 0; transition_way < L1_WAYS;
                         transition_way = transition_way + 1) begin
                        if (history_valid
                            && previous_l1_valid[transition_core][transition_set][transition_way]
                            && previous_l1_tag[transition_core][transition_set][transition_way]
                                == l1_tag[transition_core][transition_set][transition_way])
                            assert (legal_cache_transition(
                                previous_l1_state[transition_core][transition_set][transition_way],
                                l1_state[transition_core][transition_set][transition_way]))
                                else $fatal(1,
                                    "Illegal MESI transition core=%0d set=%0d way=%0d prior=%b current=%b",
                                    transition_core, transition_set, transition_way,
                                    previous_l1_state[transition_core][transition_set][transition_way],
                                    l1_state[transition_core][transition_set][transition_way]);
                        previous_l1_state[transition_core][transition_set][transition_way] <=
                            l1_state[transition_core][transition_set][transition_way];
                    end
                end
            end
            for (integer c0 = 0; c0 < CORE_COUNT; c0 = c0 + 1) begin
                for (integer s0 = 0; s0 < L1_SET_COUNT; s0 = s0 + 1) begin
                    for (integer w0 = 0; w0 < L1_WAYS; w0 = w0 + 1) begin
                        if (l1_valid[c0][s0][w0]) begin
                            assert (l1_state[c0][s0][w0] != MESI_I)
                                else $fatal(1, "Valid L1 line has I state");
                            assert (l2_valid[
                                (make_l1_line_address(l1_tag[c0][s0][w0], s0)
                                    >> LINE_OFFSET_BITS) & (L2_SET_COUNT - 1)
                            ][0] && l2_tag[
                                (make_l1_line_address(l1_tag[c0][s0][w0], s0)
                                    >> LINE_OFFSET_BITS) & (L2_SET_COUNT - 1)
                            ][0] == L2_TAG_WIDTH'(
                                make_l1_line_address(l1_tag[c0][s0][w0], s0)
                                    >> (LINE_OFFSET_BITS + L2_INDEX_BITS))
                            || l2_valid[
                                (make_l1_line_address(l1_tag[c0][s0][w0], s0)
                                    >> LINE_OFFSET_BITS) & (L2_SET_COUNT - 1)
                            ][1] && l2_tag[
                                (make_l1_line_address(l1_tag[c0][s0][w0], s0)
                                    >> LINE_OFFSET_BITS) & (L2_SET_COUNT - 1)
                            ][1] == L2_TAG_WIDTH'(
                                make_l1_line_address(l1_tag[c0][s0][w0], s0)
                                    >> (LINE_OFFSET_BITS + L2_INDEX_BITS)))
                                else $fatal(1, "Inclusive L2 entry missing for a valid L1 line");
                        end
                    end
                end
            end
            for (integer s = 0; s < L1_SET_COUNT; s = s + 1) begin
                for (integer w0 = 0; w0 < L1_WAYS; w0 = w0 + 1) begin
                    for (integer w1 = 0; w1 < L1_WAYS; w1 = w1 + 1) begin
                        if (l1_valid[0][s][w0] && l1_valid[1][s][w1]
                            && l1_tag[0][s][w0] == l1_tag[1][s][w1]) begin
                            assert (l1_state[0][s][w0] != MESI_M
                                    && l1_state[1][s][w1] != MESI_M
                                    && l1_state[0][s][w0] != MESI_E
                                    && l1_state[1][s][w1] != MESI_E)
                                else $fatal(1, "MESI exclusive ownership invariant failed");
                            assert (l1_data[0][s][w0] == l1_data[1][s][w1])
                                else $fatal(1, "Shared copies have different line data");
                        end
                    end
                end
            end
        end
    end

    initial begin
        if (CORE_COUNT != 2 || DATA_WIDTH != 32 || LINE_BYTES != 16
            || L1_WAYS != 2 || L2_WAYS != 2
            || (L1_SET_COUNT & (L1_SET_COUNT - 1)) != 0
            || (L2_SET_COUNT & (L2_SET_COUNT - 1)) != 0)
            $fatal(1, "mesi_cache_system currently requires 2 cores, 32-bit data, 16-byte lines, 2-way caches, and power-of-two set counts");
    end
`endif

`ifdef FORMAL
    logic formal_history_valid;
    logic [1:0] formal_previous_l1_state
        [0:CORE_COUNT-1][0:L1_SET_COUNT-1][0:L1_WAYS-1];
    logic formal_previous_l1_valid
        [0:CORE_COUNT-1][0:L1_SET_COUNT-1][0:L1_WAYS-1];
    logic [L1_TAG_WIDTH-1:0] formal_previous_l1_tag
        [0:CORE_COUNT-1][0:L1_SET_COUNT-1][0:L1_WAYS-1];
    logic formal_dirty_l1_writeback_pending;
    integer formal_dirty_l2_set;
    integer formal_dirty_l2_way;
    logic [LINE_BITS-1:0] formal_dirty_l1_writeback_data;
    logic formal_backinvalidate_pending;
    logic [ADDRESS_WIDTH-1:0] formal_backinvalidate_address;
    integer formal_core;
    integer formal_set;
    integer formal_way;
    integer formal_peer_set;
    integer formal_peer_way;
    integer formal_l2_set;
    integer formal_l2_way;
    logic [ADDRESS_WIDTH-1:0] formal_line_address;
    logic [ADDRESS_WIDTH-1:0] formal_peer_line_address;
    logic [L2_TAG_WIDTH-1:0] formal_l2_tag;
    logic formal_l2_found;

    function automatic logic formal_legal_transition(
        input logic [1:0] prior,
        input logic [1:0] current
    );
        begin
            formal_legal_transition = prior == current
                || (prior == MESI_I
                    && (current == MESI_S || current == MESI_E || current == MESI_M))
                || (prior == MESI_S && (current == MESI_I || current == MESI_M))
                || (prior == MESI_E
                    && (current == MESI_I || current == MESI_S || current == MESI_M))
                || (prior == MESI_M && (current == MESI_I || current == MESI_S));
        end
    endfunction

    always @(posedge clk) begin
        if (!rst_n) begin
            formal_history_valid <= 1'b0;
            formal_dirty_l1_writeback_pending <= 1'b0;
            formal_backinvalidate_pending <= 1'b0;
            formal_backinvalidate_address <= '0;
            formal_dirty_l2_set <= 0;
            formal_dirty_l2_way <= 0;
            formal_dirty_l1_writeback_data <= '0;
            assert (state == ST_IDLE);
            assert (mshr_valid == '0);
            assert (cpu_rsp_valid == '0);
            assert (!mem_req_valid);
            for (formal_core = 0; formal_core < CORE_COUNT; formal_core = formal_core + 1)
                for (formal_set = 0; formal_set < L1_SET_COUNT; formal_set = formal_set + 1)
                    for (formal_way = 0; formal_way < L1_WAYS; formal_way = formal_way + 1) begin
                        assert (!l1_valid[formal_core][formal_set][formal_way]);
                        formal_previous_l1_valid[formal_core][formal_set][formal_way] <= 1'b0;
                        formal_previous_l1_state[formal_core][formal_set][formal_way] <= MESI_I;
                        formal_previous_l1_tag[formal_core][formal_set][formal_way] <= '0;
                    end
            for (formal_set = 0; formal_set < L2_SET_COUNT; formal_set = formal_set + 1)
                for (formal_way = 0; formal_way < L2_WAYS; formal_way = formal_way + 1)
                    assert (!l2_valid[formal_set][formal_way]);
        end else begin
            formal_history_valid <= 1'b1;

            if (formal_dirty_l1_writeback_pending) begin
                assert (l2_valid[formal_dirty_l2_set][formal_dirty_l2_way]);
                assert (l2_dirty[formal_dirty_l2_set][formal_dirty_l2_way]);
                assert (l2_data[formal_dirty_l2_set][formal_dirty_l2_way]
                    == formal_dirty_l1_writeback_data);
            end
            formal_dirty_l1_writeback_pending <=
                state == ST_INSTALL && install_victim_l2_hit
                && l1_valid[active_core][active_l1_set][install_way]
                && l1_state[active_core][active_l1_set][install_way] == MESI_M;
            if (state == ST_INSTALL && install_victim_l2_hit
                && l1_valid[active_core][active_l1_set][install_way]
                && l1_state[active_core][active_l1_set][install_way] == MESI_M) begin
                formal_dirty_l2_set <= install_victim_l2_set;
                formal_dirty_l2_way <= install_victim_l2_way;
                formal_dirty_l1_writeback_data <=
                    l1_data[active_core][active_l1_set][install_way];
            end

            if (formal_backinvalidate_pending) begin
                for (formal_core = 0; formal_core < CORE_COUNT;
                     formal_core = formal_core + 1)
                    for (formal_set = 0; formal_set < L1_SET_COUNT;
                         formal_set = formal_set + 1)
                        for (formal_way = 0; formal_way < L1_WAYS;
                             formal_way = formal_way + 1)
                            assert (!l1_valid[formal_core][formal_set][formal_way]
                                || make_l1_line_address(
                                    l1_tag[formal_core][formal_set][formal_way],
                                    formal_set) != formal_backinvalidate_address);
            end
            formal_backinvalidate_pending <= state == ST_EVICT_L2;
            if (state == ST_EVICT_L2)
                formal_backinvalidate_address <= victim_line_addr;

            for (formal_core = 0; formal_core < CORE_COUNT; formal_core = formal_core + 1)
                for (formal_set = 0; formal_set < L1_SET_COUNT; formal_set = formal_set + 1)
                    for (formal_way = 0; formal_way < L1_WAYS; formal_way = formal_way + 1) begin
                        formal_previous_l1_valid[formal_core][formal_set][formal_way] <=
                            l1_valid[formal_core][formal_set][formal_way];
                        formal_previous_l1_state[formal_core][formal_set][formal_way] <=
                            l1_state[formal_core][formal_set][formal_way];
                        formal_previous_l1_tag[formal_core][formal_set][formal_way] <=
                            l1_tag[formal_core][formal_set][formal_way];

                        if (l1_valid[formal_core][formal_set][formal_way]) begin
                            assert (l1_state[formal_core][formal_set][formal_way] != MESI_I);
                            formal_line_address = make_l1_line_address(
                                l1_tag[formal_core][formal_set][formal_way], formal_set);
                            formal_l2_set = (formal_line_address >> LINE_OFFSET_BITS)
                                & (L2_SET_COUNT - 1);
                            formal_l2_tag = formal_line_address
                                >> (LINE_OFFSET_BITS + L2_INDEX_BITS);
                            formal_l2_found = 1'b0;
                            for (integer scan_set = 0; scan_set < L2_SET_COUNT;
                                 scan_set = scan_set + 1)
                                for (integer scan_way = 0; scan_way < L2_WAYS;
                                     scan_way = scan_way + 1)
                                    if (formal_l2_set == scan_set
                                        && l2_valid[scan_set][scan_way]
                                        && l2_tag[scan_set][scan_way] == formal_l2_tag)
                                        formal_l2_found = 1'b1;
                            assert (formal_l2_found);
                        end

                        if (formal_history_valid
                            && formal_previous_l1_valid[formal_core][formal_set][formal_way]
                            && formal_previous_l1_tag[formal_core][formal_set][formal_way]
                                == l1_tag[formal_core][formal_set][formal_way])
                            assert (formal_legal_transition(
                                formal_previous_l1_state[formal_core][formal_set][formal_way],
                                l1_state[formal_core][formal_set][formal_way]));
                    end

            for (formal_set = 0; formal_set < L1_SET_COUNT; formal_set = formal_set + 1)
                for (formal_way = 0; formal_way < L1_WAYS; formal_way = formal_way + 1)
                    for (formal_peer_set = 0; formal_peer_set < L1_SET_COUNT;
                         formal_peer_set = formal_peer_set + 1)
                        for (formal_peer_way = 0; formal_peer_way < L1_WAYS;
                             formal_peer_way = formal_peer_way + 1)
                            if (l1_valid[0][formal_set][formal_way]
                                && l1_valid[1][formal_peer_set][formal_peer_way]) begin
                                formal_line_address = make_l1_line_address(
                                    l1_tag[0][formal_set][formal_way], formal_set);
                                formal_peer_line_address = make_l1_line_address(
                                    l1_tag[1][formal_peer_set][formal_peer_way],
                                    formal_peer_set);
                                if (formal_line_address == formal_peer_line_address) begin
                                    assert (l1_state[0][formal_set][formal_way] != MESI_M
                                        && l1_state[0][formal_set][formal_way] != MESI_E
                                        && l1_state[1][formal_peer_set][formal_peer_way] != MESI_M
                                        && l1_state[1][formal_peer_set][formal_peer_way] != MESI_E);
                                    assert (l1_data[0][formal_set][formal_way]
                                        == l1_data[1][formal_peer_set][formal_peer_way]);
                                end
                            end

            assert (!l1_lookup_hit
                || (l1_valid[active_core][active_l1_set][l1_lookup_way]
                    && l1_state[active_core][active_l1_set][l1_lookup_way] != MESI_I));
            if (state == ST_MEM_WRITE_REQ) begin
                assert (mem_req_valid && mem_req_write);
                assert (mem_req_addr == victim_line_addr);
                assert (mem_req_wdata == victim_line_data);
            end
            if (state == ST_INSTALL && active_source_valid
                && !active_write && active_peer_state == MESI_M)
                assert (fill_data == active_source_data);
        end
    end
`endif
endmodule
