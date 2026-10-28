package game

import "core:time"

// The simulation runs at a fixed rate on both sides; the server announces it
// in the handshake and the client refuses a server with a different one.

TICK_RATE :: 30
INTERPOLATION_TICKS :: 3 // how far behind the newest update others are drawn (100 ms at 30 Hz: covers a late or lost update)
TICK_DURATION :: time.Second / TICK_RATE
