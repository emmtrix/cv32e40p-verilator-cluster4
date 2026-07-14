// SPDX-FileCopyrightText: 2026 emmtrix Technologies GmbH
// SPDX-License-Identifier: Apache-2.0

module tb_cv32e40p_cluster_core #(
    parameter int unsigned NUM_CORES = 4,
    parameter int unsigned CORE_ID = 0,
    parameter int unsigned INSTR_RDATA_WIDTH = 32,
    parameter logic [31:0] BOOT_ADDR = 32'h00000080,
    parameter logic [31:0] DM_HALTADDRESS = 32'h1A110800,
    parameter int unsigned SPM_ADDR_WIDTH = 12,
    parameter logic [31:0] SPM_BASE_ADDR = 32'h1800_0000
) (
    input  logic clk_i,
    input  logic rst_ni,
    input  logic fetch_enable_i,

    // IRQ / debug
    input  logic [31:0] irq_i,
    input  logic        debug_req_i,
    output logic        irq_ack_o,
    output logic [4:0]  irq_id_o,

    // Outgoing instruction interface to shared memory
    output logic                         instr_req_o,
    output logic [31:0]                  instr_addr_o,
    input  logic                         instr_gnt_i,
    input  logic                         instr_rvalid_i,
    input  logic [INSTR_RDATA_WIDTH-1:0] instr_rdata_i,

    // Outgoing shared-data interface to shared memory
    output logic        shared_data_req_o,
    output logic [31:0] shared_data_addr_o,
    output logic        shared_data_we_o,
    output logic [3:0]  shared_data_be_o,
    output logic [31:0] shared_data_wdata_o,
    input  logic        shared_data_gnt_i,
    input  logic        shared_data_rvalid_i,
    input  logic [31:0] shared_data_rdata_i,

    // Outgoing remote-SPM request interface
    output logic                         remote_req_o,
    output logic [((NUM_CORES > 1) ? $clog2(NUM_CORES) : 1)-1:0] remote_target_o,
    output logic [31:0]                  remote_addr_o,
    output logic                         remote_we_o,
    output logic [3:0]                   remote_be_o,
    output logic [31:0]                  remote_wdata_o,
    input  logic                         remote_gnt_i,
    input  logic                         remote_rvalid_i,
    input  logic [31:0]                  remote_rdata_i,

    // Incoming remote-SPM access interface (other cores -> this core's scratchpad)
    input  logic                         remote_in_req_i,
    input  logic [((NUM_CORES > 1) ? $clog2(NUM_CORES) : 1)-1:0] remote_in_src_core_i,
    input  logic [31:0]                  remote_in_addr_i,
    input  logic                         remote_in_we_i,
    input  logic [3:0]                   remote_in_be_i,
    input  logic [31:0]                  remote_in_wdata_i,
    output logic                         remote_in_gnt_o,
    output logic                         remote_in_rvalid_o,
    output logic [((NUM_CORES > 1) ? $clog2(NUM_CORES) : 1)-1:0] remote_in_rsp_core_o,
    output logic [31:0]                  remote_in_rdata_o
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

        .instr_req_o        (instr_req_o),
        .instr_gnt_i        (instr_gnt_i),
        .instr_rvalid_i     (instr_rvalid_i),
        .instr_addr_o       (instr_addr_o),
        .instr_rdata_i      (instr_rdata_i),

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

    assign core_is_spm =
        (core_data_addr >= SPM_BASE_ADDR) &&
        (core_data_addr <  SPM_END_ADDR);
    assign core_spm_target = core_data_addr[SPM_ADDR_WIDTH +: CORE_IDX_W];
    assign core_is_local_spm = core_is_spm && (core_spm_target == CORE_IDX_W'(CORE_ID));
    assign core_is_remote_spm = core_is_spm && (core_spm_target != CORE_IDX_W'(CORE_ID));
    assign core_is_shared = ~core_is_spm;

    assign local_spm_en = core_data_req && core_is_local_spm;

    assign shared_data_req_o   = core_data_req && core_is_shared;
    assign shared_data_addr_o  = core_data_addr;
    assign shared_data_we_o    = core_data_we;
    assign shared_data_be_o    = core_data_be;
    assign shared_data_wdata_o = core_data_wdata;

    assign remote_req_o    = core_data_req && core_is_remote_spm;
    assign remote_target_o = core_spm_target;
    assign remote_addr_o   = core_data_addr;
    assign remote_we_o     = core_data_we;
    assign remote_be_o     = core_data_be;
    assign remote_wdata_o  = core_data_wdata;

    // Local accesses take priority over incoming remote accesses.
    always_comb begin
        if (local_spm_en) begin
            spm_en    = 1'b1;
            spm_we    = core_data_we;
            spm_be    = core_data_be;
            spm_addr  = core_data_addr[SPM_ADDR_WIDTH-1:0];
            spm_wdata = core_data_wdata;
        end else if (remote_in_req_i) begin
            spm_en    = 1'b1;
            spm_we    = remote_in_we_i;
            spm_be    = remote_in_be_i;
            spm_addr  = remote_in_addr_i[SPM_ADDR_WIDTH-1:0];
            spm_wdata = remote_in_wdata_i;
        end else begin
            spm_en    = 1'b0;
            spm_we    = 1'b0;
            spm_be    = '0;
            spm_addr  = '0;
            spm_wdata = '0;
        end
    end

    assign remote_in_gnt_o = remote_in_req_i && !local_spm_en;

    always_ff @(posedge clk_i or negedge rst_ni) begin
        if (!rst_ni) begin
            local_spm_rvalid_q <= 1'b0;
            remote_rsp_valid_q <= 1'b0;
            remote_rsp_src_q   <= '0;
        end else begin
            local_spm_rvalid_q <= local_spm_en;
            remote_rsp_valid_q <= remote_in_gnt_o;
            if (remote_in_gnt_o)
                remote_rsp_src_q <= remote_in_src_core_i;
        end
    end

    assign remote_in_rvalid_o   = remote_rsp_valid_q;
    assign remote_in_rsp_core_o = remote_rsp_src_q;
    assign remote_in_rdata_o     = spm_rdata;

    always_comb begin
        core_data_gnt = 1'b0;
        if (local_spm_en) begin
            core_data_gnt = 1'b1;
        end else if (core_data_req && core_is_remote_spm) begin
            core_data_gnt = remote_gnt_i;
        end else if (core_data_req && core_is_shared) begin
            core_data_gnt = shared_data_gnt_i;
        end
    end

    always_comb begin
        core_data_rvalid = 1'b0;
        core_data_rdata  = '0;

        if (local_spm_rvalid_q) begin
            core_data_rvalid = 1'b1;
            core_data_rdata  = spm_rdata;
        end
        if (remote_rvalid_i) begin
            core_data_rvalid = 1'b1;
            core_data_rdata  = remote_rdata_i;
        end
        if (shared_data_rvalid_i) begin
            core_data_rvalid = 1'b1;
            core_data_rdata  = shared_data_rdata_i;
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