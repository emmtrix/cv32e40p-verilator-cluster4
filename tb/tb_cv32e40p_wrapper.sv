module tb_cv32e40p_wrapper #(
    parameter INSTR_RDATA_WIDTH = 32,
    parameter RAM_ADDR_WIDTH = 22,
    parameter BOOT_ADDR = 32'h00000080,
    parameter DM_HALTADDRESS = 32'h1A110800,
    parameter HART_ID = 32'h00000000
) (
    input logic clk_i,
    input logic rst_ni,
    input logic fetch_enable_i,
    output logic tests_passed_o,
    output logic tests_failed_o,
    output logic [31:0] exit_value_o,
    output logic exit_valid_o
);

    logic instr_req;
    logic instr_gnt;
    logic instr_rvalid;
    logic [31:0] instr_addr;
    logic [INSTR_RDATA_WIDTH-1:0] instr_rdata;

    logic data_req;
    logic data_gnt;
    logic data_rvalid;
    logic data_we;
    logic [3:0] data_be;
    logic [31:0] data_addr;
    logic [31:0] data_wdata;
    logic [31:0] data_rdata;

    logic [31:0] irq;
    logic irq_ack;
    logic [4:0] irq_id;

    logic debug_req;
    logic core_sleep;

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
        .hart_id_i(HART_ID),
        .dm_exception_addr_i(32'h1A111000),

        .instr_req_o(instr_req),
        .instr_gnt_i(instr_gnt),
        .instr_rvalid_i(instr_rvalid),
        .instr_addr_o(instr_addr),
        .instr_rdata_i(instr_rdata),

        .data_req_o(data_req),
        .data_gnt_i(data_gnt),
        .data_rvalid_i(data_rvalid),
        .data_we_o(data_we),
        .data_be_o(data_be),
        .data_addr_o(data_addr),
        .data_wdata_o(data_wdata),
        .data_rdata_i(data_rdata),

        .irq_i(irq),
        .irq_ack_o(irq_ack),
        .irq_id_o(irq_id),

        .debug_req_i(debug_req),
        .debug_havereset_o(),
        .debug_running_o(),
        .debug_halted_o(),

        .fetch_enable_i(fetch_enable_i),
        .core_sleep_o(core_sleep)
    );

    mm_ram #(
        .RAM_ADDR_WIDTH(RAM_ADDR_WIDTH),
        .INSTR_RDATA_WIDTH(INSTR_RDATA_WIDTH),
        .NUM_CORES(1)
    ) ram_i (
        .clk_i(clk_i),
        .rst_ni(rst_ni),
        .dm_halt_addr_i(DM_HALTADDRESS),

        .instr_req_i(instr_req),
        .instr_addr_i(instr_addr),
        .instr_rdata_o(instr_rdata),
        .instr_rvalid_o(instr_rvalid),
        .instr_gnt_o(instr_gnt),

        .data_req_i(data_req),
        .data_addr_i(data_addr),
        .data_we_i(data_we),
        .data_be_i(data_be),
        .data_wdata_i(data_wdata),
        .data_rdata_o(data_rdata),
        .data_rvalid_o(data_rvalid),
        .data_gnt_o(data_gnt),

        .irq_id_i(irq_id),
        .irq_ack_i(irq_ack),
        .irq_o(irq),

        .pc_core_id_i(instr_addr),
        .data_core_id_i(HART_ID),

        .debug_req_o(debug_req),

        .tests_passed_o(tests_passed_o),
        .tests_failed_o(tests_failed_o),
        .exit_valid_o(exit_valid_o),
        .exit_value_o(exit_value_o)
    );

endmodule
