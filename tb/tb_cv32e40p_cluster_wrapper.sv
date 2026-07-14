// SPDX-FileCopyrightText: 2026 emmtrix Technologies GmbH
// SPDX-License-Identifier: Apache-2.0

module tb_cv32e40p_cluster_wrapper #(
    parameter int unsigned NUM_CORES = 4,
    parameter int unsigned INSTR_RDATA_WIDTH = 32,
    parameter int unsigned RAM_ADDR_WIDTH = 26,
    parameter logic [31:0] BOOT_ADDR = 32'h00000080,
    parameter logic [31:0] DM_HALTADDRESS = 32'h1A110800,
    parameter int unsigned SPM_ADDR_WIDTH = 18,
    parameter logic [31:0] SPM_BASE_ADDR = 32'h1800_0000,
    parameter int unsigned SHARED_MEM_EXTRA_LATENCY = 20,
    parameter int unsigned REMOTE_SPM_EXTRA_LATENCY = 20,
    parameter int unsigned DMA_QUEUE_SLOTS = 3
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

    tb_mem_types_pkg::tb_mem_req_t core_instr_req [NUM_CORES];
    tb_mem_types_pkg::tb_mem_rsp_t core_instr_rsp [NUM_CORES];

    tb_mem_types_pkg::tb_mem_req_t core_shared_req [NUM_CORES];
    tb_mem_types_pkg::tb_mem_rsp_t core_shared_rsp [NUM_CORES];
    tb_mem_types_pkg::tb_mem_rsp_t core_shared_rsp_raw [NUM_CORES];

    tb_mem_types_pkg::tb_mem_req_t core_remote_req [NUM_CORES];
    tb_mem_types_pkg::tb_mem_rsp_t core_remote_rsp_raw [NUM_CORES];
    tb_mem_types_pkg::tb_mem_rsp_t core_remote_rsp [NUM_CORES];

    logic [NUM_CORES-1:0][CORE_IDX_W-1:0] core_remote_target;

    tb_mem_types_pkg::tb_mem_req_t instr_shared_req;
    tb_mem_types_pkg::tb_mem_rsp_t instr_shared_rsp;

    tb_mem_types_pkg::tb_mem_req_t data_shared_req;
    tb_mem_types_pkg::tb_mem_rsp_t data_shared_rsp;

    tb_mem_types_pkg::tb_mem_req_t remote_in_req [NUM_CORES];
    tb_mem_types_pkg::tb_mem_rsp_t remote_in_rsp [NUM_CORES];
    logic [NUM_CORES-1:0][CORE_IDX_W-1:0] remote_in_src_core;

    logic [31:0]                   irq_shared;
    logic [4:0]                    irq_id_shared;
    logic                          irq_ack_shared;
    logic                          debug_req_shared;
    logic [31:0]                   instr_pc_shared;

    logic [NUM_CORES-1:0][31:0]                 core_irq;
    logic [NUM_CORES-1:0]                       core_irq_ack;
    logic [NUM_CORES-1:0][4:0]                  core_irq_id;
    logic [NUM_CORES-1:0]                       core_debug_req;

    logic [NUM_CORES-1:0][NUM_CORES-1:0]        remote_req_mask;
    tb_mem_types_pkg::tb_mem_rsp_t              remote_rsp_vec [NUM_CORES][NUM_CORES];
    logic [CORE_IDX_W-1:0]                      remote_req_idx [NUM_CORES];

    logic [CORE_IDX_W-1:0] instr_req_idx;
    logic                  instr_req_valid;

    logic [CORE_IDX_W-1:0] data_req_idx;
    logic                  data_req_valid;

    logic                  data_rsp_valid_raw;
    logic [CORE_IDX_W-1:0] data_rsp_idx_raw;
    logic [31:0]           data_rsp_data_raw;

    logic                  shared_pipe_valid_out;
    logic [CORE_IDX_W-1:0] shared_pipe_core_out;
    logic [31:0]           shared_pipe_rdata_out;

    logic [NUM_CORES-1:0]        remote_rsp_valid_raw;
    logic [NUM_CORES-1:0]        remote_pipe_valid_out;
    logic [NUM_CORES-1:0][31:0]  remote_pipe_rdata_out;

    initial begin : checks
        if ((SPM_BASE_ADDR & ((NUM_CORES << SPM_ADDR_WIDTH) - 1)) != 0)
            $fatal(1, "[CLUSTER] SPM_BASE_ADDR must be aligned to NUM_CORES * 2**SPM_ADDR_WIDTH");
        if (INSTR_RDATA_WIDTH != 32)
            $fatal(1, "[CLUSTER] Struct refactor currently expects INSTR_RDATA_WIDTH=32");
    end

    genvar g_core;
    generate
        for (g_core = 0; g_core < NUM_CORES; g_core++) begin : core_gen
            tb_cv32e40p_cluster_core #(
                .NUM_CORES        (NUM_CORES),
                .CORE_ID          (g_core),
                .INSTR_RDATA_WIDTH(INSTR_RDATA_WIDTH),
                .BOOT_ADDR        (BOOT_ADDR),
                .DM_HALTADDRESS   (DM_HALTADDRESS),
                .SPM_ADDR_WIDTH   (SPM_ADDR_WIDTH),
                .SPM_BASE_ADDR    (SPM_BASE_ADDR),
                .DMA_QUEUE_SLOTS  (DMA_QUEUE_SLOTS)
            ) core_i (
                .clk_i              (clk_i),
                .rst_ni             (rst_ni),
                .fetch_enable_i     (fetch_enable_i),
                .irq_i              (core_irq[g_core]),
                .debug_req_i        (core_debug_req[g_core]),
                .irq_ack_o          (core_irq_ack[g_core]),
                .irq_id_o           (core_irq_id[g_core]),
                .instr_req_o        (core_instr_req[g_core]),
                .instr_rsp_i        (core_instr_rsp[g_core]),
                .shared_req_o       (core_shared_req[g_core]),
                .shared_rsp_i       (core_shared_rsp[g_core]),
                .remote_req_o       (core_remote_req[g_core]),
                .remote_rsp_i       (core_remote_rsp[g_core]),
                .remote_target_o    (core_remote_target[g_core]),
                .remote_in_req_i    (remote_in_req[g_core]),
                .remote_in_src_core_i(remote_in_src_core[g_core]),
                .remote_in_rsp_o    (remote_in_rsp[g_core]),
                .remote_in_rsp_core_o()
            );

            assign core_irq[g_core] = irq_shared;
            assign core_debug_req[g_core] = debug_req_shared;
        end
    endgenerate

    rr_arbiter #(
        .NUM_REQ(NUM_CORES)
    ) instr_arb_i (
        .clk_i      (clk_i),
        .rst_ni     (rst_ni),
        .req_mask_i ('1),
        .req_i      (core_instr_req),
        .rsp_o      (core_instr_rsp),
        .req_o      (instr_shared_req),
        .rsp_i      (instr_shared_rsp),
        .req_idx_o  (instr_req_idx),
        .req_valid_o(instr_req_valid)
    );

    rr_arbiter #(
        .NUM_REQ(NUM_CORES)
    ) data_arb_i (
        .clk_i      (clk_i),
        .rst_ni     (rst_ni),
        .req_mask_i ('1),
        .req_i      (core_shared_req),
        .rsp_o      (core_shared_rsp_raw),
        .req_o      (data_shared_req),
        .rsp_i      (data_shared_rsp),
        .req_idx_o  (data_req_idx),
        .req_valid_o(data_req_valid)
    );

    always_comb begin
        data_rsp_valid_raw = 1'b0;
        data_rsp_idx_raw   = '0;
        data_rsp_data_raw  = '0;
        for (int i = 0; i < NUM_CORES; i++) begin
            if (!data_rsp_valid_raw && core_shared_rsp_raw[i].rvalid) begin
                data_rsp_valid_raw = 1'b1;
                data_rsp_idx_raw   = i[CORE_IDX_W-1:0];
                data_rsp_data_raw  = core_shared_rsp_raw[i].rdata;
            end
        end
    end

    generate
        for (g_core = 0; g_core < NUM_CORES; g_core++) begin : remote_arb_gen
            always_comb begin
                for (int i = 0; i < NUM_CORES; i++) begin
                    remote_req_mask[g_core][i] = (i != g_core) &&
                                                 (core_remote_target[i] == g_core[CORE_IDX_W-1:0]);
                end
            end

            rr_arbiter #(
                .NUM_REQ(NUM_CORES)
            ) remote_arb_i (
                .clk_i      (clk_i),
                .rst_ni     (rst_ni),
                .req_mask_i (remote_req_mask[g_core]),
                .req_i      (core_remote_req),
                .rsp_o      (remote_rsp_vec[g_core]),
                .req_o      (remote_in_req[g_core]),
                .rsp_i      (remote_in_rsp[g_core]),
                .req_idx_o  (remote_req_idx[g_core]),
                .req_valid_o()
            );

            assign remote_in_src_core[g_core] = remote_req_idx[g_core];
        end
    endgenerate

    assign instr_pc_shared = instr_req_valid ? core_instr_req[instr_req_idx].addr : '0;

    tb_shared_latency_pipe #(
        .EXTRA_LATENCY(SHARED_MEM_EXTRA_LATENCY),
        .CORE_IDX_W   (CORE_IDX_W),
        .DATA_W       (32)
    ) shared_data_pipe_i (
        .clk_i      (clk_i),
        .rst_ni     (rst_ni),
        .in_valid_i (data_rsp_valid_raw),
        .in_core_i  (data_rsp_idx_raw),
        .in_data_i  (data_rsp_data_raw),
        .out_valid_o(shared_pipe_valid_out),
        .out_core_o (shared_pipe_core_out),
        .out_data_o (shared_pipe_rdata_out)
    );

    generate
        for (g_core = 0; g_core < NUM_CORES; g_core++) begin : remote_data_pipe_gen
            logic unused_remote_core;
            tb_shared_latency_pipe #(
                .EXTRA_LATENCY(REMOTE_SPM_EXTRA_LATENCY),
                .CORE_IDX_W   (1),
                .DATA_W       (32)
            ) remote_data_pipe_i (
                .clk_i      (clk_i),
                .rst_ni     (rst_ni),
                .in_valid_i (remote_rsp_valid_raw[g_core]),
                .in_core_i  (1'b0),
                .in_data_i  (core_remote_rsp_raw[g_core].rdata),
                .out_valid_o(remote_pipe_valid_out[g_core]),
                .out_core_o (unused_remote_core),
                .out_data_o (remote_pipe_rdata_out[g_core])
            );
        end
    endgenerate

    always_comb begin
        for (int i = 0; i < NUM_CORES; i++) begin
            core_shared_rsp[i] = core_shared_rsp_raw[i];
            core_shared_rsp[i].rvalid = 1'b0;
            core_shared_rsp[i].rdata  = '0;

            core_remote_rsp_raw[i] = '0;
            core_remote_rsp[i] = '0;
        end

        if (shared_pipe_valid_out) begin
            core_shared_rsp[shared_pipe_core_out].rvalid = 1'b1;
            core_shared_rsp[shared_pipe_core_out].rdata  = shared_pipe_rdata_out;
        end

        for (int t = 0; t < NUM_CORES; t++) begin
            for (int i = 0; i < NUM_CORES; i++) begin
                core_remote_rsp_raw[i].gnt    |= remote_rsp_vec[t][i].gnt;
                core_remote_rsp_raw[i].rvalid |= remote_rsp_vec[t][i].rvalid;
                if (remote_rsp_vec[t][i].rvalid)
                    core_remote_rsp_raw[i].rdata = remote_rsp_vec[t][i].rdata;
            end
        end

        for (int i = 0; i < NUM_CORES; i++) begin
            core_remote_rsp[i].gnt    = core_remote_rsp_raw[i].gnt;
            core_remote_rsp[i].rvalid = remote_pipe_valid_out[i];
            core_remote_rsp[i].rdata  = remote_pipe_rdata_out[i];
            remote_rsp_valid_raw[i]   = core_remote_rsp_raw[i].rvalid;
        end
    end

    always_comb begin
        irq_ack_shared = 1'b0;
        irq_id_shared  = '0;
        for (int i = 0; i < NUM_CORES; i++) begin
            if (!irq_ack_shared && core_irq_ack[i]) begin
                irq_ack_shared = 1'b1;
                irq_id_shared  = core_irq_id[i];
            end
        end
    end

    mm_ram #(
        .RAM_ADDR_WIDTH    (RAM_ADDR_WIDTH),
        .INSTR_RDATA_WIDTH (INSTR_RDATA_WIDTH),
        .NUM_CORES         (NUM_CORES)
    ) ram_i (
        .clk_i          (clk_i),
        .rst_ni         (rst_ni),
        .dm_halt_addr_i (DM_HALTADDRESS),

        .instr_req_i    (instr_shared_req.req),
        .instr_addr_i   (instr_shared_req.addr),
        .instr_rdata_o  (instr_shared_rsp.rdata),
        .instr_rvalid_o (instr_shared_rsp.rvalid),
        .instr_gnt_o    (instr_shared_rsp.gnt),

        .data_req_i     (data_shared_req.req),
        .data_addr_i    (data_shared_req.addr),
        .data_we_i      (data_shared_req.we),
        .data_be_i      (data_shared_req.be),
        .data_wdata_i   (data_shared_req.wdata),
        .data_rdata_o   (data_shared_rsp.rdata),
        .data_rvalid_o  (data_shared_rsp.rvalid),
        .data_gnt_o     (data_shared_rsp.gnt),

        .irq_id_i       (irq_id_shared),
        .irq_ack_i      (irq_ack_shared),
        .irq_o          (irq_shared),

        .pc_core_id_i   (instr_pc_shared),
        .data_core_id_i (data_req_valid ? {{(32-CORE_IDX_W){1'b0}}, data_req_idx} : '0),

        .debug_req_o    (debug_req_shared),
        .tests_passed_o (tests_passed_o),
        .tests_failed_o (tests_failed_o),
        .exit_valid_o   (exit_valid_o),
        .exit_value_o   (exit_value_o)
    );

endmodule
