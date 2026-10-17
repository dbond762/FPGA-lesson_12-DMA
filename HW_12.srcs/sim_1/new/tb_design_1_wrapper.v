`timescale 1ns / 1ps

module tb_design_1_wrapper();
    
    localparam integer W      = 320;
    localparam integer H      = 200;
    localparam integer WORDS  = W * H / 4;
    
    reg diff_clock_rtl_0_clk_p = 0;
    wire diff_clock_rtl_0_clk_n = ~diff_clock_rtl_0_clk_p;
    always #5 diff_clock_rtl_0_clk_p = ~diff_clock_rtl_0_clk_p;  // 100 МГц
    
    reg reset_rtl_0 = 1;   // reset активний
    
    reg pix_clk = 0;
    always #20 pix_clk = ~pix_clk;
    
    reg       btn_tri_i;
    reg [7:0] pix_data;
    reg       pix_valid;

    design_1_wrapper dut (
        .btn_tri_i(btn_tri_i),
        .diff_clock_rtl_0_clk_n(diff_clock_rtl_0_clk_n),
        .diff_clock_rtl_0_clk_p(diff_clock_rtl_0_clk_p),
        .pix_clk(pix_clk), .pix_data(pix_data), .pix_valid(pix_valid),
        .reset_rtl_0(reset_rtl_0)
    );

    `define FRAME_READER dut.design_1_i.axis_frame_reader_0.inst
    `define RAM_MEM      dut.design_1_i.axi4_full_ram_0.inst.mem
    
    wire capture_en = `FRAME_READER.capture_en;
    
    function [7:0] pattern;
        input integer x, y;
        begin
            pattern = (x + 2 * y) & 8'hFF;        // диагональный градиент
        end
    endfunction
    
    function [31:0] expected_word;
        input integer k;
        integer p, j;
        begin
            expected_word = 32'd0;
            for (j = 0; j < 4; j = j + 1) begin
                p = 4 * k + j;
                expected_word[8*j +: 8] = pattern(p % W, p / W);
            end
        end
    endfunction
    
    initial begin
        reset_rtl_0  = 1'b0;
        #200;
        reset_rtl_0  = 1'b1;
 
        // держим кнопку, пока программа MicroBlaze не выставит start
        #5000;
        btn_tri_i = 1'b1;
        $display("[%0t] button pressed", $time);
        wait (capture_en === 1'b1);
        $display("[%0t] capture_en = 1 (DMA armed, start from MicroBlaze)", $time);
        #2000;
        btn_tri_i = 1'b0;
    end
    
    integer x, y;
    initial begin
        wait (capture_en === 1'b1);
        // capture_en проходит 2-FF синхронизатор в pix_clk - даём ему время,
        // иначе первые пиксели будут проигнорированы
        repeat (8) @(posedge pix_clk);
 
        $display("[%0t] frame transmission started", $time);
        for (y = 0; y < H; y = y + 1) begin
            for (x = 0; x < W; x = x + 1) begin
                pix_data  <= pattern(x, y);
                pix_valid <= 1'b1;
                @(posedge pix_clk);
            end
            pix_valid <= 1'b0;
            repeat (16) @(posedge pix_clk);
        end
        $display("[%0t] frame transmission finished", $time);
    end
    
    integer k, errors;
    initial begin
        errors = 0;
        // ждём, пока DMA запишет последнее слово (до этого там X)
        wait (!$isunknown(`RAM_MEM[WORDS-1]));
        #(1000);
 
        for (k = 0; k < WORDS; k = k + 1) begin
            if (`RAM_MEM[k] !== expected_word(k)) begin
                if (errors < 10)
                    $display("MISMATCH word %0d: got %h, expected %h",
                             k, `RAM_MEM[k], expected_word(k));
                errors = errors + 1;
            end
        end
 
        if (errors == 0)
            $display("[%0t] PASS: all %0d words match", $time, WORDS);
        else
            $display("[%0t] FAIL: %0d mismatched words", $time, errors);
        $finish;
    end
 
    initial begin
        #(20_000_000);                            // 20 мс
        $display("[%0t] TIMEOUT", $time);
        $finish;
    end

endmodule
