module tb_top_verilator #(
    parameter INSTR_RDATA_WIDTH = 32,
    parameter RAM_ADDR_WIDTH = 22,
    parameter BOOT_ADDR = 32'h00000080,
    parameter NUM_CORES = 4,
    parameter SPM_ADDR_WIDTH = 12,
    parameter SPM_BASE_ADDR = 32'h1800_0000,
    parameter SHARED_MEM_EXTRA_LATENCY = 2
) (
    input logic clk_i,
    input logic rst_ni,
    input logic fetch_enable_i,
    output logic tests_passed_o,
    output logic tests_failed_o
);

    int unsigned cycle_cnt_q;
    logic exit_valid;
    logic [31:0] exit_value;

    initial begin : check_num_cores
        if (NUM_CORES != 4) begin
            $fatal(1, "[TB] This testbench is configured for NUM_CORES=4");
        end
    end

    initial begin : load_prog
        logic [1023:0] firmware;
        if ($value$plusargs("firmware=%s", firmware)) begin
            $display("[TB] loading shared firmware image: %0s", firmware);
            $readmemh(firmware, tb_cv32e40p_cluster_wrapper_i.ram_i.dp_ram_i.mem);
        end else begin
            $fatal(1, "[TB] +firmware=<hex> plusarg is required");
        end
    end

    always_ff @(posedge clk_i or negedge rst_ni) begin
        int maxcycles;
        if (!rst_ni) begin
            cycle_cnt_q <= 0;
        end else begin
            cycle_cnt_q <= cycle_cnt_q + 1;
            if ($value$plusargs("maxcycles=%d", maxcycles)) begin
                if (cycle_cnt_q >= maxcycles) begin
                    $fatal(1, "[TB] max cycle limit reached (%0d)", maxcycles);
                end
            end
        end
    end

    always_ff @(posedge clk_i or negedge rst_ni) begin
        if (!rst_ni) begin
        end else begin
            if (tests_passed_o) begin
                $display("[TB] CLUSTER TESTS PASSED");
                $finish;
            end
            if (tests_failed_o) begin
                $fatal(1, "[TB] CLUSTER TESTS FAILED");
            end
            if (exit_valid) begin
                if (exit_value == 0) begin
                    $display("[TB] CLUSTER EXIT SUCCESS");
                    $finish;
                end else begin
                    $fatal(1, "[TB] CLUSTER EXIT FAILURE: %0d", exit_value);
                end
            end
        end
    end

    tb_cv32e40p_cluster_wrapper #(
        .NUM_CORES(NUM_CORES),
        .INSTR_RDATA_WIDTH(INSTR_RDATA_WIDTH),
        .RAM_ADDR_WIDTH(RAM_ADDR_WIDTH),
        .BOOT_ADDR(BOOT_ADDR),
        .DM_HALTADDRESS(32'h1A110800),
        .SPM_ADDR_WIDTH(SPM_ADDR_WIDTH),
        .SPM_BASE_ADDR(SPM_BASE_ADDR),
        .SHARED_MEM_EXTRA_LATENCY(SHARED_MEM_EXTRA_LATENCY)
    ) tb_cv32e40p_cluster_wrapper_i (
        .clk_i(clk_i),
        .rst_ni(rst_ni),
        .fetch_enable_i(fetch_enable_i),
        .tests_passed_o(tests_passed_o),
        .tests_failed_o(tests_failed_o),
        .exit_valid_o(exit_valid),
        .exit_value_o(exit_value)
    );

endmodule
