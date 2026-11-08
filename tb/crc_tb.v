// ============================================================
//  crc_tb.v  -  self-checking testbench for crc16_checker
//  Plain Verilog-2001 (no SystemVerilog, no 'automatic').
//
//  Checks per packet: busy after start, done pulse, busy low,
//  crc_result vs reference, match, done is 1 cycle only, and
//  crc_result/match HOLD until the next packet completes.
//
//  Tests
//   T0  reset sanity
//   T1  hard-coded known answers (reference model self-check)
//   T2  1-bit packets (bit=0, bit=1)
//   T3  lengths 1..40, random data, no stalls
//   T4  lengths 1..40, random stalls + junk on stall/start cycles
//       (includes last_bit=1 while bit_valid=0 -> must be ignored)
//   T5  long packets (64, 72, 128, 256 bits) with stalls
//   T6  wrong expected_crc: every single-bit flip + all-bits flip
//   T7  idle noise: bit_valid/last_bit/data toggling while idle
//   T8  start pulse while busy must be ignored
//   T9  back-to-back packets (start the cycle after done)
//   T10 all-zeros / all-ones payloads
//   T11 reset during packet (incl. reset on the last-bit cycle),
//       then a fresh packet must still be correct
// ============================================================
`timescale 1ns/1ps
 
module crc16_tb;
 
    // ---------------- clock / DUT signals --------------------
    reg         clk;
    reg         rst_n;
    reg         start;
    reg         bit_valid;
    reg         data_bit;
    reg         last_bit;
    reg  [15:0] expected_crc;
    wire        busy;
    wire [15:0] crc_result;
    wire        match;
    wire        done;
 
    crc16_checker dut (
        .clk         (clk),
        .rst_n       (rst_n),
        .start       (start),
        .bit_valid   (bit_valid),
        .data_bit    (data_bit),
        .last_bit    (last_bit),
        .expected_crc(expected_crc),
        .busy        (busy),
        .crc_result  (crc_result),
        .match       (match),
        .done        (done)
    );
 
    initial clk = 1'b0;
    always #5 clk = ~clk;                 // 100 MHz
 
    // ---------------- 32-bit Galois LFSR ----------------------
    function [31:0] lfsr_next;
        input [31:0] x;
    begin
        lfsr_next = {x[30:0], 1'b0} ^ ({32{x[31]}} & 32'hB400_0000);
    end
    endfunction
 
    // ---------------- shared state ----------------------------
    integer     err_cnt;
    integer     pkt_cnt;
    integer     idx;
    integer     idx2;
    reg [31:0]  lfsr;
    reg [255:0] pkt;
    reg [15:0]  rcrc;                     // reference CRC of last packet
    reg [15:0]  prev_res;                 // what crc_result must hold
    reg         prev_match;               // what match must hold
    reg [15:0]  ref_crc;
    reg         ref_fb;
    reg         sp_stall;
 
    // ---------------- reference model -------------------------
    // bit_stream[255] is the first transmitted bit.
    // init FFFF, poly 1021, MSB first, no reflect, no final XOR.
    task ref_compute;
        input  [255:0] bit_stream;
        input  [31:0]  num_bits;
        output [15:0]  crc_out;
        integer        k;
    begin
        ref_crc = 16'hFFFF;
        for (k = 0; k < num_bits; k = k + 1) begin
            ref_fb  = ref_crc[15] ^ bit_stream[255 - k];
            ref_crc = {ref_crc[14:0], 1'b0};
            if (ref_fb) ref_crc = ref_crc ^ 16'h1021;
        end
        crc_out = ref_crc;
    end
    endtask
 
    // ---------------- random packet ---------------------------
    task gen_pkt;
        integer w;
    begin
        for (w = 0; w < 8; w = w + 1) begin
            lfsr = lfsr_next(lfsr);
            pkt  = {pkt[223:0], lfsr};
        end
    end
    endtask
 
    // ---------------- reset helper ----------------------------
    task apply_reset;
        input [31:0] n;
        integer k;
    begin
        rst_n        = 1'b0;
        start        = 1'b0;
        bit_valid    = 1'b0;
        data_bit     = 1'b0;
        last_bit     = 1'b0;
        expected_crc = 16'h0000;
        for (k = 0; k < n; k = k + 1) @(posedge clk);
        #1;
        rst_n      = 1'b1;
        prev_res   = 16'h0000;
        prev_match = 1'b0;
    end
    endtask
 
    // ---------------- error helper ----------------------------
    task fail;
        input [31:0] id;
        input [8*48-1:0] msg;
    begin
        $display("ERROR [T%0d] t=%0t : %0s", id, $time, msg);
        err_cnt = err_cnt + 1;
    end
    endtask
 
    // ---------------- drive one packet ------------------------
    // Call aligned at (posedge clk + 1ns).  Returns aligned at the
    // same point right after the edge that accepted the last bit.
    // mode[0] random stalls
    // mode[1] junk: bit_valid/data/last toggle on start and stall cycles
    // mode[2] extra start pulse in the middle of the packet
    task send_packet;
        input [255:0] bits;
        input [31:0]  n_bits;
        input [15:0]  exp_crc;
        input [2:0]   mode;
        input [31:0]  id;
        integer       j;
    begin
        // ---- start cycle ----
        start        = 1'b1;
        expected_crc = exp_crc;
        if (mode[1]) begin
            bit_valid = 1'b1; data_bit = 1'b1; last_bit = 1'b1;   // must NOT be taken
        end else begin
            bit_valid = 1'b0; data_bit = 1'b0; last_bit = 1'b0;
        end
        @(posedge clk); #1;
        start        = 1'b0;
        expected_crc = ~exp_crc;          // expected must have been captured at start
        bit_valid    = 1'b0; data_bit = 1'b0; last_bit = 1'b0;
 
        if (busy !== 1'b1)             fail(id, "busy not high after start");
        if (done !== 1'b0)             fail(id, "done high after start");
        if (crc_result !== prev_res)   fail(id, "crc_result changed at start");
        if (match !== prev_match)      fail(id, "match changed at start");
 
        // ---- data bits ----
        for (j = 0; j < n_bits; j = j + 1) begin
            // optional stall cycles (bit_valid = 0)
            if (mode[0]) begin
                lfsr     = lfsr_next(lfsr);
                sp_stall = (lfsr[1:0] != 2'b00);
            end else begin
                sp_stall = 1'b0;
            end
            while (sp_stall) begin
                bit_valid = 1'b0;
                if (mode[1]) begin
                    data_bit = lfsr[4];
                    last_bit = lfsr[5] | lfsr[6];   // last_bit=1 with bit_valid=0 happens
                end else begin
                    data_bit = 1'b0;
                    last_bit = 1'b0;
                end
                @(posedge clk); #1;
                if (busy !== 1'b1)           fail(id, "busy dropped during stall");
                if (done !== 1'b0)           fail(id, "done during stall");
                if (crc_result !== prev_res) fail(id, "crc_result changed in stall");
                if (match !== prev_match)    fail(id, "match changed in stall");
                lfsr     = lfsr_next(lfsr);
                sp_stall = (lfsr[1:0] == 2'b11);
            end
 
            // the accepted bit
            bit_valid = 1'b1;
            data_bit  = bits[255 - j];
            last_bit  = (j == n_bits - 1) ? 1'b1 : 1'b0;
            if (mode[2] && (n_bits >= 4) && (j == (n_bits >> 1)))
                start = 1'b1;                 // bogus start while busy
            @(posedge clk); #1;
            start = 1'b0;
 
            if (j < n_bits - 1) begin
                if (busy !== 1'b1)           fail(id, "busy dropped mid-packet");
                if (done !== 1'b0)           fail(id, "done mid-packet");
                if (crc_result !== prev_res) fail(id, "crc_result changed mid-packet");
                if (match !== prev_match)    fail(id, "match changed mid-packet");
            end
        end
        bit_valid = 1'b0; data_bit = 1'b0; last_bit = 1'b0;
    end
    endtask
 
    // ---------------- check just after the last-bit edge -------
    task check_packet;
        input [15:0] ref_val;
        input        exp_match;
        input [31:0] id;
    begin
        pkt_cnt = pkt_cnt + 1;
        if (done !== 1'b1)             fail(id, "done not asserted");
        if (busy !== 1'b0)             fail(id, "busy still high after last bit");
        if (crc_result !== ref_val) begin
            $display("       crc_result=%04h  reference=%04h", crc_result, ref_val);
            fail(id, "crc_result != reference");
        end
        if (match !== exp_match)       fail(id, "match wrong");
        prev_res   = ref_val;
        prev_match = exp_match;
    end
    endtask
 
    // ---------------- done must drop, results must hold --------
    task check_done_drop;
        input [31:0] id;
    begin
        @(posedge clk); #1;
        if (done !== 1'b0)             fail(id, "done longer than 1 cycle");
        if (busy !== 1'b0)             fail(id, "busy high while idle");
        if (crc_result !== prev_res)   fail(id, "crc_result did not hold");
        if (match !== prev_match)      fail(id, "match did not hold");
    end
    endtask
 
    // ---------------- one complete packet, fully checked -------
    task run_packet;
        input [255:0] bits;
        input [31:0]  n_bits;
        input [15:0]  exp_crc;      // value handed to DUT as expected_crc
        input [2:0]   mode;
        input [31:0]  id;
        reg   [15:0]  r;
    begin
        ref_compute(bits, n_bits, r);
        send_packet(bits, n_bits, exp_crc, mode, id);
        check_packet(r, (exp_crc == r), id);
        check_done_drop(id);
    end
    endtask
 
    // convenience: expected = true CRC
    task run_good;
        input [255:0] bits;
        input [31:0]  n_bits;
        input [2:0]   mode;
        input [31:0]  id;
        reg   [15:0]  r;
    begin
        ref_compute(bits, n_bits, r);
        run_packet(bits, n_bits, r, mode, id);
    end
    endtask
 
    // ---------------- idle noise ------------------------------
    task idle_noise;
        input [31:0] cycles;
        input [31:0] id;
        integer k;
    begin
        for (k = 0; k < cycles; k = k + 1) begin
            lfsr      = lfsr_next(lfsr);
            start     = 1'b0;
            bit_valid = 1'b1;
            data_bit  = lfsr[3];
            last_bit  = 1'b1;
            @(posedge clk); #1;
            if (busy !== 1'b0)           fail(id, "busy rose without start");
            if (done !== 1'b0)           fail(id, "done rose while idle");
            if (crc_result !== prev_res) fail(id, "crc_result changed while idle");
            if (match !== prev_match)    fail(id, "match changed while idle");
        end
        bit_valid = 1'b0; data_bit = 1'b0; last_bit = 1'b0;
    end
    endtask
 
    // ---------------- known-answer helper ----------------------
    task known;
        input [255:0] bits;
        input [31:0]  n_bits;
        input [15:0]  known_crc;
        input [31:0]  id;
        reg   [15:0]  r;
    begin
        ref_compute(bits, n_bits, r);
        if (r !== known_crc) begin
            $display("       ref model=%04h  known=%04h", r, known_crc);
            fail(id, "reference model != known answer");
        end
        run_packet(bits, n_bits, known_crc, 3'b000, id);
    end
    endtask
 
    // =========================================================
    //  MAIN
    // =========================================================
    initial begin
        err_cnt    = 0;
        pkt_cnt    = 0;
        lfsr       = 32'hDEAD_BEEF;
        pkt        = 256'h0;
        prev_res   = 16'h0000;
        prev_match = 1'b0;
        start = 1'b0; bit_valid = 1'b0; data_bit = 1'b0; last_bit = 1'b0;
        expected_crc = 16'h0000;
        rst_n = 1'b0;
 
        $dumpfile("/home/vlsi19/23bec1412_l29l30_asic/proj/crc16_tb.vcd");
        $dumpvars(0, crc16_tb);
 
        // ---- T0: reset sanity ----
        $display("=== T0: reset sanity ===");
        apply_reset(4);
        if (busy !== 1'b0 || done !== 1'b0 || match !== 1'b0 || crc_result !== 16'h0000)
            fail(0, "outputs not cleared by reset");
        @(posedge clk); #1;
 
        // ---- T1: known answers (hard-coded, independent of RTL and model) ----
        $display("=== T1: known answers ===");
        pkt = 256'h0; pkt[255:184] = 72'h31_32_33_34_35_36_37_38_39;   // "123456789"
        known(pkt, 32'd72, 16'h29B1, 1);
        pkt = 256'h0; pkt[255:248] = 8'h41;                            // "A"
        known(pkt, 32'd8,  16'hB915, 1);
        pkt = 256'h0; pkt[255:240] = 16'h4142;                         // "AB"
        known(pkt, 32'd16, 16'h4B74, 1);
        pkt = 256'h0; pkt[255:248] = 8'h00;                            // 0x00
        known(pkt, 32'd8,  16'hE1F0, 1);
        pkt = 256'h0; pkt[255:248] = 8'hFF;                            // 0xFF
        known(pkt, 32'd8,  16'hFF00, 1);
 
        // ---- T2: single-bit packets ----
        $display("=== T2: 1-bit packets ===");
        pkt = 256'h0; pkt[255] = 1'b1;  run_good(pkt, 32'd1, 3'b000, 2);
        pkt = 256'h0; pkt[255] = 1'b0;  run_good(pkt, 32'd1, 3'b000, 2);
        pkt = 256'h0; pkt[255] = 1'b1;  run_good(pkt, 32'd1, 3'b010, 2);   // junk on start cycle
 
        // ---- T3: lengths 1..40, no stalls ----
        $display("=== T3: lengths 1..40 ===");
        for (idx = 1; idx <= 40; idx = idx + 1) begin
            gen_pkt;
            run_good(pkt, idx, 3'b000, 3);
        end
 
        // ---- T4: lengths 1..40, stalls + junk ----
        $display("=== T4: stalls + junk, lengths 1..40 ===");
        for (idx = 1; idx <= 40; idx = idx + 1) begin
            gen_pkt;
            run_good(pkt, idx, 3'b011, 4);
        end
 
        // ---- T5: long packets ----
        $display("=== T5: long packets ===");
        gen_pkt; run_good(pkt, 32'd64,  3'b011, 5);
        gen_pkt; run_good(pkt, 32'd72,  3'b001, 5);
        gen_pkt; run_good(pkt, 32'd128, 3'b011, 5);
        gen_pkt; run_good(pkt, 32'd256, 3'b011, 5);
 
        // ---- T6: wrong expected values ----
        $display("=== T6: wrong expected_crc ===");
        gen_pkt;
        ref_compute(pkt, 32'd24, rcrc);
        for (idx = 0; idx < 16; idx = idx + 1)
            run_packet(pkt, 32'd24, rcrc ^ (16'h0001 << idx), 3'b000, 6);   // one bit off
        run_packet(pkt, 32'd24, ~rcrc, 3'b000, 6);                           // all bits off
        run_packet(pkt, 32'd24, rcrc,  3'b000, 6);                           // and correct again
 
        // ---- T7: idle noise ----
        $display("=== T7: idle noise ===");
        idle_noise(10, 7);
        gen_pkt; run_good(pkt, 32'd12, 3'b000, 7);
        idle_noise(10, 7);                                                   // results must still hold
 
        // ---- T8: start while busy ----
        $display("=== T8: start while busy ===");
        for (idx = 4; idx <= 24; idx = idx + 4) begin
            gen_pkt;
            run_good(pkt, idx, 3'b100, 8);
            gen_pkt;
            run_good(pkt, idx, 3'b111, 8);
        end
 
        // ---- T9: back-to-back (start in the cycle right after done) ----
        $display("=== T9: back-to-back ===");
        gen_pkt;
        ref_compute(pkt, 32'd16, rcrc);
        send_packet(pkt, 32'd16, rcrc, 3'b000, 9);
        check_packet(rcrc, 1'b1, 9);
        pkt = 256'h0; pkt[255:248] = 8'h55;
        ref_compute(pkt, 32'd8, rcrc);
        send_packet(pkt, 32'd8, rcrc, 3'b000, 9);      // no idle cycle in between
        check_packet(rcrc, 1'b1, 9);
        pkt = 256'h0; pkt[255:248] = 8'hAA;
        ref_compute(pkt, 32'd8, rcrc);
        send_packet(pkt, 32'd8, ~rcrc, 3'b000, 9);     // third one with wrong expected
        check_packet(rcrc, 1'b0, 9);
        check_done_drop(9);
 
        // ---- T10: all-zeros / all-ones ----
        $display("=== T10: all-zeros / all-ones ===");
        pkt = 256'h0;                                     run_good(pkt, 32'd16, 3'b000, 10);
        pkt = 256'h0;                                     run_good(pkt, 32'd33, 3'b011, 10);
        pkt = {256{1'b1}};                                run_good(pkt, 32'd16, 3'b000, 10);
        pkt = {256{1'b1}};                                run_good(pkt, 32'd33, 3'b011, 10);
 
        // ---- T11: reset during a packet ----
        $display("=== T11: reset during packet ===");
        gen_pkt; run_good(pkt, 32'd20, 3'b000, 11);       // leaves non-zero result / match=1
 
        // (a) reset in the middle of a packet
        start = 1'b1; expected_crc = 16'h1234;
        @(posedge clk); #1;
        start = 1'b0;
        for (idx = 0; idx < 5; idx = idx + 1) begin
            bit_valid = 1'b1; data_bit = idx[0]; last_bit = 1'b0;
            @(posedge clk); #1;
        end
        rst_n = 1'b0; bit_valid = 1'b0;
        @(posedge clk); #1;
        rst_n = 1'b1;
        prev_res = 16'h0000; prev_match = 1'b0;
        if (busy !== 1'b0 || done !== 1'b0 || crc_result !== 16'h0000 || match !== 1'b0)
            fail(11, "reset did not clear outputs");
        @(posedge clk); #1;
        gen_pkt; run_good(pkt, 32'd17, 3'b011, 11);       // fresh packet must be correct
 
        // (b) reset on the very cycle that would accept the last bit
        start = 1'b1; expected_crc = 16'hABCD;
        @(posedge clk); #1;
        start = 1'b0;
        bit_valid = 1'b1; data_bit = 1'b1; last_bit = 1'b0; @(posedge clk); #1;
        bit_valid = 1'b1; data_bit = 1'b0; last_bit = 1'b0; @(posedge clk); #1;
        rst_n = 1'b0; bit_valid = 1'b1; data_bit = 1'b1; last_bit = 1'b1;   // would be last bit
        @(posedge clk); #1;
        rst_n = 1'b1; bit_valid = 1'b0; last_bit = 1'b0; data_bit = 1'b0;
        prev_res = 16'h0000; prev_match = 1'b0;
        if (busy !== 1'b0 || done !== 1'b0 || crc_result !== 16'h0000 || match !== 1'b0)
            fail(11, "reset on last-bit cycle published a result");
        @(posedge clk); #1;
        if (done !== 1'b0) fail(11, "done after reset-on-last-bit");
        gen_pkt; run_good(pkt, 32'd9, 3'b000, 11);
 
        // ---- summary ----
        #20;
        $display("-----------------------------------------");
        $display("packets checked : %0d", pkt_cnt);
        if (err_cnt == 0)
            $display("*** ALL TESTS PASSED ***");
        else
            $display("*** %0d ERRORS DETECTED ***", err_cnt);
        $display("-----------------------------------------");
        $dumpflush;
        $finish;
    end
 
    // ---------------- watchdog -------------------------------
    initial begin
        #20000000;
        $display("TIMEOUT: simulation exceeded 20 ms");
        $dumpflush;
        $finish;
    end
 
endmodule
