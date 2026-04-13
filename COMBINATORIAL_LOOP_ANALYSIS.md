# Combinatorial Loop Analysis

## 1. Plausibility of the Bug Report

The bug report at https://github.com/lowRISC/muntjac/issues/4 identifies a zero-delay combinatorial loop between the backend and the cache. It details two halves of the loop:
1. `muntjac_backend.sv` (Cache Ready blocks Request Valid): `dcache_h2d_o.req_valid` is gated by `ex_issue`, which is blocked by `struct_hazard`. `struct_hazard` is asserted if `!mem_ready` (which is wired to `dcache_d2h_i.req_ready`). This means the valid signal is combinationally waiting for the cache to be ready.
2. `muntjac_dcache.sv` / `muntjac_icache.sv` (Request Valid drives Cache Ready): The cache's `req_ready` signal combinationally depends on `req_valid`. The incoming `req_valid` feeds into internal requests (like `mem_a_valid_mult`), which feed into the `openip_round_robin_arbiter`. The arbiter's `grant` output drives `mem_a_select` and ultimately `mem_a_ready_mult`, which is part of the combinational path driving the cache's output `req_ready`.

**Conclusion:** The bug report is entirely plausible and correct. Because event-driven simulators like Vivado XSIM evaluate all combinational logic in a delta cycle, this circular dependency (valid waiting for ready, ready waiting for valid) causes an infinite evaluation loop without advancing simulation time, leading to the fatal iteration limit error.

## 2. Other Modules with Potential Combinatorial Loops

Scanning the codebase for ready/valid handshakes where `ready` depends combinationally on `valid` (which forms half of a loop and could cause similar simulation hangs if connected to a component that makes `valid` depend on `ready`):

1. **`ip/tl/rtl/tl_broadcast.sv`**
   - `host_a_ready` combinationally depends on `device_req_ready_mult[1]`.
   - `device_req_ready_mult[1]` depends on `device_req_select`.
   - `device_req_select` comes from the arbiter `grant`, which is generated from the `request` signal (`host_a_valid`).
   - Thus, `ready` depends on `valid` through the arbiter.

2. **`ip/tl/rtl/tl_socket_1n.sv`**
   - `host_a_ready` depends on `|req_ready_mult`.
   - `req_ready_mult[i]` combinationally uses `host_a_valid` (`assign req_ready_mult[i] = host_a_valid && ... && device_a_ready[i]`).

3. **`ip/tl/rtl/tl_socket_m1.sv`**
   - `host_a_ready[i]` depends on `req_select[i]`.
   - `req_select` comes from `req_arb_grant`, which depends on `host_a_valid`.
   - Thus, `ready` depends on `valid` through the arbiter.

4. **`ip/core/rtl/muntjac_llc.sv`**
   - `wb_req_ready_mult` logic is multiplexed based on `wb_req_valid_mult`.
   - This means `wb_req_ready_mult` (and signals like `device_b_ready`) combinationally depend on `wb_req_valid_mult`.
