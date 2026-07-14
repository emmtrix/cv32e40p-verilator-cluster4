// SPDX-FileCopyrightText: 2026 emmtrix Technologies GmbH
// SPDX-License-Identifier: Apache-2.0

module tb_cv32e40p_cluster_core #(
    parameter int unsigned NUM_CORES = 4,
    parameter int unsigned CORE_ID = 0,
    parameter int unsigned INSTR_RDATA_WIDTH = 32,
    parameter logic [31:0] BOOT_ADDR = 32'h00000080,
    parameter logic [31:0] DM_HALTADDRESS = 32'h1A110800,
    parameter int unsigned SPM_ADDR_WIDTH = 18,
    parameter logic [31:0] SPM_BASE_ADDR = 32'h1800_0000
) (
    input  logic clk_i,
    input  logic rst_ni,
    input  logic fetch_enable_i,

    input  logic [31:0] irq_i,
    input  logic        debug_req_i,
    output logic        irq_ack_o,
    output logic [4:0]  irq_id_o,

    output tb_mem_types_pkg::tb_mem_req_t instr_req_o,
    input  tb_mem_types_pkg::tb_mem_rsp_t instr_rsp_i,

    output tb_mem_types_pkg::tb_mem_req_t shared_req_o,
    input  tb_mem_types_pkg::tb_mem_rsp_t shared_rsp_i,

    output tb_mem_types_pkg::tb_mem_req_t remote_req_o,
    input  tb_mem_types_pkg::tb_mem_rsp_t remote_rsp_i,
    output logic [((NUM_CORES > 1) ? $clog2(NUM_CORES) : 1)-1:0] remote_target_o,

    input  tb_mem_types_pkg::tb_mem_req_t remote_in_req_i,
    input  logic [((NUM_CORES > 1) ? $clog2(NUM_CORES) : 1)-1:0] remote_in_src_core_i,
    output tb_mem_types_pkg::tb_mem_rsp_t remote_in_rsp_o,
    output logic [((NUM_CORES > 1) ? $clog2(NUM_CORES) : 1)-1:0] remote_in_rsp_core_o
);

    localparam int unsigned CORE_IDX_W = (NUM_CORES > 1) ? $clog2(NUM_CORES) : 1;
    localparam logic [31:0] SPM_END_ADDR = SPM_BASE_ADDR + (NUM_CORES * (1 << SPM_ADDR_WIDTH));

    logic                  core_data_req;
    logic                  core_data_gnt;
    logic                  core_data_rvalid;
    logic                  core_data_we;
    logic [3:0]            core_data_be;
    logic [31:0]           core_data_addr;
    logic [31:0]           core_data_wdata;
    logic [31:0]           core_data_rdata;

    logic                  core_is_spm;
    logic [CORE_IDX_W-1:0] core_spm_target;
    logic                  core_is_local_spm;
    logic                  core_is_remote_spm;
    logic                  core_is_shared;

    logic                  local_spm_en;
    logic                  local_spm_rvalid_q;

    logic                  remote_rsp_valid_q;
    logic [CORE_IDX_W-1:0] remote_rsp_src_q;

    logic                  spm_en;
    logic                  spm_we;
    logic [3:0]            spm_be;
    logic [SPM_ADDR_WIDTH-1:0] spm_addr;
    logic [31:0]           spm_wdata;
    logic [31:0]           spm_rdata;

    cv32e40p_top #(
        .COREV_PULP(0),
        .COREV_CLUSTER(0),
        .FPU(0),
        .ZFINX(0),
        .NUM_MHPMCOUNTERS(1)
    ) cv32e40p_top_i (
        .clk_i              (clk_i),
        .rst_ni             (rst_ni),
        .pulp_clock_en_i    (1'b1),
        .scan_cg_en_i       (1'b0),
        .boot_addr_i        (BOOT_ADDR),
        .mtvec_addr_i       (32'h00000000),
        .dm_halt_addr_i     (DM_HALTADDRESS),
        .hart_id_i          (CORE_ID),
        .dm_exception_addr_i(32'h1A111000),

        .instr_req_o        (instr_req_o.req),
        .instr_gnt_i        (instr_rsp_i.gnt),
        .instr_rvalid_i     (instr_rsp_i.rvalid),
        .instr_addr_o       (instr_req_o.addr),
        .instr_rdata_i      (instr_rsp_i.rdata),

        .data_req_o         (core_data_req),
        .data_gnt_i         (core_data_gnt),
        .data_rvalid_i      (core_data_rvalid),
        .data_we_o          (core_data_we),
        .data_be_o          (core_data_be),
        .data_addr_o        (core_data_addr),
        .data_wdata_o       (core_data_wdata),
        .data_rdata_i       (core_data_rdata),

        .irq_i              (irq_i),
        .irq_ack_o          (irq_ack_o),
        .irq_id_o           (irq_id_o),
        .debug_req_i        (debug_req_i),
        .debug_havereset_o  (),
        .debug_running_o    (),
        .debug_halted_o     (),
        .fetch_enable_i     (fetch_enable_i),
        .core_sleep_o       ()
    );

    assign instr_req_o.we    = 1'b0;
    assign instr_req_o.be    = '0;
    assign instr_req_o.wdata = '0;

    assign core_is_spm =
        (core_data_addr >= SPM_BASE_ADDR) &&
        (core_data_addr <  SPM_END_ADDR);
    assign core_spm_target = core_data_addr[SPM_ADDR_WIDTH +: CORE_IDX_W];
    assign core_is_local_spm = core_is_spm && (core_spm_target == CORE_IDX_W'(CORE_ID));
    assign core_is_remote_spm = core_is_spm && (core_spm_target != CORE_IDX_W'(CORE_ID));
    assign core_is_shared = ~core_is_spm;

    assign local_spm_en = core_data_req && core_is_local_spm;

    assign shared_req_o.req   = core_data_req && core_is_shared;
    assign shared_req_o.addr  = core_data_addr;
    assign shared_req_o.we    = core_data_we;
    assign shared_req_o.be    = core_data_be;
    assign shared_req_o.wdata = core_data_wdata;

    assign remote_req_o.req   = core_data_req && core_is_remote_spm;
    assign remote_req_o.addr  = core_data_addr;
    assign remote_req_o.we    = core_data_we;
    assign remote_req_o.be    = core_data_be;
    assign remote_req_o.wdata = core_data_wdata;
    assign remote_target_o    = core_spm_target;

    always_comb begin
        if (local_spm_en) begin
            spm_en    = 1'b1;
            spm_we    = core_data_we;
            spm_be    = core_data_be;
            spm_addr  = core_data_addr[SPM_ADDR_WIDTH-1:0];
            spm_wdata = core_data_wdata;
        end else if (remote_in_req_i.req) begin
            spm_en    = 1'b1;
            spm_we    = remote_in_req_i.we;
            spm_be    = remote_in_req_i.be;
            spm_addr  = remote_in_req_i.addr[SPM_ADDR_WIDTH-1:0];
            spm_wdata = remote_in_req_i.wdata;
        end else begin
            spm_en    = 1'b0;
            spm_we    = 1'b0;
            spm_be    = '0;
            spm_addr  = '0;
            spm_wdata = '0;
        end
    end

    assign remote_in_rsp_o.gnt = remote_in_req_i.req && !local_spm_en;

    always_ff @(posedge clk_i or negedge rst_ni) begin
        if (!rst_ni) begin
            local_spm_rvalid_q <= 1'b0;
            remote_rsp_valid_q <= 1'b0;
            remote_rsp_src_q   <= '0;
        end else begin
            local_spm_rvalid_q <= local_spm_en;
            remote_rsp_valid_q <= remote_in_rsp_o.gnt;
            if (remote_in_rsp_o.gnt)
                remote_rsp_src_q <= remote_in_src_core_i;
        end
    end

    assign remote_in_rsp_o.rvalid = remote_rsp_valid_q;
    assign remote_in_rsp_o.rdata  = spm_rdata;
    assign remote_in_rsp_core_o   = remote_rsp_src_q;

    always_comb begin
        core_data_gnt = 1'b0;
        if (local_spm_en) begin
            core_data_gnt = 1'b1;
        end else if (core_data_req && core_is_remote_spm) begin
            core_data_gnt = remote_rsp_i.gnt;
        end else if (core_data_req && core_is_shared) begin
            core_data_gnt = shared_rsp_i.gnt;
        end
    end

    always_comb begin
        core_data_rvalid = 1'b0;
        core_data_rdata  = '0;

        if (local_spm_rvalid_q) begin
            core_data_rvalid = 1'b1;
            core_data_rdata  = spm_rdata;
        end
        if (remote_rsp_i.rvalid) begin
            core_data_rvalid = 1'b1;
            core_data_rdata  = remote_rsp_i.rdata;
        end
        if (shared_rsp_i.rvalid) begin
            core_data_rvalid = 1'b1;
            core_data_rdata  = shared_rsp_i.rdata;
        end
    end

    scratchpad_ram #(
        .ADDR_WIDTH(SPM_ADDR_WIDTH)
    ) spm_i (
        .clk_i   (clk_i),
        .en_i    (spm_en),
        .we_i    (spm_we),
        .be_i    (spm_be),
        .addr_i  (spm_addr),
        .wdata_i (spm_wdata),
        .rdata_o (spm_rdata)
    );

endmodule
