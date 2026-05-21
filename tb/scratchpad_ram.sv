// Single-port scratchpad SRAM with byte-enable writes.
// Runs at core clock frequency; one read or write per cycle.
// Read data is registered and available the cycle after en_i is asserted.

module scratchpad_ram #(
    parameter int unsigned ADDR_WIDTH = 12   // default 4 KB
) (
    input  logic                    clk_i,
    input  logic                    en_i,
    input  logic                    we_i,
    input  logic [3:0]              be_i,
    input  logic [ADDR_WIDTH-1:0]   addr_i,
    input  logic [31:0]             wdata_i,
    output logic [31:0]             rdata_o
);

    localparam int unsigned NUM_BYTES = 2**ADDR_WIDTH;

    logic [7:0]              mem [NUM_BYTES];
    logic [ADDR_WIDTH-1:0]   addr_aligned;

    always_comb addr_aligned = {addr_i[ADDR_WIDTH-1:2], 2'b0};

    always @(posedge clk_i) begin
        if (en_i) begin
            if (we_i) begin
                if (be_i[0]) mem[addr_aligned    ] <= wdata_i[ 7: 0];
                if (be_i[1]) mem[addr_aligned + 1] <= wdata_i[15: 8];
                if (be_i[2]) mem[addr_aligned + 2] <= wdata_i[23:16];
                if (be_i[3]) mem[addr_aligned + 3] <= wdata_i[31:24];
            end

            rdata_o <= {mem[addr_aligned + 3], mem[addr_aligned + 2],
                        mem[addr_aligned + 1], mem[addr_aligned    ]};
        end
    end

endmodule
