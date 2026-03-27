-- ============================================================================
-- BLACKJACK GAME FOR DE2-115 FPGA
-- ============================================================================
library IEEE;
use IEEE.STD_LOGIC_1164.ALL;
use IEEE.NUMERIC_STD.ALL;

entity BlackJack is
    port (
        -- Clock
        CLOCK_50    : in  std_logic;
        
        -- active-low buttons: shuffle,	stand, hit, deal
        KEY         : in  std_logic_vector(3 downto 0);
        
        -- seven-segment displays (active low) 4,5 for plater 6,7 for dealer, 0123 for betting
        HEX0        : out std_logic_vector(6 downto 0);
        HEX1        : out std_logic_vector(6 downto 0);
        HEX2        : out std_logic_vector(6 downto 0);
        HEX3        : out std_logic_vector(6 downto 0);
		HEX4        : out std_logic_vector(6 downto 0);
        HEX5        : out std_logic_vector(6 downto 0);
        HEX6        : out std_logic_vector(6 downto 0);
        HEX7        : out std_logic_vector(6 downto 0);	
		
		-- switch for choosing betting ammounts
		SW         : in  std_logic_vector(3 downto 0);
        
        -- LEDs (active high) for win/loss effects
        LEDR        : out std_logic_vector(17 downto 0);
        LEDG        : out std_logic_vector(7 downto 0)
    );
end entity BlackJack;

