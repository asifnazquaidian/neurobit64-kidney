/*
 * NeuroBit64-Kidney : 1000 nephron units with alpha-1 and beta-1 adrenergic neurons on one
 * time-shared circuit. Variant of NeuroBit64-S for the kidney.
 * Copyright (c) 2026 Asif Mehmood.  SPDX-License-Identifier: Apache-2.0
 *
 * Cell model: Hybrid Excitable Cell model (A. Mehmood, PhD thesis, UET Taxila 2025, chapter 3,
 * regular-spiking constants), forward Euler, 1 ms per tick. Its use for the nephron is an
 * extension proposed in the thesis chapter "Conclusion and Future Directions"; it has not been
 * compared with kidney recordings.
 *   v' = v + k (v - Vr)(v - Vt) / C - u / C + I          u' = u + a (b (v - Vr) - u)
 *   spike (one quantum of filtrate) when v >= Vt + F:  v = c, u = u + d, F = F + 40 mV
 *   F decays with 128 ms: the threshold elevation F plays the part of tubuloglomerular feedback
 *   I = perfusion pressure * 10/64 + renin field / 128 - 3 mV for every spike of the alpha-1 neuron
 * Renin field: goes up by (16 - spikes of all nephrons) every tick, i.e. it rises while total
 * filtration is below the set point of 16 spikes per tick and so drives the working nephrons
 * harder. A second, decaying part is added by the spikes of the beta-1 neurons.
 * The alpha-1 neuron of a unit integrates the sympathetic signal, the beta-1 neuron the
 * sympathetic signal plus a low-pressure term (NeuroBit64 leaky integrate-and-fire rule).
 *
 * Timing: one unit per slot of 8 clocks, N slots per tick; N = 1000 at 8 MHz is real time.
 * State:  55 bits per unit {n2[6:0], n1[6:0], act, tr[11:0], u[15:0], v[11:0]}
 *         v 1/16 mV, u 1/32 mV, tr = F in 1/16 mV, act = filtered at least once in this epoch
 *
 * cond[2:0]  0 healthy  1, 2, 3 = 25 %, 50 %, 75 % of the nephrons do not work
 *            4 perfusion pressure 60 mmHg  5 160 mmHg  6 high sympathetic tone
 *            7 healthy, pressure sweep 60..187 mmHg (16.4 s)
 * uart_rx    50 lo hi  = use this perfusion pressure (mmHg); FFFF = built-in value
 * Report (16 bytes, every 16 ticks): seq, 0x30|link<<3|cond, flags, mean v (mV), filtration
 *   spikes, alpha-1 spikes, beta-1 spikes, working nephrons of the last 256-tick epoch, total
 *   filtration in % of the set point, pressure (mmHg), renin level, brain drive.
 *   Flags: 0 nephrons missing 1 filtration per working nephron above 125 % 2 total filtration
 *   below 60 % 3 renin high 4 strong sympathetic drive 5 pressure above 140 mmHg
 *   6 early pattern (0 and 1 without 2)  7 any of them.
 * Bit-exact software model: design/model/nb64_kidney_model.js
 */

