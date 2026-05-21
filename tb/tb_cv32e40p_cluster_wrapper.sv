module tb_cv32e40p_cluster_wrapper #(
    parameter int unsigned NUM_CORES = 4,
    parameter int unsigned INSTR_RDATA_WIDTH = 32,
    parameter int unsigned RAM_ADDR_WIDTH = 22,
    parameter logic [31:0] BOOT_ADDR = 32'h00000080,
    parameter logic [31:0] DM_HALTADDRESS = 32'h1A110800,
    // ---- scratchpad parameters ----
    parameter int unsigned SPM_ADDR_WIDTH = 12,              // bytes per scratchpad (2^12 = 4 KB)
    parameter logic [31:0] SPM_BASE_ADDR  = 32'h1000_0000,   // base of the SPM window
    parameter int unsigned SHARED_MEM_EXTRA_LATENCY = 2       // extra cycles on shared-mem data rvalid
) (
    input  logic clk_i,
    input  logic rst_ni,
    input  logic fetch_enable_i,
    output logic tests_passed_o,
    output logic tests_failed_o,
    output logic [31:0] exit_value_o,
    output logic exit_valid_o
);

    // ----------------------------------------------------------------
    //  Derived constants
    // ----------------------------------------------------------------
    localparam int unsigned CORE_IDX_W = (NUM_CORES > 1) ? $clog2(NUM_CORES) : 1;
    localparam int unsigned FIFO_DEPTH = 32;
    localparam int unsigned FIFO_PTR_W = $clog2(FIFO_DEPTH);
    localparam logic [31:0] SPM_END_ADDR = SPM_BASE_ADDR
                                         + (NUM_CORES * (1 << SPM_ADDR_WIDTH));

    // ----------------------------------------------------------------
    //  Alignment check on SPM_BASE_ADDR
    // ----------------------------------------------------------------
    initial begin : spm_align_check
        if ((SPM_BASE_ADDR & (SPM_END_ADDR - SPM_BASE_ADDR - 1)) != 0)
            $fatal(1, "[CLUSTER] SPM_BASE_ADDR must be aligned to NUM_CORES * 2**SPM_ADDR_WIDTH");
    end

    // ----------------------------------------------------------------
    //  Core ↔ bus signals
    // ----------------------------------------------------------------
    logic [NUM_CORES-1:0]                       core_instr_req;
    logic [NUM_CORES-1:0]                       core_instr_gnt;
    logic [NUM_CORES-1:0]                       core_instr_rvalid;
    logic [NUM_CORES-1:0][31:0]                 core_instr_addr;
    logic [NUM_CORES-1:0][INSTR_RDATA_WIDTH-1:0] core_instr_rdata;

    logic [NUM_CORES-1:0]                       core_data_req;
    logic [NUM_CORES-1:0]                       core_data_gnt;
    logic [NUM_CORES-1:0]                       core_data_rvalid;
    logic [NUM_CORES-1:0]                       core_data_we;
    logic [NUM_CORES-1:0][3:0]                  core_data_be;
    logic [NUM_CORES-1:0][31:0]                 core_data_addr;
    logic [NUM_CORES-1:0][31:0]                 core_data_wdata;
    logic [NUM_CORES-1:0][31:0]                 core_data_rdata;

    logic [NUM_CORES-1:0][31:0]                 core_irq;
    logic [NUM_CORES-1:0]                       core_irq_ack;
    logic [NUM_CORES-1:0][4:0]                  core_irq_id;

    logic [NUM_CORES-1:0]                       core_debug_req;

    // ----------------------------------------------------------------
    //  Shared-memory bus signals (instruction + data to mm_ram)
    // ----------------------------------------------------------------
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

    // ----------------------------------------------------------------
    //  Instruction arbiter state
    // ----------------------------------------------------------------
    logic [CORE_IDX_W-1:0] instr_rr_q;
    logic [CORE_IDX_W-1:0] instr_sel_idx;
    logic                  instr_sel_valid;

    logic [CORE_IDX_W-1:0] instr_rsp_fifo [FIFO_DEPTH-1:0];
    logic [FIFO_PTR_W-1:0] instr_rsp_wptr_q;
    logic [FIFO_PTR_W-1:0] instr_rsp_rptr_q;
    logic [FIFO_PTR_W:0]   instr_rsp_count_q;

    logic                  instr_push;
    logic                  instr_pop;
    logic [CORE_IDX_W-1:0] instr_pop_core;

    // ----------------------------------------------------------------
    //  Data arbiter state (shared memory only)
    // ----------------------------------------------------------------
    logic [CORE_IDX_W-1:0] data_rr_q;
    logic [CORE_IDX_W-1:0] data_sel_idx;
    logic                  data_sel_valid;

    logic [CORE_IDX_W-1:0] data_rsp_fifo [FIFO_DEPTH-1:0];
    logic [FIFO_PTR_W-1:0] data_rsp_wptr_q;
    logic [FIFO_PTR_W-1:0] data_rsp_rptr_q;
    logic [FIFO_PTR_W:0]   data_rsp_count_q;

    logic                  data_push;
    logic                  data_pop;
    logic [CORE_IDX_W-1:0] data_pop_core;

    // ----------------------------------------------------------------
    //  Per-core address decode
    // ----------------------------------------------------------------
    logic [NUM_CORES-1:0]          core_is_spm;
    logic [NUM_CORES-1:0]          core_is_local_spm;
    logic [NUM_CORES-1:0]          core_is_remote_spm;
    logic [NUM_CORES-1:0]          core_is_shared;
    logic [CORE_IDX_W-1:0]        core_spm_target   [NUM_CORES];

    // Filtered request vectors
    logic [NUM_CORES-1:0]          local_spm_en;      // local SPM access active
    logic [NUM_CORES-1:0]          shared_data_req;   // request to shared mem

    // ----------------------------------------------------------------
    //  Scratchpad RAM interface signals
    // ----------------------------------------------------------------
    logic [NUM_CORES-1:0]                      spm_en;
    logic [NUM_CORES-1:0]                      spm_we;
    logic [NUM_CORES-1:0][3:0]                 spm_be;
    logic [NUM_CORES-1:0][SPM_ADDR_WIDTH-1:0]  spm_addr;
    logic [NUM_CORES-1:0][31:0]                spm_wdata;
    logic [NUM_CORES-1:0][31:0]                spm_rdata;

    // ----------------------------------------------------------------
    //  Local SPM response tracking (1-cycle latency)
    // ----------------------------------------------------------------
    logic [NUM_CORES-1:0] local_spm_rvalid_q;

    // ----------------------------------------------------------------
    //  Remote SPM crossbar signals
    // ----------------------------------------------------------------
    // Per-target arbitration
    logic [NUM_CORES-1:0]          remote_winner_valid;
    logic [CORE_IDX_W-1:0]        remote_winner_idx   [NUM_CORES];
    logic [NUM_CORES-1:0]          remote_access_gnt;           // target j: remote granted
    logic [CORE_IDX_W-1:0]        remote_rr_q         [NUM_CORES];

    // Per-target response tracking (1-cycle latency after grant)
    logic [NUM_CORES-1:0]          remote_rsp_valid_q;
    logic [CORE_IDX_W-1:0]        remote_rsp_src_q    [NUM_CORES];

    // Per-target remote request vector (helper)
    logic [NUM_CORES-1:0]          remote_req_vec      [NUM_CORES];

    // ----------------------------------------------------------------
    //  Shared-memory latency pipeline output
    // ----------------------------------------------------------------
    logic                  shared_pipe_valid_out;
    logic [CORE_IDX_W-1:0] shared_pipe_core_out;
    logic [31:0]           shared_pipe_rdata_out;

    // ================================================================
    //  Core instantiation
    // ================================================================
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
                .clk_i              (clk_i),
                .rst_ni             (rst_ni),
                .pulp_clock_en_i    (1'b1),
                .scan_cg_en_i       (1'b0),
                .boot_addr_i        (BOOT_ADDR),
                .mtvec_addr_i       (32'h00000000),
                .dm_halt_addr_i     (DM_HALTADDRESS),
                .hart_id_i          (g_core),
                .dm_exception_addr_i(32'h1A111000),
                .instr_req_o        (core_instr_req[g_core]),
                .instr_gnt_i        (core_instr_gnt[g_core]),
                .instr_rvalid_i     (core_instr_rvalid[g_core]),
                .instr_addr_o       (core_instr_addr[g_core]),
                .instr_rdata_i      (core_instr_rdata[g_core]),
                .data_req_o         (core_data_req[g_core]),
                .data_gnt_i         (core_data_gnt[g_core]),
                .data_rvalid_i      (core_data_rvalid[g_core]),
                .data_we_o          (core_data_we[g_core]),
                .data_be_o          (core_data_be[g_core]),
                .data_addr_o        (core_data_addr[g_core]),
                .data_wdata_o       (core_data_wdata[g_core]),
                .data_rdata_i       (core_data_rdata[g_core]),
                .irq_i              (core_irq[g_core]),
                .irq_ack_o          (core_irq_ack[g_core]),
                .irq_id_o           (core_irq_id[g_core]),
                .debug_req_i        (core_debug_req[g_core]),
                .debug_havereset_o  (),
                .debug_running_o    (),
                .debug_halted_o     (),
                .fetch_enable_i     (fetch_enable_i),
                .core_sleep_o       ()
            );

            assign core_irq[g_core]       = irq_shared;
            assign core_debug_req[g_core]  = debug_req_shared;
        end
    endgenerate

    // ================================================================
    //  Address decode (per core, combinational)
    // ================================================================
    generate
        for (g_core = 0; g_core < NUM_CORES; g_core++) begin : addr_dec
            assign core_is_spm[g_core] =
                (core_data_addr[g_core] >= SPM_BASE_ADDR) &&
                (core_data_addr[g_core] <  SPM_END_ADDR);

            assign core_spm_target[g_core] =
                core_data_addr[g_core][SPM_ADDR_WIDTH +: CORE_IDX_W];

            assign core_is_local_spm[g_core] =
                core_is_spm[g_core] &&
                (core_spm_target[g_core] == g_core[CORE_IDX_W-1:0]);

            assign core_is_remote_spm[g_core] =
                core_is_spm[g_core] &&
                (core_spm_target[g_core] != g_core[CORE_IDX_W-1:0]);

            assign core_is_shared[g_core] = ~core_is_spm[g_core];

            assign local_spm_en[g_core]   = core_data_req[g_core] && core_is_local_spm[g_core];
            assign shared_data_req[g_core] = core_data_req[g_core] && core_is_shared[g_core];
        end
    endgenerate

    // ================================================================
    //  Remote SPM crossbar – combinational arbitration
    // ================================================================
    always_comb begin
        for (int j = 0; j < NUM_CORES; j++) begin
            // Build request vector: which cores want remote access to SPM j?
            for (int i = 0; i < NUM_CORES; i++) begin
                if (i != j)
                    remote_req_vec[j][i] = core_data_req[i] &&
                                           core_is_remote_spm[i] &&
                                           (core_spm_target[i] == j[CORE_IDX_W-1:0]);
                else
                    remote_req_vec[j][i] = 1'b0;
            end

            // Round-robin arbiter among remote requestors for target j
            remote_winner_valid[j] = 1'b0;
            remote_winner_idx[j]   = remote_rr_q[j];
            for (int ofs = 0; ofs < NUM_CORES; ofs++) begin
                int unsigned idx;
                idx = int'(remote_rr_q[j]) + ofs;
                if (idx >= NUM_CORES) idx -= NUM_CORES;
                if (!remote_winner_valid[j] && remote_req_vec[j][idx]) begin
                    remote_winner_valid[j] = 1'b1;
                    remote_winner_idx[j]   = idx[CORE_IDX_W-1:0];
                end
            end

            // Grant remote access only if the local core is NOT accessing
            remote_access_gnt[j] = remote_winner_valid[j] && !local_spm_en[j];
        end
    end

    // ================================================================
    //  SPM access mux & scratchpad instantiation
    // ================================================================
    //  For each scratchpad j: local access has priority, then remote.
    always_comb begin
        for (int j = 0; j < NUM_CORES; j++) begin
            if (local_spm_en[j]) begin
                spm_en[j]    = 1'b1;
                spm_we[j]    = core_data_we[j];
                spm_be[j]    = core_data_be[j];
                spm_addr[j]  = core_data_addr[j][SPM_ADDR_WIDTH-1:0];
                spm_wdata[j] = core_data_wdata[j];
            end else if (remote_access_gnt[j]) begin
                spm_en[j]    = 1'b1;
                spm_we[j]    = core_data_we[remote_winner_idx[j]];
                spm_be[j]    = core_data_be[remote_winner_idx[j]];
                spm_addr[j]  = core_data_addr[remote_winner_idx[j]][SPM_ADDR_WIDTH-1:0];
                spm_wdata[j] = core_data_wdata[remote_winner_idx[j]];
            end else begin
                spm_en[j]    = 1'b0;
                spm_we[j]    = 1'b0;
                spm_be[j]    = '0;
                spm_addr[j]  = '0;
                spm_wdata[j] = '0;
            end
        end
    end

    generate
        for (g_core = 0; g_core < NUM_CORES; g_core++) begin : spm_gen
            scratchpad_ram #(
                .ADDR_WIDTH(SPM_ADDR_WIDTH)
            ) spm_i (
                .clk_i   (clk_i),
                .en_i    (spm_en[g_core]),
                .we_i    (spm_we[g_core]),
                .be_i    (spm_be[g_core]),
                .addr_i  (spm_addr[g_core]),
                .wdata_i (spm_wdata[g_core]),
                .rdata_o (spm_rdata[g_core])
            );
        end
    endgenerate

    // ================================================================
    //  SPM response tracking (registered, 1-cycle latency)
    // ================================================================
    always_ff @(posedge clk_i or negedge rst_ni) begin
        if (!rst_ni) begin
            local_spm_rvalid_q  <= '0;
            remote_rsp_valid_q  <= '0;
            for (int j = 0; j < NUM_CORES; j++) begin
                remote_rr_q[j]      <= '0;
                remote_rsp_src_q[j] <= '0;
            end
        end else begin
            for (int j = 0; j < NUM_CORES; j++) begin
                local_spm_rvalid_q[j]  <= local_spm_en[j];
                remote_rsp_valid_q[j]  <= remote_access_gnt[j];
                if (remote_access_gnt[j]) begin
                    remote_rsp_src_q[j] <= remote_winner_idx[j];
                    if (remote_winner_idx[j] == CORE_IDX_W'(NUM_CORES - 1))
                        remote_rr_q[j] <= '0;
                    else
                        remote_rr_q[j] <= remote_winner_idx[j] + 1'b1;
                end
            end
        end
    end

    // ================================================================
    //  Instruction arbiter (round-robin, unchanged)
    // ================================================================
    always_comb begin
        instr_sel_valid = 1'b0;
        instr_sel_idx   = instr_rr_q;
        for (int ofs = 0; ofs < NUM_CORES; ofs++) begin
            int unsigned idx;
            idx = int'(instr_rr_q) + ofs;
            if (idx >= NUM_CORES) idx -= NUM_CORES;
            if (!instr_sel_valid && core_instr_req[idx]) begin
                instr_sel_valid = 1'b1;
                instr_sel_idx   = idx[CORE_IDX_W-1:0];
            end
        end
    end

    // ================================================================
    //  Data arbiter – shared memory only (round-robin)
    // ================================================================
    always_comb begin
        data_sel_valid = 1'b0;
        data_sel_idx   = data_rr_q;
        for (int ofs = 0; ofs < NUM_CORES; ofs++) begin
            int unsigned idx;
            idx = int'(data_rr_q) + ofs;
            if (idx >= NUM_CORES) idx -= NUM_CORES;
            if (!data_sel_valid && shared_data_req[idx]) begin
                data_sel_valid = 1'b1;
                data_sel_idx   = idx[CORE_IDX_W-1:0];
            end
        end
    end

    // ================================================================
    //  Shared-memory signal routing (to mm_ram)
    // ================================================================
    assign instr_req_shared   = instr_sel_valid;
    assign instr_addr_shared  = instr_sel_valid ? core_instr_addr[instr_sel_idx]  : '0;
    assign instr_pc_shared    = instr_sel_valid ? core_instr_addr[instr_sel_idx]  : '0;

    assign data_req_shared    = data_sel_valid;
    assign data_addr_shared   = data_sel_valid ? core_data_addr[data_sel_idx]     : '0;
    assign data_we_shared     = data_sel_valid ? core_data_we[data_sel_idx]       : 1'b0;
    assign data_be_shared     = data_sel_valid ? core_data_be[data_sel_idx]       : '0;
    assign data_wdata_shared  = data_sel_valid ? core_data_wdata[data_sel_idx]    : '0;

    // ================================================================
    //  Grant routing (combines local SPM / remote SPM / shared mem)
    // ================================================================
    generate
        for (g_core = 0; g_core < NUM_CORES; g_core++) begin : grant_route
            // Instruction grant (unchanged)
            assign core_instr_gnt[g_core] =
                instr_sel_valid &&
                (instr_sel_idx == g_core[CORE_IDX_W-1:0]) &&
                instr_gnt_shared;

            // Data grant – three possible sources
            logic local_data_gnt;
            logic remote_data_gnt;
            logic shared_data_gnt;

            assign local_data_gnt  = local_spm_en[g_core]; // always immediate

            // Remote grant: check if any target scratchpad picked this core
            always_comb begin
                remote_data_gnt = 1'b0;
                for (int j = 0; j < NUM_CORES; j++) begin
                    if (remote_access_gnt[j] &&
                        remote_winner_idx[j] == g_core[CORE_IDX_W-1:0])
                        remote_data_gnt = 1'b1;
                end
            end

            assign shared_data_gnt =
                data_sel_valid &&
                (data_sel_idx == g_core[CORE_IDX_W-1:0]) &&
                data_gnt_shared;

            assign core_data_gnt[g_core] =
                local_data_gnt | remote_data_gnt | shared_data_gnt;
        end
    endgenerate

    // ================================================================
    //  Shared-memory data-response latency pipeline
    // ================================================================
    generate
        if (SHARED_MEM_EXTRA_LATENCY == 0) begin : no_latency_pipe
            assign shared_pipe_valid_out = data_pop;
            assign shared_pipe_core_out  = data_pop_core;
            assign shared_pipe_rdata_out = data_rdata_shared;
        end else begin : latency_pipe_gen
            logic                  pipe_valid [SHARED_MEM_EXTRA_LATENCY];
            logic [CORE_IDX_W-1:0] pipe_core  [SHARED_MEM_EXTRA_LATENCY];
            logic [31:0]           pipe_rdata [SHARED_MEM_EXTRA_LATENCY];

            always_ff @(posedge clk_i or negedge rst_ni) begin
                if (!rst_ni) begin
                    for (int s = 0; s < SHARED_MEM_EXTRA_LATENCY; s++)
                        pipe_valid[s] <= 1'b0;
                end else begin
                    pipe_valid[0]  <= data_pop;
                    pipe_core[0]   <= data_pop_core;
                    pipe_rdata[0]  <= data_rdata_shared;
                    for (int s = 1; s < SHARED_MEM_EXTRA_LATENCY; s++) begin
                        pipe_valid[s]  <= pipe_valid[s-1];
                        pipe_core[s]   <= pipe_core[s-1];
                        pipe_rdata[s]  <= pipe_rdata[s-1];
                    end
                end
            end

            assign shared_pipe_valid_out = pipe_valid[SHARED_MEM_EXTRA_LATENCY-1];
            assign shared_pipe_core_out  = pipe_core [SHARED_MEM_EXTRA_LATENCY-1];
            assign shared_pipe_rdata_out = pipe_rdata[SHARED_MEM_EXTRA_LATENCY-1];
        end
    endgenerate

    // ================================================================
    //  Response routing (instruction + data)
    // ================================================================
    always_comb begin
        for (int i = 0; i < NUM_CORES; i++) begin
            core_instr_rvalid[i] = 1'b0;
            core_instr_rdata[i]  = '0;
            core_data_rvalid[i]  = 1'b0;
            core_data_rdata[i]   = '0;
        end

        // Instruction response (unchanged)
        if (instr_pop) begin
            core_instr_rvalid[instr_pop_core] = 1'b1;
            core_instr_rdata[instr_pop_core]  = instr_rdata_shared;
        end

        // Data responses – local SPM
        for (int i = 0; i < NUM_CORES; i++) begin
            if (local_spm_rvalid_q[i]) begin
                core_data_rvalid[i] = 1'b1;
                core_data_rdata[i]  = spm_rdata[i];
            end
        end

        // Data responses – remote SPM
        for (int j = 0; j < NUM_CORES; j++) begin
            if (remote_rsp_valid_q[j]) begin
                core_data_rvalid[remote_rsp_src_q[j]] = 1'b1;
                core_data_rdata[remote_rsp_src_q[j]]  = spm_rdata[j];
            end
        end

        // Data responses – shared memory (from latency pipeline)
        if (shared_pipe_valid_out) begin
            core_data_rvalid[shared_pipe_core_out] = 1'b1;
            core_data_rdata[shared_pipe_core_out]  = shared_pipe_rdata_out;
        end
    end

    // ================================================================
    //  IRQ routing (unchanged)
    // ================================================================
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

    // ================================================================
    //  Instruction / data response FIFOs (unchanged)
    // ================================================================
    assign instr_push     = instr_sel_valid && instr_gnt_shared && (instr_rsp_count_q < FIFO_DEPTH);
    assign instr_pop      = instr_rvalid_shared && (instr_rsp_count_q != 0);
    assign instr_pop_core = instr_rsp_fifo[instr_rsp_rptr_q];

    assign data_push      = data_sel_valid && data_gnt_shared && (data_rsp_count_q < FIFO_DEPTH);
    assign data_pop       = data_rvalid_shared && (data_rsp_count_q != 0);
    assign data_pop_core  = data_rsp_fifo[data_rsp_rptr_q];

    always_ff @(posedge clk_i or negedge rst_ni) begin
        if (!rst_ni) begin
            instr_rr_q        <= '0;
            data_rr_q         <= '0;
            instr_rsp_wptr_q  <= '0;
            instr_rsp_rptr_q  <= '0;
            instr_rsp_count_q <= '0;
            data_rsp_wptr_q   <= '0;
            data_rsp_rptr_q   <= '0;
            data_rsp_count_q  <= '0;
        end else begin
            // Instruction FIFO
            if (instr_push) begin
                instr_rsp_fifo[instr_rsp_wptr_q] <= instr_sel_idx;
                instr_rsp_wptr_q <= instr_rsp_wptr_q + 1'b1;
            end
            if (instr_pop)
                instr_rsp_rptr_q <= instr_rsp_rptr_q + 1'b1;
            case ({instr_push, instr_pop})
                2'b10: instr_rsp_count_q <= instr_rsp_count_q + 1'b1;
                2'b01: instr_rsp_count_q <= instr_rsp_count_q - 1'b1;
                default: ;
            endcase

            // Data FIFO
            if (data_push) begin
                data_rsp_fifo[data_rsp_wptr_q] <= data_sel_idx;
                data_rsp_wptr_q <= data_rsp_wptr_q + 1'b1;
            end
            if (data_pop)
                data_rsp_rptr_q <= data_rsp_rptr_q + 1'b1;
            case ({data_push, data_pop})
                2'b10: data_rsp_count_q <= data_rsp_count_q + 1'b1;
                2'b01: data_rsp_count_q <= data_rsp_count_q - 1'b1;
                default: ;
            endcase

            // Round-robin pointer updates
            if (instr_sel_valid && instr_gnt_shared) begin
                if (instr_sel_idx == CORE_IDX_W'(NUM_CORES - 1)) instr_rr_q <= '0;
                else instr_rr_q <= instr_sel_idx + 1'b1;
            end
            if (data_sel_valid && data_gnt_shared) begin
                if (data_sel_idx == CORE_IDX_W'(NUM_CORES - 1)) data_rr_q <= '0;
                else data_rr_q <= data_sel_idx + 1'b1;
            end
        end
    end

    // ================================================================
    //  Shared-memory (mm_ram) instantiation  (unchanged)
    // ================================================================
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
        .data_core_id_i ({{(32-CORE_IDX_W){1'b0}}, data_sel_idx}),

        .debug_req_o    (debug_req_shared),
        .tests_passed_o (tests_passed_o),
        .tests_failed_o (tests_failed_o),
        .exit_valid_o   (exit_valid_o),
        .exit_value_o   (exit_value_o)
    );

endmodule