architecture rtl of BlackJack is

    -- ========================================================================
    -- CONSTANTS
    -- ========================================================================
    
    -- Clock frequency and timing
    constant CLK_FREQ           : integer := 50_000_000;  -- 50 MHz
    constant DEBOUNCE_TIME_MS   : integer := 20;          -- 20ms debounce
    constant DEBOUNCE_CYCLES    : integer := CLK_FREQ / 1000 * DEBOUNCE_TIME_MS;
    constant SHUFFLE_TIME_SEC   : integer := 2;           -- for shuffle animation
    constant SHUFFLE_CYCLES     : integer := CLK_FREQ * SHUFFLE_TIME_SEC;
    constant DEAL_DELAY_CYCLES  : integer := CLK_FREQ / 4; -- for time between cards
    
    -- Card deck constants (2-deck blackjack)
    constant CARDS_PER_VALUE    : integer := 8;   -- 8 cards each for A-9
    constant TENS_IN_DECK       : integer := 32;  -- 32 ten-value cards
    constant TOTAL_CARDS        : integer := 104; -- Total cards in 2 decks
    
    -- LFSR seed (must be non-zero)
    constant LFSR_SEED          : std_logic_vector(6 downto 0) := "1010101";
	
	--max ammount of money
	constant MAX_MONEY          : integer := 9999;
    
    -- ========================================================================
    -- TYPE DEFINITIONS
    -- ========================================================================
    
    -- game states
    type game_state_t is (
        ST_IDLE, --nothing happening(allows only shuffle button to be pressed and bets to be placed)
        ST_SHUFFLE,	-- resets all flags for cards available in the deck
        ST_DEAL_INITIAL, -- starts dealing
        ST_DEAL_PLAYER_1, -- players first card
        ST_DEAL_PLAYER_2, --  players second card
        ST_DEAL_DEALER_1,  -- dealers first card
        ST_PLAYER_TURN,	 -- wait for player to hit or stand
        ST_PLAYER_HIT,	 -- gives player another card
        ST_DEALER_TURN,	 -- when player stands start dealer process
        ST_DEALER_SECOND_CARD,	-- dealers second card
        ST_DEALER_HIT,		   -- if dealer <17 hit
        ST_DETERMINE_WINNER,   -- compare player and dealer counts
        ST_DISPLAY_RESULT	   -- use leds to show winner/loser
    );
    
    -- Result type
    type result_t is (
        RESULT_NONE,  -- during game
        RESULT_PLAYER_WINS,	-- player wins
        RESULT_DEALER_WINS,	-- dealer wins
        RESULT_PUSH	 -- tie
    );
    
    --card counter array type 8
	-- 2 decks so 8 cards each (1-9) and 32 worth 10
    type card_counter_array_t is array (1 to 10) of unsigned(5 downto 0);
    
    -- ========================================================================
    -- SEVEN-SEGMENT DECODER FUNCTION
    -- ========================================================================
    -- Active low outputs for DE2-115
    -- Segment bit mapping: 6=g, 5=f, 4=e, 3=d, 2=c, 1=b, 0=a
	-- aaa
    --f   b
    -- ggg
    --e   c
    -- ddd
    
    function seven_seg_decode(digit : unsigned(3 downto 0)) return std_logic_vector is
        variable result : std_logic_vector(6 downto 0);
    begin
        case to_integer(digit) is
            when 0 => result := "1000000";  -- 0
            when 1 => result := "1111001";  -- 1
            when 2 => result := "0100100";  -- 2
            when 3 => result := "0110000";  -- 3
            when 4 => result := "0011001";  -- 4
            when 5 => result := "0010010";  -- 5
            when 6 => result := "0000010";  -- 6
            when 7 => result := "1111000";  -- 7
            when 8 => result := "0000000";  -- 8
            when 9 => result := "0010000";  -- 9
            when others => result := "1111111";  -- Blank
        end case;
        return result;
    end function;
    
    -- ========================================================================
    -- SIGNALS
    -- ========================================================================
    
    -- debounced button signals (active high after debouncing)
    signal btn_start_raw    : std_logic;
    signal btn_hit_raw      : std_logic;
    signal btn_stand_raw    : std_logic;
    signal btn_shuffle_raw  : std_logic;
    
	-- debounced signals
    signal btn_start        : std_logic := '0';
    signal btn_hit          : std_logic := '0';
    signal btn_stand        : std_logic := '0';
    signal btn_shuffle      : std_logic := '0';
    
    -- store previous signals
    signal btn_start_prev   : std_logic := '0';
    signal btn_hit_prev     : std_logic := '0';
    signal btn_stand_prev   : std_logic := '0';
    signal btn_shuffle_prev : std_logic := '0';
    
	-- one-clock-cycle pulses
    signal btn_start_pulse  : std_logic;
    signal btn_hit_pulse    : std_logic;
    signal btn_stand_pulse  : std_logic;
    signal btn_shuffle_pulse: std_logic;
    
    -- debounce counters
	-- fill count up when pressed, if it reaches 1M cycles then valid press
    signal debounce_cnt_start   : integer range 0 to DEBOUNCE_CYCLES := 0;
    signal debounce_cnt_hit     : integer range 0 to DEBOUNCE_CYCLES := 0;
    signal debounce_cnt_stand   : integer range 0 to DEBOUNCE_CYCLES := 0;
    signal debounce_cnt_shuffle : integer range 0 to DEBOUNCE_CYCLES := 0;
    
    -- holds current game state
    signal current_state    : game_state_t := ST_IDLE;
    
    -- holds current game result
    signal game_result      : result_t := RESULT_NONE;
    
    -- deck tracker
    signal card_counters    : card_counter_array_t := (
        1 => to_unsigned(CARDS_PER_VALUE, 6),
        2 => to_unsigned(CARDS_PER_VALUE, 6),
        3 => to_unsigned(CARDS_PER_VALUE, 6),
        4 => to_unsigned(CARDS_PER_VALUE, 6),
        5 => to_unsigned(CARDS_PER_VALUE, 6),
        6 => to_unsigned(CARDS_PER_VALUE, 6),
        7 => to_unsigned(CARDS_PER_VALUE, 6),
        8 => to_unsigned(CARDS_PER_VALUE, 6),
        9 => to_unsigned(CARDS_PER_VALUE, 6),
        10 => to_unsigned(TENS_IN_DECK, 6)
    );
	 
	 -- signals for shuffle check
    signal total_cards_remaining : integer range 0 to 104 := 104;
    signal deck_low_warning : std_logic := '0';
    
    -- LFSR for random number generation
    signal lfsr_reg         : std_logic_vector(6 downto 0) := LFSR_SEED;
    signal lfsr_value       : unsigned(6 downto 0);
    
    -- signals to track if card generated is valid
    signal generated_card   : unsigned(3 downto 0) := (others => '0'); --card value
    signal card_request     : std_logic := '0';	 -- 1 when a card is needed
    signal card_ready       : std_logic := '0';	 -- 1 when we have valid card
    
    -- player hand
    signal player_total     : unsigned(5 downto 0) := (others => '0');  -- players count
    signal player_ace_count : unsigned(2 downto 0) := (others => '0');  -- track aces to see if they need to be worth 1 or 11
    signal player_bust      : std_logic := '0';	 -- 1 if player goes over 21(game will end)
    
    -- dealer hand
    signal dealer_total     : unsigned(5 downto 0) := (others => '0'); -- dealer count
    signal dealer_ace_count : unsigned(2 downto 0) := (others => '0'); -- dealer ace count 
    signal dealer_bust      : std_logic := '0';	-- 1 if dealer busts(player wins)
    signal dealer_second_dealt : std_logic := '0'; -- tracks if dealer has gotten their second card(basically has player pressed stand?)
    
    -- timing counters
    signal shuffle_counter  : integer range 0 to SHUFFLE_CYCLES := 0;-- counts from 1-100M, when 100M shuffle is done
    signal deal_delay_cnt   : integer range 0 to DEAL_DELAY_CYCLES := 0; --	counts from 1-12.5M, when 12.5M card has been dealt
    
    -- LED animation counter for shuffle  (right to left led animation)
    signal led_anim_counter : unsigned(24 downto 0) := (others => '0');
    signal led_anim_pattern : unsigned(3 downto 0) := (others => '0');
    
    -- display values (BCD)
    signal player_display_tens  : unsigned(3 downto 0) := (others => '0');-- player 10's column
    signal player_display_ones  : unsigned(3 downto 0) := (others => '0');-- player 1's column
    signal dealer_display_tens  : unsigned(3 downto 0) := (others => '0');-- dealer 10's column
    signal dealer_display_ones  : unsigned(3 downto 0) := (others => '0');-- dealer 1's column
    
    -- Seven-segment patterns (numbers to be displayed)
    signal hex4_pattern     : std_logic_vector(6 downto 0); -- number in players 10's
    signal hex5_pattern     : std_logic_vector(6 downto 0); -- number in players 1's
    signal hex6_pattern     : std_logic_vector(6 downto 0); -- number in dealers 10's
    signal hex7_pattern     : std_logic_vector(6 downto 0);	-- number in dealers 1's
    
    -- LED output registers
    signal ledr_reg         : std_logic_vector(17 downto 0) := (others => '0');	 -- 18 red LEDs
    signal ledg_reg         : std_logic_vector(7 downto 0) := (others => '0');	 -- 8 green LEDs
	
	-- signals for betting
	signal hex0_pattern     : std_logic_vector(6 downto 0); -- 1's
	signal hex1_pattern     : std_logic_vector(6 downto 0);	-- 10's
	signal hex2_pattern     : std_logic_vector(6 downto 0);	-- 100's
	signal hex3_pattern     : std_logic_vector(6 downto 0);	-- 1000's
	signal bet_amount : integer range 0 to 180 := 0; -- total bet ammount
	signal total_cash : integer range 0 to 9999 := 100; -- total player money
	signal bet_display_ones  : unsigned(3 downto 0) := (others => '0');
	signal bet_display_tens  : unsigned(3 downto 0) := (others => '0');
	signal bet_display_hundreds  : unsigned(3 downto 0) := (others => '0');
	signal cash_display_ones  : unsigned(3 downto 0) := (others => '0');
	signal cash_display_tens  : unsigned(3 downto 0) := (others => '0');
	signal cash_display_hundreds  : unsigned(3 downto 0) := (others => '0');
	signal cash_display_thousands  : unsigned(3 downto 0) := (others => '0');

