// SPDX-FileCopyrightText: 2026 emmtrix Technologies GmbH
// SPDX-License-Identifier: Apache-2.0

package tb_mem_types_pkg;
    typedef struct packed {
        logic        req;
        logic [31:0] addr;
        logic        we;
        logic [3:0]  be;
        logic [31:0] wdata;
    } tb_mem_req_t;

    typedef struct packed {
        logic        gnt;
        logic        rvalid;
        logic [31:0] rdata;
    } tb_mem_rsp_t;
endpackage