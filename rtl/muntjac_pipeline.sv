module muntjac_pipeline import muntjac_pkg::*; #(
  // Number of bits of physical address supported. This must not exceed 56.
  parameter PhysAddrLen = 56
) (
    // Clock and reset
    input  logic            clk_i,
    input  logic            rst_ni,

    // Memory interfaces
    output icache_h2d_t icache_h2d_o,
    input  icache_d2h_t icache_d2h_i,
    output dcache_h2d_t dcache_h2d_o,
    input  dcache_d2h_t dcache_d2h_i,

    input  logic irq_software_m_i,
    input  logic irq_timer_m_i,
    input  logic irq_external_m_i,
    input  logic irq_external_s_i,

    input  logic [63:0] hart_id_i,

    // Debug connections
    output logic [63:0] dbg_pc_o
);

  logic [63:0]     satp;
  priv_lvl_e       prv;
  status_t         status;
  logic            redirect_valid;
  if_reason_e      redirect_reason;
  logic [63:0]     redirect_pc;
  branch_info_t    branch_info;
  logic            fetch_valid;
  logic            fetch_ready;
  fetched_instr_t  fetch_instr;

  muntjac_frontend #(
    .PhysAddrLen (PhysAddrLen)
  ) frontend (
      .clk_i,
      .rst_ni,
      .icache_h2d_o,
      .icache_d2h_i,
      .satp_i            (satp),
      .prv_i             (prv),
      .status_i          (status),
      .redirect_valid_i  (redirect_valid),
      .redirect_reason_i (redirect_reason),
      .redirect_pc_i     (redirect_pc),
      .branch_info_i     (branch_info),
      .fetch_valid_o     (fetch_valid),
      .fetch_ready_i     (fetch_ready),
      .fetch_instr_o     (fetch_instr)
  );

  muntjac_backend #(
    .PhysAddrLen (PhysAddrLen)
  ) backend (
      .clk_i,
      .rst_ni,
      .dcache_h2d_o,
      .dcache_d2h_i,
      .satp_o            (satp),
      .prv_o             (prv),
      .status_o          (status),
      .redirect_valid_o  (redirect_valid),
      .redirect_reason_o (redirect_reason),
      .redirect_pc_o     (redirect_pc),
      .branch_info_o     (branch_info),
      .fetch_valid_i     (fetch_valid),
      .fetch_ready_o     (fetch_ready),
      .fetch_instr_i     (fetch_instr),
      .irq_software_m_i,
      .irq_timer_m_i,
      .irq_external_m_i,
      .irq_external_s_i,
      .hart_id_i,
      .dbg_pc_o
  );

endmodule
