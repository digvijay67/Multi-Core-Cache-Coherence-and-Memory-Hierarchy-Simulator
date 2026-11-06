module mesi_cache_system_formal;
    localparam integer CORE_COUNT = 2;
    localparam integer ADDRESS_WIDTH = 8;
    localparam integer DATA_WIDTH = 32;
    localparam integer LINE_BYTES = 4;
    localparam integer LINE_BITS = LINE_BYTES * 8;

    (* gclk *) logic clk;
    (* anyseq *) logic rst_n;
    logic past_valid = 1'b0;

    (* anyseq *) logic [CORE_COUNT-1:0] cpu_req_valid;
    logic [CORE_COUNT-1:0] cpu_req_ready;
    (* anyseq *) logic [CORE_COUNT-1:0] cpu_req_write;
    (* anyseq *) logic [CORE_COUNT-1:0][ADDRESS_WIDTH-1:0] cpu_req_addr;
    (* anyseq *) logic [CORE_COUNT-1:0][1:0] cpu_req_size;
    (* anyseq *) logic [CORE_COUNT-1:0][DATA_WIDTH-1:0] cpu_req_wdata;
    logic [CORE_COUNT-1:0] cpu_rsp_valid;
    (* anyseq *) logic [CORE_COUNT-1:0] cpu_rsp_ready;
    logic [CORE_COUNT-1:0][DATA_WIDTH-1:0] cpu_rsp_rdata;
    logic [CORE_COUNT-1:0] cpu_rsp_error;

    logic mem_req_valid;
    (* anyseq *) logic mem_req_ready;
    logic mem_req_write;
    logic [ADDRESS_WIDTH-1:0] mem_req_addr;
    logic [LINE_BITS-1:0] mem_req_wdata;
    (* anyseq *) logic mem_rsp_valid;
    logic mem_rsp_ready;
    (* anyseq *) logic [LINE_BITS-1:0] mem_rsp_rdata;

    logic [CORE_COUNT-1:0] request_open = '0;
    logic memory_transaction_open = 1'b0;
    logic [CORE_COUNT-1:0] stalled_cpu_request = '0;
    logic [CORE_COUNT-1:0][ADDRESS_WIDTH-1:0] stalled_cpu_addr;
    logic [CORE_COUNT-1:0] stalled_cpu_write;
    logic [CORE_COUNT-1:0][1:0] stalled_cpu_size;
    logic [CORE_COUNT-1:0][DATA_WIDTH-1:0] stalled_cpu_wdata;
    logic [CORE_COUNT-1:0] stalled_cpu_response = '0;
    logic [CORE_COUNT-1:0][DATA_WIDTH-1:0] stalled_cpu_rdata;
    logic [CORE_COUNT-1:0] stalled_cpu_error;
    logic stalled_mem_request = 1'b0;
    logic stalled_mem_write;
    logic [ADDRESS_WIDTH-1:0] stalled_mem_addr;
    logic [LINE_BITS-1:0] stalled_mem_wdata;

    mesi_cache_system #(
        .CORE_COUNT(CORE_COUNT),
        .ADDRESS_WIDTH(ADDRESS_WIDTH),
        .DATA_WIDTH(DATA_WIDTH),
        .LINE_BYTES(LINE_BYTES),
        .L1_CAPACITY_BYTES(16),
        .L1_WAYS(2),
        .L2_CAPACITY_BYTES(16),
        .L2_WAYS(2)
    ) dut (
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

    always @(posedge clk) begin
        past_valid <= 1'b1;
        if (!past_valid)
            assume (!rst_n);

        if (!rst_n) begin
            assume (cpu_req_valid == '0);
            request_open <= '0;
            memory_transaction_open <= 1'b0;
            stalled_cpu_request <= '0;
            stalled_cpu_response <= '0;
            stalled_mem_request <= 1'b0;
        end else begin
            for (integer core = 0; core < CORE_COUNT; core = core + 1) begin
                if (stalled_cpu_request[core]) begin
                    assume (cpu_req_valid[core]);
                    assume (cpu_req_addr[core] == stalled_cpu_addr[core]);
                    assume (cpu_req_write[core] == stalled_cpu_write[core]);
                    assume (cpu_req_size[core] == stalled_cpu_size[core]);
                    assume (cpu_req_wdata[core] == stalled_cpu_wdata[core]);
                end
                if (stalled_cpu_response[core]) begin
                    assert (cpu_rsp_valid[core]);
                    assert (cpu_rsp_rdata[core] == stalled_cpu_rdata[core]);
                    assert (cpu_rsp_error[core] == stalled_cpu_error[core]);
                end
                stalled_cpu_request[core] <=
                    cpu_req_valid[core] && !cpu_req_ready[core];
                stalled_cpu_addr[core] <= cpu_req_addr[core];
                stalled_cpu_write[core] <= cpu_req_write[core];
                stalled_cpu_size[core] <= cpu_req_size[core];
                stalled_cpu_wdata[core] <= cpu_req_wdata[core];
                stalled_cpu_response[core] <=
                    cpu_rsp_valid[core] && !cpu_rsp_ready[core];
                stalled_cpu_rdata[core] <= cpu_rsp_rdata[core];
                stalled_cpu_error[core] <= cpu_rsp_error[core];

                if (cpu_rsp_valid[core])
                    assert (request_open[core]);
                if (cpu_req_valid[core] && cpu_req_ready[core])
                    assert (!request_open[core]);
                if (cpu_rsp_valid[core] && cpu_rsp_ready[core])
                    request_open[core] <= 1'b0;
                else if (cpu_req_valid[core] && cpu_req_ready[core])
                    request_open[core] <= 1'b1;
            end

            if (stalled_mem_request) begin
                assert (mem_req_valid);
                assert (mem_req_write == stalled_mem_write);
                assert (mem_req_addr == stalled_mem_addr);
                assert (mem_req_wdata == stalled_mem_wdata);
            end
            stalled_mem_request <= mem_req_valid && !mem_req_ready;
            stalled_mem_write <= mem_req_write;
            stalled_mem_addr <= mem_req_addr;
            stalled_mem_wdata <= mem_req_wdata;

            if (mem_rsp_valid)
                assume (memory_transaction_open);
            if (past_valid && $past(rst_n && mem_rsp_valid && !mem_rsp_ready)) begin
                assume (mem_rsp_valid);
                assume (mem_rsp_rdata == $past(mem_rsp_rdata));
            end
            if (mem_req_valid && mem_req_ready) begin
                assert (!memory_transaction_open);
                memory_transaction_open <= 1'b1;
            end
            if (mem_rsp_valid && mem_rsp_ready)
                memory_transaction_open <= 1'b0;
        end
    end
endmodule
