--------------------------------------------------------------------------------
-- hdlc_top.vhd
--
-- Top-level integration (ARCHITECTURE.md sections 6.2 / 7) for the Digilent
-- Arty A7 (XC7A35T / XC7A100T), 100 MHz system clock:
--
--   * bit-rate tick generator: replaces the original clkdiv — instead of a
--     derived TxC/RxC clock, a single-cycle clock enable `bit_en` paces both
--     controllers inside the one 100 MHz domain (no CDC, clean timing).
--   * sync_fifo behind the TxInputData byte bus (show-ahead).
--   * HDLC_TRANSMIT + HDLC_RECEIVE with TxD looped back to RxD
--     (internally by default, or externally over PMOD JA per generic).
--   * Self-test stimulus per section 7.5: BTN0 loads a 16-byte message into
--     the FIFO and pulses TxStart; BTN1 pulses TxAbort mid-frame (and
--     flushes the FIFO); BTN3 is reset.
--
--   LEDs: LD4 = last frame received OK (status = Abort 0 / Octet_err 0 /
--         CRC_err 0), LD5 = CRC_err, LD6 = Abort seen, LD7 = TX busy.
--
--   Received data bytes (including the two trailing FCS bytes — see note in
--   hdlc_receive.vhd) appear on rx_data with rx_data_write_n; a host would
--   capture them there. In this self-test top they are simply counted.
--------------------------------------------------------------------------------
library IEEE;
use IEEE.std_logic_1164.all;
use IEEE.numeric_std.all;

entity hdlc_top is
  generic (
    CLK_FREQ_HZ       : positive := 100_000_000;
    BIT_RATE_HZ       : positive := 1_000_000;    -- serial line rate (1 Mb/s)
    INTERNAL_LOOPBACK : boolean  := true          -- false: loop over PMOD JA1->JA2
  );
  port (
    clk    : in  std_logic;                       -- 100 MHz (Arty pin E3)
    btn    : in  std_logic_vector(3 downto 0);    -- 0:send 1:abort 3:reset
    led    : out std_logic_vector(3 downto 0);
    ja_txd : out std_logic;                       -- PMOD JA1: TxD (scope/loop)
    ja_rxd : in  std_logic                        -- PMOD JA2: RxD (external loop)
  );
end entity hdlc_top;

architecture rtl of hdlc_top is

  ------------------------------------------------------------------
  -- bit-rate divider (must be >= 2: RX relies on one idle clk
  -- between bit ticks for the deferred status handoff)
  ------------------------------------------------------------------
  constant BIT_DIV : positive := CLK_FREQ_HZ / BIT_RATE_HZ;

  constant MSG_LEN : positive := 16;
  type t_rom is array (0 to MSG_LEN-1) of std_logic_vector(7 downto 0);
  constant MESSAGE : t_rom := (
    x"48", x"45", x"4C", x"4C", x"4F", x"20", x"66", x"72",   -- "HELLO fr"
    x"6F", x"6D", x"20", x"48", x"44", x"4C", x"43", x"21"    -- "om HDLC!"
  );

  -- resets / buttons
  signal rst_meta, rst_sync : std_logic := '1';
  signal btn_meta, btn_sync, btn_deb, btn_prev : std_logic_vector(1 downto 0) := (others => '0');
  signal deb_cnt   : unsigned(16 downto 0) := (others => '0');  -- ~1.3 ms @ 100 MHz
  signal send_edge, abort_edge : std_logic := '0';

  -- bit tick
  signal div_cnt : unsigned(31 downto 0) := (others => '0');
  signal bit_en  : std_logic := '0';

  -- FIFO / TX
  signal fifo_wr, fifo_clear   : std_logic := '0';
  signal fifo_din, fifo_dout   : std_logic_vector(7 downto 0) := (others => '0');
  signal fifo_empty, fifo_full : std_logic;
  signal tx_read_n, tx_start, tx_abort, tx_busy : std_logic := '0';
  signal txd, rxd_int          : std_logic;
  signal rxd_meta, rxd_sync    : std_logic := '1';

  -- message loader
  signal loading  : std_logic := '0';
  signal load_idx : unsigned(4 downto 0) := (others => '0');

  -- RX / status capture
  signal rx_data           : std_logic_vector(7 downto 0);
  signal rx_data_write_n   : std_logic;
  signal rx_status_write_n : std_logic;
  signal led_ok, led_crc, led_abt : std_logic := '0';
  signal rx_byte_cnt : unsigned(7 downto 0) := (others => '0'); -- observability

