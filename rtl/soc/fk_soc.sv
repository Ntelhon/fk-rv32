// fk-soc: simulation SoC around fk_core
//
//   0x0000_1000 - 0x0000_FFFF  Boot ROM (60 KiB)
//   0x0010_0000 - 0x0010_0FFF  Test finisher ("sifive,test1": 0x5555 pass, 0x3333 fail, 0x7777 reset)
//   0x0200_0000 - 0x0200_FFFF  CLINT
//   0x0C00_0000 - 0x0FFF_FFFF  PLIC (UART = source 10)
//   0x1000_0000 - 0x1000_00FF  UART 16550A
//   0x8000_0000 - +RAM_SIZE    RAM
module fk_soc #(
  parameter logic [31:0] RAM_BASE = 32'h8000_0000,
  parameter logic [31:0] RAM_SIZE = 32'h0800_0000,   // 128 MiB
  parameter logic [31:0] ROM_BASE = 32'h0000_1000,
  parameter logic [31:0] ROM_SIZE = 32'h0000_F000,
  parameter int          TICK_DIV = 1
)(
  input  logic clk,
  input  logic rst_n
);
  // ---------------------------------------------------------------
  // Core
  // ---------------------------------------------------------------
  logic        awvalid, awready, wvalid, wready, wlast, bvalid, bready;
  logic        arvalid, arready, rvalid, rready, rlast;
  logic [3:0]  awid, bid, arid, rid, wstrb;
  logic [31:0] awaddr, wdata, araddr, rdata;
  logic [7:0]  awlen, arlen;
  logic [2:0]  awsize, arsize;
  logic [1:0]  awburst, arburst, bresp, rresp;

  logic        mtip, msip;
  logic [63:0] mtime;
  logic [1:0]  plic_eip;
  logic        uart_irq;

  fk_core #(
    .RESET_PC(ROM_BASE), .RAM_BASE(RAM_BASE), .RAM_SIZE(RAM_SIZE),
    .ROM_BASE(ROM_BASE), .ROM_SIZE(ROM_SIZE)
  ) u_core (
    .clk, .rst_n,
    .irq_mtip(mtip), .irq_msip(msip), .irq_meip(plic_eip[0]), .irq_seip(plic_eip[1]), .mtime,
    .m_awvalid(awvalid), .m_awready(awready), .m_awid(awid), .m_awaddr(awaddr), .m_awlen(awlen),
    .m_awsize(awsize), .m_awburst(awburst),
    .m_wvalid(wvalid), .m_wready(wready), .m_wdata(wdata), .m_wstrb(wstrb), .m_wlast(wlast),
    .m_bvalid(bvalid), .m_bready(bready), .m_bid(bid), .m_bresp(bresp),
    .m_arvalid(arvalid), .m_arready(arready), .m_arid(arid), .m_araddr(araddr), .m_arlen(arlen),
    .m_arsize(arsize), .m_arburst(arburst),
    .m_rvalid(rvalid), .m_rready(rready), .m_rid(rid), .m_rdata(rdata), .m_rresp(rresp), .m_rlast(rlast)
  );

  // ---------------------------------------------------------------
  // AXI -> simple bus
  // ---------------------------------------------------------------
  logic        b_req, b_we, b_err;
  logic [31:0] b_addr, b_wdata, b_rdata;
  logic [2:0]  b_size;
  logic [3:0]  b_wstrb;

  fk_axi2simple u_bridge (
    .clk, .rst_n,
    .s_awvalid(awvalid), .s_awready(awready), .s_awid(awid), .s_awaddr(awaddr), .s_awlen(awlen),
    .s_awsize(awsize), .s_awburst(awburst),
    .s_wvalid(wvalid), .s_wready(wready), .s_wdata(wdata), .s_wstrb(wstrb), .s_wlast(wlast),
    .s_bvalid(bvalid), .s_bready(bready), .s_bid(bid), .s_bresp(bresp),
    .s_arvalid(arvalid), .s_arready(arready), .s_arid(arid), .s_araddr(araddr), .s_arlen(arlen),
    .s_arsize(arsize), .s_arburst(arburst),
    .s_rvalid(rvalid), .s_rready(rready), .s_rid(rid), .s_rdata(rdata), .s_rresp(rresp), .s_rlast(rlast),
    .b_req, .b_we, .b_addr, .b_size, .b_wdata, .b_wstrb, .b_rdata, .b_err
  );

  // ---------------------------------------------------------------
  // Address decode
  // ---------------------------------------------------------------
  logic sel_rom, sel_ram, sel_clint, sel_plic, sel_uart, sel_test;
  assign sel_rom   = (b_addr >= ROM_BASE) && (b_addr - ROM_BASE < ROM_SIZE);
  assign sel_ram   = (b_addr >= RAM_BASE) && (b_addr - RAM_BASE < RAM_SIZE);
  assign sel_clint = (b_addr[31:16] == 16'h0200);
  assign sel_plic  = (b_addr[31:26] == 6'b000011);
  assign sel_uart  = (b_addr[31:8]  == 24'h100000);
  assign sel_test  = (b_addr[31:12] == 20'h00100);

  // ---------------------------------------------------------------
  // RAM / ROM (loaded by the testbench through DPI)
  // ---------------------------------------------------------------
  localparam int RAM_WORDS = RAM_SIZE / 4;
  localparam int ROM_WORDS = ROM_SIZE / 4;
  logic [31:0] ram [RAM_WORDS];
  logic [31:0] rom [ROM_WORDS];
  logic [31:0] tohost_addr;

  logic [31:0] ram_idx, rom_idx;
  assign ram_idx = (b_addr - RAM_BASE) >> 2;
  assign rom_idx = (b_addr - ROM_BASE) >> 2;

`ifndef SYNTHESIS
  import "DPI-C" function void sim_tohost(input int unsigned value);

  export "DPI-C" function soc_mem_write;
  export "DPI-C" function soc_mem_read;
  export "DPI-C" function soc_set_tohost;

  function void soc_mem_write(input int unsigned addr, input int unsigned data);
    if (addr >= RAM_BASE && addr - RAM_BASE < RAM_SIZE) ram[(addr - RAM_BASE) >> 2] = data;
    else if (addr >= ROM_BASE && addr - ROM_BASE < ROM_SIZE) rom[(addr - ROM_BASE) >> 2] = data;
  endfunction

  function int unsigned soc_mem_read(input int unsigned addr);
    if (addr >= RAM_BASE && addr - RAM_BASE < RAM_SIZE) return ram[(addr - RAM_BASE) >> 2];
    if (addr >= ROM_BASE && addr - ROM_BASE < ROM_SIZE) return rom[(addr - ROM_BASE) >> 2];
    return 0;
  endfunction

  function void soc_set_tohost(input int unsigned addr);
    tohost_addr = addr;
  endfunction

  initial tohost_addr = 32'd0;
`endif

  always_ff @(posedge clk) begin
    if (b_req && b_we && sel_ram) begin
      for (int b = 0; b < 4; b++)
        if (b_wstrb[b]) ram[ram_idx][8*b +: 8] <= b_wdata[8*b +: 8];
`ifndef SYNTHESIS
      if (tohost_addr != 0 && b_addr[31:2] == tohost_addr[31:2] && b_wdata != 0)
        sim_tohost(b_wdata);
`endif
    end
`ifndef SYNTHESIS
    // test finisher: report through the same channel as tohost
    if (b_req && b_we && sel_test && b_addr[11:0] == 12'h0) begin
      if (b_wdata[15:0] == 16'h5555 || b_wdata[15:0] == 16'h7777) sim_tohost(32'd1);
      else if (b_wdata[15:0] == 16'h3333) sim_tohost({15'd0, b_wdata[31:16] | {15'd0, b_wdata[31:16] == 16'd0}, 1'b1});
    end
`endif
  end

  // ---------------------------------------------------------------
  // Peripherals
  // ---------------------------------------------------------------
  logic [31:0] clint_rdata, plic_rdata, uart_rdata;
  logic        clint_err, plic_err, uart_err;

  fk_clint #(.TICK_DIV(TICK_DIV)) u_clint (
    .clk, .rst_n,
    .req(b_req && sel_clint), .we(b_we), .addr(b_addr[15:0]), .wdata(b_wdata), .wstrb(b_wstrb),
    .rdata(clint_rdata), .err(clint_err), .mtip, .msip, .mtime
  );

  logic [31:1] plic_src;
  always_comb begin
    plic_src     = '0;
    plic_src[10] = uart_irq;
  end

  fk_plic #(.NSRC(31)) u_plic (
    .clk, .rst_n,
    .req(b_req && sel_plic), .we(b_we), .addr(b_addr[25:0]), .wdata(b_wdata),
    .rdata(plic_rdata), .err(plic_err), .src(plic_src), .eip(plic_eip)
  );

  fk_uart u_uart (
    .clk, .rst_n,
    .req(b_req && sel_uart), .we(b_we), .addr(b_addr[2:0]), .wdata(b_wdata),
    .rdata(uart_rdata), .err(uart_err), .irq(uart_irq)
  );

  always_comb begin
    b_err   = 1'b0;
    b_rdata = 32'd0;
    if (sel_ram)        b_rdata = ram[ram_idx];
    else if (sel_rom)   begin b_rdata = rom[rom_idx]; b_err = b_we; end
    else if (sel_clint) begin b_rdata = clint_rdata;  b_err = clint_err; end
    else if (sel_plic)  begin b_rdata = plic_rdata;   b_err = plic_err;  end
    else if (sel_uart)  begin b_rdata = uart_rdata;   b_err = uart_err;  end
    else if (sel_test)  b_rdata = 32'd0;
    else                b_err = 1'b1;
  end

  logic unused;
  assign unused = ^{b_size};

endmodule
