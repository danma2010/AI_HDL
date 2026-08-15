--------------------------------------------------------------------------------
-- hdlc_transmit.vhd   (entity HDLC_TRANSMIT)
--
-- HDLC framer, reproduced from ARCHITECTURE.md section 4. Functional blocks
-- of the original design map onto this implementation as follows:
--
--   F_INSERT  -> S_FLAG state: free-running 0x7E flags while idle and as
--                opening/closing delimiters (TxD = '0' at bits 0/7).
--   Z_STUFF   -> ones_cnt: after five consecutive '1's on the frame body,
--                one '0' is inserted and the data/FCS pipeline is stalled.
--   T_BUFFER/ -> shift_reg: byte shift register, LSB-first, reloaded from
--   T_SHIFT      the host FIFO (show-ahead) at each byte boundary.
--   CRC_GEN   -> crc_reg (LFSR, poly 0x1021, preset all-ones over the data
--                bits); transmitted FCS = not(crc_reg), MSB-first (S_FCS).
--   A_INSERT  -> abort_pend/S_ABORT: forces >= 8 consecutive '1's (HDLC
--                abort), then returns to flags.
--   T_CONTROL -> the state machine + start/abort latches + tx_read_n pulse.
--
-- Clocking (adapted for Artix-7 @ 100 MHz): everything runs on `clk`;
-- the serial bit rate is set by the single-cycle `bit_en` tick (the TxC
-- bit clock of the original is replaced by this clock enable). `tx_read_n`
-- is a single `clk`-cycle pulse so a 100 MHz synchronous FIFO pops exactly
-- one byte.
--------------------------------------------------------------------------------
library IEEE;
use IEEE.std_logic_1164.all;
use IEEE.numeric_std.all;
use work.hdlc_package.all;

entity HDLC_TRANSMIT is
  port (
    clk         : in  std_logic;                     -- 100 MHz system clock
    rst         : in  std_logic;                     -- synchronous, active-high
    tx_enable   : in  std_logic;                     -- master enable (TxEnable)
    bit_en      : in  std_logic;                     -- 1-clk bit-rate tick
    -- Host / FIFO interface (show-ahead FIFO assumed)
    tx_data     : in  std_logic_vector(7 downto 0);  -- TxInputData
    tx_has_data : in  std_logic;                     -- '1' = FIFO not empty (TxEmpty_n)
    tx_read_n   : out std_logic;                     -- active-low 1-clk pop strobe
    tx_start    : in  std_logic;                     -- pulse: begin a frame
    tx_abort    : in  std_logic;                     -- pulse: abort frame in progress
    tx_busy     : out std_logic;                     -- frame in progress / pending
    -- Line
    txd         : out std_logic                      -- serial output (TxD)
  );
end entity HDLC_TRANSMIT;

architecture rtl of HDLC_TRANSMIT is

  type t_state is (S_FLAG, S_DATA, S_FCS, S_ABORT);
  signal state      : t_state := S_FLAG;

  signal flag_cnt   : unsigned(2 downto 0) := (others => '0'); -- bit within flag
  signal data_cnt   : unsigned(2 downto 0) := (others => '0'); -- bit within byte
  signal fcs_cnt    : unsigned(3 downto 0) := (others => '0'); -- bit within FCS
  signal abort_cnt  : unsigned(2 downto 0) := (others => '0');

  signal shift_reg  : std_logic_vector(7 downto 0)  := (others => '0');
  signal crc_reg    : std_logic_vector(FCS_size-1 downto 0) := (others => '1');
  signal fcs_shift  : std_logic_vector(FCS_size-1 downto 0) := (others => '0');

  signal ones_cnt   : unsigned(2 downto 0) := (others => '0'); -- consecutive 1s sent

  signal start_pend : std_logic := '0';
  signal abort_pend : std_logic := '0';

  signal txd_r      : std_logic := '1';
  signal tx_read_ni : std_logic := '1';

