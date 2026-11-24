// SPDX-FileCopyrightText: 2026 emmtrix Technologies GmbH
// SPDX-License-Identifier: Apache-2.0

// Per-core instruction cache.
//
// Sits between a core's OBI instruction port and the shared instruction
// fetch arbiter. Read-only, set-associative, true-LRU replacement.
//
// Hit:  gnt in the request cycle, rvalid one cycle later (same timing as an
//       uncontended single-cycle memory), so a core running from the cache
//       fetches one word per cycle without touching the shared port.
// Miss: gnt is held low while the whole line is fetched word by word
//       through mem_req_o (in address order, pipelined). The line is then
//       installed and the still-pending core request hits on the next cycle.
//
// flush_i invalidates every line. It is driven by fence.i, so code written
// through the data port (stores or DMA) becomes visible to this core after a
// fence.i. A flush during a refill discards the line being fetched, because
// some of its words may have been read before the flush. While flush_i is
// high no request hits, so a fetch issued in the same cycle as the flush
// (the core refetches pc+4 right away) cannot return stale data.
//
// Responses are returned in order: at most one hit response is in flight and
// the core's next request is not granted until its line is present.

module tb_icache #(
    parameter bit          ENABLE     = 1'b1,
    parameter int unsigned SIZE_BYTES = 4096,
    parameter int unsigned LINE_BYTES = 16,
    parameter int unsigned WAYS       = 2,
    parameter int unsigned CORE_ID    = 0
) (
    input  logic clk_i,
    input  logic rst_ni,
    input  logic flush_i,

    // Core side (instruction port, read only).
    input  tb_mem_types_pkg::tb_mem_req_t core_req_i,
    output tb_mem_types_pkg::tb_mem_rsp_t core_rsp_o,

    // Memory side (towards the shared instruction arbiter).
    output tb_mem_types_pkg::tb_mem_req_t mem_req_o,
    input  tb_mem_types_pkg::tb_mem_rsp_t mem_rsp_i
);

    generate
        if (!ENABLE) begin : gen_bypass
            assign mem_req_o  = core_req_i;
            assign core_rsp_o = mem_rsp_i;
        end else begin : gen_cache
            localparam int unsigned LINE_WORDS = LINE_BYTES / 4;
            localparam int unsigned SETS       = SIZE_BYTES / (LINE_BYTES * WAYS);
            localparam int unsigned OFFSET_W   = $clog2(LINE_BYTES);
            localparam int unsigned WORD_W     = (LINE_WORDS > 1) ? $clog2(LINE_WORDS) : 1;
            localparam int unsigned SET_W      = (SETS > 1) ? $clog2(SETS) : 1;
            localparam int unsigned INDEX_W    = (SETS > 1) ? $clog2(SETS) : 0;
            localparam int unsigned TAG_W      = 32 - OFFSET_W - INDEX_W;
            localparam int unsigned WAY_W      = (WAYS > 1) ? $clog2(WAYS) : 1;
            localparam int unsigned CNT_W      = $clog2(LINE_WORDS + 1);

