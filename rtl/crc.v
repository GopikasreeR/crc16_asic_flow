// ============================================================
//  crc.v  (module crc16_checker)
//  CRC-16/CCITT checker
//  Polynomial : x^16 + x^12 + x^5 + 1  (0x1021)
//  Convention : init=0xFFFF, MSB-first, no reflection,
//               no final-XOR, no augmentation bits
//  'busy' is the only state bit (no redundant state register),
//  so RTL and synthesized netlist have identical flop sets.
// ============================================================
`timescale 1ns/1ps
 
module crc16_checker (
    input  wire        clk,
    input  wire        rst_n,          // active-low synchronous reset
    input  wire        start,          // pulse: begin new packet (idle only)
    input  wire        bit_valid,      // data_bit is valid this cycle
    input  wire        data_bit,       // serial data, MSB-first
    input  wire        last_bit,       // this accepted bit is the last
    input  wire [15:0] expected_crc,   // captured on start
    output reg         busy,           // 1 while processing a packet
    output reg  [15:0] crc_result,     // final CRC after last_bit
    output reg         match,          // crc_result == expected_crc
    output reg         done            // 1-cycle pulse after last_bit
);
 
    reg [15:0] crc_reg;        // working CRC
    reg [15:0] exp_reg;        // captured expected value
 
    wire        feedback;
    wire [15:0] crc_next;
    wire        accept;
 
    assign feedback = crc_reg[15] ^ data_bit;
    assign crc_next = {crc_reg[14:0], 1'b0} ^ (feedback ? 16'h1021 : 16'h0000);
    assign accept   = busy & bit_valid;
 
    always @(posedge clk) begin
        if (!rst_n) begin
            busy       <= 1'b0;
            crc_reg    <= 16'hFFFF;
            exp_reg    <= 16'h0000;
            crc_result <= 16'h0000;
            match      <= 1'b0;
            done       <= 1'b0;
        end
        else begin
            done <= accept & last_bit;         // 1-cycle pulse on the accepted last bit
 
            if (!busy) begin
                if (start) begin
                    busy    <= 1'b1;
                    crc_reg <= 16'hFFFF;
                    exp_reg <= expected_crc;
                end
            end
            else if (accept) begin
                if (last_bit) begin
                    crc_result <= crc_next;
                    match      <= (crc_next == exp_reg);
                    busy       <= 1'b0;
                    crc_reg    <= 16'hFFFF;
                end
                else begin
                    crc_reg <= crc_next;
                end
            end
            // stall (busy && !bit_valid): hold everything
        end
    end
 
endmodule
