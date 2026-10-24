`timescale 1ns / 1ps

module tb_top_core;

    reg clk;
    reg reset;

    wire [31:0] core0_pc;
    wire [31:0] core1_pc;
    wire core0_exception;
    wire core1_exception;

    integer i;
    integer errors;
    integer core0_grants;
    integer core1_grants;
    integer simultaneous_requests;

    // --------------------------------------------------------
    // DUT: dual-core system
    // --------------------------------------------------------

    top_core DUT (
        .clk             (clk),
        .reset           (reset),
        .core0_pc        (core0_pc),
        .core1_pc        (core1_pc),
        .core0_exception (core0_exception),
        .core1_exception (core1_exception)
    );

    // 100 MHz clock
    initial begin
        clk = 1'b0;
        forever #5 clk = ~clk;
    end

    // --------------------------------------------------------
    // Initialize each private instruction memory.
    //
    // Core 0:
    //   x1 = 5
    //   x2 = 10
    //   x3 = x1 + x2 = 15
    //   store x3 to address 0
    //   load address 0 into x4
    //
    // Core 1:
    //   x1 = 9
    //   x2 = 4
    //   store x1 to address x2 (address 4)
    //
    // NOPs are inserted between dependent instructions to
    // reduce dependence on forwarding/hazard behavior.
    // --------------------------------------------------------

    initial begin
        reset = 1'b1;
        errors = 0;
        core0_grants = 0;
        core1_grants = 0;
        simultaneous_requests = 0;

        // Wait for hierarchy and memories to initialize.
        #1;

        // Fill both private instruction memories with NOPs.
        for (i = 0; i < 1024; i = i + 1) begin
            DUT.CORE0.IMEM.imem[i] = 32'h00000013;
            DUT.CORE1.IMEM.imem[i] = 32'h00000013;
        end

        // Initialize shared data memory.
        for (i = 0; i < 1024; i = i + 1)
            DUT.DMEM.dmem[i] = 32'h00000000;

        // -------------------------
        // Core 0 program
        // -------------------------

        DUT.CORE0.IMEM.imem[0]  = 32'h00500093; // addi x1,x0,5
        DUT.CORE0.IMEM.imem[1]  = 32'h00000013; // nop
        DUT.CORE0.IMEM.imem[2]  = 32'h00000013; // nop
        DUT.CORE0.IMEM.imem[3]  = 32'h00A00113; // addi x2,x0,10
        DUT.CORE0.IMEM.imem[4]  = 32'h00000013; // nop
        DUT.CORE0.IMEM.imem[5]  = 32'h00000013; // nop
        DUT.CORE0.IMEM.imem[6]  = 32'h002081B3; // add x3,x1,x2
        DUT.CORE0.IMEM.imem[7]  = 32'h00000013; // nop
        DUT.CORE0.IMEM.imem[8]  = 32'h00000013; // nop
        DUT.CORE0.IMEM.imem[9]  = 32'h00302023; // sw x3,0(x0)
        DUT.CORE0.IMEM.imem[10] = 32'h00000013; // nop
        DUT.CORE0.IMEM.imem[11] = 32'h00000013; // nop
        DUT.CORE0.IMEM.imem[12] = 32'h00002203; // lw x4,0(x0)
        DUT.CORE0.IMEM.imem[13] = 32'h00000013; // nop
        DUT.CORE0.IMEM.imem[14] = 32'h00000013; // nop
        DUT.CORE0.IMEM.imem[15] = 32'h0000006F; // jal x0,0

        // -------------------------
        // Core 1 program
        // -------------------------

        DUT.CORE1.IMEM.imem[0] = 32'h00900093; // addi x1,x0,9
        DUT.CORE1.IMEM.imem[1] = 32'h00000013; // nop
        DUT.CORE1.IMEM.imem[2] = 32'h00000013; // nop
        DUT.CORE1.IMEM.imem[3] = 32'h00400113; // addi x2,x0,4
        DUT.CORE1.IMEM.imem[4] = 32'h00000013; // nop
        DUT.CORE1.IMEM.imem[5] = 32'h00000013; // nop
        DUT.CORE1.IMEM.imem[6] = 32'h00112023; // sw x1,0(x2)
        DUT.CORE1.IMEM.imem[7] = 32'h00000013; // nop
        DUT.CORE1.IMEM.imem[8] = 32'h00000013; // nop
        DUT.CORE1.IMEM.imem[9] = 32'h0000006F; // jal x0,0

        // Apply reset for several rising edges.
        repeat (4) @(posedge clk);
        @(negedge clk);
        reset = 1'b0;

        // Run both cores long enough to execute their programs.
        repeat (250) @(posedge clk);

        @(negedge clk);

        $display("");
        $display("========================================");
        $display(" DUAL-CORE TEST RESULTS");
        $display("========================================");

        $display("Core 0 PC        = %08h", core0_pc);
        $display("Core 1 PC        = %08h", core1_pc);
        $display("Core 0 exception = %b", core0_exception);
        $display("Core 1 exception = %b", core1_exception);

        $display("DMEM[0]          = %08h (expected 0000000F)",
                 DUT.DMEM.dmem[0]);

        $display("DMEM[1]          = %08h (expected 00000009)",
                 DUT.DMEM.dmem[1]);

        $display("Core 0 grants    = %0d", core0_grants);
        $display("Core 1 grants    = %0d", core1_grants);
        $display("Contended cycles = %0d", simultaneous_requests);

        // ----------------------------------------------------
        // Basic checks
        // ----------------------------------------------------

        if (core0_pc == 32'h00000000) begin
            $display("FAIL: Core 0 PC never progressed.");
            errors = errors + 1;
        end

        if (core1_pc == 32'h00000000) begin
            $display("FAIL: Core 1 PC never progressed.");
            errors = errors + 1;
        end

        if (DUT.DMEM.dmem[0] !== 32'h0000000F) begin
            $display("FAIL: Core 0 store/arithmetic result incorrect.");
            errors = errors + 1;
        end

        if (DUT.DMEM.dmem[1] !== 32'h00000009) begin
            $display("FAIL: Core 1 store/arithmetic result incorrect.");
            errors = errors + 1;
        end

        if (errors == 0)
            $display("BASIC DUAL-CORE CHECKS PASSED.");
        else
            $display("TEST FINISHED WITH %0d FAILURE(S).", errors);

        $display("========================================");
        $finish;
    end

    // --------------------------------------------------------
    // Monitor arbitration.
    //
    // Internal signals are observed hierarchically because
    // they are not top-level ports.
    // --------------------------------------------------------

    always @(posedge clk) begin
        if (!reset) begin

            if (DUT.grant0 && DUT.grant1) begin
                $display(
                    "FAIL at %0t: both cores granted simultaneously",
                    $time
                );
                errors = errors + 1;
            end

            if (DUT.grant0)
                core0_grants = core0_grants + 1;

            if (DUT.grant1)
                core1_grants = core1_grants + 1;

            if (DUT.c0_request && DUT.c1_request)
                simultaneous_requests =
                    simultaneous_requests + 1;

        end
    end

endmodule