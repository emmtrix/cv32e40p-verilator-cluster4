#include "Vtb_top_verilator.h"
#include "verilated.h"

#ifdef VCD_TRACE
#include "verilated_vcd_c.h"
#endif

static vluint64_t sim_time = 0;

double sc_time_stamp() {
    return static_cast<double>(sim_time);
}

int main(int argc, char** argv) {
    Verilated::commandArgs(argc, argv);

    Vtb_top_verilator* top = new Vtb_top_verilator();

#ifdef VCD_TRACE
    Verilated::traceEverOn(true);
    VerilatedVcdC* tfp = new VerilatedVcdC();
    top->trace(tfp, 99);
    tfp->open("build/verilator/waves.vcd");
#endif

    top->clk_i = 0;
    top->rst_ni = 0;
    top->fetch_enable_i = 1;

    while (!Verilated::gotFinish()) {
        if (sim_time > 40) {
            top->rst_ni = 1;
        }

        top->clk_i = !top->clk_i;
        top->eval();

#ifdef VCD_TRACE
        tfp->dump(sim_time);
#endif

        sim_time += 5;
    }

#ifdef VCD_TRACE
    tfp->close();
    delete tfp;
#endif

    delete top;
    return 0;
}
