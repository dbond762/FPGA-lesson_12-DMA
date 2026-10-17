// axi4_full_ram.v
// Простий AXI4 (Full) slave на Block RAM. Порти названі за конвенцією
// Vivado (s_axi_...), щоб Package IP / Module Reference автоматично
// розпізнавав AXI4-інтерфейс.
//
// Зміни відносно попередньої версії:
//   * пам'ять винесена в окремі always-блоки БЕЗ reset -> Vivado виводить Block RAM
//   * синхронне читання в регістр (s_axi_rdata), стабільне поки rvalid && !rready
//   * підтримка WSTRB (побайтовий запис)
//   * виправлено завершення read-burst (останній beat не губиться,
//     немає зайвого beat при arlen = 0)
//   * burst вважається INCR (DMA і MicroBlaze використовують INCR)
//
// Розмір: MEM_DEPTH слів по DATA_WIDTH біт; адреса байтова,
// тому MEM_DEPTH * DATA_WIDTH/8 має дорівнювати 2^ADDR_WIDTH.
// Для кадру 320x200 (16000 слів): MEM_DEPTH = 16384, ADDR_WIDTH = 16 (64 KB).
 
module axi4_full_ram #(
    parameter DATA_WIDTH = 32,
    parameter ADDR_WIDTH = 16,
    parameter MEM_DEPTH  = 16384
) (
    input  wire                        s_axi_aclk,
    input  wire                        s_axi_aresetn,
 
    input  wire [ADDR_WIDTH-1:0]       s_axi_awaddr,
    input  wire [7:0]                  s_axi_awlen,
    input  wire [2:0]                  s_axi_awsize,
    input  wire [1:0]                  s_axi_awburst,
    input  wire                        s_axi_awvalid,
    output wire                        s_axi_awready,
 
    input  wire [DATA_WIDTH-1:0]       s_axi_wdata,
    input  wire [DATA_WIDTH/8-1:0]     s_axi_wstrb,
    input  wire                        s_axi_wlast,
    input  wire                        s_axi_wvalid,
    output wire                        s_axi_wready,
 
    output reg  [1:0]                  s_axi_bresp,
    output reg                         s_axi_bvalid,
    input  wire                        s_axi_bready,
 
    input  wire [ADDR_WIDTH-1:0]       s_axi_araddr,
    input  wire [7:0]                  s_axi_arlen,
    input  wire [2:0]                  s_axi_arsize,
    input  wire [1:0]                  s_axi_arburst,
    input  wire                        s_axi_arvalid,
    output wire                        s_axi_arready,
 
    output reg  [DATA_WIDTH-1:0]       s_axi_rdata,
    output reg                         s_axi_rlast,
    output reg  [1:0]                  s_axi_rresp,
    output reg                         s_axi_rvalid,
    input  wire                        s_axi_rready
);
 
    localparam BYTES = DATA_WIDTH / 8;
 
    // =========================================================================
    // Пам'ять (Block RAM, simple dual port: 1 запис + 1 читання)
    // =========================================================================
    reg [DATA_WIDTH-1:0] mem [0:MEM_DEPTH-1];
 
    // керуючі сигнали від FSM
    wire                  mem_we;
    wire [ADDR_WIDTH-3:0] mem_waddr;
    wire                  mem_re;
    wire [ADDR_WIDTH-3:0] mem_raddr;
 
    // запис: тільки клок, без reset; побайтово за WSTRB
    integer i;
    always @(posedge s_axi_aclk) begin
        if (mem_we) begin
            for (i = 0; i < BYTES; i = i + 1)
                if (s_axi_wstrb[i])
                    mem[mem_waddr][8*i +: 8] <= s_axi_wdata[8*i +: 8];
        end
    end
 
    // читання: синхронне, у вихідний регістр, без reset
    always @(posedge s_axi_aclk) begin
        if (mem_re)
            s_axi_rdata <= mem[mem_raddr];
    end
 
    // =========================================================================
    // Канал запису (AW / W / B)
    // =========================================================================
    localparam WRIDLE = 2'd0, WRDATA = 2'd1, WRRESP = 2'd2;
    reg [1:0]            wstate;
    reg [ADDR_WIDTH-1:0] waddr_cur;
    reg [7:0]            wburst_cnt;
 
    assign s_axi_awready = (wstate == WRIDLE);
    assign s_axi_wready  = (wstate == WRDATA);
 
    assign mem_we    = (wstate == WRDATA) && s_axi_wvalid;
    assign mem_waddr = waddr_cur[ADDR_WIDTH-1:2];
 
    always @(posedge s_axi_aclk or negedge s_axi_aresetn) begin
        if (!s_axi_aresetn) begin
            wstate       <= WRIDLE;
            waddr_cur    <= {ADDR_WIDTH{1'b0}};
            wburst_cnt   <= 8'd0;
            s_axi_bvalid <= 1'b0;
            s_axi_bresp  <= 2'b00;
        end else begin
            case (wstate)
                WRIDLE: begin
                    if (s_axi_awvalid) begin
                        waddr_cur  <= s_axi_awaddr;
                        wburst_cnt <= s_axi_awlen;
                        wstate     <= WRDATA;
                    end
                end
                WRDATA: begin
                    if (s_axi_wvalid) begin            // wready = 1 у цьому стані
                        waddr_cur <= waddr_cur + BYTES;
                        if (wburst_cnt == 8'd0) begin
                            s_axi_bvalid <= 1'b1;
                            s_axi_bresp  <= 2'b00;     // OKAY
                            wstate       <= WRRESP;
                        end else begin
                            wburst_cnt <= wburst_cnt - 1'b1;
                        end
                    end
                end
                WRRESP: begin
                    if (s_axi_bready) begin            // bvalid = 1 у цьому стані
                        s_axi_bvalid <= 1'b0;
                        wstate       <= WRIDLE;
                    end
                end
                default: wstate <= WRIDLE;
            endcase
        end
    end
 
    // =========================================================================
    // Канал читання (AR / R)
    //   RDIDLE -> RDREAD (читання BRAM, 1 такт) -> RDDATA (beat на шині)
    //   1 beat на 2 такти; s_axi_rdata змінюється лише в RDREAD,
    //   тому стабільний, поки мастер тримає rready = 0.
    // =========================================================================
    localparam RDIDLE = 2'd0, RDREAD = 2'd1, RDDATA = 2'd2;
    reg [1:0]            rstate;
    reg [ADDR_WIDTH-1:0] raddr_cur;
    reg [7:0]            rburst_cnt;
 
    assign s_axi_arready = (rstate == RDIDLE);
 
    assign mem_re    = (rstate == RDREAD);
    assign mem_raddr = raddr_cur[ADDR_WIDTH-1:2];
 
    always @(posedge s_axi_aclk or negedge s_axi_aresetn) begin
        if (!s_axi_aresetn) begin
            rstate       <= RDIDLE;
            raddr_cur    <= {ADDR_WIDTH{1'b0}};
            rburst_cnt   <= 8'd0;
            s_axi_rvalid <= 1'b0;
            s_axi_rlast  <= 1'b0;
            s_axi_rresp  <= 2'b00;
        end else begin
            case (rstate)
                RDIDLE: begin
                    if (s_axi_arvalid) begin
                        raddr_cur  <= s_axi_araddr;
                        rburst_cnt <= s_axi_arlen;
                        rstate     <= RDREAD;
                    end
                end
                RDREAD: begin
                    // на цьому фронті BRAM кладе дані в s_axi_rdata
                    s_axi_rvalid <= 1'b1;
                    s_axi_rresp  <= 2'b00;             // OKAY
                    s_axi_rlast  <= (rburst_cnt == 8'd0);
                    rstate       <= RDDATA;
                end
                RDDATA: begin
                    if (s_axi_rready) begin            // rvalid = 1 у цьому стані
                        s_axi_rvalid <= 1'b0;
                        s_axi_rlast  <= 1'b0;
                        if (rburst_cnt == 8'd0) begin
                            rstate <= RDIDLE;
                        end else begin
                            raddr_cur  <= raddr_cur + BYTES;
                            rburst_cnt <= rburst_cnt - 1'b1;
                            rstate     <= RDREAD;
                        end
                    end
                end
                default: rstate <= RDIDLE;
            endcase
        end
    end
 
endmodule