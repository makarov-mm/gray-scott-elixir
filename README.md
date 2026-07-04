# Gray-Scott: Elixir backend + Swift/Metal frontend

Gray-Scott reaction-diffusion where the grid is **domain-decomposed across
supervised Elixir processes**: 8 horizontal strips, each strip a `GenServer`
owning its rows, halo rows exchanged through messages every step — the actor
version of an MPI stencil computation. A macOS app renders the V field over
TCP as a Metal texture with a colormap shader.

The demo: press **K** — a random strip process is killed. Its part of the
pattern vanishes (the supervisor restarts it blank), and then the
reaction-diffusion dynamics **heal the wound** from the neighbouring strips.
Fault tolerance you can literally watch.

Zero external dependencies on both sides: pure OTP/Elixir stdlib, pure
Metal/MetalKit/Network.framework.

```
+-------------------------------+        +---------------------------+
|  Elixir node                  |  TCP   |  macOS app                |
|  Supervisor (one_for_one)     | -----> |  FieldClient (Network)    |
|   +- Strip 0 (GenServer,      | ~26fps |  FieldRenderer (Metal,    |
|   |   16 rows x 128 cols)     | frames |   r8Unorm texture +       |
|   +- Strip 1 ... Strip 7      | <----- |   colormap shader)        |
|   +- Server (gen_tcp)         |  cmds  |  keys: K=chaos, S=seed    |
|  Coordinator: halo exchange,  |        |                           |
|  Task.async per strip         |        +---------------------------+
+-------------------------------+
```

## Wire protocol

Little-endian:

```
frame = rows :: uint32, cols :: uint32, rows*cols bytes (V field, 0..255)
```

Commands from the client, single bytes:
`0x01` chaos (kill a random strip process), `0x02` drop new seed spots.

## Run the server (tested on Elixir 1.14 / OTP 24+)

```bash
cd elixir
mix run --no-halt        # 128x128 grid, port 4041
```

`test_client.py` verifies the protocol, pattern formation, the chaos wound,
and the healing — no Mac required:

```
chaos: strip 4 energy 52126 -> 1440 (wound visible: True)
after 15s: strip 4 energy 1440 -> 94016
healed: YES
```

## Build the macOS app

1. Xcode -> New Project -> macOS -> **App**, name `GrayScottMetal`, SwiftUI.
2. Replace the generated sources with the four files from
   `swift/GrayScottMetal/`.
3. Signing & Capabilities -> App Sandbox -> enable
   **Outgoing Connections (Client)** — otherwise the sandbox silently
   blocks TCP.
4. Start the Elixir server, then Run.

## Notes

- The hot loop (`Strip.update_cells/12`) is a hand-rolled 10-list recursion
  instead of `Enum.zip/1` — ~3x faster, ~180 sim steps/s on a 128x128 grid.
  Pure-BEAM float math is not the point here; the coordination is.
- `Coordinator` tolerates strips dying between lookup and call
  (`catch :exit`) — the same race as in any distributed system: a pid can
  die between "found" and "called".
- Parameters are the "coral" regime (F=0.055, k=0.062, Du=0.16, Dv=0.08).