begin

    -- ========================================================================
    -- BUTTON INPUT PROCESSING (Active low buttons on DE2-115)
    -- ========================================================================
    
    -- invert active-low buttons
    btn_start_raw   <= not KEY(0);
    btn_hit_raw     <= not KEY(1);
    btn_stand_raw   <= not KEY(2);
    btn_shuffle_raw <= not KEY(3);
	 
	 deck_low_warning <= '1' when total_cards_remaining < 20 else '0'; -- Deck needs shuffle
    
    -- debounce process for all buttons
    debounce_proc: process(CLOCK_50) 
    begin
        if rising_edge(CLOCK_50) then -- rising edge trigger
            -- start button debounce
            if btn_start_raw = '1' then
                if debounce_cnt_start < DEBOUNCE_CYCLES then -- track how long button has been pressed
                    debounce_cnt_start <= debounce_cnt_start + 1;
                else
                    btn_start <= '1'; --set 1 if pressed for more than 20ms
                end if;
            else
                debounce_cnt_start <= 0;
                btn_start <= '0';
            end if;
            
            -- hit button debounce
            if btn_hit_raw = '1' then
                if debounce_cnt_hit < DEBOUNCE_CYCLES then
                    debounce_cnt_hit <= debounce_cnt_hit + 1;
                else
                    btn_hit <= '1';
                end if;
            else
                debounce_cnt_hit <= 0;
                btn_hit <= '0';
            end if;
            
            -- stand button debounce
            if btn_stand_raw = '1' then
                if debounce_cnt_stand < DEBOUNCE_CYCLES then
                    debounce_cnt_stand <= debounce_cnt_stand + 1;
                else
                    btn_stand <= '1';
                end if;
            else
                debounce_cnt_stand <= 0;
                btn_stand <= '0';
            end if;
            
            -- shuffle button debounce
            if btn_shuffle_raw = '1' then
                if debounce_cnt_shuffle < DEBOUNCE_CYCLES then
                    debounce_cnt_shuffle <= debounce_cnt_shuffle + 1;
                else
                    btn_shuffle <= '1';
                end if;
            else
                debounce_cnt_shuffle <= 0;
                btn_shuffle <= '0';
            end if;
            
            -- save prev inputs
            btn_start_prev   <= btn_start;
            btn_hit_prev     <= btn_hit;
            btn_stand_prev   <= btn_stand;
            btn_shuffle_prev <= btn_shuffle;
        end if;
    end process;
    
    -- Generate button pulses (single clock cycle on press)
    btn_start_pulse   <= btn_start and not btn_start_prev;
    btn_hit_pulse     <= btn_hit and not btn_hit_prev;
    btn_stand_pulse   <= btn_stand and not btn_stand_prev;
    btn_shuffle_pulse <= btn_shuffle and not btn_shuffle_prev;
    
    -- ========================================================================
    -- LFSR RANDOM NUMBER GENERATOR
    -- ========================================================================
    -- 7-bit LFSR with taps at positions 7 and 6 (x^7 + x^6 + 1)
    -- Generates pseudo-random numbers 0-127, we use 0-103 for card selection
    
    lfsr_proc: process(CLOCK_50)
        variable feedback : std_logic;
    begin
        if rising_edge(CLOCK_50) then
            -- XOR feedback from bits 6 and 5 (positions 7 and 6 in 1-indexed)
            feedback := lfsr_reg(6) xor lfsr_reg(5);
            -- Shift and insert feedback
            lfsr_reg <= lfsr_reg(5 downto 0) & feedback;
        end if;
    end process;
    
    lfsr_value <= unsigned(lfsr_reg);
    
    -- ========================================================================
    -- CARD GENERATION LOGIC
    -- ========================================================================
    -- Maps LFSR value to card value and checks availability
    
    card_gen_proc: process(CLOCK_50)
    variable lfsr_int       : integer range 0 to 127;
    variable initial_value  : integer range 1 to 10;
    variable check_value    : integer range 0 to 20;
    variable found          : boolean;
	begin
	    if rising_edge(CLOCK_50) then
	        -- CHANGED: Only clear card_ready when request is cleared
	        if card_request = '0' then
	            card_ready <= '0';
	        end if;
	        
	        if card_request = '1' and card_ready = '0' then
	            -- Convert LFSR to card value
	            lfsr_int := to_integer(lfsr_value);
	            
	            -- Map ranges: 1-8(Ace), 9-16(2), ..., 65-72(9), 73-104(10)
	            if lfsr_int > 104 then
	                -- Out of range, use modulo
	                lfsr_int := (lfsr_int mod 104) * 4;
	            end if;
	            
	            if lfsr_int < 9 then
	                initial_value := 1;  -- Ace
	            elsif lfsr_int < 17 then
	                initial_value := 2;
	            elsif lfsr_int < 25 then
	                initial_value := 3;
	            elsif lfsr_int < 33 then
	                initial_value := 4;
	            elsif lfsr_int < 41 then
	                initial_value := 5;
	            elsif lfsr_int < 49 then
	                initial_value := 6;
	            elsif lfsr_int < 57 then
	                initial_value := 7;
	            elsif lfsr_int < 65 then
	                initial_value := 8;
	            elsif lfsr_int < 73 then
	                initial_value := 9;
	            else
	                initial_value := 10;
	            end if;
	            
	            -- Check if card is available, search for nearest if not
	            found := false;
	            
	            -- First check the initial value
	            if card_counters(initial_value) > 0 then
	                generated_card <= to_unsigned(initial_value, 4);
	                card_ready <= '1';
	                found := true;
	            else
	                -- Search alternating up and down using unrolled checks
	                -- Check +1, -1
	                if not found then
	                    check_value := initial_value + 1;
	                    if check_value <= 10 and card_counters(check_value) > 0 then
	                        generated_card <= to_unsigned(check_value, 4);
	                        card_ready <= '1';
	                        found := true;
	                    end if;
	                end if;
	                if not found then
	                    check_value := initial_value - 1;
	                    if check_value >= 1 and card_counters(check_value) > 0 then
	                        generated_card <= to_unsigned(check_value, 4);
	                        card_ready <= '1';
	                        found := true;
	                    end if;
	                end if;
	                -- Check +2, -2
	                if not found then
	                    check_value := initial_value + 2;
	                    if check_value <= 10 and card_counters(check_value) > 0 then
	                        generated_card <= to_unsigned(check_value, 4);
	                        card_ready <= '1';
	                        found := true;
	                    end if;
	                end if;
	                if not found then
	                    check_value := initial_value - 2;
	                    if check_value >= 1 and card_counters(check_value) > 0 then
	                        generated_card <= to_unsigned(check_value, 4);
	                        card_ready <= '1';
	                        found := true;
	                    end if;
	                end if;
	                -- Check +3, -3
	                if not found then
	                    check_value := initial_value + 3;
	                    if check_value <= 10 and card_counters(check_value) > 0 then
	                        generated_card <= to_unsigned(check_value, 4);
	                        card_ready <= '1';
	                        found := true;
	                    end if;
	                end if;
	                if not found then
	                    check_value := initial_value - 3;
	                    if check_value >= 1 and card_counters(check_value) > 0 then
	                        generated_card <= to_unsigned(check_value, 4);
	                        card_ready <= '1';
	                        found := true;
	                    end if;
	                end if;
	                -- Check +4, -4
	                if not found then
	                    check_value := initial_value + 4;
	                    if check_value <= 10 and card_counters(check_value) > 0 then
	                        generated_card <= to_unsigned(check_value, 4);
	                        card_ready <= '1';
	                        found := true;
	                    end if;
	                end if;
	                if not found then
	                    check_value := initial_value - 4;
	                    if check_value >= 1 and card_counters(check_value) > 0 then
	                        generated_card <= to_unsigned(check_value, 4);
	                        card_ready <= '1';
	                        found := true;
	                    end if;
	                end if;
	                -- Check +5, -5
	                if not found then
	                    check_value := initial_value + 5;
	                    if check_value <= 10 and card_counters(check_value) > 0 then
	                        generated_card <= to_unsigned(check_value, 4);
	                        card_ready <= '1';
	                        found := true;
	                    end if;
	                end if;
	                if not found then
	                    check_value := initial_value - 5;
	                    if check_value >= 1 and card_counters(check_value) > 0 then
	                        generated_card <= to_unsigned(check_value, 4);
	                        card_ready <= '1';
	                        found := true;
	                    end if;
	                end if;
	                -- Check +6, -6
	                if not found then
	                    check_value := initial_value + 6;
	                    if check_value <= 10 and card_counters(check_value) > 0 then
	                        generated_card <= to_unsigned(check_value, 4);
	                        card_ready <= '1';
	                        found := true;
	                    end if;
	                end if;
	                if not found then
	                    check_value := initial_value - 6;
	                    if check_value >= 1 and card_counters(check_value) > 0 then
	                        generated_card <= to_unsigned(check_value, 4);
	                        card_ready <= '1';
	                        found := true;
	                    end if;
	                end if;
	                -- Check +7, -7
	                if not found then
	                    check_value := initial_value + 7;
	                    if check_value <= 10 and card_counters(check_value) > 0 then
	                        generated_card <= to_unsigned(check_value, 4);
	                        card_ready <= '1';
	                        found := true;
	                    end if;
	                end if;
	                if not found then
	                    check_value := initial_value - 7;
	                    if check_value >= 1 and card_counters(check_value) > 0 then
	                        generated_card <= to_unsigned(check_value, 4);
	                        card_ready <= '1';
	                        found := true;
	                    end if;
	                end if;
	                -- Check +8, -8
	                if not found then
	                    check_value := initial_value + 8;
	                    if check_value <= 10 and card_counters(check_value) > 0 then
	                        generated_card <= to_unsigned(check_value, 4);
	                        card_ready <= '1';
	                        found := true;
	                    end if;
	                end if;
	                if not found then
	                    check_value := initial_value - 8;
	                    if check_value >= 1 and card_counters(check_value) > 0 then
	                        generated_card <= to_unsigned(check_value, 4);
	                        card_ready <= '1';
	                        found := true;
	                    end if;
	                end if;
	                -- Check +9, -9
	                if not found then
	                    check_value := initial_value + 9;
	                    if check_value <= 10 and card_counters(check_value) > 0 then
	                        generated_card <= to_unsigned(check_value, 4);
	                        card_ready <= '1';
	                        found := true;
	                    end if;
	                end if;
	                if not found then
	                    check_value := initial_value - 9;
	                    if check_value >= 1 and card_counters(check_value) > 0 then
	                        generated_card <= to_unsigned(check_value, 4);
	                        card_ready <= '1';
	                        found := true;
	                    end if;
	                end if;
	            end if;
	            
	            -- If still not found, no cards left (shouldn't happen in normal play)
	            if not found then
	                generated_card <= to_unsigned(0, 4);  -- Invalid
	                card_ready <= '1';
	            end if;
	        end if;
	    end if;
	end process;
    
    -- ========================================================================
    -- BINARY TO BCD CONVERSION
    -- ========================================================================
    -- Convert 6-bit totals to 2-digit BCD for display
    
    bcd_conv_proc: process(player_total, dealer_total, bet_amount, total_cash)
        variable p_total_int : integer range 0 to 63;
        variable d_total_int : integer range 0 to 63;
		variable bet_total_int : integer range 0 to 180;
        variable money_total_int : integer range 0 to 9999;
    begin
        p_total_int := to_integer(player_total);
        d_total_int := to_integer(dealer_total);
		
		bet_total_int  := bet_amount;
		money_total_int  := total_cash;
        
        -- player display
        player_display_tens <= to_unsigned(p_total_int / 10, 4);
        player_display_ones <= to_unsigned(p_total_int mod 10, 4);
        
        -- dealer display
        dealer_display_tens <= to_unsigned(d_total_int / 10, 4);
        dealer_display_ones <= to_unsigned(d_total_int mod 10, 4);
		
		--bet display
		bet_display_hundreds <= to_unsigned(bet_total_int / 100, 4);
		bet_display_tens	 <= to_unsigned((bet_total_int / 10) mod 10, 4);
		bet_display_ones	 <= to_unsigned(bet_total_int mod 10, 4);
		
		--cash display
		cash_display_thousands <= to_unsigned(money_total_int / 1000, 4);
		cash_display_hundreds <= to_unsigned((money_total_int / 100) mod 10, 4);
		cash_display_tens	 <= to_unsigned((money_total_int / 10) mod 10, 4);
		cash_display_ones	 <= to_unsigned(money_total_int mod 10, 4);
		
    end process;
    
    -- ========================================================================
    -- SEVEN-SEGMENT DISPLAY OUTPUTS
    -- ========================================================================
    
    -- generate seven-segment patterns
    hex4_pattern <= seven_seg_decode(player_display_ones);
    hex5_pattern <= seven_seg_decode(player_display_tens);
    hex6_pattern <= seven_seg_decode(dealer_display_ones);
    hex7_pattern <= seven_seg_decode(dealer_display_tens);
    
    -- output to displays
    HEX4 <= hex4_pattern;
    HEX5 <= hex5_pattern;
    HEX6 <= hex6_pattern;
    HEX7 <= hex7_pattern;
	HEX0 <= hex0_pattern;
	HEX1 <= hex1_pattern;
	HEX2 <= hex2_pattern;
	HEX3 <= hex3_pattern;
	
	-- ========================================================================
    -- GENERATE BET AMOUNTS
    -- ========================================================================
	
	process_name: process(SW)
		variable temp_bet : integer range 0 to 180;
	
	begin
		
		temp_bet  := 0;
		
		if SW(0) = '1' then
			temp_bet := temp_bet + 10;
		end if;
		if SW(1) = '1' then
			temp_bet := temp_bet + 20; 
		end if;
		if SW(2) = '1' then
			temp_bet := temp_bet + 50;
		end if;
		if SW(3) = '1' then
			temp_bet := temp_bet + 100;
		end if;
			
		if temp_bet <= total_cash then
			bet_amount <= temp_bet;
		else
			bet_amount <= total_cash;
		end if;
		
		
		
	end process;
	
	
	-- ========================================================================
    -- PROCESS FOR CHECKING IF SHUFFLE IS NEEDED
    -- ========================================================================
	 deck_count_proc: process(card_counters)
		variable total : integer range 0 to 104;
	 begin
			total := 0;
			for i in 1 to 10 loop
				total := total + to_integer(card_counters(i));
			end loop;
			total_cards_remaining <= total;
	 end process;
    
    -- ========================================================================
    -- MAIN GAME STATE MACHINE
    -- ========================================================================
    
    game_fsm_proc: process(CLOCK_50)
        variable new_total      : unsigned(5 downto 0); --temp total storage
        variable new_ace_count  : unsigned(2 downto 0);	-- temp ace count storage
        variable card_value     : integer range 0 to 15; -- value of card just dealt
        variable temp_total     : unsigned(5 downto 0);	-- for ace conversions
        variable temp_ace       : unsigned(2 downto 0);	-- for ace conversions
    begin
        if rising_edge(CLOCK_50) then
            -- default: no card request
            card_request <= '0';
            
            case current_state is
                
                -- ============================================================
                -- IDLE STATE
                -- ============================================================
                when ST_IDLE =>
						 game_result <= RESULT_NONE;
						 
						 --if out of cash set back to 100
						 if total_cash = 0 then
							 total_cash <= 100;
						 end if;
						 -- generate seven-segment patterns
						 hex0_pattern <= seven_seg_decode(bet_display_ones);
						 hex1_pattern <= seven_seg_decode(bet_display_tens);
						 hex2_pattern <= seven_seg_decode(bet_display_hundreds);
						 hex3_pattern <= seven_seg_decode(to_unsigned(0, 4));
						
						 -- Force shuffle if deck is low
						 if total_cards_remaining < 20 then
							  player_total <= (others => '0');
							  player_ace_count <= (others => '0');
							  player_bust <= '0';
							  dealer_total <= (others => '0');
							  dealer_ace_count <= (others => '0');
							  dealer_bust <= '0';
							  dealer_second_dealt <= '0';
							  current_state <= ST_SHUFFLE;
							  shuffle_counter <= 0;
						 else
							  -- Normal reset
							  player_total <= (others => '0');
							  player_ace_count <= (others => '0');
							  player_bust <= '0';
							  dealer_total <= (others => '0');
							  dealer_ace_count <= (others => '0');
							  dealer_bust <= '0';
							  dealer_second_dealt <= '0';
							  
							  if btn_start_pulse = '1' then
									current_state <= ST_DEAL_INITIAL;
							  elsif btn_shuffle_pulse = '1' then
									current_state <= ST_SHUFFLE;
									shuffle_counter <= 0;
							  end if;
						 end if;
                
                -- ============================================================
                -- SHUFFLE STATE
                -- ============================================================
                when ST_SHUFFLE =>
                    -- Reset all card counters
                    card_counters(1) <= to_unsigned(CARDS_PER_VALUE, 6);
                    card_counters(2) <= to_unsigned(CARDS_PER_VALUE, 6);
                    card_counters(3) <= to_unsigned(CARDS_PER_VALUE, 6);
                    card_counters(4) <= to_unsigned(CARDS_PER_VALUE, 6);
                    card_counters(5) <= to_unsigned(CARDS_PER_VALUE, 6);
                    card_counters(6) <= to_unsigned(CARDS_PER_VALUE, 6);
                    card_counters(7) <= to_unsigned(CARDS_PER_VALUE, 6);
                    card_counters(8) <= to_unsigned(CARDS_PER_VALUE, 6);
                    card_counters(9) <= to_unsigned(CARDS_PER_VALUE, 6);
                    card_counters(10) <= to_unsigned(TENS_IN_DECK, 6);
					
                    
                    -- Shuffle animation counter
                    if shuffle_counter < SHUFFLE_CYCLES then
                        shuffle_counter <= shuffle_counter + 1;
                        -- Animate LEDs
                        led_anim_counter <= led_anim_counter + 1;
                        if led_anim_counter(22 downto 0) = 0 then
                            led_anim_pattern <= led_anim_pattern + 1;
                        end if;
                    else
                        current_state <= ST_IDLE;
                        shuffle_counter <= 0;
                        led_anim_pattern <= (others => '0');
                    end if;
                
                -- ============================================================
                -- DEAL INITIAL CARDS
                -- ============================================================
                when ST_DEAL_INITIAL =>
                    deal_delay_cnt <= 0;
                    current_state <= ST_DEAL_PLAYER_1;
                
                -- Deal first card to player
                when ST_DEAL_PLAYER_1 =>
                    card_request <= '1';
                    if card_ready = '1' then
                        card_value := to_integer(generated_card);
                        
                        -- Decrement card counter
                        if card_value > 0 and card_value <= 10 then
                            card_counters(card_value) <= card_counters(card_value) - 1;
                        end if;
                        
                        -- Add to player total
                        if card_value = 1 then
                            -- Ace: add 11, increment soft ace count
                            player_total <= player_total + 11;
                            player_ace_count <= player_ace_count + 1;
                        else
                            player_total <= player_total + to_unsigned(card_value, 6);
                        end if;
                        
								card_request <= '0';
                        deal_delay_cnt <= 0;
                        current_state <= ST_DEAL_PLAYER_2;
                    end if;
                
                -- Deal second card to player (with delay)
                when ST_DEAL_PLAYER_2 =>
                    if deal_delay_cnt < DEAL_DELAY_CYCLES then
                        deal_delay_cnt <= deal_delay_cnt + 1;
                    else
                        card_request <= '1';
                        if card_ready = '1' then
                            card_value := to_integer(generated_card);
                            
                            -- Decrement card counter
                            if card_value > 0 and card_value <= 10 then
                                card_counters(card_value) <= card_counters(card_value) - 1;
                            end if;
                            
                            -- Add to player total with ace handling
                            if card_value = 1 then
                                new_total := player_total + 11;
                                new_ace_count := player_ace_count + 1;
                            else
                                new_total := player_total + to_unsigned(card_value, 6);
                                new_ace_count := player_ace_count;
                            end if;
                            
                            -- Adjust for bust with soft aces (unrolled - max 4 aces)
                            temp_total := new_total;
                            temp_ace := new_ace_count;
                            if temp_total > 21 and temp_ace > 0 then
                                temp_total := temp_total - 10;
                                temp_ace := temp_ace - 1;
                            end if;
                            if temp_total > 21 and temp_ace > 0 then
                                temp_total := temp_total - 10;
                                temp_ace := temp_ace - 1;
                            end if;
                            if temp_total > 21 and temp_ace > 0 then
                                temp_total := temp_total - 10;
                                temp_ace := temp_ace - 1;
                            end if;
                            if temp_total > 21 and temp_ace > 0 then
                                temp_total := temp_total - 10;
                                temp_ace := temp_ace - 1;
                            end if;
                            
                            player_total <= temp_total;
                            player_ace_count <= temp_ace;
                            card_request <= '0';
                            deal_delay_cnt <= 0;
                            current_state <= ST_DEAL_DEALER_1;
                        end if;
                    end if;
                
                -- Deal first card to dealer
                when ST_DEAL_DEALER_1 =>
                    if deal_delay_cnt < DEAL_DELAY_CYCLES then
                        deal_delay_cnt <= deal_delay_cnt + 1;
                    else
                        card_request <= '1';
                        if card_ready = '1' then
                            card_value := to_integer(generated_card);
                            
                            -- Decrement card counter
                            if card_value > 0 and card_value <= 10 then
                                card_counters(card_value) <= card_counters(card_value) - 1;
                            end if;
                            
                            -- Add to dealer total
                            if card_value = 1 then
                                dealer_total <= dealer_total + 11;
                                dealer_ace_count <= dealer_ace_count + 1;
                            else
                                dealer_total <= dealer_total + to_unsigned(card_value, 6);
                            end if;
                            card_request <= '0';
                            current_state <= ST_PLAYER_TURN;
                        end if;
                    end if;
                
                -- ============================================================
                -- PLAYER TURN
                -- ============================================================
                when ST_PLAYER_TURN =>
                    -- Check for blackjack (21)
                    if player_total = 21 then
                        current_state <= ST_DEALER_TURN;
                    elsif btn_hit_pulse = '1' then
                        card_request <= '1';
                        current_state <= ST_PLAYER_HIT;
                    elsif btn_stand_pulse = '1' then
                        current_state <= ST_DEALER_TURN;
                    end if;
                
                -- Process player hit
                when ST_PLAYER_HIT =>
                    card_request <= '1';
                    if card_ready = '1' then
                        card_value := to_integer(generated_card);
                        
                        -- Decrement card counter
                        if card_value > 0 and card_value <= 10 then
                            card_counters(card_value) <= card_counters(card_value) - 1;
                        end if;
                        
                        -- Add to player total with ace handling
                        if card_value = 1 then
                            new_total := player_total + 11;
                            new_ace_count := player_ace_count + 1;
                        else
                            new_total := player_total + to_unsigned(card_value, 6);
                            new_ace_count := player_ace_count;
                        end if;
                        
                        -- Adjust for bust with soft aces (unrolled - max 4 aces)
                        temp_total := new_total;
                        temp_ace := new_ace_count;
                        if temp_total > 21 and temp_ace > 0 then
                            temp_total := temp_total - 10;
                            temp_ace := temp_ace - 1;
                        end if;
                        if temp_total > 21 and temp_ace > 0 then
                            temp_total := temp_total - 10;
                            temp_ace := temp_ace - 1;
                        end if;
                        if temp_total > 21 and temp_ace > 0 then
                            temp_total := temp_total - 10;
                            temp_ace := temp_ace - 1;
                        end if;
                        if temp_total > 21 and temp_ace > 0 then
                            temp_total := temp_total - 10;
                            temp_ace := temp_ace - 1;
                        end if;
                        
                        player_total <= temp_total;
                        player_ace_count <= temp_ace;
                        card_request <= '0';
                        -- Check result
                        if temp_total > 21 then
                            player_bust <= '1';
                            current_state <= ST_DETERMINE_WINNER;
                        elsif temp_total = 21 then
                            current_state <= ST_DEALER_TURN;
                        else
                            current_state <= ST_PLAYER_TURN;
                        end if;
                    end if;
                
                -- ============================================================
                -- DEALER TURN
                -- ============================================================
                when ST_DEALER_TURN =>
                    deal_delay_cnt <= 0;
                    -- Deal second card if not yet dealt
                    if dealer_second_dealt = '0' then
                        card_request <= '1';
                        current_state <= ST_DEALER_SECOND_CARD;
                    else
                        -- Check if dealer should hit (< 17)
                        if dealer_total < 17 then
                            card_request <= '1';
                            current_state <= ST_DEALER_HIT;
                        else
                            current_state <= ST_DETERMINE_WINNER;
                        end if;
                    end if;
                
                -- Deal dealer's second card
                when ST_DEALER_SECOND_CARD =>
                    card_request <= '1';
                    if card_ready = '1' then
                        card_value := to_integer(generated_card);
                        
                        -- Decrement card counter
                        if card_value > 0 and card_value <= 10 then
                            card_counters(card_value) <= card_counters(card_value) - 1;
                        end if;
                        
                        -- Add to dealer total with ace handling
                        if card_value = 1 then
                            new_total := dealer_total + 11;
                            new_ace_count := dealer_ace_count + 1;
                        else
                            new_total := dealer_total + to_unsigned(card_value, 6);
                            new_ace_count := dealer_ace_count;
                        end if;
                        
                        -- Adjust for bust with soft aces (unrolled - max 4 aces)
                        temp_total := new_total;
                        temp_ace := new_ace_count;
                        if temp_total > 21 and temp_ace > 0 then
                            temp_total := temp_total - 10;
                            temp_ace := temp_ace - 1;
                        end if;
                        if temp_total > 21 and temp_ace > 0 then
                            temp_total := temp_total - 10;
                            temp_ace := temp_ace - 1;
                        end if;
                        if temp_total > 21 and temp_ace > 0 then
                            temp_total := temp_total - 10;
                            temp_ace := temp_ace - 1;
                        end if;
                        if temp_total > 21 and temp_ace > 0 then
                            temp_total := temp_total - 10;
                            temp_ace := temp_ace - 1;
                        end if;
                        
                        dealer_total <= temp_total;
                        dealer_ace_count <= temp_ace;
                        dealer_second_dealt <= '1';
                        card_request <= '0';
                        -- Check if dealer busts or should continue
                        if temp_total > 21 then
                            dealer_bust <= '1';
                            current_state <= ST_DETERMINE_WINNER;
                        elsif temp_total < 17 then
                            deal_delay_cnt <= 0;
                            current_state <= ST_DEALER_HIT;
                        else
                            current_state <= ST_DETERMINE_WINNER;
                        end if;
                    end if;
                
                -- Process dealer hit
                when ST_DEALER_HIT =>
                    if deal_delay_cnt < DEAL_DELAY_CYCLES then
                        deal_delay_cnt <= deal_delay_cnt + 1;
                    else
                        card_request <= '1';
                        if card_ready = '1' then
                            card_value := to_integer(generated_card);
                            
                            -- Decrement card counter
                            if card_value > 0 and card_value <= 10 then
                                card_counters(card_value) <= card_counters(card_value) - 1;
                            end if;
                            
                            -- Add to dealer total with ace handling
                            if card_value = 1 then
                                new_total := dealer_total + 11;
                                new_ace_count := dealer_ace_count + 1;
                            else
                                new_total := dealer_total + to_unsigned(card_value, 6);
                                new_ace_count := dealer_ace_count;
                            end if;
                            
                            -- Adjust for bust with soft aces (unrolled - max 4 aces)
                            temp_total := new_total;
                            temp_ace := new_ace_count;
                            if temp_total > 21 and temp_ace > 0 then
                                temp_total := temp_total - 10;
                                temp_ace := temp_ace - 1;
                            end if;
                            if temp_total > 21 and temp_ace > 0 then
                                temp_total := temp_total - 10;
                                temp_ace := temp_ace - 1;
                            end if;
                            if temp_total > 21 and temp_ace > 0 then
                                temp_total := temp_total - 10;
                                temp_ace := temp_ace - 1;
                            end if;
                            if temp_total > 21 and temp_ace > 0 then
                                temp_total := temp_total - 10;
                                temp_ace := temp_ace - 1;
                            end if;
                            
                            dealer_total <= temp_total;
                            dealer_ace_count <= temp_ace;
                            deal_delay_cnt <= 0;
                            card_request <= '0';
                            -- Check result
                            if temp_total > 21 then
                                dealer_bust <= '1';
                                current_state <= ST_DETERMINE_WINNER;
                            elsif temp_total < 17 then
                                current_state <= ST_DEALER_HIT;
                            else
                                current_state <= ST_DETERMINE_WINNER;
                            end if;
                        end if;
                    end if;
                
                -- ============================================================
                -- DETERMINE WINNER
                -- ============================================================
                when ST_DETERMINE_WINNER =>
                    if player_bust = '1' then
                        -- Player busted, dealer wins
						total_cash <= total_cash - bet_amount;
                        game_result <= RESULT_DEALER_WINS;
                    elsif dealer_bust = '1' then
                        -- Dealer busted, player wins
						total_cash <= total_cash + bet_amount;
                        game_result <= RESULT_PLAYER_WINS;
                    elsif player_total = 21 then
                        -- Player has 21, player wins (even if dealer also has 21)
						total_cash <= total_cash + bet_amount;
                        game_result <= RESULT_PLAYER_WINS;
                    elsif player_total > dealer_total then
                        -- Player has higher total
						total_cash <= total_cash + bet_amount;
                        game_result <= RESULT_PLAYER_WINS;
                    elsif dealer_total > player_total then
                        -- Dealer has higher total
						total_cash <= total_cash - bet_amount;
                        game_result <= RESULT_DEALER_WINS;
                    else
                        -- Equal totals (and player doesn't have 21)
                        game_result <= RESULT_PUSH;
                    end if;
                    
                    current_state <= ST_DISPLAY_RESULT;
                
                -- ============================================================
                -- DISPLAY RESULT
                -- ============================================================
                when ST_DISPLAY_RESULT =>
				
					-- generate seven-segment patterns
					hex0_pattern <= seven_seg_decode(cash_display_ones);
					hex1_pattern <= seven_seg_decode(cash_display_tens);
					hex2_pattern <= seven_seg_decode(cash_display_hundreds);
					hex3_pattern <= seven_seg_decode(cash_display_thousands);
					
					-- Increment animation counter for win animation
				    led_anim_counter <= led_anim_counter + 1;
				    if led_anim_counter(22 downto 0) = 0 then
				        led_anim_pattern <= led_anim_pattern + 1;
				    end if;
					
					-- Wait for start button to return to idle
                    if btn_start_pulse = '1' then
                        current_state <= ST_IDLE;
                    end if;
                
                when others =>
                    current_state <= ST_IDLE;
                    
            end case;
        end if;
    end process;
    
    -- ========================================================================
    -- LED OUTPUT CONTROL
    -- ========================================================================
    
    led_proc: process(CLOCK_50)
    begin
        if rising_edge(CLOCK_50) then
            -- Default: all LEDs off
            ledr_reg <= (others => '0');
            ledg_reg <= (others => '0');
            
            case current_state is
                when ST_SHUFFLE =>
                    -- Shuffle animation: shifting pattern
                    case to_integer(led_anim_pattern(2 downto 0)) is
                        when 0 => ledr_reg <= "000000000000000011";
                        when 1 => ledr_reg <= "000000000000001100";
                        when 2 => ledr_reg <= "000000000000110000";
                        when 3 => ledr_reg <= "000000000011000000";
                        when 4 => ledr_reg <= "000000001100000000";
                        when 5 => ledr_reg <= "000000110000000000";
                        when 6 => ledr_reg <= "000011000000000000";
                        when 7 => ledr_reg <= "001100000000000000";
                        when others => ledr_reg <= (others => '0');
                    end case;
                    
                when ST_DISPLAY_RESULT =>
                    case game_result is
                        when RESULT_PLAYER_WINS =>
                            --pattern on red LEDs
                            case to_integer(led_anim_pattern(2 downto 0)) is
		                        when 0 => ledg_reg <= "10101010";
		                        when 1 => ledg_reg <= "01010101";
		                        when 2 => ledg_reg <= "10101010";
		                        when 3 => ledg_reg <= "01010101";
		                        when 4 => ledg_reg <= "10101010";
		                        when 5 => ledg_reg <= "01010101";
		                        when 6 => ledg_reg <= "10101010";
		                        when 7 => ledg_reg <= "01010101";
		                        when others => ledg_reg <= (others => '0');
		                    end case;
                            
                        when RESULT_DEALER_WINS =>
                            --pattern on red LEDs
                            case to_integer(led_anim_pattern(2 downto 0)) is
		                        when 0 => ledr_reg <= "110011001100110011";
		                        when 1 => ledr_reg <= "001100110011001100";
		                        when 2 => ledr_reg <= "110011001100110011";
		                        when 3 => ledr_reg <= "001100110011001100";
		                        when 4 => ledr_reg <= "110011001100110011";
		                        when 5 => ledr_reg <= "001100110011001100";
		                        when 6 => ledr_reg <= "110011001100110011";
		                        when 7 => ledr_reg <= "001100110011001100";
		                        when others => ledr_reg <= (others => '0');
		                    end case;
                            
                        when RESULT_PUSH =>
                            -- Alternating pattern for tie
                            ledr_reg <= "010101010101010101";
                            ledg_reg <= "10101010";
                            
                        when others =>
                            null;
                    end case;
                    
                when ST_PLAYER_TURN =>
                    -- Indicate player's turn with green LEDs
                    ledg_reg <= "00001111";
                    
                when ST_DEALER_TURN | ST_DEALER_SECOND_CARD | ST_DEALER_HIT =>
                    -- Indicate dealer's turn with red LEDs
                    ledr_reg <= "000000000000001111";
                    
                when others =>
                    null;
            end case;
        end if;
    end process;
    
    -- Output LED registers
    LEDR <= ledr_reg;
    LEDG <= ledg_reg;

end architecture rtl;
