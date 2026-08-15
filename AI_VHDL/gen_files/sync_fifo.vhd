--------------------------------------------------------------------------------
-- sync_fifo.vhd
--
-- Minimal synchronous show-ahead (first-word-fall-through) FIFO for the
-- host side of HDLC_TRANSMIT (ARCHITECTURE.md sections 6.2 / 7.3):
--   * dout always presents the head word while not empty
--   * rd_en pops the head (1-clk pulse, e.g. tx_read_n inverted)
--   * clear flushes synchronously (used after a transmit abort)
--
-- Depth = 2**DEPTH_LOG2. Maps to distributed RAM on Artix-7.
--------------------------------------------------------------------------------
library IEEE;
use IEEE.std_logic_1164.all;
use IEEE.numeric_std.all;

entity sync_fifo is
  generic (
    WIDTH      : positive := 8;
    DEPTH_LOG2 : positive := 4          -- 16 entries
  );
  port (
    clk    : in  std_logic;
    rst    : in  std_logic;             -- synchronous, active-high
    clear  : in  std_logic;             -- synchronous flush
    wr_en  : in  std_logic;
    din    : in  std_logic_vector(WIDTH-1 downto 0);
    rd_en  : in  std_logic;
    dout   : out std_logic_vector(WIDTH-1 downto 0);
    empty  : out std_logic;
    full   : out std_logic
  );
end entity sync_fifo;

architecture rtl of sync_fifo is
  type t_mem is array (0 to 2**DEPTH_LOG2 - 1) of std_logic_vector(WIDTH-1 downto 0);
  signal mem   : t_mem := (others => (others => '0'));
  signal wptr  : unsigned(DEPTH_LOG2 downto 0) := (others => '0'); -- +1 wrap bit
  signal rptr  : unsigned(DEPTH_LOG2 downto 0) := (others => '0');
  signal emptyi, fulli : std_logic;
begin

  emptyi <= '1' when wptr = rptr else '0';
  fulli  <= '1' when (wptr(DEPTH_LOG2) /= rptr(DEPTH_LOG2)) and
                     (wptr(DEPTH_LOG2-1 downto 0) = rptr(DEPTH_LOG2-1 downto 0))
            else '0';

  empty <= emptyi;
  full  <= fulli;

  -- show-ahead read port (distributed RAM, asynchronous read)
  dout <= mem(to_integer(rptr(DEPTH_LOG2-1 downto 0)));

  process (clk)
  begin
    if rising_edge(clk) then
      if rst = '1' or clear = '1' then
        wptr <= (others => '0');
        rptr <= (others => '0');
      else
        if wr_en = '1' and fulli = '0' then
          mem(to_integer(wptr(DEPTH_LOG2-1 downto 0))) <= din;
          wptr <= wptr + 1;
        end if;
        if rd_en = '1' and emptyi = '0' then
          rptr <= rptr + 1;
        end if;
      end if;
    end if;
  end process;

end architecture rtl;