`default_nettype none

module nb64_kidney #(
    parameter N = 1000
) (
    input  wire       clk,
    input  wire       rst_n,
    input  wire [2:0] cond,
    input  wire       link_en,
    input  wire       adv_en,
    input  wire       nb_sdo,
    input  wire       nb_sync,
    input  wire       uart_rx,
    output wire       nb_sdi,
    output reg        sdo,        // raster: one filtration bit per nephron per tick
    output reg        sck,
    output reg        sync,
    output wire       uart_tx,
    output wire       bb_data,
    output wire       bb_en,
    output wire       pll_en,
    output wire [1:0] rf_ch
);
    localparam SW = 55;
    localparam [9:0] NM1 = N - 1;

    // ---------------------------------------------------------------- condition table
    wire [3:0] c_loss = (cond == 3'd1) ? 4'd4 : (cond == 3'd2) ? 4'd8 : (cond == 3'd3) ? 4'd12 : 4'd0;
    wire [7:0] c_p    = (cond == 3'd4) ? 8'd60 : (cond == 3'd5) ? 8'd160 : (cond == 3'd7) ? 8'd0 : 8'd100;
    wire [4:0] c_symp = (cond == 3'd6) ? 5'd12 : 5'd0;

    // ---------------------------------------------------------------- pressure command on uart_rx
    reg  [2:0]  rxs;
    reg  [6:0]  rxdiv;
    reg  [3:0]  rxbit;
    reg         rxbusy, rxstb;
    reg  [7:0]  rxsh, clo;
    reg  [1:0]  cst;
    reg  [13:0] cidle;                          // 2 ms without a byte puts the parser back to idle
    reg         px_v;                           // an external pressure value has been written
    reg  [7:0]  px;
    wire [15:0] cval = {rxsh, clo};
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            rxs <= 3'b111; rxdiv <= 7'd0; rxbit <= 4'd0; rxbusy <= 1'b0; rxsh <= 8'd0; rxstb <= 1'b0;
            cst <= 2'd0; clo <= 8'd0; cidle <= 14'd0; px_v <= 1'b0; px <= 8'd0;
        end else begin
            rxs   <= {rxs[1:0], uart_rx};
            rxstb <= 1'b0;
            if (!rxbusy) begin
                if (!rxs[2]) begin rxbusy <= 1'b1; rxdiv <= 7'd34; rxbit <= 4'd0; end
            end else if (rxdiv != 7'd0) begin
                rxdiv <= rxdiv - 7'd1;
            end else begin
                rxdiv <= 7'd68;
                rxbit <= rxbit + 4'd1;
                if (rxbit == 4'd0) begin
                    if (rxs[2]) rxbusy <= 1'b0;
                end else if (rxbit <= 4'd8) begin
                    rxsh <= {rxs[2], rxsh[7:1]};
                end else begin
                    rxbusy <= 1'b0;
                    rxstb  <= rxs[2];
                end
            end
            if (rxstb) begin
                cidle <= 14'd0;
                case (cst)
                    2'd0: cst <= (rxsh == 8'h50) ? 2'd1 : 2'd0;
                    2'd1: begin clo <= rxsh; cst <= 2'd2; end
                    default: begin
                        px_v <= (cval != 16'hFFFF);
                        px   <= (cval > 16'd255) ? 8'd255 : cval[7:0];
                        cst  <= 2'd0;
                    end
                endcase
            end else if (cst != 2'd0) begin
                cidle <= cidle + 14'd1;
                if (&cidle) cst <= 2'd0;
            end
        end
    end



    // ---------------------------------------------------------------- sequencer
    reg  [2:0]      b;
    reg  [9:0]      ci;
    reg  [15:0]     t;
    reg  [31:0]     x32;
    reg  [N*SW-1:0] vm;
    reg  [10:0]     gacc;
    reg  [4:0]      g;
    reg  [5:0]      gup;
    reg             valid;
    reg             pr_v;                       // pressure source of this tick, taken at the tick boundary
    reg  [7:0]      pr_x;
    wire            last  = (b == 3'd7);
    wire            tlast = last && (ci == NM1);
    wire            elast = (t[7:0] == 8'd255); // last tick of a 256-tick epoch

    wire [31:0] x1 = x32 ^ (x32 << 13);
    wire [31:0] x2 = x1 ^ (x1 >> 17);
    wire [31:0] x3 = x2 ^ (x2 << 5);

    // ---------------------------------------------------------------- brain link
    wire [7:0] aff_rd;
    wire [9:0] sym, par, sym_now, par_now;
    wire       gend;
    wire [7:0] aff_wd;
    nb64_link link (
        .clk(clk), .rst_n(rst_n), .nb_sdo(nb_sdo), .nb_sync(nb_sync), .nb_sdi(nb_sdi),
        .aff_we(last && gend), .aff_wa(g), .aff_wd(aff_wd), .aff_ra(g), .aff_rd(aff_rd),
        .tick_end(tlast), .sym_now(sym_now), .par_now(par_now), .sym(sym), .par(par)
    );

    // ---------------------------------------------------------------- values that hold for one tick
    reg  [11:0] renin, rsym;
    wire [13:0] ph   = t[13:0];
    wire [6:0]  trw  = ph[13] ? ~ph[12:6] : ph[12:6];                    // slow triangle, 16.4 s
    wire [7:0]  pr   = pr_v ? pr_x : (c_p != 8'd0) ? c_p : (8'd60 + {1'b0, trw});
    wire [6:0]  sds  = {2'b00, c_symp} + (link_en ? {1'b0, sym[9:4]} : 7'd0);
    wire [4:0]  sd   = (sds > 7'd31) ? 5'd31 : sds[4:0];
    wire [7:0]  plo  = (pr < 8'd80) ? (8'd80 - pr) : 8'd0;
    wire [6:0]  sbs  = {2'b00, sd} + {1'b0, plo[7:2]};
    wire [4:0]  sdb  = (sbs > 7'd31) ? 5'd31 : sbs[4:0];
    wire [11:0] pr10 = {1'b0, pr, 3'b000} + {3'b000, pr, 1'b0};          // 10 * pressure
    wire [6:0]  drv  = {1'b0, pr10[11:6]} + {2'b00, renin[11:7]};

    // ---------------------------------------------------------------- one nephron unit
    wire signed [11:0] v   = vm[11:0];
    wire signed [15:0] u   = vm[27:12];
    wire        [11:0] tr  = vm[39:28];
    wire               act = vm[40];
    wire        [6:0]  n1  = vm[47:41];
    wire        [6:0]  n2  = vm[54:48];

    wire [3:0] r    = {ci[0], ci[1], ci[2], ci[3]} ^ ci[7:4] ^ {2'b00, ci[9:8]};
    wire       dead = (r < c_loss);
    wire signed [4:0] nz = $signed({1'b0, x32[31:28]}) - $signed({1'b0, x32[27:24]});

    wire signed [12:0] x   = v + 13'sd960;
    wire signed [12:0] y   = x - 13'sd320;
    wire signed [25:0] p   = x * y;
    wire signed [35:0] qf  = p * 36'sd229 + 36'sd262144;
    wire signed [16:0] q   = qf >>> 19;                                   // k/C (v - Vr)(v - Vt)
    wire signed [23:0] tuf = u * 24'sd41 + 24'sd4096;
    wire signed [10:0] tu  = tuf >>> 13;                                  // u / C
    wire signed [13:0] thr = -14'sd640 + $signed({2'b00, tr});
    wire               fire = !dead && ($signed({{2{v[11]}}, v}) >= thr);

    wire [7:0] n1s = {1'b0, n1} - {3'b000, n1[6:2]} + {3'b000, sd};       // alpha-1 neuron
    wire [7:0] n2s = {1'b0, n2} - {3'b000, n2[6:2]} + {3'b000, sdb};      // beta-1 neuron
    wire       s1  = (n1s >= 8'd32);
    wire       s2  = (n2s >= 8'd32);

    wire signed [8:0]  din  = dead ? 9'sd0 : ($signed({2'b00, drv}) - (s1 ? 9'sd48 : 9'sd0));
    wire signed [18:0] vsum = v + q - tu + din + nz;
    wire signed [11:0] vn   = (vsum > 19'sd2047) ? 12'sd2047 : (vsum < -19'sd2048) ? -12'sd2048 : vsum[11:0];
    wire signed [17:0] tt   = -(18'sd4 * x) - u;                          // b (v - Vr) - u
    wire signed [27:0] duf  = tt * 28'sd123 + 28'sd2048;
    wire signed [19:0] us   = u + (duf >>> 12);
    wire signed [15:0] un   = (us > 20'sd32767) ? 16'sd32767 : (us < -20'sd32768) ? -16'sd32768 : us[15:0];
    wire signed [17:0] ud   = u + 18'sd3200;                              // u + d
    wire signed [15:0] uf   = (ud > 18'sd32767) ? 16'sd32767 : ud[15:0];
    wire        [12:0] tru  = {1'b0, tr} + 13'd640;                       // feedback step
    wire        [12:0] trr  = {1'b0, tr} + 13'd127;
    wire        [11:0] trd  = tr - {6'd0, trr[12:7]};
    wire               wasact = act | fire;

    wire [11:0] v_nx  = fire ? -12'sd800 : vn;
    wire [15:0] u_nx  = fire ? uf : un;
    wire [11:0] tr_nx = fire ? (tru[12] ? 12'd4095 : tru[11:0]) : trd;
    wire        act_nx = elast ? 1'b0 : wasact;
    wire [6:0]  n1_nx = s1 ? 7'd0 : n1s[6:0];
    wire [6:0]  n2_nx = s2 ? 7'd0 : n2s[6:0];

    // ---------------------------------------------------------------- groups (activity for the brain)
    wire [10:0] gsum  = gacc + 11'd32;
    assign      gend  = (gsum >= N);
    wire [6:0]  gupn  = {1'b0, gup} + {6'd0, fire};
    wire [9:0]  affs  = {2'b00, aff_rd} - {4'b0000, aff_rd[7:2]} + {1'b0, gupn[5:0], 3'b000};
    assign      aff_wd = (|affs[9:8]) ? 8'd255 : affs[7:0];

    // ---------------------------------------------------------------- per-tick totals
    reg  [9:0]  nf, na, nb, nact;
    reg  signed [22:0] vacc;
    wire [9:0]  nf_t = nf + {9'd0, fire};
    wire [9:0]  na_t = na + {9'd0, s1};
    wire [9:0]  nb_t = nb + {9'd0, s2};
    wire [9:0]  nact_t = nact + {9'd0, wasact};
    wire signed [22:0] vacc_t = vacc + $signed(v_nx);

    // ---------------------------------------------------------------- renin, epoch measurements, flags
    reg  [15:0] etot, rate;
    reg  [9:0]  active;
    reg  [7:0]  gfr;
    reg  [1:0]  epochs;
    reg  [7:0]  seq;
    reg  [15:0] wf, wa, wb;

    wire signed [13:0] ren_s = $signed({2'b00, renin}) + 14'sd16 - $signed({4'b0000, nf_t});
    wire [11:0] renin_n = ren_s[13] ? 12'd0 : ren_s[12] ? 12'd4095 : ren_s[11:0];
    wire [13:0] rsy_s   = {2'b00, rsym} - {8'd0, rsym[11:6]} + {6'd0, nb_t[9:2]};
    wire [11:0] rsym_n  = (|rsy_s[13:12]) ? 12'd4095 : rsy_s[11:0];
    wire [12:0] rlv_s   = {1'b0, renin_n} + {1'b0, rsym_n};
    wire [11:0] rlev_n  = rlv_s[12] ? 12'd4095 : rlv_s[11:0];

    wire [16:0] et_s    = {1'b0, etot} + {7'd0, nf_t};
    wire [15:0] etot_n  = et_s[16] ? 16'hFFFF : et_s[15:0];
    wire [20:0] gfr_m   = etot_n * 21'd25;
    wire [7:0]  gfr_c   = (|gfr_m[20:18]) ? 8'd255 : gfr_m[17:10];
    wire [9:0]  active_n = elast ? nact_t : active;
    wire [7:0]  gfr_n    = elast ? gfr_c : gfr;
    wire [15:0] rate_n   = elast ? etot_n : rate;
    wire [1:0]  epochs_n = (elast && epochs != 2'd3) ? epochs + 2'd1 : epochs;
    wire        ok       = (epochs_n >= 2'd2);
    wire [26:0] lhs      = rate_n * N;
    wire [26:0] rhs      = active_n * 27'd5120;
    wire [7:0]  flags_n;
    assign flags_n[0] = ok && (active_n < N - (N >> 3));
    assign flags_n[1] = ok && (lhs > rhs);
    assign flags_n[2] = ok && (gfr_n < 8'd60);
    assign flags_n[3] = (rlev_n > 12'd2048);
    assign flags_n[4] = (sd >= 5'd8);
    assign flags_n[5] = (pr > 8'd140);
    assign flags_n[6] = flags_n[0] && flags_n[1] && !flags_n[2];
    assign flags_n[7] = |flags_n[6:0];

    // ---------------------------------------------------------------- report
    wire [16:0] wf_s = {1'b0, wf} + {7'd0, nf_t};
    wire [16:0] wa_s = {1'b0, wa} + {7'd0, na_t};
    wire [16:0] wb_s = {1'b0, wb} + {7'd0, nb_t};
    wire [15:0] wf_n = wf_s[16] ? 16'hFFFF : wf_s[15:0];
    wire [15:0] wa_n = wa_s[16] ? 16'hFFFF : wa_s[15:0];
    wire [15:0] wb_n = wb_s[16] ? 16'hFFFF : wb_s[15:0];
    wire signed [8:0]  mvs  = vacc_t >>> 14;
    wire signed [10:0] dnow = $signed({1'b0, sym_now}) - $signed({1'b0, par_now});
    wire [7:0]  brb = !link_en ? 8'd0 : (dnow > 11'sd127) ? 8'd127 : (dnow < -11'sd128) ? 8'h80 : dnow[7:0];
    wire        wend = tlast && (t[3:0] == 4'd15);
    wire [127:0] payload = {brb, rlev_n[11:4], pr, gfr_n, 6'd0, active_n, wb_n, wa_n, wf_n,
                            mvs[7:0], flags_n, 4'h3, link_en, cond, seq};
    wire        tbusy;
    nb64_telemetry tele (
        .clk(clk), .rst_n(rst_n), .send(wend), .adv(adv_en && (seq[2:0] == 3'd7)), .organ(4'd3),
        .payload(payload), .uart_tx(uart_tx), .bb_data(bb_data), .bb_en(bb_en), .pll_en(pll_en),
        .rf_ch(rf_ch), .busy(tbusy)
    );

    // ---------------------------------------------------------------- registers
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            b <= 3'd0; ci <= 10'd0; t <= 16'd0; x32 <= 32'h1234_5678;
            vm <= {N{43'd0, 12'hC40}};                                    // every unit at rest, v = Vr
            gacc <= 11'd0; g <= 5'd0; gup <= 6'd0;
            valid <= 1'b0; sdo <= 1'b0; sck <= 1'b0; sync <= 1'b0; pr_v <= 1'b0; pr_x <= 8'd0;
            nf <= 10'd0; na <= 10'd0; nb <= 10'd0; nact <= 10'd0; vacc <= 23'sd0;
            renin <= 12'd0; rsym <= 12'd0; etot <= 16'd0; rate <= 16'd0; active <= 10'd0; gfr <= 8'd0;
            epochs <= 2'd0; seq <= 8'd0; wf <= 16'd0; wa <= 16'd0; wb <= 16'd0;
        end else begin
            b   <= b + 3'd1;
            sck <= valid && (b >= 3'd3) && (b <= 3'd6);
            if (last) begin
                sdo   <= fire;
                sync  <= (ci == 10'd0);
                valid <= 1'b1;
                x32   <= x3;
                vm    <= {n2_nx, n1_nx, act_nx, tr_nx, u_nx, v_nx, vm[N*SW-1:SW]};
                ci    <= (ci == NM1) ? 10'd0 : ci + 10'd1;
                if (gend) begin gacc <= gsum - N; g <= g + 5'd1; gup <= 6'd0; end
                else begin gacc <= gsum; gup <= gupn[5:0]; end
                if (ci == NM1) begin
                    t    <= t + 16'd1;
                    pr_v <= px_v; pr_x <= px;
                    nf <= 10'd0; na <= 10'd0; nb <= 10'd0; nact <= 10'd0; vacc <= 23'sd0;
                    renin <= renin_n; rsym <= rsym_n;
                    etot <= elast ? 16'd0 : etot_n; rate <= rate_n; active <= active_n; gfr <= gfr_n;
                    epochs <= epochs_n;
                    if (t[3:0] == 4'd15) begin seq <= seq + 8'd1; wf <= 16'd0; wa <= 16'd0; wb <= 16'd0; end
                    else begin wf <= wf_n; wa <= wa_n; wb <= wb_n; end
                end else begin
                    nf <= nf_t; na <= na_t; nb <= nb_t; nact <= nact_t; vacc <= vacc_t;
                end
            end
        end
    end

    wire _unused = &{tbusy, sym[3:0], par, sym_now[3:0], 1'b0};
endmodule