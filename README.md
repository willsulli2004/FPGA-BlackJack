# BlackJack FPGA Game for DE2-115

A complete hardware implementation of a 2-deck Blackjack game written in VHDL for the Altera/Intel DE2-115 FPGA Development Board.

## Hardware Requirements

- **Board:** Terasic DE2-115 Development Board
- **FPGA:** Cyclone IV E EP4CE115F29C7
- **Clock:** 50 MHz onboard oscillator

## Features

- Full 2-deck (104 card) blackjack simulation
- LFSR-based pseudo-random card generation
- Proper ace handling (automatic 11→1 conversion when busting)
- Card counting/tracking to prevent duplicate draws
- Hardware button debouncing (20ms)
- Seven-segment display score output
- LED indicators for game state and results
- 2-second shuffle animation

## Controls

| Button | Function |
|--------|----------|
| KEY0 | Deal / Start New Game |
| KEY1 | Hit (request another card) |
| KEY2 | Stand (end player turn) |
| KEY3 | Shuffle Deck |

### Button Behavior by State

- **IDLE:** KEY0 starts game, KEY3 shuffles deck
- **Player Turn:** KEY1 hits, KEY2 stands
- **Result Display:** KEY0 starts new game

## Display Layout

```
    HEX7 HEX6       HEX5 HEX4
    ┌───┐┌───┐     ┌───┐┌───┐
    │ D ││ D │     │ P ││ P │
    │10s││ 1s│     │10s││ 1s│
    └───┘└───┘     └───┘└───┘
      DEALER         PLAYER
```

- **HEX5-HEX4:** Player's current score (00-31)
- **HEX7-HEX6:** Dealer's current score (00-31)

## LED Indicators

| State | Red LEDs (LEDR) | Green LEDs (LEDG) |
|-------|-----------------|-------------------|
| Shuffle | Animated sweep pattern | Off |
| Player Turn | Off | Lower 4 on |
| Dealer Turn | Lower 4 on | Off |
| Player Wins | Alternating pattern | All on |
| Dealer Wins | All on | Off |
| Push (Tie) | Alternating pattern | Alternating pattern |

## Game Rules Implemented

### Card Values
- **Aces:** Worth 11, automatically converted to 1 if hand would bust
- **2-9:** Face value
- **10, J, Q, K:** Worth 10

### Deck Composition (2 decks combined)
- 8 cards each of values 1-9 (Aces through 9s)
- 32 cards of value 10 (10s, Jacks, Queens, Kings)
- Total: 104 cards

### Gameplay Flow
1. Press KEY3 to shuffle (required before first game)
2. Press KEY0 to deal initial cards
3. Player receives 2 cards, dealer receives 1 visible card
4. Player chooses to Hit (KEY1) or Stand (KEY2)
5. If player busts (>21), dealer wins immediately
6. If player stands or hits 21, dealer plays
7. Dealer hits until reaching 17 or higher
8. Winner determined by comparing totals

### Win Conditions
- **Player Wins:** Dealer busts, player has higher total, or player has 21
- **Dealer Wins:** Player busts, or dealer has higher total
- **Push (Tie):** Equal totals (except player 21 always wins)

## Project Files

| File | Description |
|------|-------------|
| `BlackJack.vhd` | Main VHDL source code |
| `blackjack_pins.qsf` | Quartus pin assignments |

## Installation & Compilation

### 1. Create New Quartus Project
- Open Quartus Prime
- File → New Project Wizard
- Set project name to `BlackJack`
- Select device: **Cyclone IV E → EP4CE115F29C7**

### 2. Add Source Files
- Project → Add/Remove Files in Project
- Add `BlackJack.vhd`

### 3. Import Pin Assignments
Either:
- **Option A:** Assignments → Import Assignments → Select `blackjack_pins.qsf`
- **Option B:** Copy contents of `blackjack_pins.qsf` into your project's `.qsf` file

### 4. Compile
- Processing → Start Compilation
- Wait for successful completion

### 5. Program FPGA
- Tools → Programmer
- Hardware Setup → Select USB-Blaster
- Add `BlackJack.sof` file
- Click Start

## Technical Details

### State Machine

```
IDLE → SHUFFLE → IDLE
  ↓
DEAL_INITIAL → DEAL_PLAYER_1 → DEAL_PLAYER_2 → DEAL_DEALER_1
                                                      ↓
                                               PLAYER_TURN ←───┐
                                                  ↓    ↓       │
                                            (stand) (hit)      │
                                                  ↓    ↓       │
                                           DEALER_TURN  PLAYER_HIT
                                                  ↓            ↓
                                      DEALER_SECOND_CARD   (if <21)
                                                  ↓
                                             DEALER_HIT ←──┐
                                                  ↓        │
                                              (if <17) ────┘
                                                  ↓
                                         DETERMINE_WINNER
                                                  ↓
                                          DISPLAY_RESULT → IDLE
```

### Clock Domains
- Single 50 MHz clock domain
- All logic synchronous to rising edge

### Timing Constants
- Button debounce: 20ms (1,000,000 cycles)
- Shuffle animation: 2 seconds (100,000,000 cycles)
- Card deal delay: 250ms (12,500,000 cycles)

### Random Number Generation
- 7-bit Linear Feedback Shift Register (LFSR)
- Polynomial: x⁷ + x⁶ + 1
- Continuously cycles, sampled when card needed
- Maps 0-103 to card values with weighted distribution for 10s

## Troubleshooting

### "Illegal location assignment" errors
- Ensure device is set to **EP4CE115F29C7**
- Assignments → Device → Cyclone IV E → EP4CE115F29C7

### Display shows wrong numbers
- Check that seven-segment displays are active-low
- Verify pin assignments match physical board

### Buttons not responding
- Buttons are active-low with hardware debouncing
- Hold button for at least 20ms

### Cards seem non-random
- LFSR runs continuously at 50 MHz
- Randomness comes from human timing of button presses
- Press KEY3 to shuffle before starting

## License

This project is provided for educational purposes.

## Version History

- **v1.0** - Initial release with full game functionality
