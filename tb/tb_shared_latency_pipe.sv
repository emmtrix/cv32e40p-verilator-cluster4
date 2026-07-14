// SPDX-FileCopyrightText: 2026 emmtrix Technologies GmbH
// SPDX-License-Identifier: Apache-2.0

module tb_shared_latency_pipe #(
    parameter int unsigned EXTRA_LATENCY = 2,
    parameter int unsigned CORE_IDX_W = 2,
    parameter int unsigned DATA_W = 32
) (
    input  logic                    clk_i,
    input  logic                    rst_ni,
    input  logic                    in_valid_i,
    input  logic [CORE_IDX_W-1:0]   in_core_i,
    input  logic [DATA_W-1:0]       in_data_i,
    output logic                    out_valid_o,
    output logic [CORE_IDX_W-1:0]   out_core_o,
    output logic [DATA_W-1:0]       out_data_o
);

    generate
        if (EXTRA_LATENCY == 0) begin : no_latency
            assign out_valid_o = in_valid_i;
            assign out_core_o  = in_core_i;
            assign out_data_o  = in_data_i;
        end else begin : with_latency
            logic                  pipe_valid [EXTRA_LATENCY];
            logic [CORE_IDX_W-1:0] pipe_core  [EXTRA_LATENCY];
            logic [DATA_W-1:0]     pipe_data  [EXTRA_LATENCY];

            always_ff @(posedge clk_i or negedge rst_ni) begin
                if (!rst_ni) begin
                    for (int s = 0; s < EXTRA_LATENCY; s++)
                        pipe_valid[s] <= 1'b0;
                end else begin
                    pipe_valid[0] <= in_valid_i;
                    pipe_core[0]  <= in_core_i;
                    pipe_data[0]  <= in_data_i;
                    for (int s = 1; s < EXTRA_LATENCY; s++) begin
                        pipe_valid[s] <= pipe_valid[s-1];
                        pipe_core[s]  <= pipe_core[s-1];
                        pipe_data[s]  <= pipe_data[s-1];
                    end
                end
            end

            assign out_valid_o = pipe_valid[EXTRA_LATENCY-1];
            assign out_core_o  = pipe_core [EXTRA_LATENCY-1];
            assign out_data_o  = pipe_data [EXTRA_LATENCY-1];
        end
    endgenerate

endmodule