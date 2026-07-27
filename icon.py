"""Author the mod icon as real 32x32 pixel art, then scale by integer factors
with nearest-neighbour so every source pixel stays a hard square."""
import math
from PIL import Image

W = H = 32

BG   = (26, 30, 38)
OUT  = (12, 14, 19)
GRN  = (92, 191, 74)
GRND = (58, 133, 46)
SCR  = (108, 209, 242)
SCRD = (52, 140, 178)
CYA  = (127, 232, 255)
CYAD = (70, 168, 208)

PAL = {'.': BG, 'o': OUT, 'g': GRN, 'G': GRND, 's': SCR, 'S': SCRD,
       'c': CYA, 'C': CYAD}

# A computer: black outline, green bezel and stand, cyan screen. 11x10.
MACHINE = [
    "ooooooooooo",
    "ogggggggggo",
    "ogsssssssgo",
    "ogsSSSSSsgo",
    "ogsssssssgo",
    "ogggggggggo",
    "ooooooooooo",
    "...oGGGo...",
    ".oGGGGGGGo.",
    ".ooooooooo.",
]

grid = [['.'] * W for _ in range(H)]


def blit(sprite, ox, oy):
    for dy, row in enumerate(sprite):
        for dx, ch in enumerate(row):
            if ch != '.':
                grid[oy + dy][ox + dx] = ch


# Wi-fi fan rising from the gap between the two machines. Stepped along the
# arc rather than tested per-pixel, so the curves come out unbroken.
CX, CY = 15.5, 17.5
for radius, ch in ((5.0, 'c'), (9.0, 'c'), (13.0, 'C')):
    steps = int(radius * 12)
    for i in range(steps + 1):
        ang = math.radians(40 + (100 * i / steps))
        x = int(CX + radius * math.cos(ang))
        y = int(CY - radius * math.sin(ang))
        if 0 <= x < W and 0 <= y < H:
            grid[y][x] = ch

# Apex the arcs radiate from.
for y in (16, 17):
    for x in (15, 16):
        grid[y][x] = 'c'

blit(MACHINE, 1, 19)
blit(MACHINE, 20, 19)

img = Image.new("RGB", (W, H))
img.putdata([PAL[ch] for row in grid for ch in row])
# 128 for the jar, 512 for the Modrinth project icon. Run from the repo root.
for scale, name in ((4, "mod/src/main/resources/assets/awdl-lan/icon.png"),
                    (16, "icon-512.png")):
    img.resize((W * scale, H * scale), Image.NEAREST).save(name)
