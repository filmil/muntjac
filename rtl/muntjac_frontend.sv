module muntjac_frontend import muntjac_pkg::*; #(
  // Number of bits of physical address supported. This must not exceed 56.
  parameter PhysAddrLen = 56,

  // Number of bits of virtual address supported. This currently must be 39.
  parameter VirtAddrLen = 39
) (
    input  logic           clk_i,
    input  logic           rst_ni,

    output icache_h2d_t    icache_h2d_o,
    input  icache_d2h_t    icache_d2h_i,

    input  logic [63:0]    satp_i,
    input  priv_lvl_e      prv_i,
    input  status_t        status_i,
    // When the signals are valid, instruction fetcher needs to flush its pipeline
    // and restart fetching from the specified PC.
    input  logic           redirect_valid_i,
    input  if_reason_e     redirect_reason_i,
    input  logic [63:0]    redirect_pc_i,
    input  branch_info_t   branch_info_i,
    output logic           fetch_valid_o,
    input  logic           fetch_ready_i,
    output fetched_instr_t fetch_instr_o
);

  // Number of bits required to recover a legal full 64-bit address.
  // This requires one extra bit for physical address because we need to perform sign extension.
  localparam LogicSextAddrLen = PhysAddrLen >= VirtAddrLen ? PhysAddrLen + 1 : VirtAddrLen;

  wire [63:0] insn_atp = {prv_i == PRIV_LVL_M ? 4'd0 : satp_i[63:60], satp_i[59:0]};

  ////////////////////////
  // Next PC Generation //
  ////////////////////////

  // Latched redirection information. I$ may be busy when the request comes in, but they are pulse
  // signals so we need to latch them.
  logic [63:0] redirect_pc_q;
  if_reason_e redirect_reason_q;
  logic redirect_valid_q;
  logic [63:0] redirect_atp_q;
  logic redirect_prv_q;
  logic redirect_sum_q;

  logic align_ready;

  always_ff @(posedge clk_i or negedge rst_ni) begin
    if (!rst_ni) begin
      // Reset vector
      redirect_pc_q <= '0;
      redirect_reason_q <= IF_FENCE_I;
      redirect_valid_q <= 1'b1;
      redirect_atp_q <= '0;
      redirect_prv_q <= 1'b0;
      redirect_sum_q <= 1'b0;
    end else begin
      if (align_ready) begin
        redirect_valid_q <= 1'b0;
      end
      if (redirect_valid_i) begin
        redirect_pc_q <= redirect_pc_i;
        redirect_valid_q <= redirect_valid_i;
        redirect_reason_q <= redirect_reason_i;
        redirect_atp_q <= insn_atp;
        redirect_prv_q <= prv_i[0];
        redirect_sum_q <= status_i.sum;
      end
    end
  end

  // We need to latch these so that their changes do not affect currently prefetched instructions.
  logic [63:0] atp_latch;
  logic prv_latch;
  logic sum_latch;

  always_ff @(posedge clk_i or negedge rst_ni) begin
    if (!rst_ni) begin
      atp_latch <= '0;
      prv_latch <= 1'b0;
      sum_latch <= 1'b0;
    end
    else begin
      if (redirect_valid_q && align_ready) begin
        atp_latch <= redirect_atp_q;
        prv_latch <= redirect_prv_q;
        sum_latch <= redirect_sum_q;
      end
    end
  end

  logic [63:0] pc;
  if_reason_e reason;

  logic                          predict_taken;
  logic [LogicSextAddrLen-1:0] predict_target;

  // Next PC word to fetch if no branch is taken.
  wire [LogicSextAddrLen-1:0] npc_word = {pc[LogicSextAddrLen-1:2], 2'b0} + 4;
  wire [63:0] pc_next = redirect_valid_q ? {redirect_pc_q[63:1], 1'b0} : 64'(signed'((predict_taken ? predict_target : npc_word)));
  wire if_reason_e reason_next = redirect_valid_q ? redirect_reason_q : (predict_taken ? IF_PREDICT : IF_PREFETCH);

  always_ff @(posedge clk_i or negedge rst_ni) begin
    if (!rst_ni) begin
      pc <= 0;
      reason <= IF_PREFETCH;
    end
    else begin
      if (align_ready) begin
        pc <= pc_next;
        reason <= reason_next;
      end
    end
  end

  ///////////////////////
  // Branch Prediction //
  ///////////////////////

  wire [LogicSextAddrLen-1:0] branch_info_pc = branch_info_i.pc[LogicSextAddrLen-1:0];

  // For misaligned 4-byte instruction, since we can only make prediction once the entire 4 bytes are fetched,
  // we need to make sure to increment PC to next word.
  wire [LogicSextAddrLen-1:0] train_pc = branch_info_pc[1] && !branch_info_i.compressed ? branch_info_pc + 4 : branch_info_pc;

  // The branch prediction logic will need to predict whether the full word or only part of it will be used.
  // A word is partially used if a misaligned 4-byte instruction or a aligned 2-byte instruction triggers
  // a branch/jump.
  wire train_partial = branch_info_pc[1] ^ branch_info_i.compressed;

  logic                          btb_valid;
  branch_type_e                  btb_type;
  logic                          btb_partial;
  logic [LogicSextAddrLen-1:0] btb_target;

  muntjac_btb #(
    .AddrLen (LogicSextAddrLen),
    .IndexWidth (6)
  ) btb (
    .clk_i,
    .rst_ni,
    // Only train BTB for jump and taken branches, and only do so when mispredicted
    .train_valid_i        ((branch_info_i.branch_type[2] || branch_info_i.branch_type[0]) && redirect_valid_i),
    .train_branch_type_i  (branch_info_i.branch_type),
    .train_pc_i           (train_pc),
    .train_partial_i      (train_partial),
    .train_npc_i          (redirect_pc_i[LogicSextAddrLen-1:0]),
    .access_valid_i       (align_ready),
    .access_pc_i          (pc_next[LogicSextAddrLen-1:0]),
    .access_hit_o         (btb_valid),
    .access_branch_type_o (btb_type),
    .access_partial_o     (btb_partial),
    .access_npc_o         (btb_target)
  );

  logic bht_taken;

  muntjac_bp_bimodal #(
    .AddrLen (LogicSextAddrLen),
    .IndexWidth (9)
  ) bht (
    .clk_i,
    .rst_ni,
    // Only train BHT for branches.
    .train_valid_i  (branch_info_i.branch_type inside {BRANCH_UNTAKEN, BRANCH_TAKEN}),
    // LSB determines whether this is BRANCH_TAKEN or BRANCH_UNTAKEN
    .train_taken_i  (branch_info_i.branch_type[0]),
    .train_pc_i     (train_pc),
    .access_valid_i (align_ready),
    .access_pc_i    (pc_next[LogicSextAddrLen-1:0]),
    .access_taken_o (bht_taken)
  );

  logic [LogicSextAddrLen-1:0] ras_peek_addr;
  logic                          ras_peek_valid;

  // Compute RAS action
  wire ras_push = btb_valid && btb_type inside {BRANCH_CALL, BRANCH_YIELD};
  wire ras_pop  = btb_valid && btb_type inside {BRANCH_RET , BRANCH_YIELD};

  muntjac_ras #(
    .AddrLen (LogicSextAddrLen)
  ) ras (
    .clk_i,
    .rst_ni,
    .peek_valid_o (ras_peek_valid),
    .peek_addr_o  (ras_peek_addr),
    .pop_spec_i   (ras_pop && align_ready),
    .pop_i        (branch_info_i.branch_type inside {BRANCH_RET, BRANCH_YIELD}),
    .push_spec_i  (ras_push && align_ready),
    .push_i       (branch_info_i.branch_type inside {BRANCH_CALL, BRANCH_YIELD}),
    .push_addr_i  (btb_partial ? {pc[LogicSextAddrLen-1:2], 2'b10} : npc_word),
    .revert_i     (redirect_valid_q)
  );

  always_comb begin
    // Don't honor the BTB lookup if the current PC is from a redirection that targets a misaligned instruction.
    // Otherwise if we indeed predicted that this is a jump.
    // Also don't honor the result if we jumped to the second half while the prediction is for the first half.
    if (btb_valid && !(pc[1] && (reason ==? 4'b???1 || btb_partial))) begin
      predict_taken = btb_type[2] || bht_taken;
      if (ras_pop && ras_peek_valid) begin
        predict_target = ras_peek_addr;
      end else begin
        predict_target = btb_target;
      end
    end else begin
      predict_taken = 1'b0;
      predict_target = 'x;
    end
  end

  ///////////////
  // I$ Access //
  ///////////////

  assign icache_h2d_o.req_pc = pc_next;
  assign icache_h2d_o.req_reason = reason_next;
  assign icache_h2d_o.req_valid = align_ready;
  assign icache_h2d_o.req_sum = redirect_valid_q && align_ready ? redirect_sum_q : sum_latch;
  assign icache_h2d_o.req_atp = redirect_valid_q && align_ready ? redirect_atp_q : atp_latch;
  assign icache_h2d_o.req_prv = redirect_valid_q && align_ready ? redirect_prv_q : prv_latch;

  logic resp_latched;
  logic [31:0] resp_instr_latched;
  logic resp_exception_latched;
  exc_cause_e resp_ex_code_latched;

  wire align_valid = resp_latched ? 1'b1 : icache_d2h_i.resp_valid;
  wire [31:0] align_instr = resp_latched ? resp_instr_latched : icache_d2h_i.resp_instr;
  wire align_exception = resp_latched ? resp_exception_latched : icache_d2h_i.resp_exception;
  wire exc_cause_e align_ex_code = resp_latched ? resp_ex_code_latched : icache_d2h_i.resp_ex_code;
  wire [63:0] align_pc = pc;
  wire if_reason_e align_reason = reason;
  wire [1:0] align_strb = pc[1] ? 2'b10 : (predict_taken && btb_partial ? 2'b01 : 2'b11);

  always_ff @(posedge clk_i or negedge rst_ni)
    if (!rst_ni) begin
      resp_latched <= 1'b1;
      resp_instr_latched <= '0;
      resp_exception_latched <= 1'b0;
      resp_ex_code_latched <= exc_cause_e'('x);
    end
    else begin
      if (!align_ready && icache_d2h_i.resp_valid) begin
        assert (!resp_latched);
        resp_latched <= 1'b1;
        resp_instr_latched <= icache_d2h_i.resp_instr;
        resp_exception_latched <= icache_d2h_i.resp_exception;
        resp_ex_code_latched <= icache_d2h_i.resp_ex_code;
      end

      if (align_ready) begin
        resp_latched <= 1'b0;
      end
    end

  ///////////////////////////
  // Instruction Alignment //
  ///////////////////////////

  logic prev_valid_q, prev_valid_d;
  logic [63:0] prev_pc_q;
  if_reason_e prev_reason_q, prev_reason_d;
  logic [15:0] prev_instr_q;

  logic second_half_q, second_half_d;

  always_comb begin
    prev_valid_d = prev_valid_q;
    align_ready = 1'b0;
    second_half_d = second_half_q;
    prev_reason_d = IF_PREFETCH;

    fetch_valid_o = 1'b0;
    fetch_instr_o.instr_word = 'x;
    fetch_instr_o.pc = 'x;
    fetch_instr_o.if_reason = if_reason_e'('x);
    fetch_instr_o.ex_valid = 1'b0;
    fetch_instr_o.exception.cause = exc_cause_e'('x);
    fetch_instr_o.exception.tval = 'x;

    if (align_valid && align_exception) begin
      prev_valid_d = 1'b0;

      fetch_valid_o = 1'b1;
      fetch_instr_o.pc = prev_valid_q && align_reason ==? IF_PREFETCH ? prev_pc_q : align_pc;
      fetch_instr_o.if_reason = prev_valid_q && align_reason ==? IF_PREFETCH ? prev_reason_q : align_reason;
      fetch_instr_o.ex_valid = 1'b1;
      fetch_instr_o.exception.cause = align_ex_code;
      fetch_instr_o.exception.tval = align_pc;

      if (fetch_ready_i) align_ready = 1'b1;
    end else if (align_valid && align_strb == 2'b10 && align_instr[17:16] == 2'b11) begin
      // A redirection fetches unaligned 32-bit instruction. Keep the higher half,
      // discard the lower half, without waiting for the fetch_ready_i signal.
      prev_valid_d = 1'b1;
      second_half_d = 1'b0;
      prev_reason_d = align_reason;

      align_ready = 1'b1;
    end else if (align_valid) begin
      if (fetch_ready_i) begin
        prev_valid_d = 1'b0;
        second_half_d = 1'b0;
      end

      if (align_strb == 2'b10 || second_half_q) begin
        // Misaligned compressed instruction.
        fetch_valid_o = 1'b1;
        fetch_instr_o.pc = {align_pc[63:2], 2'b10};
        fetch_instr_o.if_reason = second_half_q ? IF_PREFETCH : align_reason;
        fetch_instr_o.instr_word = {16'd0, align_instr[31:16]};

        if (fetch_ready_i) align_ready = 1'b1;
      end else begin
        if (prev_valid_q && align_reason ==? IF_PREFETCH) begin
          // If there is a half word left (and we can use it), then this is the second half
          // of a misaligned 32-bit instruction.
          fetch_valid_o = 1'b1;
          fetch_instr_o.pc = prev_pc_q;
          fetch_instr_o.if_reason = prev_reason_q;
          fetch_instr_o.instr_word = {align_instr[15:0], prev_instr_q};

          // If the second half is also a 32-bit instruction, fetch the next word.
          if (fetch_ready_i) begin
            prev_valid_d = 1'b1;

            if (align_instr[17:16] == 2'b11 || align_strb == 2'b01) begin
              align_ready = 1'b1;
            end else begin
              second_half_d = 1'b1;
            end
          end
        end else begin
          if (align_instr[1:0] == 2'b11) begin
            // Full instruction, output it.
            fetch_valid_o = 1'b1;
            fetch_instr_o.pc = align_pc;
            fetch_instr_o.if_reason = align_reason;
            fetch_instr_o.instr_word = align_instr;

            if (fetch_ready_i) align_ready = 1'b1;
          end else begin
            // Compressed instruction, output it.
            fetch_valid_o = 1'b1;
            fetch_instr_o.pc = align_pc;
            fetch_instr_o.if_reason = align_reason;
            fetch_instr_o.instr_word = {16'd0, align_instr[15:0]};

            if (fetch_ready_i) begin
              prev_valid_d = 1'b1;

              if (align_instr[17:16] == 2'b11 || align_strb == 2'b01) begin
                // The second half is not compressed instruction, fetch next word
                align_ready = 1'b1;
              end else begin
                second_half_d = 1'b1;
              end
            end
          end
        end
      end
    end
  end

  always_ff @(posedge clk_i or negedge rst_ni) begin
    if (!rst_ni) begin
      prev_valid_q <= 1'b0;
      second_half_q <= 1'b0;
      prev_instr_q <= 'x;
      prev_reason_q <= if_reason_e'('x);
      prev_pc_q <= 'x;
    end else begin
      prev_valid_q <= prev_valid_d;
      second_half_q <= second_half_d;
      if (align_ready) begin
        prev_instr_q <= align_instr[31:16];
        prev_pc_q <= {align_pc[63:2], 2'b10};
        prev_reason_q <= prev_reason_d;
      end
    end
  end

endmodule
