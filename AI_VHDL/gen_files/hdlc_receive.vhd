--------------------------------------------------------------------------------
-- hdlc_receive.vhd   (entity HDLC_RECEIVE)
--
-- HDLC deframer, reproduced from ARCHITECTURE.md section 5. Functional
-- blocks of the original design map onto this implementation as follows:
--
--   F_DETECT  -> r_buffer window compare against 0x7E (flag) + ones_head
--                run-length counter (abort / mark-idle).
--   Z_UNSTUFF -> exit_ones counter at the commit stage: a '0' after five
--                consecutive '1's is a stuffed bit and is discarded.
--   A_DETECT  -> ones_head reaching 7 while a frame is open -> Abort.
--   BIT_CNT   -> bit_cnt: DataValid every 8th committed bit; a non-zero
--                count at frame end -> Octet_err (frame not octet-aligned).
--   CRC_CHK   -> crc_reg over the destuffed frame body; a good frame leaves
--                the residue CRC_Good_Residue (0x1D0F).
--   R_BUFFER/ -> r_buffer is the raw 8-bit SIPO; committed (destuffed) bits
--   R_SHIFT      are shifted LSB-first into r_shift.
--   R_CONTROL -> data-byte strobe rx_data_write_n; at frame end a status
--   R_DATA       byte "11111" & Abort & Octet_err & CRC_err is presented
--                with rx_status_write_n (the doc's 7-stage StatusValid
--                alignment chain is replaced by committing bits through the
--                8-bit look-ahead buffer, which aligns status exactly).
--
-- Pipeline principle: every raw line bit spends 8 bit-periods inside
-- r_buffer before it is "committed" (destuffed / CRC'd / shifted to the
-- host). A flag or abort is detected the moment its last bit ENTERS the
-- buffer, i.e. before any of its bits has been committed, so delimiter
-- bits are never mistaken for data (skip_cnt then discards them on exit).
--
-- NOTE (matches the original design's behavior): data bytes are delivered
-- as they complete, so the two FCS bytes are also delivered, followed by
-- the status byte. On a good status the host discards the last two bytes.
--
-- Clocking: single 100 MHz clk; bit sampling paced by the 1-clk bit_en
-- tick (replaces the original RxC bit clock). Strobes are 1-clk pulses.
--------------------------------------------------------------------------------
library IEEE;
use IEEE.std_logic_1164.all;
use IEEE.numeric_std.all;
use work.hdlc_package.all;

entity HDLC_RECEIVE is
  port (
    clk               : in  std_logic;                    -- 100 MHz system clock
    rst               : in  std_logic;                    -- synchronous, active-high
    rx_enable         : in  std_logic;                    -- master enable (RxEnable)
    bit_en            : in  std_logic;                    -- 1-clk bit-rate tick
    rxd               : in  std_logic;                    -- serial input (RxD)
    rx_data           : out std_logic_vector(7 downto 0); -- data byte / status byte
    rx_data_write_n   : out std_logic;                    -- active-low 1-clk strobe
    rx_status_write_n : out std_logic                     -- active-low 1-clk strobe
  );
end entity HDLC_RECEIVE;

architecture rtl of HDLC_RECEIVE is

  signal r_buffer  : std_logic_vector(7 downto 0) := (others => '1'); -- raw SIPO
  signal r_shift   : std_logic_vector(7 downto 0) := (others => '0'); -- destuffed
  signal crc_reg   : std_logic_vector(FCS_size-1 downto 0) := (others => '1');

  signal ones_head : unsigned(2 downto 0) := (others => '0'); -- raw 1-run at input
  signal exit_ones : unsigned(2 downto 0) := (others => '0'); -- 1-run at commit
  signal skip_cnt  : unsigned(3 downto 0) := (others => '0'); -- delimiter bits to drop
  signal bit_cnt   : unsigned(2 downto 0) := (others => '0'); -- committed bits mod 8

  signal in_frame  : std_logic := '0';
  signal got_bits  : std_logic := '0'; -- at least one committed bit this frame

  signal status_pend : std_logic := '0';
  signal status_reg  : std_logic_vector(7 downto 0) := (others => '0');

  signal rx_data_r   : std_logic_vector(7 downto 0) := (others => '0');
  signal data_wr_ni  : std_logic := '1';
  signal stat_wr_ni  : std_logic := '1';

begin

  rx_data           <= rx_data_r;
  rx_data_write_n   <= data_wr_ni;
  rx_status_write_n <= stat_wr_ni;

  process (clk)
    variable v_bit    : std_logic;
    variable v_buf    : std_logic_vector(7 downto 0);
    variable v_shift  : std_logic_vector(7 downto 0);
    variable v_crc    : std_logic_vector(FCS_size-1 downto 0);
    variable v_bcnt   : unsigned(2 downto 0);
    variable v_any    : std_logic;
    variable v_octerr : std_logic;
    variable v_crcerr : std_logic;
  begin
    if rising_edge(clk) then
      -- defaults: strobes are single-clk pulses
      data_wr_ni <= '1';
      stat_wr_ni <= '1';

      if rst = '1' then
        r_buffer    <= (others => '1');
        ones_head   <= (others => '0');
        exit_ones   <= (others => '0');
        skip_cnt    <= (others => '0');
        bit_cnt     <= (others => '0');
        in_frame    <= '0';
        got_bits    <= '0';
        status_pend <= '0';

      elsif rx_enable = '1' then

        ----------------------------------------------------------------------
        -- Deferred status handoff: a frame can end on the same bit tick that
        -- completes a data byte; the data byte takes the bus first and the
        -- status byte is presented on the following clk cycle (R_DATA).
        -- (Requires bit_en period >= 2 clk, guaranteed by the top level.)
        ----------------------------------------------------------------------
        if status_pend = '1' then
          rx_data_r   <= status_reg;
          stat_wr_ni  <= '0';
          status_pend <= '0';
        end if;

        if bit_en = '1' then
          -- working copies (so frame-end status sees this tick's commit)
          v_crc  := crc_reg;
          v_bcnt := bit_cnt;
          v_any  := got_bits;

          ----------------------------------------------------------------------
          -- 1) COMMIT stage: the oldest buffered bit r_buffer(0) leaves the
          --    8-bit window on this tick. Destuff it (Z_UNSTUFF) and shift it
          --    into the data register, unless it belongs to a delimiter.
          ----------------------------------------------------------------------
          if skip_cnt /= 0 then
            skip_cnt <= skip_cnt - 1;              -- flag bit: discard

          elsif in_frame = '1' then
            v_bit := r_buffer(0);

            if v_bit = '1' then
              if exit_ones /= 7 then
                exit_ones <= exit_ones + 1;        -- saturating
              end if;
              -- commit '1'
              v_shift := v_bit & r_shift(7 downto 1);
              r_shift <= v_shift;
              v_crc   := crc_step(v_crc, v_bit);
              v_any   := '1';
              if v_bcnt = 7 then
                rx_data_r  <= v_shift;             -- DataValid: byte complete
                data_wr_ni <= '0';
                v_bcnt := (others => '0');
              else
                v_bcnt := v_bcnt + 1;
              end if;

            elsif exit_ones = 5 then
              exit_ones <= (others => '0');        -- stuffed '0': discard

            else
              exit_ones <= (others => '0');
              -- commit '0'
              v_shift := v_bit & r_shift(7 downto 1);
              r_shift <= v_shift;
              v_crc   := crc_step(v_crc, v_bit);
              v_any   := '1';
              if v_bcnt = 7 then
                rx_data_r  <= v_shift;
                data_wr_ni <= '0';
                v_bcnt := (others => '0');
              else
                v_bcnt := v_bcnt + 1;
              end if;
            end if;
          end if;

          ----------------------------------------------------------------------
          -- 2) HEAD stage: shift the new line bit in, track the raw 1-run.
          ----------------------------------------------------------------------
          v_buf    := rxd & r_buffer(7 downto 1);
          r_buffer <= v_buf;

          if rxd = '1' then
            if ones_head /= 7 then
              ones_head <= ones_head + 1;          -- saturating (mark idle)
            end if;
          else
            ones_head <= (others => '0');
          end if;

          ----------------------------------------------------------------------
          -- 3) DELIMITER events (F_DETECT / A_DETECT), evaluated on the new
          --    window so no delimiter bit has been committed yet.
          ----------------------------------------------------------------------
          if v_buf = HDLC_Flag then
            -- Flag: close the current frame (if it carried bits) and open a
            -- new one. Empty frames (back-to-back flags) are silent.
            if in_frame = '1' and v_any = '1' then
              if v_bcnt /= 0 then v_octerr := '1'; else v_octerr := '0'; end if;
              if v_crc /= CRC_Good_Residue then v_crcerr := '1'; else v_crcerr := '0'; end if;
              status_reg  <= "11111" & '0' & v_octerr & v_crcerr;
              status_pend <= '1';
            end if;
            in_frame  <= '1';
            skip_cnt  <= to_unsigned(8, skip_cnt'length); -- drop the 8 flag bits
            exit_ones <= (others => '0');
            v_crc  := (others => '1');            -- FCS preset (RstStatus)
            v_bcnt := (others => '0');
            v_any  := '0';

          elsif in_frame = '1' and ones_head = 6 and rxd = '1' then
            -- seventh consecutive raw '1' while a frame is open: HDLC abort
            if v_any = '1' then
              if v_bcnt /= 0 then v_octerr := '1'; else v_octerr := '0'; end if;
              status_reg  <= "11111" & '1' & v_octerr & '1';
              status_pend <= '1';
            end if;
            in_frame <= '0';                       -- discard remainder
          end if;

          -- write back working copies
          crc_reg  <= v_crc;
          bit_cnt  <= v_bcnt;
          got_bits <= v_any;
        end if;
      end if;
    end if;
  end process;

end architecture rtl;
