`timescale 1ns / 1ps
//
// axis_frame_reader
//   Принимает 8-битные пиксели в домене pix_clk, упаковывает по 4 в 32-битное
//   слово (первый пиксель -> [7:0]), передаёт через асинхронный FIFO в домен
//   aclk и выдаёт как AXI4-Stream master с TLAST на последнем слове кадра.
//
//   FIFO: fifo_generator_0, Independent Clocks Block RAM,
//         32 bit write / 32 bit read, First Word Fall Through,
//         reset включён (wr_rst_busy / rd_rst_busy), overflow включён.
//
module axis_frame_reader #(
    parameter integer FRAME_WORDS = 16000          // 320*200 / 4
)(
    // ---- вход пикселей (домен pix_clk) ----
    input wire       pix_clk,
    input wire [7:0] pix_data,
    input wire       pix_valid,
    
    // ---- управление (домен aclk, от AXI GPIO канал 2) ----
    input wire capture_en,
    
    // ---- AXI4-Stream master (домен aclk) ----
    input  wire        aclk,
    input  wire        aresetn,
    output wire [31:0] m_axis_tdata,
    output wire [3:0]  m_axis_tkeep,
    output wire        m_axis_tvalid,
    input  wire        m_axis_tready,
    output wire        m_axis_tlast,
    
    // ---- отладка ----
    output wire overflow  // импульс в домене pix_clk
);

    localparam integer CW = $clog2(FRAME_WORDS + 1);

    // =========================================================================
    // 1. Синхронизация capture_en: aclk -> pix_clk (2-FF)
    // =========================================================================
    (* ASYNC_REG = "TRUE" *) reg [1:0] cap_sync = 2'b00;
    always @(posedge pix_clk)
        cap_sync <= {cap_sync[0], capture_en};
    wire cap_pix = cap_sync[1];

    // =========================================================================
    // 2. Упаковка 4 x 8 бит -> 32 бита (домен pix_clk)
    //    Принимается ровно один кадр после подъёма capture_en.
    // =========================================================================
    reg [31:0]   word       = 32'd0;
    reg [1:0]    byte_cnt   = 2'd0;
    reg          word_valid = 1'b0;
    reg [CW-1:0] wr_words   = {CW{1'b0}};
    reg          frame_done = 1'b0;
    
    wire active = cap_pix && !frame_done;
 
    always @(posedge pix_clk) begin
        word_valid <= 1'b0;
        if (!cap_pix) begin
            byte_cnt   <= 2'd0;
            wr_words   <= {CW{1'b0}};
            frame_done <= 1'b0;
        end else if (active && pix_valid) begin
            // сдвиг вправо: после p0..p3 получаем {p3, p2, p1, p0}
            word     <= {pix_data, word[31:8]};
            byte_cnt <= byte_cnt + 2'd1;
            if (byte_cnt == 2'd3) begin
                word_valid <= 1'b1;
                wr_words   <= wr_words + 1'b1;
                if (wr_words == FRAME_WORDS - 1)
                    frame_done <= 1'b1;
            end
        end
    end
    
    // =========================================================================
    // 3. Асинхронный FIFO pix_clk -> aclk
    // =========================================================================
    // xpm_fifo_async требует rst, синхронный с wr_clk -> синхронизируем ~aresetn в pix_clk
    (* ASYNC_REG = "TRUE" *) reg [1:0] rst_sync = 2'b11;
    always @(posedge pix_clk)
        rst_sync <= {rst_sync[0], ~aresetn};
    wire fifo_rst = rst_sync[1];
    
    wire [31:0] fifo_dout;
    wire        fifo_full, fifo_empty;
    wire        wr_rst_busy, rd_rst_busy;
 
    wire fifo_wr_en = word_valid & ~wr_rst_busy;
    wire fifo_rd_en = m_axis_tvalid & m_axis_tready;
    
    xpm_fifo_async #(
        .FIFO_MEMORY_TYPE    ("block"),   // Block RAM
        .FIFO_WRITE_DEPTH    (1024),
        .WRITE_DATA_WIDTH    (32),
        .READ_DATA_WIDTH     (32),
        .READ_MODE           ("fwft"),    // First Word Fall Through
        .FIFO_READ_LATENCY   (0),         // обязательно 0 для fwft
        .CDC_SYNC_STAGES     (2),
        .RELATED_CLOCKS      (0),
        .USE_ADV_FEATURES    ("0001"),    // включить только overflow
        .ECC_MODE            ("no_ecc"),
        .DOUT_RESET_VALUE    ("0"),
        .FULL_RESET_VALUE    (0),
        .PROG_FULL_THRESH    (10),
        .PROG_EMPTY_THRESH   (10),
        .WR_DATA_COUNT_WIDTH (1),
        .RD_DATA_COUNT_WIDTH (1),
        .SIM_ASSERT_CHK      (0),
        .WAKEUP_TIME         (0)
    ) u_fifo (
        .rst           (fifo_rst),
        .wr_clk        (pix_clk),
        .wr_en         (fifo_wr_en),
        .din           (word),
        .full          (fifo_full),
        .overflow      (overflow),
        .wr_rst_busy   (wr_rst_busy),
 
        .rd_clk        (aclk),
        .rd_en         (fifo_rd_en),
        .dout          (fifo_dout),
        .empty         (fifo_empty),
        .rd_rst_busy   (rd_rst_busy),
 
        // неиспользуемые входы
        .sleep         (1'b0),
        .injectsbiterr (1'b0),
        .injectdbiterr (1'b0),
 
        // неиспользуемые выходы
        .prog_full     (),
        .wr_data_count (),
        .almost_full   (),
        .wr_ack        (),
        .prog_empty    (),
        .rd_data_count (),
        .underflow     (),
        .almost_empty  (),
        .data_valid    (),
        .sbiterr       (),
        .dbiterr       ()
    );
    
    // =========================================================================
    // 4. AXI4-Stream выход (домен aclk), FIFO в режиме FWFT
    // =========================================================================
    assign m_axis_tdata  = fifo_dout;
    assign m_axis_tvalid = ~fifo_empty & ~rd_rst_busy;
    assign m_axis_tkeep  = 4'hF;
 
    reg [CW-1:0] rd_words = {CW{1'b0}};
    always @(posedge aclk) begin
        if (!aresetn || !capture_en)
            rd_words <= {CW{1'b0}};
        else if (fifo_rd_en)
            rd_words <= (rd_words == FRAME_WORDS - 1) ? {CW{1'b0}} : rd_words + 1'b1;
    end
 
    assign m_axis_tlast = (rd_words == FRAME_WORDS - 1);

endmodule