`ifndef SYNTHESIS
            initial begin : checks
                if (LINE_BYTES < 4 || (LINE_BYTES & (LINE_BYTES - 1)) != 0)
                    $fatal(1, "[ICACHE] LINE_BYTES must be a power of two >= 4");
                if (WAYS < 1)
                    $fatal(1, "[ICACHE] WAYS must be >= 1");
                if (SETS < 1 || (SETS & (SETS - 1)) != 0 || SETS * WAYS * LINE_BYTES != SIZE_BYTES)
                    $fatal(1, "[ICACHE] SIZE_BYTES / (LINE_BYTES * WAYS) must be a power of two");
            end
`endif

            typedef enum logic { S_IDLE, S_REFILL } state_e;

            typedef logic [LINE_WORDS-1:0][31:0] line_t;

            line_t            data_q  [SETS][WAYS];
            logic [TAG_W-1:0] tag_q   [SETS][WAYS];
            logic [SETS-1:0][WAYS-1:0]            valid_q;
            // LRU age per way: 0 = most recently used, WAYS-1 = victim.
            logic [SETS-1:0][WAYS-1:0][WAY_W-1:0] age_q;

            state_e            state_q;
            logic [31:0]       fill_base_q;
            logic [CNT_W-1:0]  issue_cnt_q;
            logic [CNT_W-1:0]  recv_cnt_q;
            line_t             fill_buf_q;
            line_t             fill_line;
            logic              fill_discard_q;

            logic              rvalid_q;
            logic [31:0]       rdata_q;
            logic [31:0]       hit_word;

            logic [SET_W-1:0]  req_set;
            logic [TAG_W-1:0]  req_tag;
            logic [WORD_W-1:0] req_word;
            logic              hit;
            logic [WAY_W-1:0]  hit_way;
            logic              core_gnt;

            logic [SET_W-1:0]  fill_set;
            logic [TAG_W-1:0]  fill_tag;
            logic              fill_done;
            logic [WAY_W-1:0]  victim_way;
            logic              install;
            logic              touch_en;
            logic [SET_W-1:0]  touch_set;
            logic [WAY_W-1:0]  touch_way;

            longint unsigned   stat_hits_q;
            longint unsigned   stat_misses_q;
            longint unsigned   stat_flushes_q;
            longint unsigned   stat_refill_flushes_q;

            assign req_set  = (INDEX_W > 0) ? SET_W'(core_req_i.addr >> OFFSET_W) : '0;
            assign req_tag  = TAG_W'(core_req_i.addr >> (OFFSET_W + INDEX_W));
            assign req_word = (LINE_WORDS > 1) ? WORD_W'(core_req_i.addr >> 2) : '0;

            assign fill_set = (INDEX_W > 0) ? SET_W'(fill_base_q >> OFFSET_W) : '0;
            assign fill_tag = TAG_W'(fill_base_q >> (OFFSET_W + INDEX_W));

            always_comb begin
                hit     = 1'b0;
                hit_way = '0;
                for (int w = 0; w < WAYS; w++) begin
                    if (!hit && valid_q[req_set][w] && tag_q[req_set][w] == req_tag) begin
                        hit     = 1'b1;
                        hit_way = WAY_W'(w);
                    end
                end
                if (flush_i)
                    hit = 1'b0;
            end

            // Victim: first invalid way, otherwise the least recently used one.
            always_comb begin
                logic found;
                found      = 1'b0;
                victim_way = '0;
                for (int w = 0; w < WAYS; w++) begin
                    if (!found && !valid_q[fill_set][w]) begin
                        found      = 1'b1;
                        victim_way = WAY_W'(w);
                    end
                end
                for (int w = 0; w < WAYS; w++) begin
                    if (!found && age_q[fill_set][w] == WAY_W'(WAYS - 1)) begin
                        found      = 1'b1;
                        victim_way = WAY_W'(w);
                    end
                end
            end

            assign core_gnt  = core_req_i.req && (state_q == S_IDLE) && hit;
            assign fill_done = (state_q == S_REFILL) && mem_rsp_i.rvalid &&
                               (recv_cnt_q == CNT_W'(LINE_WORDS - 1));

            // The last word comes straight from the memory response.
            always_comb begin
                fill_line = fill_buf_q;
                fill_line[LINE_WORDS-1] = mem_rsp_i.rdata;
            end

            assign core_rsp_o.gnt    = core_gnt;
            assign core_rsp_o.rvalid = rvalid_q;
            assign core_rsp_o.rdata  = rdata_q;

            assign mem_req_o.req   = (state_q == S_REFILL) && (issue_cnt_q < CNT_W'(LINE_WORDS));
            assign mem_req_o.addr  = fill_base_q + {issue_cnt_q, 2'b00};
            assign mem_req_o.we    = 1'b0;
            assign mem_req_o.be    = 4'b1111;
            assign mem_req_o.wdata = '0;

            // LRU update: a hit or an installed line becomes most recently used.
            // Hits happen only in S_IDLE and installs only in S_REFILL, so at
            // most one of them touches the LRU state per cycle.
            assign install    = fill_done && !fill_discard_q && !flush_i;
            assign touch_en   = core_gnt || install;
            assign touch_set  = core_gnt ? req_set : fill_set;
            assign touch_way  = core_gnt ? hit_way : victim_way;

            always_ff @(posedge clk_i or negedge rst_ni) begin
                if (!rst_ni) begin
                    for (int s = 0; s < SETS; s++)
                        for (int w = 0; w < WAYS; w++)
                            age_q[s][w] <= WAY_W'(w);
                end else if (touch_en) begin
                    for (int w = 0; w < WAYS; w++) begin
                        if (WAY_W'(w) == touch_way)
                            age_q[touch_set][w] <= '0;
                        else if (age_q[touch_set][w] < age_q[touch_set][touch_way])
                            age_q[touch_set][w] <= age_q[touch_set][w] + 1'b1;
                    end
                end
            end

            always_ff @(posedge clk_i or negedge rst_ni) begin
                if (!rst_ni) begin
                    state_q        <= S_IDLE;
                    fill_base_q    <= '0;
                    issue_cnt_q    <= '0;
                    recv_cnt_q     <= '0;
                    fill_discard_q <= 1'b0;
                    rvalid_q       <= 1'b0;
                    rdata_q        <= '0;
                    stat_hits_q    <= '0;
                    stat_misses_q  <= '0;
                    stat_flushes_q <= '0;
                    stat_refill_flushes_q <= '0;
                    valid_q        <= '0;
                end else begin
                    rvalid_q <= core_gnt;

                    if (core_gnt) begin
                        rdata_q     <= hit_word;
                        stat_hits_q <= stat_hits_q + 1;
                    end

                    unique case (state_q)
                        S_IDLE: begin
                            if (core_req_i.req && !hit) begin
                                state_q        <= S_REFILL;
                                fill_base_q    <= {core_req_i.addr[31:OFFSET_W], OFFSET_W'(0)};
                                issue_cnt_q    <= '0;
                                recv_cnt_q     <= '0;
                                fill_discard_q <= 1'b0;
                                stat_misses_q  <= stat_misses_q + 1;
                            end
                        end
                        S_REFILL: begin
                            if (mem_req_o.req && mem_rsp_i.gnt)
                                issue_cnt_q <= issue_cnt_q + 1'b1;
                            if (mem_rsp_i.rvalid) begin
                                fill_buf_q[recv_cnt_q[WORD_W-1:0]] <= mem_rsp_i.rdata;
                                recv_cnt_q <= recv_cnt_q + 1'b1;
                            end
                            if (flush_i) begin
                                fill_discard_q        <= 1'b1;
                                stat_refill_flushes_q <= stat_refill_flushes_q + 1;
                            end
                            if (fill_done) begin
                                state_q <= S_IDLE;
                                if (install)
                                    valid_q[fill_set][victim_way] <= 1'b1;
                            end
                        end
                        default: state_q <= S_IDLE;
                    endcase

                    // Invalidate last so it wins over a same-cycle install.
                    if (flush_i) begin
                        stat_flushes_q <= stat_flushes_q + 1;
                        valid_q <= '0;
                    end
                end
            end

            // The data and tag arrays are neither reset nor touched by the
            // process above, so synthesis can keep them as memories instead
            // of flip-flops. install implies fill_done, i.e. S_REFILL.
            always_ff @(posedge clk_i) begin
                if (install) begin
                    data_q[fill_set][victim_way] <= fill_line;
                    tag_q[fill_set][victim_way]  <= fill_tag;
                end
            end

            assign hit_word = data_q[req_set][hit_way][req_word];

`ifndef SYNTHESIS
            final begin
                $display("[ICACHE] core %0d: hits=%0d misses=%0d flushes=%0d flushes_during_refill=%0d",
                         CORE_ID, stat_hits_q, stat_misses_q, stat_flushes_q, stat_refill_flushes_q);
            end
`endif
        end
    endgenerate

endmodule
