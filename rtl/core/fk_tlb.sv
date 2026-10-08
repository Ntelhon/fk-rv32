// fk-core: fully associative Sv32 TLB (4 KiB pages + 4 MiB megapages)
// No ASIDs are implemented (satp.ASID is hardwired to zero).
module fk_tlb import fk_pkg::*; #(
  parameter int ENTRIES = 16
)(
  input  logic        clk,
  input  logic        rst_n,
  input  logic        flush,
  // lookup
  input  logic [19:0] vpn,
  output logic        hit,
  output logic [21:0] ppn,       // final physical page number for vpn
  output pte_flags_t  flags,
  // fill
  input  logic        fill,
  input  logic [19:0] fill_vpn,
  input  logic [21:0] fill_ppn,
  input  logic        fill_mega,
  input  pte_flags_t  fill_flags
);
  localparam int IW = $clog2(ENTRIES);

  logic [ENTRIES-1:0] valid_q;
  logic [19:0]        vpn_q   [ENTRIES];
  logic [21:0]        ppn_q   [ENTRIES];
  logic               mega_q  [ENTRIES];
  pte_flags_t         flags_q [ENTRIES];
  logic [IW-1:0]      rr_q;

  function automatic logic match(input int i, input logic [19:0] v);
    return valid_q[i] && (vpn_q[i][19:10] == v[19:10]) && (mega_q[i] || vpn_q[i][9:0] == v[9:0]);
  endfunction

  always_comb begin
    hit   = 1'b0;
    ppn   = '0;
    flags = '0;
    for (int i = 0; i < ENTRIES; i++) begin
      if (match(i, vpn)) begin
        hit   = 1'b1;
        ppn   = mega_q[i] ? {ppn_q[i][21:10], vpn[9:0]} : ppn_q[i];
        flags = flags_q[i];
      end
    end
  end

  // Replace an existing entry for the same page (e.g. dirty-bit update), else round robin
  logic          fill_hit;
  logic [IW-1:0] fill_idx;
  always_comb begin
    fill_hit = 1'b0;
    fill_idx = rr_q;
    for (int i = 0; i < ENTRIES; i++) begin
      if (match(i, fill_vpn)) begin
        fill_hit = 1'b1;
        fill_idx = IW'(i);
      end
    end
  end

  always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
      valid_q <= '0;
      rr_q    <= '0;
    end else if (flush) begin
      valid_q <= '0;
    end else if (fill) begin
      valid_q[fill_idx] <= 1'b1;
      if (!fill_hit) rr_q <= rr_q + 1'b1;
    end
  end

  always_ff @(posedge clk) begin
    if (fill && !flush) begin
      vpn_q[fill_idx]   <= fill_vpn;
      ppn_q[fill_idx]   <= fill_ppn;
      mega_q[fill_idx]  <= fill_mega;
      flags_q[fill_idx] <= fill_flags;
    end
  end

endmodule
