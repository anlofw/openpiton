// ============================================================================
//  maw_ctrl.v  --  Memory Access Window controller (per tile)
//
//  Part of the MAW port to OpenPiton + S3K.
//
//  A pure schedule engine placed at tile level, a sibling of the DMBR
//  bandwidth regulator (piton/design/chip/tile/dmbr).  It holds a periodic,
//  per-destination access schedule and exports, every cycle, the allowed-
//  destination mask for the current slot.  The actual single-bit injection
//  gate lives on the NoC1 request path in l15/rtl/noc1encoder.v, where the
//  request's home id is available.
//
//  Design notes:
//    * Slot timebase is a cycle counter advanced by slot_dur (tau). A global
//      epoch pulse (maw_epoch), driven from S3K's time-synchronised major
//      frame, resets the phase so every tile agrees on slot 0.
//    * Reconfiguration is glitch-free via shadow-and-commit: software writes
//      the shadow schedule, then pulses commit; the swap happens at the next
//      slot boundary so no partially written schedule is ever enforced.
//    * cur_slot_mask is the active schedule row for the current slot. It is
//      combinational off slot_idx; noc1encoder indexes it by the request's
//      home slice.
//    * t_remain is a deterministic lower bound on how long the selected slice
//      stays open. The k*tau multiply here is a first-cut; it
//      can be replaced by an accumulating countdown for silicon.  [TODO]
// ============================================================================
`include "maw_define.vh"

module maw_ctrl (
    input  wire                              clk,
    input  wire                              rst_n,

    // Global major-frame epoch: single-cycle pulse that resets schedule phase.
    // Tie to the tile's synchronised frame boundary (S3K keeps per-hart major
    // frames time-aligned).  If left 0, the schedule free-runs from reset.
    input  wire                              maw_epoch,

    // ---- Configuration (from tile config_regs) ----------------------------
    input  wire                              cfg_func_en,     // enable gating
    input  wire [`MAW_SLOT_DUR_WIDTH-1:0]    cfg_slot_dur,    // tau, in cycles (>=1)
    input  wire                              cfg_sched_wr,    // pulse: write one shadow row
    input  wire [`MAW_SLOT_IDX_WIDTH-1:0]    cfg_sched_slot,  // which slot row
    input  wire [`MAW_NUM_SLICES-1:0]        cfg_sched_mask,  // allowed-dest mask for that slot
    input  wire                              cfg_commit,      // pulse: swap shadow -> active
    input  wire [`MAW_SLICE_IDX_WIDTH-1:0]   cfg_status_sel,  // slice for t_remain read

    // ---- Outputs to the injection path (l15 -> noc1encoder) ---------------
    output wire                              func_en_out,     // registered enable
    output wire [`MAW_NUM_SLICES-1:0]        cur_slot_mask,   // active row for current slot

    // ---- Status (to config_regs read-back) --------------------------------
    output wire [`MAW_SLOT_IDX_WIDTH-1:0]    cur_slot,
    output reg  [`MAW_TREMAIN_WIDTH-1:0]     t_remain
);

    localparam SLOT_MAX = `MAW_NUM_SLOTS - 1;

    // ---- Schedule storage: active (enforced) and shadow (being written) ----
    reg [`MAW_NUM_SLICES-1:0] active_sched [0:`MAW_NUM_SLOTS-1];
    reg [`MAW_NUM_SLICES-1:0] shadow_sched [0:`MAW_NUM_SLOTS-1];

    // ---- Phase counters ----------------------------------------------------
    reg [`MAW_SLOT_DUR_WIDTH-1:0] cycle_cnt;   // 0 .. tau-1 within current slot
    reg [`MAW_SLOT_IDX_WIDTH-1:0] slot_idx;    // current slot
    reg                           commit_pend; // commit requested, apply at boundary
    reg                           func_en_r;

    integer i;

    // A slot boundary occurs when the in-slot cycle counter reaches tau-1.
    wire slot_boundary = (cycle_cnt >= (cfg_slot_dur - 1'b1));

    assign cur_slot     = slot_idx;
    assign cur_slot_mask = active_sched[slot_idx];
    assign func_en_out  = func_en_r;

    // ---- Shadow write + commit latch --------------------------------------
    always @(posedge clk) begin
        if (!rst_n) begin
            commit_pend <= 1'b0;
            func_en_r   <= 1'b0;
            for (i = 0; i < `MAW_NUM_SLOTS; i = i + 1) begin
                active_sched[i] <= {`MAW_NUM_SLICES{1'b1}}; // reset: all open (transparent)
                shadow_sched[i] <= {`MAW_NUM_SLICES{1'b1}};
            end
        end else begin
            func_en_r <= cfg_func_en;

            // Software programs the shadow copy one slot row at a time.
            if (cfg_sched_wr)
                shadow_sched[cfg_sched_slot] <= cfg_sched_mask;

            // Register a pending commit; it takes effect at the next boundary.
            if (cfg_commit)
                commit_pend <= 1'b1;

            if (slot_boundary && (slot_idx == SLOT_MAX) && commit_pend) begin
                for (i = 0; i < `MAW_NUM_SLOTS; i = i + 1)
                    active_sched[i] <= shadow_sched[i];
                commit_pend <= 1'b0;
            end
        end
    end

    // ---- Slot / cycle phase advance ---------------------------------------
    always @(posedge clk) begin
        if (!rst_n) begin
            cycle_cnt <= {`MAW_SLOT_DUR_WIDTH{1'b0}};
            slot_idx  <= {`MAW_SLOT_IDX_WIDTH{1'b0}};
        end else if (maw_epoch) begin
            // Re-align phase to the global major frame.
            cycle_cnt <= {`MAW_SLOT_DUR_WIDTH{1'b0}};
            slot_idx  <= {`MAW_SLOT_IDX_WIDTH{1'b0}};
        end else if (slot_boundary) begin
            cycle_cnt <= {`MAW_SLOT_DUR_WIDTH{1'b0}};
            slot_idx  <= (slot_idx == SLOT_MAX) ? {`MAW_SLOT_IDX_WIDTH{1'b0}}
                                                : (slot_idx + 1'b1);
        end else begin
            cycle_cnt <= cycle_cnt + 1'b1;
        end
    end

    // ---- Window counter T_remain for the selected slice --------------------
    // Count consecutive enabled slots ahead (including current) for the
    // selected destination, then subtract time already elapsed in this slot.
    // NUM_SLOTS is a power of two, so the wrap is a bit-mask, not a modulo.
    reg [`MAW_SLOT_IDX_WIDTH:0]   k;
    reg                           run_done;
    reg [`MAW_SLOT_IDX_WIDTH-1:0] scan_idx;
    integer s;
    always @* begin
        k        = 0;
        run_done = 1'b0;
        for (s = 0; s < `MAW_NUM_SLOTS; s = s + 1) begin
            scan_idx = (slot_idx + s[`MAW_SLOT_IDX_WIDTH-1:0]) & SLOT_MAX[`MAW_SLOT_IDX_WIDTH-1:0];
            if (!run_done) begin
                if (active_sched[scan_idx][cfg_status_sel])
                    k = k + 1'b1;
                else
                    run_done = 1'b1;
            end
        end
        // t_remain = k*tau - elapsed.  Multiply is a draft convenience. [TODO]
        if (k == 0)
            t_remain = {`MAW_TREMAIN_WIDTH{1'b0}};
        else
            t_remain = (k * cfg_slot_dur) - cycle_cnt;
    end

endmodule
