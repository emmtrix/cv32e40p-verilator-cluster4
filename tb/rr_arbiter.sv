// SPDX-FileCopyrightText: 2026 emmtrix Technologies GmbH
// SPDX-License-Identifier: Apache-2.0

module rr_arbiter #(
    parameter int unsigned NUM_REQ = 4,
    parameter int unsigned IDX_W = (NUM_REQ > 1) ? $clog2(NUM_REQ) : 1,
    parameter int unsigned ADDR_W = 32,
    parameter int unsigned DATA_W = 32,
    parameter int unsigned BE_W = 4,
    parameter int unsigned FIFO_DEPTH = 32,
    parameter int unsigned FIFO_PTR_W = $clog2(FIFO_DEPTH)
) (
    input  logic                         clk_i,
    input  logic                         rst_ni,

    // Request side (masters)
    input  logic [NUM_REQ-1:0]           req_i,
    input  logic [NUM_REQ-1:0][ADDR_W-1:0]  addr_i,
    input  logic [NUM_REQ-1:0]           we_i,
    input  logic [NUM_REQ-1:0][BE_W-1:0] be_i,
    input  logic [NUM_REQ-1:0][DATA_W-1:0] wdata_i,

    // Shared memory side (slave)
    output logic                         req_o,
    output logic [ADDR_W-1:0]            addr_o,
    output logic                         we_o,
    output logic [BE_W-1:0]              be_o,
    output logic [DATA_W-1:0]            wdata_o,
    input  logic                         gnt_i,
    input  logic                         rvalid_i,
    input  logic [DATA_W-1:0]            rdata_i,

    // Return side (masters)
    output logic [NUM_REQ-1:0]           gnt_o,
    output logic                         rsp_valid_o,
    output logic [IDX_W-1:0]             rsp_idx_o,
    output logic [DATA_W-1:0]            rsp_data_o,

    // Optional visibility of current selected request
    output logic [IDX_W-1:0]             req_idx_o,
    output logic                         req_valid_o
);

    logic [IDX_W-1:0] rr_q;

    logic [IDX_W-1:0] rsp_fifo [FIFO_DEPTH-1:0];
    logic [FIFO_PTR_W-1:0] rsp_wptr_q;
    logic [FIFO_PTR_W-1:0] rsp_rptr_q;
    logic [FIFO_PTR_W:0]   rsp_count_q;

    logic                  rsp_push;
    logic                  rsp_pop;
    logic [IDX_W-1:0]      rsp_pop_idx;

    always_comb begin
        gnt_o       = '0;
        req_idx_o   = rr_q;
        req_valid_o = 1'b0;

        for (int ofs = 0; ofs < NUM_REQ; ofs++) begin
            int unsigned idx;
            idx = int'(rr_q) + ofs;
            if (idx >= NUM_REQ) idx -= NUM_REQ;
            if (!req_valid_o && req_i[idx]) begin
                req_valid_o = 1'b1;
                req_idx_o   = idx[IDX_W-1:0];
            end
        end

        req_o   = req_valid_o;
        addr_o  = req_valid_o ? addr_i[req_idx_o] : '0;
        we_o    = req_valid_o ? we_i[req_idx_o] : 1'b0;
        be_o    = req_valid_o ? be_i[req_idx_o] : '0;
        wdata_o = req_valid_o ? wdata_i[req_idx_o] : '0;

        if (req_valid_o && gnt_i) begin
            gnt_o[req_idx_o] = 1'b1;
        end

        rsp_valid_o = 1'b0;
        rsp_idx_o   = '0;
        rsp_data_o  = '0;
        if (rsp_pop) begin
            rsp_valid_o = 1'b1;
            rsp_idx_o   = rsp_pop_idx;
            rsp_data_o  = rdata_i;
        end
    end

    assign rsp_push    = req_valid_o && gnt_i && (rsp_count_q < FIFO_DEPTH);
    assign rsp_pop     = rvalid_i && (rsp_count_q != 0);
    assign rsp_pop_idx = rsp_fifo[rsp_rptr_q];

    always_ff @(posedge clk_i or negedge rst_ni) begin
        if (!rst_ni) begin
            rr_q         <= '0;
            rsp_wptr_q   <= '0;
            rsp_rptr_q   <= '0;
            rsp_count_q  <= '0;
        end else begin
            if (rsp_push) begin
                rsp_fifo[rsp_wptr_q] <= req_idx_o;
                rsp_wptr_q <= rsp_wptr_q + 1'b1;
            end
            if (rsp_pop)
                rsp_rptr_q <= rsp_rptr_q + 1'b1;

            case ({rsp_push, rsp_pop})
                2'b10: rsp_count_q <= rsp_count_q + 1'b1;
                2'b01: rsp_count_q <= rsp_count_q - 1'b1;
                default: ;
            endcase

            if (rsp_push) begin
                if (req_idx_o == IDX_W'(NUM_REQ - 1)) rr_q <= '0;
                else rr_q <= req_idx_o + 1'b1;
            end
        end
    end

endmodule