begin

  txd       <= txd_r;
  tx_read_n <= tx_read_ni;
  tx_busy   <= start_pend when state = S_FLAG else '1';

  process (clk)
    variable v_bit : std_logic;
    variable v_crc : std_logic_vector(FCS_size-1 downto 0);
  begin
    if rising_edge(clk) then
      -- default: read strobe inactive (guarantees a 1-clk pulse)
      tx_read_ni <= '1';

      if rst = '1' then
        state      <= S_FLAG;
        flag_cnt   <= (others => '0');
        ones_cnt   <= (others => '0');
        start_pend <= '0';
        abort_pend <= '0';
        txd_r      <= '1';

      elsif tx_enable = '1' then

        -- latch host pulses at full clock rate
        if tx_start = '1' then
          start_pend <= '1';
        end if;
        if tx_abort = '1' then
          abort_pend <= '1';
        end if;

        if bit_en = '1' then
          case state is

            ------------------------------------------------------------------
            -- Flag insertion (F_INSERT): 01111110, '0' at positions 0 and 7.
            -- While idle this free-runs, emitting back-to-back flags.
            ------------------------------------------------------------------
            when S_FLAG =>
              if flag_cnt = 0 or flag_cnt = 7 then
                txd_r <= '0';
              else
                txd_r <= '1';
              end if;

              if flag_cnt = 7 then
                flag_cnt <= (others => '0');
                -- open a frame at the flag boundary
                if start_pend = '1' and tx_has_data = '1' then
                  start_pend <= '0';
                  shift_reg  <= tx_data;         -- show-ahead FIFO: data valid now
                  tx_read_ni <= '0';             -- pop it
                  crc_reg    <= (others => '1'); -- FCS preset
                  ones_cnt   <= (others => '0');
                  data_cnt   <= (others => '0');
                  state      <= S_DATA;
                end if;
              else
                flag_cnt <= flag_cnt + 1;
              end if;

            ------------------------------------------------------------------
            -- Frame body: address/data bytes, LSB-first, stuffed (Z_STUFF)
            -- and CRC-accumulated (CRC_GEN) on the fly.
            ------------------------------------------------------------------
            when S_DATA =>
              if abort_pend = '1' then
                -- A_INSERT: force ones immediately
                txd_r     <= '1';
                abort_cnt <= to_unsigned(1, abort_cnt'length);
                state     <= S_ABORT;

              elsif ones_cnt = 5 then
                -- insert stuffed '0'; hold shift/CRC (pipeline stalled)
                txd_r    <= '0';
                ones_cnt <= (others => '0');

              else
                v_bit := shift_reg(0);
                txd_r <= v_bit;
                v_crc := crc_step(crc_reg, v_bit);
                crc_reg <= v_crc;

                if v_bit = '1' then
                  ones_cnt <= ones_cnt + 1;
                else
                  ones_cnt <= (others => '0');
                end if;

                if data_cnt = 7 then
                  data_cnt <= (others => '0');
                  if tx_has_data = '1' then
                    shift_reg  <= tx_data;
                    tx_read_ni <= '0';
                  else
                    -- last byte sent: append complemented FCS, MSB-first
                    fcs_shift <= not v_crc;
                    fcs_cnt   <= (others => '0');
                    state     <= S_FCS;
                  end if;
                else
                  shift_reg <= '0' & shift_reg(7 downto 1);
                  data_cnt  <= data_cnt + 1;
                end if;
              end if;

            ------------------------------------------------------------------
            -- FCS field: 16 bits, MSB-first, still subject to stuffing.
            ------------------------------------------------------------------
            when S_FCS =>
              if abort_pend = '1' then
                txd_r     <= '1';
                abort_cnt <= to_unsigned(1, abort_cnt'length);
                state     <= S_ABORT;

              elsif ones_cnt = 5 then
                txd_r    <= '0';
                ones_cnt <= (others => '0');

              else
                v_bit := fcs_shift(FCS_size-1);
                txd_r  <= v_bit;
                fcs_shift <= fcs_shift(FCS_size-2 downto 0) & '0';

                if v_bit = '1' then
                  ones_cnt <= ones_cnt + 1;
                else
                  ones_cnt <= (others => '0');
                end if;

                if fcs_cnt = FCS_size-1 then
                  flag_cnt <= (others => '0');
                  state    <= S_FLAG;            -- closing flag
                else
                  fcs_cnt <= fcs_cnt + 1;
                end if;
              end if;

            ------------------------------------------------------------------
            -- Abort (A_INSERT): eight consecutive '1's (>= 7 required by
            -- HDLC), then back to flags. Host is expected to flush its FIFO.
            ------------------------------------------------------------------
            when S_ABORT =>
              txd_r <= '1';
              if abort_cnt = 7 then
                abort_pend <= '0';
                ones_cnt   <= (others => '0');
                flag_cnt   <= (others => '0');
                state      <= S_FLAG;
              else
                abort_cnt <= abort_cnt + 1;
              end if;

          end case;
        end if;
      end if;
    end if;
  end process;

end architecture rtl;
