// SPDX-FileCopyrightText: 2026 emmtrix Technologies GmbH
// SPDX-License-Identifier: Apache-2.0

module tb_event_unit #(
    parameter int unsigned NUM_CORES = 4
) (
    input  logic        clk_i,
    input  logic        rst_ni,

    input  logic        bar_notify_valid_i,
    input  logic [31:0] bar_notify_wdata_i,
    input  logic        bar_setup_valid_i,
    input  logic [31:0] bar_setup_wdata_i,
    input  logic        evt_clear_valid_i,
    input  logic [31:0] evt_clear_wdata_i,

    input  logic        read_req_i,
    input  logic        read_wait_i,
    input  logic [31:0] read_core_id_i,
    output logic [31:0] read_rdata_o,

    output logic        irq_o
);

    logic [NUM_CORES-1:0] bar_mask_q;
    logic [NUM_CORES-1:0] bar_arrived_q;
    logic [NUM_CORES-1:0] evt_pending_q;
    logic [31:0]          bar_setup_raw_q;

    logic                 read_wait_q;
    logic [31:0]          read_core_id_q;

    logic [NUM_CORES-1:0] next_arrived;

    always_ff @(posedge clk_i or negedge rst_ni) begin
        if (!rst_ni) begin
            bar_mask_q      <= '0;
            bar_arrived_q   <= '0;
            evt_pending_q   <= '0;
            bar_setup_raw_q <= '0;
            read_wait_q     <= 1'b0;
            read_core_id_q  <= '0;
        end else begin
            if (read_req_i) begin
                read_wait_q    <= read_wait_i;
                read_core_id_q <= read_core_id_i;
            end

            if (bar_setup_valid_i) begin
                bar_setup_raw_q <= bar_setup_wdata_i;
                bar_mask_q      <= bar_setup_wdata_i[NUM_CORES-1:0];
                bar_arrived_q   <= '0;
                evt_pending_q   <= '0;
            end

            if (bar_notify_valid_i && read_core_id_i < NUM_CORES) begin
                if (bar_mask_q[read_core_id_i] && !evt_pending_q[read_core_id_i]) begin
                    next_arrived = bar_arrived_q | ({{(NUM_CORES-1){1'b0}}, 1'b1} << read_core_id_i);
                    if (next_arrived == bar_mask_q && bar_mask_q != '0) begin
                        bar_arrived_q <= '0;
                        evt_pending_q <= evt_pending_q | bar_mask_q;
                    end else begin
                        bar_arrived_q <= next_arrived;
                    end
                end
            end

            if (evt_clear_valid_i && read_core_id_i < NUM_CORES) begin
                if (evt_clear_wdata_i[3:0] == 4'd0) begin
                    evt_pending_q[read_core_id_i] <= 1'b0;
                end
            end
        end
    end

    always_comb begin
        read_rdata_o = '0;
        if (read_wait_q && read_core_id_q < NUM_CORES) begin
            read_rdata_o = {{31{1'b0}}, evt_pending_q[read_core_id_q]};
        end else if (!read_wait_q) begin
            read_rdata_o = bar_setup_raw_q;
        end
    end

    assign irq_o = |evt_pending_q;

    // Reserved for future behavior extensions while keeping write payload in the interface.
    logic unused_bar_notify_wdata;
    assign unused_bar_notify_wdata = ^bar_notify_wdata_i;

endmodule