begin

  --------------------------------------------------------------------
  -- reset synchronizer (BTN3, active-high)
  --------------------------------------------------------------------
  process (clk)
  begin
    if rising_edge(clk) then
      rst_meta <= btn(3);
      rst_sync <= rst_meta;
    end if;
  end process;

  --------------------------------------------------------------------
  -- BTN0 (send) / BTN1 (abort): 2FF sync + ~1.3 ms debounce + rising edge
  --------------------------------------------------------------------
  process (clk)
  begin
    if rising_edge(clk) then
      btn_meta <= btn(1 downto 0);
      btn_sync <= btn_meta;

      send_edge  <= '0';
      abort_edge <= '0';

      if btn_sync /= btn_deb then
        deb_cnt <= deb_cnt + 1;
        if deb_cnt = (deb_cnt'range => '1') then
          btn_deb <= btn_sync;
        end if;
      else
        deb_cnt <= (others => '0');
      end if;

      btn_prev <= btn_deb;
      if btn_deb(0) = '1' and btn_prev(0) = '0' then
        send_edge <= '1';
      end if;
      if btn_deb(1) = '1' and btn_prev(1) = '0' then
        abort_edge <= '1';
      end if;
    end if;
  end process;

  --------------------------------------------------------------------
  -- bit-rate tick: one-cycle enable every BIT_DIV clocks
  --------------------------------------------------------------------
  assert BIT_DIV >= 2
    report "BIT_RATE_HZ too high: CLK_FREQ_HZ/BIT_RATE_HZ must be >= 2"
    severity failure;

  process (clk)
  begin
    if rising_edge(clk) then
      bit_en <= '0';
      if rst_sync = '1' then
        div_cnt <= (others => '0');
      elsif div_cnt = BIT_DIV - 1 then
        div_cnt <= (others => '0');
        bit_en  <= '1';
      else
        div_cnt <= div_cnt + 1;
      end if;
    end if;
  end process;

  --------------------------------------------------------------------
  -- self-test stimulus: on send, stream the ROM message into the FIFO
  -- (one byte per clk), then pulse TxStart; on abort, pulse TxAbort and
  -- flush the FIFO
  --------------------------------------------------------------------
  process (clk)
  begin
    if rising_edge(clk) then
      fifo_wr    <= '0';
      fifo_clear <= '0';
      tx_start   <= '0';
      tx_abort   <= '0';

      if rst_sync = '1' then
        loading  <= '0';
        load_idx <= (others => '0');
      else
        if loading = '0' and send_edge = '1' and tx_busy = '0' then
          loading  <= '1';
          load_idx <= (others => '0');
        elsif loading = '1' then
          fifo_wr  <= '1';
          fifo_din <= MESSAGE(to_integer(load_idx));
          if load_idx = MSG_LEN - 1 then
            loading  <= '0';
            tx_start <= '1';
          else
            load_idx <= load_idx + 1;
          end if;
        end if;

        if abort_edge = '1' then
          tx_abort   <= '1';
          fifo_clear <= '1';
        end if;
      end if;
    end if;
  end process;

  --------------------------------------------------------------------
  -- host-side FIFO behind the TxInputData byte bus
  --------------------------------------------------------------------
  u_tx_fifo : entity work.sync_fifo
    generic map (WIDTH => 8, DEPTH_LOG2 => 5)     -- 32 deep
    port map (
      clk   => clk,
      rst   => rst_sync,
      clear => fifo_clear,
      wr_en => fifo_wr,
      din   => fifo_din,
      rd_en => not tx_read_n,
      dout  => fifo_dout,
      empty => fifo_empty,
      full  => fifo_full
    );

  --------------------------------------------------------------------
  -- HDLC controllers
  --------------------------------------------------------------------
  u_tx : entity work.HDLC_TRANSMIT
    port map (
      clk         => clk,
      rst         => rst_sync,
      tx_enable   => '1',
      bit_en      => bit_en,
      tx_data     => fifo_dout,
      tx_has_data => not fifo_empty,
      tx_read_n   => tx_read_n,
      tx_start    => tx_start,
      tx_abort    => tx_abort,
      tx_busy     => tx_busy,
      txd         => txd
    );

  -- loopback selection; external path is resynchronized (async pin)
  process (clk)
  begin
    if rising_edge(clk) then
      rxd_meta <= ja_rxd;
      rxd_sync <= rxd_meta;
    end if;
  end process;

  rxd_int <= txd when INTERNAL_LOOPBACK else rxd_sync;
  ja_txd  <= txd;

  u_rx : entity work.HDLC_RECEIVE
    port map (
      clk               => clk,
      rst               => rst_sync,
      rx_enable         => '1',
      bit_en            => bit_en,
      rxd               => rxd_int,
      rx_data           => rx_data,
      rx_data_write_n   => rx_data_write_n,
      rx_status_write_n => rx_status_write_n
    );

  --------------------------------------------------------------------
  -- status capture -> LEDs
  -- status byte = "11111" & Abort & Octet_err & CRC_err
  --------------------------------------------------------------------
  process (clk)
  begin
    if rising_edge(clk) then
      if rst_sync = '1' then
        led_ok      <= '0';
        led_crc     <= '0';
        led_abt     <= '0';
        rx_byte_cnt <= (others => '0');
      else
        if rx_data_write_n = '0' then
          rx_byte_cnt <= rx_byte_cnt + 1;
        end if;
        if rx_status_write_n = '0' then
          if rx_data = "11111000" then
            led_ok  <= '1';
            led_crc <= '0';
            led_abt <= '0';
          else
            led_ok  <= '0';
            led_crc <= rx_data(0);
            led_abt <= rx_data(2);
          end if;
        end if;
      end if;
    end if;
  end process;

  led(0) <= led_ok;
  led(1) <= led_crc;
  led(2) <= led_abt;
  led(3) <= tx_busy;

end architecture rtl;
