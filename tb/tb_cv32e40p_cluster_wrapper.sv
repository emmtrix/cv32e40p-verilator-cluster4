module tb_cv32e40p_cluster_wrapper #(
    parameter int unsigned NUM_CORES = 4,
    parameter int unsigned INSTR_RDATA_WIDTH = 32,
    parameter int unsigned RAM_ADDR_WIDTH = 22,
    parameter logic [31:0] BOOT_ADDR = 32'h00000080,
    parameter logic [31:0] DM_HALTADDRESS = 32'h1A110800
) (
    input  logic clk_i,
    input  logic rst_ni,
    input  logic fetch_enable_i,
    output logic tests_passed_o,
    output logic tests_failed_o,
    output logic [31:0] exit_value_o,
    output logic exit_valid_o
);

    localparam int unsigned CORE_IDX_W = (NUM_CORES > 1) ? $clog2(NUM_CORES) : 1;
    localparam int unsigned FIFO_DEPTH = 32;
    localparam int unsigned FIFO_PTR_W = $clog2(FIFO_DEPTH);

    logic [NUM_CORES-1:0] core_instr_req;
    logic [NUM_CORES-1:0] core_instr_gnt;
    logic [NUM_CORES-1:0] core_instr_rvalid;
    logic [NUM_CORES-1:0][31:0] core_instr_addr;
    logic [NUM_CORES-1:0][INSTR_RDATA_WIDTH-1:0] core_instr_rdata;

    logic [NUM_CORES-1:0] core_data_req;
    logic [NUM_CORES-1:0] core_data_gnt;
    logic [NUM_CORES-1:0] core_data_rvalid;
    logic [NUM_CORES-1:0] core_data_we;
    logic [NUM_CORES-1:0][3:0] core_data_be;
    logic [NUM_CORES-1:0][31:0] core_data_addr;
    logic [NUM_CORES-1:0][31:0] core_data_wdata;
    logic [NUM_CORES-1:0][31:0] core_data_rdata;

    logic [NUM_CORES-1:0][31:0] core_irq;
    logic [NUM_CORES-1:0] core_irq_ack;
    logic [NUM_CORES-1:0][4:0] core_irq_id;

    logic [NUM_CORES-1:0] core_debug_req;

    logic instr_req_shared;
    logic [31:0] instr_addr_shared;
    logic [INSTR_RDATA_WIDTH-1:0] instr_rdata_shared;
    logic instr_rvalid_shared;
    logic instr_gnt_shared;

    logic data_req_shared;
    logic [31:0] data_addr_shared;
    logic data_we_shared;
    logic [3:0] data_be_shared;
    logic [31:0] data_wdata_shared;
    logic [31:0] data_rdata_shared;
    logic data_rvalid_shared;
    logic data_gnt_shared;

    logic [31:0] irq_shared;
    logic [4:0] irq_id_shared;
    logic irq_ack_shared;
    logic debug_req_shared;

    logic [31:0] instr_pc_shared;

    logic [CORE_IDX_W-1:0] instr_rr_q;
    logic [CORE_IDX_W-1:0] instr_sel_idx;
    logic instr_sel_valid;

    logic [CORE_IDX_W-1:0] data_rr_q;
    logic [CORE_IDX_W-1:0] data_sel_idx;
    logic data_sel_valid;

    logic [CORE_IDX_W-1:0] instr_rsp_fifo[FIFO_DEPTH-1:0];
    logic [FIFO_PTR_W-1:0] instr_rsp_wptr_q;
    logic [FIFO_PTR_W-1:0] instr_rsp_rptr_q;
    logic [FIFO_PTR_W:0] instr_rsp_count_q;

    logic [CORE_IDX_W-1:0] data_rsp_fifo[FIFO_DEPTH-1:0];
    logic [FIFO_PTR_W-1:0] data_rsp_wptr_q;
    logic [FIFO_PTR_W-1:0] data_rsp_rptr_q;
    logic [FIFO_PTR_W:0] data_rsp_count_q;

    logic instr_push;
    logic instr_pop;
    logic [CORE_IDX_W-1:0] instr_pop_core;

    logic data_push;
    logic data_pop;
    logic [CORE_IDX_W-1:0] data_pop_core;

    genvar g_core;
    generate
        for (g_core = 0; g_core < NUM_CORES; g_core++) begin : core_gen
            cv32e40p_top #(
                .COREV_PULP(0),
                .COREV_CLUSTER(0),
                .FPU(0),
                .ZFINX(0),
                .NUM_MHPMCOUNTERS(1)
            ) cv32e40p_top_i (
                .clk_i(clk_i),
                .rst_ni(rst_ni),
                .pulp_clock_en_i(1'b1),
                .scan_cg_en_i(1'b0),
                .boot_addr_i(BOOT_ADDR),
                .mtvec_addr_i(32'h00000000),
                .dm_halt_addr_i(DM_HALTADDRESS),
                .hart_id_i(g_core),
                .dm_exception_addr_i(32'h1A111000),
                .instr_req_o(core_instr_req[g_core]),
                .instr_gnt_i(core_instr_gnt[g_core]),
                .instr_rvalid_i(core_instr_rvalid[g_core]),
                .instr_addr_o(core_instr_addr[g_core]),
                .instr_rdata_i(core_instr_rdata[g_core]),
                .data_req_o(core_data_req[g_core]),
                .data_gnt_i(core_data_gnt[g_core]),
                .data_rvalid_i(core_data_rvalid[g_core]),
                .data_we_o(core_data_we[g_core]),
                .data_be_o(core_data_be[g_core]),
                .data_addr_o(core_data_addr[g_core]),
                .data_wdata_o(core_data_wdata[g_core]),
                .data_rdata_i(core_data_rdata[g_core]),
                .irq_i(core_irq[g_core]),
                .irq_ack_o(core_irq_ack[g_core]),
                .irq_id_o(core_irq_id[g_core]),
                .debug_req_i(core_debug_req[g_core]),
                .debug_havereset_o(),
                .debug_running_o(),
                .debug_halted_o(),
                .fetch_enable_i(fetch_enable_i),
                .core_sleep_o()
            );

            assign core_irq[g_core] = irq_shared;
            assign core_debug_req[g_core] = debug_req_shared;
        end
    endgenerate

    always_comb begin
        instr_sel_valid = 1'b0;
        instr_sel_idx = instr_rr_q;
        for (int ofs = 0; ofs < NUM_CORES; ofs++) begin
            int idx;
            idx = instr_rr_q + ofs;
            if (idx >= NUM_CORES) idx -= NUM_CORES;
            if (!instr_sel_valid && core_instr_req[idx]) begin
                instr_sel_valid = 1'b1;
                instr_sel_idx = idx[CORE_IDX_W-1:0];
            end
        end
    end

    always_comb begin
        data_sel_valid = 1'b0;
        data_sel_idx = data_rr_q;
        for (int ofs = 0; ofs < NUM_CORES; ofs++) begin
            int idx;
            idx = data_rr_q + ofs;
            if (idx >= NUM_CORES) idx -= NUM_CORES;
            if (!data_sel_valid && core_data_req[idx]) begin
                data_sel_valid = 1'b1;
                data_sel_idx = idx[CORE_IDX_W-1:0];
            end
        end
    end

    assign instr_req_shared = instr_sel_valid;
    assign instr_addr_shared = instr_sel_valid ? core_instr_addr[instr_sel_idx] : '0;
    assign instr_pc_shared = instr_sel_valid ? core_instr_addr[instr_sel_idx] : '0;

    assign data_req_shared = data_sel_valid;
    assign data_addr_shared = data_sel_valid ? core_data_addr[data_sel_idx] : '0;
    assign data_we_shared = data_sel_valid ? core_data_we[data_sel_idx] : 1'b0;
    assign data_be_shared = data_sel_valid ? core_data_be[data_sel_idx] : '0;
    assign data_wdata_shared = data_sel_valid ? core_data_wdata[data_sel_idx] : '0;

    generate
        for (g_core = 0; g_core < NUM_CORES; g_core++) begin : grant_route
            assign core_instr_gnt[g_core] = instr_sel_valid && (instr_sel_idx == g_core[CORE_IDX_W-1:0]) && instr_gnt_shared;
            assign core_data_gnt[g_core] = data_sel_valid && (data_sel_idx == g_core[CORE_IDX_W-1:0]) && data_gnt_shared;
        end
    endgenerate

    always_comb begin
        for (int i = 0; i < NUM_CORES; i++) begin
            core_instr_rvalid[i] = 1'b0;
            core_instr_rdata[i] = '0;
            core_data_rvalid[i] = 1'b0;
            core_data_rdata[i] = '0;
        end

        if (instr_pop) begin
            core_instr_rvalid[instr_pop_core] = 1'b1;
            core_instr_rdata[instr_pop_core] = instr_rdata_shared;
        end

        if (data_pop) begin
            core_data_rvalid[data_pop_core] = 1'b1;
            core_data_rdata[data_pop_core] = data_rdata_shared;
        end
    end

    always_comb begin
        irq_ack_shared = 1'b0;
        irq_id_shared = '0;
        for (int i = 0; i < NUM_CORES; i++) begin
            if (!irq_ack_shared && core_irq_ack[i]) begin
                irq_ack_shared = 1'b1;
                irq_id_shared = core_irq_id[i];
            end
        end
    end

    assign instr_push = instr_sel_valid && instr_gnt_shared && (instr_rsp_count_q < FIFO_DEPTH);
    assign instr_pop = instr_rvalid_shared && (instr_rsp_count_q != 0);
    assign instr_pop_core = instr_rsp_fifo[instr_rsp_rptr_q];

    assign data_push = data_sel_valid && data_gnt_shared && (data_rsp_count_q < FIFO_DEPTH);
    assign data_pop = data_rvalid_shared && (data_rsp_count_q != 0);
    assign data_pop_core = data_rsp_fifo[data_rsp_rptr_q];

    always_ff @(posedge clk_i or negedge rst_ni) begin
        if (!rst_ni) begin
            instr_rr_q <= '0;
            data_rr_q <= '0;

            instr_rsp_wptr_q <= '0;
            instr_rsp_rptr_q <= '0;
            instr_rsp_count_q <= '0;

            data_rsp_wptr_q <= '0;
            data_rsp_rptr_q <= '0;
            data_rsp_count_q <= '0;
        end else begin
            if (instr_push) begin
                instr_rsp_fifo[instr_rsp_wptr_q] <= instr_sel_idx;
                instr_rsp_wptr_q <= instr_rsp_wptr_q + 1'b1;
            end
            if (instr_pop) begin
                instr_rsp_rptr_q <= instr_rsp_rptr_q + 1'b1;
            end
            case ({instr_push, instr_pop})
                2'b10: instr_rsp_count_q <= instr_rsp_count_q + 1'b1;
                2'b01: instr_rsp_count_q <= instr_rsp_count_q - 1'b1;
                default: ;
            endcase

            if (data_push) begin
                data_rsp_fifo[data_rsp_wptr_q] <= data_sel_idx;
                data_rsp_wptr_q <= data_rsp_wptr_q + 1'b1;
            end
            if (data_pop) begin
                data_rsp_rptr_q <= data_rsp_rptr_q + 1'b1;
            end
            case ({data_push, data_pop})
                2'b10: data_rsp_count_q <= data_rsp_count_q + 1'b1;
                2'b01: data_rsp_count_q <= data_rsp_count_q - 1'b1;
                default: ;
            endcase

            if (instr_sel_valid && instr_gnt_shared) begin
                if (instr_sel_idx == NUM_CORES-1) instr_rr_q <= '0;
                else instr_rr_q <= instr_sel_idx + 1'b1;
            end
            if (data_sel_valid && data_gnt_shared) begin
                if (data_sel_idx == NUM_CORES-1) data_rr_q <= '0;
                else data_rr_q <= data_sel_idx + 1'b1;
            end
        end
    end

    mm_ram #(
        .RAM_ADDR_WIDTH(RAM_ADDR_WIDTH),
        .INSTR_RDATA_WIDTH(INSTR_RDATA_WIDTH),
        .NUM_CORES(NUM_CORES)
    ) ram_i (
        .clk_i(clk_i),
        .rst_ni(rst_ni),
        .dm_halt_addr_i(DM_HALTADDRESS),
        .instr_req_i(instr_req_shared),
        .instr_addr_i(instr_addr_shared),
        .instr_rdata_o(instr_rdata_shared),
        .instr_rvalid_o(instr_rvalid_shared),
        .instr_gnt_o(instr_gnt_shared),
        .data_req_i(data_req_shared),
        .data_addr_i(data_addr_shared),
        .data_we_i(data_we_shared),
        .data_be_i(data_be_shared),
        .data_wdata_i(data_wdata_shared),
        .data_rdata_o(data_rdata_shared),
        .data_rvalid_o(data_rvalid_shared),
        .data_gnt_o(data_gnt_shared),
        .irq_id_i(irq_id_shared),
        .irq_ack_i(irq_ack_shared),
        .irq_o(irq_shared),
        .pc_core_id_i(instr_pc_shared),
        .data_core_id_i({{(32-CORE_IDX_W){1'b0}}, data_sel_idx}),
        .debug_req_o(debug_req_shared),
        .tests_passed_o(tests_passed_o),
        .tests_failed_o(tests_failed_o),
        .exit_valid_o(exit_valid_o),
        .exit_value_o(exit_value_o)
    );

endmodule
