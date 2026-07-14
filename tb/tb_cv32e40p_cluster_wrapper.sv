// SPDX-FileCopyrightText: 2026 emmtrix Technologies GmbH
// SPDX-License-Identifier: Apache-2.0

module tb_cv32e40p_cluster_wrapper #(
    parameter int unsigned NUM_CORES = 4,
    parameter int unsigned INSTR_RDATA_WIDTH = 32,
    parameter int unsigned RAM_ADDR_WIDTH = 22,
    parameter logic [31:0] BOOT_ADDR = 32'h00000080,
    parameter logic [31:0] DM_HALTADDRESS = 32'h1A110800,
    parameter int unsigned SPM_ADDR_WIDTH = 12,
    parameter logic [31:0] SPM_BASE_ADDR = 32'h1800_0000,
    parameter int unsigned SHARED_MEM_EXTRA_LATENCY = 2
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

    logic                          instr_req_shared;
    logic [31:0]                   instr_addr_shared;
    logic [INSTR_RDATA_WIDTH-1:0]  instr_rdata_shared;
    logic                          instr_rvalid_shared;
    logic                          instr_gnt_shared;

    logic                          data_req_shared;
    logic [31:0]                   data_addr_shared;
    logic                          data_we_shared;
    logic [3:0]                    data_be_shared;
    logic [31:0]                   data_wdata_shared;
    logic [31:0]                   data_rdata_shared;
    logic                          data_rvalid_shared;
    logic                          data_gnt_shared;

    logic [31:0]                   irq_shared;
    logic [4:0]                    irq_id_shared;
    logic                          irq_ack_shared;
    logic                          debug_req_shared;
    logic [31:0]                   instr_pc_shared;

    logic [NUM_CORES-1:0]                         core_instr_req;
    logic [NUM_CORES-1:0][31:0]                   core_instr_addr;

    logic [NUM_CORES-1:0]                         core_shared_data_req;
    logic [NUM_CORES-1:0][31:0]                   core_shared_data_addr;
    logic [NUM_CORES-1:0]                         core_shared_data_we;
    logic [NUM_CORES-1:0][3:0]                    core_shared_data_be;
    logic [NUM_CORES-1:0][31:0]                   core_shared_data_wdata;

    logic [NUM_CORES-1:0]                         core_remote_req;
    logic [NUM_CORES-1:0][CORE_IDX_W-1:0]         core_remote_target;
    logic [NUM_CORES-1:0][31:0]                   core_remote_addr;
    logic [NUM_CORES-1:0]                         core_remote_we;
    logic [NUM_CORES-1:0][3:0]                    core_remote_be;
    logic [NUM_CORES-1:0][31:0]                   core_remote_wdata;

    logic [NUM_CORES-1:0]                         core_instr_gnt;
    logic [NUM_CORES-1:0]                         core_instr_rvalid;
    logic [NUM_CORES-1:0][INSTR_RDATA_WIDTH-1:0]  core_instr_rdata;

    logic [NUM_CORES-1:0]                         core_shared_data_gnt;
    logic [NUM_CORES-1:0]                         core_shared_data_rvalid;
    logic [NUM_CORES-1:0][31:0]                   core_shared_data_rdata;

    logic [NUM_CORES-1:0]                         core_remote_gnt;
    logic [NUM_CORES-1:0]                         core_remote_rvalid;
    logic [NUM_CORES-1:0][31:0]                   core_remote_rdata;

    logic [NUM_CORES-1:0][31:0]                   core_irq;
    logic [NUM_CORES-1:0]                         core_irq_ack;
    logic [NUM_CORES-1:0][4:0]                    core_irq_id;
    logic [NUM_CORES-1:0]                         core_debug_req;

    logic [NUM_CORES-1:0]                         remote_in_req;
    logic [NUM_CORES-1:0][CORE_IDX_W-1:0]         remote_in_src_core;
    logic [NUM_CORES-1:0][31:0]                   remote_in_addr;
    logic [NUM_CORES-1:0]                         remote_in_we;
    logic [NUM_CORES-1:0][3:0]                    remote_in_be;
    logic [NUM_CORES-1:0][31:0]                   remote_in_wdata;

    logic [NUM_CORES-1:0]                         remote_in_gnt;
    logic [NUM_CORES-1:0]                         remote_in_rvalid;
    logic [NUM_CORES-1:0][31:0]                   remote_in_rdata;

    logic [NUM_CORES-1:0]                         instr_we_zero;
    logic [NUM_CORES-1:0][3:0]                    instr_be_zero;
    logic [NUM_CORES-1:0][INSTR_RDATA_WIDTH-1:0]  instr_wdata_zero;

    logic [CORE_IDX_W-1:0]                        instr_req_idx;
    logic                                          instr_req_valid;
    logic                                          instr_rsp_valid;
    logic [CORE_IDX_W-1:0]                        instr_rsp_idx;
    logic [INSTR_RDATA_WIDTH-1:0]                 instr_rsp_data;

    logic [CORE_IDX_W-1:0]                        data_req_idx;
    logic                                          data_req_valid;
    logic                                          data_rsp_valid_raw;
    logic [CORE_IDX_W-1:0]                        data_rsp_idx_raw;
    logic [31:0]                                   data_rsp_data_raw;

    logic                                          shared_pipe_valid_out;
    logic [CORE_IDX_W-1:0]                        shared_pipe_core_out;
    logic [31:0]                                   shared_pipe_rdata_out;

    logic [NUM_CORES-1:0][NUM_CORES-1:0]          remote_req_vec;
    logic [NUM_CORES-1:0][NUM_CORES-1:0][31:0]    remote_addr_vec;
    logic [NUM_CORES-1:0][NUM_CORES-1:0]          remote_we_vec;
    logic [NUM_CORES-1:0][NUM_CORES-1:0][3:0]     remote_be_vec;
    logic [NUM_CORES-1:0][NUM_CORES-1:0][31:0]    remote_wdata_vec;

    logic [NUM_CORES-1:0][NUM_CORES-1:0]          remote_gnt_vec;
    logic [NUM_CORES-1:0]                         remote_rsp_valid;
    logic [CORE_IDX_W-1:0]                        remote_rsp_idx [NUM_CORES];
    logic [31:0]                                   remote_rsp_data [NUM_CORES];
    logic [CORE_IDX_W-1:0]                        remote_req_idx [NUM_CORES];

    initial begin : spm_align_check
        if ((SPM_BASE_ADDR & ((NUM_CORES << SPM_ADDR_WIDTH) - 1)) != 0)
            $fatal(1, "[CLUSTER] SPM_BASE_ADDR must be aligned to NUM_CORES * 2**SPM_ADDR_WIDTH");
    end

    assign instr_we_zero    = '0;
    assign instr_be_zero    = '0;
    assign instr_wdata_zero = '0;

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
                .SPM_BASE_ADDR    (SPM_BASE_ADDR)
            ) core_i (
                .clk_i                (clk_i),
                .rst_ni               (rst_ni),
                .fetch_enable_i       (fetch_enable_i),

                .irq_i                (core_irq[g_core]),
                .debug_req_i          (core_debug_req[g_core]),
                .irq_ack_o            (core_irq_ack[g_core]),
                .irq_id_o             (core_irq_id[g_core]),

                .instr_req_o          (core_instr_req[g_core]),
                .instr_addr_o         (core_instr_addr[g_core]),
                .instr_gnt_i          (core_instr_gnt[g_core]),
                .instr_rvalid_i       (core_instr_rvalid[g_core]),
                .instr_rdata_i        (core_instr_rdata[g_core]),

                .shared_data_req_o    (core_shared_data_req[g_core]),
                .shared_data_addr_o   (core_shared_data_addr[g_core]),
                .shared_data_we_o     (core_shared_data_we[g_core]),
                .shared_data_be_o     (core_shared_data_be[g_core]),
                .shared_data_wdata_o  (core_shared_data_wdata[g_core]),
                .shared_data_gnt_i    (core_shared_data_gnt[g_core]),
                .shared_data_rvalid_i (core_shared_data_rvalid[g_core]),
                .shared_data_rdata_i  (core_shared_data_rdata[g_core]),

                .remote_req_o         (core_remote_req[g_core]),
                .remote_target_o      (core_remote_target[g_core]),
                .remote_addr_o        (core_remote_addr[g_core]),
                .remote_we_o          (core_remote_we[g_core]),
                .remote_be_o          (core_remote_be[g_core]),
                .remote_wdata_o       (core_remote_wdata[g_core]),
                .remote_gnt_i         (core_remote_gnt[g_core]),
                .remote_rvalid_i      (core_remote_rvalid[g_core]),
                .remote_rdata_i       (core_remote_rdata[g_core]),

                .remote_in_req_i      (remote_in_req[g_core]),
                .remote_in_src_core_i (remote_in_src_core[g_core]),
                .remote_in_addr_i     (remote_in_addr[g_core]),
                .remote_in_we_i       (remote_in_we[g_core]),
                .remote_in_be_i       (remote_in_be[g_core]),
                .remote_in_wdata_i    (remote_in_wdata[g_core]),
                .remote_in_gnt_o      (remote_in_gnt[g_core]),
                .remote_in_rvalid_o   (remote_in_rvalid[g_core]),
                .remote_in_rsp_core_o (),
                .remote_in_rdata_o    (remote_in_rdata[g_core])
            );

            assign core_irq[g_core] = irq_shared;
            assign core_debug_req[g_core] = debug_req_shared;
        end
    endgenerate

    rr_arbiter #(
        .NUM_REQ(NUM_CORES),
        .DATA_W (INSTR_RDATA_WIDTH)
    ) instr_arb_i (
        .clk_i      (clk_i),
        .rst_ni     (rst_ni),
        .req_i      (core_instr_req),
        .addr_i     (core_instr_addr),
        .we_i       (instr_we_zero),
        .be_i       (instr_be_zero),
        .wdata_i    (instr_wdata_zero),
        .req_o      (instr_req_shared),
        .addr_o     (instr_addr_shared),
        .we_o       (),
        .be_o       (),
        .wdata_o    (),
        .gnt_i      (instr_gnt_shared),
        .rvalid_i   (instr_rvalid_shared),
        .rdata_i    (instr_rdata_shared),
        .gnt_o      (core_instr_gnt),
        .rsp_valid_o(instr_rsp_valid),
        .rsp_idx_o  (instr_rsp_idx),
        .rsp_data_o (instr_rsp_data),
        .req_idx_o  (instr_req_idx),
        .req_valid_o(instr_req_valid)
    );

    rr_arbiter #(
        .NUM_REQ(NUM_CORES),
        .DATA_W (32)
    ) data_arb_i (
        .clk_i      (clk_i),
        .rst_ni     (rst_ni),
        .req_i      (core_shared_data_req),
        .addr_i     (core_shared_data_addr),
        .we_i       (core_shared_data_we),
        .be_i       (core_shared_data_be),
        .wdata_i    (core_shared_data_wdata),
        .req_o      (data_req_shared),
        .addr_o     (data_addr_shared),
        .we_o       (data_we_shared),
        .be_o       (data_be_shared),
        .wdata_o    (data_wdata_shared),
        .gnt_i      (data_gnt_shared),
        .rvalid_i   (data_rvalid_shared),
        .rdata_i    (data_rdata_shared),
        .gnt_o      (core_shared_data_gnt),
        .rsp_valid_o(data_rsp_valid_raw),
        .rsp_idx_o  (data_rsp_idx_raw),
        .rsp_data_o (data_rsp_data_raw),
        .req_idx_o  (data_req_idx),
        .req_valid_o(data_req_valid)
    );

    generate
        for (g_core = 0; g_core < NUM_CORES; g_core++) begin : remote_arb_gen
            always_comb begin
                for (int i = 0; i < NUM_CORES; i++) begin
                    remote_req_vec[g_core][i] = core_remote_req[i] &&
                                                (core_remote_target[i] == g_core[CORE_IDX_W-1:0]) &&
                                                (i != g_core);
                    remote_addr_vec[g_core][i]  = core_remote_addr[i];
                    remote_we_vec[g_core][i]    = core_remote_we[i];
                    remote_be_vec[g_core][i]    = core_remote_be[i];
                    remote_wdata_vec[g_core][i] = core_remote_wdata[i];
                end
            end

            rr_arbiter #(
                .NUM_REQ(NUM_CORES),
                .DATA_W (32)
            ) remote_arb_i (
                .clk_i      (clk_i),
                .rst_ni     (rst_ni),
                .req_i      (remote_req_vec[g_core]),
                .addr_i     (remote_addr_vec[g_core]),
                .we_i       (remote_we_vec[g_core]),
                .be_i       (remote_be_vec[g_core]),
                .wdata_i    (remote_wdata_vec[g_core]),
                .req_o      (remote_in_req[g_core]),
                .addr_o     (remote_in_addr[g_core]),
                .we_o       (remote_in_we[g_core]),
                .be_o       (remote_in_be[g_core]),
                .wdata_o    (remote_in_wdata[g_core]),
                .gnt_i      (remote_in_gnt[g_core]),
                .rvalid_i   (remote_in_rvalid[g_core]),
                .rdata_i    (remote_in_rdata[g_core]),
                .gnt_o      (remote_gnt_vec[g_core]),
                .rsp_valid_o(remote_rsp_valid[g_core]),
                .rsp_idx_o  (remote_rsp_idx[g_core]),
                .rsp_data_o (remote_rsp_data[g_core]),
                .req_idx_o  (remote_req_idx[g_core]),
                .req_valid_o()
            );

            assign remote_in_src_core[g_core] = remote_req_idx[g_core];
        end
    endgenerate

    assign instr_pc_shared = instr_req_valid ? core_instr_addr[instr_req_idx] : '0;

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

    always_comb begin
        core_instr_rvalid       = '0;
        core_instr_rdata        = '0;
        core_shared_data_rvalid = '0;
        core_shared_data_rdata  = '0;

        if (instr_rsp_valid) begin
            core_instr_rvalid[instr_rsp_idx] = 1'b1;
            core_instr_rdata[instr_rsp_idx]  = instr_rsp_data;
        end

        if (shared_pipe_valid_out) begin
            core_shared_data_rvalid[shared_pipe_core_out] = 1'b1;
            core_shared_data_rdata[shared_pipe_core_out]  = shared_pipe_rdata_out;
        end
    end

    always_comb begin
        core_remote_gnt    = '0;
        core_remote_rvalid = '0;
        core_remote_rdata  = '0;

        for (int j = 0; j < NUM_CORES; j++) begin
            core_remote_gnt |= remote_gnt_vec[j];
            if (remote_rsp_valid[j]) begin
                core_remote_rvalid[remote_rsp_idx[j]] = 1'b1;
                core_remote_rdata[remote_rsp_idx[j]]  = remote_rsp_data[j];
            end
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

        .instr_req_i    (instr_req_shared),
        .instr_addr_i   (instr_addr_shared),
        .instr_rdata_o  (instr_rdata_shared),
        .instr_rvalid_o (instr_rvalid_shared),
        .instr_gnt_o    (instr_gnt_shared),

        .data_req_i     (data_req_shared),
        .data_addr_i    (data_addr_shared),
        .data_we_i      (data_we_shared),
        .data_be_i      (data_be_shared),
        .data_wdata_i   (data_wdata_shared),
        .data_rdata_o   (data_rdata_shared),
        .data_rvalid_o  (data_rvalid_shared),
        .data_gnt_o     (data_gnt_shared),

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
