--------------------------------------------------------------------------------
-- hdlc_package.vhd
--
-- Shared constants and helper functions for the HDLC controller
-- (HDLC_TRANSMIT / HDLC_RECEIVE), per ARCHITECTURE.md section 6.1.
--
-- Protocol: HDLC (ISO/IEC 13239)
--   * Flag delimiter 0x7E ("01111110")
--   * Zero-bit insertion after five consecutive '1's
--   * 16-bit FCS, CRC-CCITT / X.25: x^16 + x^12 + x^5 + 1 (0x1021)
--   * FCS register preset to all-ones; transmitted FCS is the ones-complement
--     of the register, serialized MSB-first. Data bytes are serialized
--     LSB-first.
--   * Receiver check: running the same LFSR over the destuffed frame body
--     (data + received FCS) leaves the message-independent residue 0x1D0F.
--
-- Target: single 100 MHz clock domain, AMD/Xilinx Artix-7.
--------------------------------------------------------------------------------
library IEEE;
use IEEE.std_logic_1164.all;

package hdlc_package is

  constant FCS_size : integer := 16;

  -- CRC-CCITT (x^16 + x^12 + x^5 + 1). Bit i is the x^i tap; the x^16 term
  -- is implicit in the feedback.
  constant CRC_Polynomial : std_logic_vector(FCS_size-1 downto 0) :=
    "0001000000100001";  -- 0x1021

  -- Residue left in the receiver's FCS register after a good frame
  -- (data + complemented FCS), with all-ones preset. Verified against a
  -- software golden model for multiple payloads.
  constant CRC_Good_Residue : std_logic_vector(FCS_size-1 downto 0) :=
    "0001110100001111";  -- 0x1D0F

  -- HDLC flag octet, as it sits in an 8-bit SIPO window (oldest bit at
  -- index 0): on-line order 0,1,1,1,1,1,1,0 is palindromic, so the window
  -- pattern equals 0x7E regardless of shift direction.
  constant HDLC_Flag : std_logic_vector(7 downto 0) := "01111110";

  -- One serial CRC step: shift left, feedback = din xor MSB.
  function crc_step (
    reg : std_logic_vector(FCS_size-1 downto 0);
    din : std_logic
  ) return std_logic_vector;

end package hdlc_package;

package body hdlc_package is

  function crc_step (
    reg : std_logic_vector(FCS_size-1 downto 0);
    din : std_logic
  ) return std_logic_vector is
    variable fb  : std_logic;
    variable nxt : std_logic_vector(FCS_size-1 downto 0);
  begin
    fb  := din xor reg(FCS_size-1);
    nxt := reg(FCS_size-2 downto 0) & '0';
    if fb = '1' then
      nxt := nxt xor CRC_Polynomial;
    end if;
    return nxt;
  end function;

end package body hdlc_package;
