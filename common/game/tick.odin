package game

import "core:time"

// The simulation runs at a fixed rate on both sides; the server announces it
// in the handshake and the client refuses a server with a different one.

TICK_RATE :: 30
TICK_DURATION :: time.Second / TICK_RATE
