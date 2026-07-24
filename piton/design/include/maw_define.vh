// ============================================================================
//  maw_define.vh  --  Memory Access Window (MAW) controller parameters
//
//  Part of the MAW port to OpenPiton + S3K.
//  Defines the compile-time geometry of the per-tile MAW schedule and the
//  config-register bit fields used to program it.
// ============================================================================
`ifndef MAW_DEFINE_VH
`define MAW_DEFINE_VH

`include "define.tmp.h"

// ---- Build switch ----------------------------------------------------------
// MAW logic is compiled in by default. For a BASELINE bitstream (to measure
// MAW hardware overhead as a diff), synthesize with +define+MAW_DISABLE, which
// leaves out all MAW logic (the gate, maw_ctrl, and the L2 MAW registers);
// module ports remain but are driven with constants and optimize away.
`ifndef MAW_DISABLE
`define MAW_EN
`endif

// ---- Schedule geometry -----------------------------------------------------
// Number of slots L in the circular schedule (period P = L * tau).
`define MAW_NUM_SLOTS        64
`define MAW_SLOT_IDX_WIDTH   $clog2(`MAW_NUM_SLOTS)

// Number of destination home slices N gated per slot (one mask bit each).
// Keep N small enough that one slot's mask fits in a single 64-bit config
// word alongside the slot index (see CFG_MAW_SCHED_* below).
`define MAW_NUM_SLICES       `PITON_NUM_TILES
`define MAW_SLICE_IDX_WIDTH  $clog2(`PITON_NUM_TILES)

// Slot duration tau, in core cycles.  Aligned by software to an integer
// multiple of S3K's time-slot tick so the schedule shares the major frame.
`define MAW_SLOT_DUR_WIDTH   18                 // up to ~262143 cycles per slot
`define MAW_TREMAIN_WIDTH    32                 // exported window counter (cycles)

// ---- Config register indices (extend define.h.pyv CONFIG_REG_* space) ------
// DMBR already uses reg indices 8'd2 and 8'd5; home-alloc uses 8'd6.
`define CONFIG_REG_MAW_CTRL    8'd7             // control / params / status
`define CONFIG_REG_MAW_SCHED   8'd8             // shadow schedule write (one slot row)

// ---- CONFIG_REG_MAW_CTRL bit fields (write) --------------------------------
`define CFG_MAW_FUNC_EN_BIT        0                       // 1 = gating active
`define CFG_MAW_COMMIT_BIT         1                       // pulse: shadow -> active
`define CFG_MAW_SLOT_DUR_BITS     (2 + `MAW_SLOT_DUR_WIDTH - 1) : 2      // tau
// Gate machine mode too? 0 (default/reset) = bypass on (kernel/M-mode never
// gated, required for S3K); 1 = also gate M-mode (for bare-metal experiments
// with no OS/interrupts that want to observe gating in machine mode).
`define CFG_MAW_MMODE_GATE_BIT     20
`define CFG_MAW_STATUS_SEL_BITS   (24 + `MAW_SLICE_IDX_WIDTH - 1) : 24   // slice for T_remain read

// ---- CONFIG_REG_MAW_CTRL fields (read-back / status) -----------------------
// read_data returns { cur_slot, T_remain } for the selected slice.
`define CFG_MAW_RD_TREMAIN_BITS   (`MAW_TREMAIN_WIDTH - 1) : 0
`define CFG_MAW_RD_CURSLOT_BITS   (32 + `MAW_SLOT_IDX_WIDTH - 1) : 32

// ---- CONFIG_REG_MAW_SCHED bit fields (write one slot's mask into shadow) ---
`define CFG_MAW_SCHED_SLOT_BITS   (`MAW_SLOT_IDX_WIDTH - 1) : 0
`define CFG_MAW_SCHED_MASK_BITS   (8 + `MAW_NUM_SLICES - 1) : 8

`endif // MAW_DEFINE_VH
