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
    localparam logic [31:0] SPM_END_ADDR = SPM_BASE_ADDR + (NUM_CORES * (1 << SPM_ADDR_WIDTH));
    localparam int unsigned GLOBAL_DATA_EXTRA_LATENCY = SHARED_MEM_EXTRA_LATENCY;

    tb_mem_types_pkg::tb_mem_req_t core_instr_req [NUM_CORES];
    tb_mem_types_pkg::tb_mem_rsp_t core_instr_rsp [NUM_CORES];

    tb_mem_types_pkg::tb_mem_req_t core_shared_req [NUM_CORES];
    tb_mem_types_pkg::tb_mem_rsp_t core_shared_rsp [NUM_CORES];

    tb_mem_types_pkg::tb_mem_req_t instr_shared_req;
    tb_mem_types_pkg::tb_mem_rsp_t instr_shared_rsp;

    tb_mem_types_pkg::tb_mem_req_t data_shared_req;
    tb_mem_types_pkg::tb_mem_rsp_t data_shared_rsp;

    tb_mem_types_pkg::tb_mem_req_t mm_data_req;
    tb_mem_types_pkg::tb_mem_rsp_t mm_data_rsp;

    tb_mem_types_pkg::tb_mem_req_t remote_in_req [NUM_CORES];
    tb_mem_types_pkg::tb_mem_rsp_t remote_in_rsp [NUM_CORES];

    logic [31:0]                   irq_shared;
    logic [4:0]                    irq_id_shared;
    logic                          irq_ack_shared;
    logic                          debug_req_shared;
    logic [31:0]                   instr_pc_shared;

    logic [NUM_CORES-1:0][31:0]                 core_irq;
    logic [NUM_CORES-1:0]                       core_irq_ack;
    logic [NUM_CORES-1:0][4:0]                  core_irq_id;
    logic [NUM_CORES-1:0]                       core_debug_req;

    logic [CORE_IDX_W-1:0] instr_req_idx;
    logic                  instr_req_valid;

    logic [CORE_IDX_W-1:0] data_req_idx;
    logic                  data_req_valid;

    logic                  data_req_is_spm;
    logic [CORE_IDX_W-1:0] data_req_spm_target;
    logic                  data_split_gnt;
    logic                  data_rsp_valid_raw;
    logic [31:0]           data_rsp_rdata_raw;
    logic                  data_pipe_valid;
    logic [31:0]           data_pipe_rdata;
    logic                  data_outstanding_q;
    logic                  data_pending_is_spm_q;
    logic [CORE_IDX_W-1:0] data_pending_spm_target_q;

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
                .remote_in_req_i    (remote_in_req[g_core]),
                .remote_in_rsp_o    (remote_in_rsp[g_core])
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
        .rsp_o      (core_shared_rsp),
        .req_o      (data_shared_req),
        .rsp_i      (data_shared_rsp),
        .req_idx_o  (data_req_idx),
        .req_valid_o(data_req_valid)
    );

    assign instr_pc_shared = instr_req_valid ? core_instr_req[instr_req_idx].addr : '0;

    assign data_req_is_spm =
        (data_shared_req.addr >= SPM_BASE_ADDR) &&
        (data_shared_req.addr <  SPM_END_ADDR);
    assign data_req_spm_target = data_shared_req.addr[SPM_ADDR_WIDTH +: CORE_IDX_W];

    always_ff @(posedge clk_i or negedge rst_ni) begin
        if (!rst_ni) begin
            data_outstanding_q <= 1'b0;
            data_pending_is_spm_q <= 1'b0;
            data_pending_spm_target_q <= '0;
        end else begin
            if (data_shared_req.req && data_split_gnt) begin
                data_outstanding_q <= 1'b1;
                data_pending_is_spm_q <= data_req_is_spm;
                data_pending_spm_target_q <= data_req_spm_target;
            end
            if (data_pipe_valid)
                data_outstanding_q <= 1'b0;
        end
    end

    always_comb begin
        mm_data_req = '0;
        data_split_gnt = 1'b0;
        data_rsp_valid_raw = 1'b0;
        data_rsp_rdata_raw = '0;

        for (int i = 0; i < NUM_CORES; i++) begin
            remote_in_req[i] = '0;
        end

        if (data_shared_req.req && !data_outstanding_q) begin
            if (data_req_is_spm) begin
                remote_in_req[data_req_spm_target] = data_shared_req;
                data_split_gnt = remote_in_rsp[data_req_spm_target].gnt;
            end else begin
                mm_data_req = data_shared_req;
                data_split_gnt = mm_data_rsp.gnt;
            end
        end

        if (data_outstanding_q) begin
            if (data_pending_is_spm_q) begin
                data_rsp_valid_raw = remote_in_rsp[data_pending_spm_target_q].rvalid;
                data_rsp_rdata_raw = remote_in_rsp[data_pending_spm_target_q].rdata;
            end else begin
                data_rsp_valid_raw = mm_data_rsp.rvalid;
                data_rsp_rdata_raw = mm_data_rsp.rdata;
            end
        end else if (data_shared_req.req && data_split_gnt) begin
            if (data_req_is_spm) begin
                data_rsp_valid_raw = remote_in_rsp[data_req_spm_target].rvalid;
                data_rsp_rdata_raw = remote_in_rsp[data_req_spm_target].rdata;
            end else begin
                data_rsp_valid_raw = mm_data_rsp.rvalid;
                data_rsp_rdata_raw = mm_data_rsp.rdata;
            end
        end
    end

    tb_shared_latency_pipe #(
        .EXTRA_LATENCY(GLOBAL_DATA_EXTRA_LATENCY),
        .CORE_IDX_W   (1),
        .DATA_W       (32)
    ) data_pipe_i (
        .clk_i      (clk_i),
        .rst_ni     (rst_ni),
        .in_valid_i (data_rsp_valid_raw),
        .in_core_i  (1'b0),
        .in_data_i  (data_rsp_rdata_raw),
        .out_valid_o(data_pipe_valid),
        .out_core_o (),
        .out_data_o (data_pipe_rdata)
    );

    always_comb begin
        data_shared_rsp = '0;
        data_shared_rsp.gnt = data_split_gnt;
        data_shared_rsp.rvalid = data_pipe_valid;
        data_shared_rsp.rdata = data_pipe_rdata;
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

        .data_req_i     (mm_data_req.req),
        .data_addr_i    (mm_data_req.addr),
        .data_we_i      (mm_data_req.we),
        .data_be_i      (mm_data_req.be),
        .data_wdata_i   (mm_data_req.wdata),
        .data_rdata_o   (mm_data_rsp.rdata),
        .data_rvalid_o  (mm_data_rsp.rvalid),
        .data_gnt_o     (mm_data_rsp.gnt),

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
