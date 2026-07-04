#!/usr/bin/env python3
"""Test client for the Elixir Gray-Scott server. Verifies protocol,
pattern formation, performance, and healing after killing a strip."""
import socket, struct, time, statistics

def read_exact(s, n):
    buf = b""
    while len(buf) < n:
        chunk = s.recv(n - len(buf))
        if not chunk:
            raise ConnectionError("closed")
        buf += chunk
    return buf

def read_frame(s):
    rows, cols = struct.unpack("<II", read_exact(s, 8))
    return rows, cols, read_exact(s, rows * cols)

def stats(field):
    vals = list(field)
    return statistics.mean(vals), statistics.pstdev(vals)

s = socket.create_connection(("127.0.0.1", 4041))
rows, cols, f0 = read_frame(s)
print(f"frame ok: {rows}x{cols}, {len(f0)} bytes")
m0, sd0 = stats(f0)
print(f"t=0: mean={m0:.1f} std={sd0:.1f} (seeds only)")

# let the pattern grow ~12 s
t_end = time.time() + 12
frames = 0
while time.time() < t_end:
    rows, cols, field = read_frame(s)
    frames += 1
m1, sd1 = stats(field)
print(f"after 12s: frames={frames} (~{frames/12:.0f} fps), mean={m1:.1f} std={sd1:.1f}")
print(f"pattern formed: {'YES' if m1 > m0 * 2 else 'NO'} (V spreading => mean grows)")

# kill a strip, verify the wound and the healing
strip_rows = rows // 8
def strip_energy(field):
    return [sum(field[i*strip_rows*cols:(i+1)*strip_rows*cols]) for i in range(8)]

e_before = strip_energy(field)
s.sendall(b"\x01")
time.sleep(0.4)
rows, cols, f_wound = read_frame(s)
e_wound = strip_energy(f_wound)
dead = min(range(8), key=lambda i: e_wound[i] - 0.001 * e_before[i]) \
       if any(w < b * 0.3 for w, b in zip(e_wound, e_before)) else None
# find the strip that lost most energy
drops = [(b - w, i) for i, (b, w) in enumerate(zip(e_before, e_wound))]
drop, dead = max(drops)
print(f"chaos: strip {dead} energy {e_before[dead]} -> {e_wound[dead]} (wound visible: {e_wound[dead] < e_before[dead] * 0.5})")

# healing: let diffusion refill the dead strip
t_end = time.time() + 15
while time.time() < t_end:
    rows, cols, field = read_frame(s)
e_healed = strip_energy(field)
print(f"after 15s: strip {dead} energy {e_wound[dead]} -> {e_healed[dead]}")
print(f"healed: {'YES' if e_healed[dead] > max(e_wound[dead] * 3, 1000) else 'PARTIAL/NO'}")

s.close()
print("ALL CHECKS DONE")
