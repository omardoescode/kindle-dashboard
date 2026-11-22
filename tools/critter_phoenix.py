#!/usr/bin/env python3
"""Makes "Cinder", the phoenix critter for Simple UI's Tiny Critter, from the "Pixel Phoenix" sprite sheet
by zonked (CC0, https://opengameart.org/content/pixel-phoenix): one gray PNG per mood, all on one canvas.
The face, the flame crest, the tail plumes, the wing flames and the mood symbols are drawn here.

Usage: python3 -I tools/critter_phoenix.py tools/assets/phoenix-cc0-spritesheet.png OUT_DIR
Copy OUT_DIR to <KOReader settings>/simpleui/sui_critters/cinder/ (deploy.sh does it).
"""
import os
import sys

from PIL import Image

CELL, COLS = 20, 5
# Sheet frames: 0 sits, 5 flaps its wings. The flapping bird gets the sitting head. WAVE sits and raises a drawn wing.
SIT, FLAP = 0, 5
FACE_TOP = 7
# In gray the sheet's reds, oranges and pinks all become one mid tone. Band its colors by brightness into five
# well-separated e-ink levels (the darkest reds stay black) and add a black outline.
BANDS = ((30, 0), (60, 85), (100, 136), (150, 187), (256, 238))
K, D, M, L, W = 0, 85, 136, 187, 238
# Canvas in sheet cell coordinates. Simple UI scales the critter by row height // image height: keep it low.
X0, Y0, WIDTH, HEIGHT = 2, 2, 26, 19
PIX = {"#": K, "d": D, "m": M, "l": L, "o": W}

CREST = (
    "....o..o...",
    "..o.lo.lo..",
    ".lllllllllo",
)
TAIL = (
    "....m...m",
    "...ml..ml",
    "..mlo.mlo",
    "mmlooloo.",
    "mllooool.",
    "mmlloolm.",
    "mmmllm...",
    "mmm......",
)
WAVE = (
    ".....oo",
    "....llo",
    "...lllo",
    "..mllo.",
    ".mmll..",
    "mmml...",
    "mmm....",
)
WING_FLAMES = {(4, 10): L, (3, 9): W, (5, 10): L, (18, 10): L, (19, 9): W}

SYMBOLS = {
    "zz": ("...####", ".....#.", "....#..", "###.###", "..#....", ".#.....", "###...."),
    "drop": ("..#..", ".#m#.", "#mmm#", "#mmm#", ".###."),
    "heart": ("##.##", "#####", "#####", ".###.", "..#.."),
    "bang": ("##", "##", "##", "##", "..", "##"),
    "ask": (".###.", "##.##", "...##", "..##.", "..#..", ".....", "..#.."),
    "anger": (".#.#.", "##.##", ".....", "##.##", ".#.#."),
    "sparkles": ("....#..", "...###.", "....#..", "#......", "##.....", "#......"),
    "note": ("..##..", "..#.#.", "..#..#", "..#...", "###...", "###..."),
    "confetti": ("d...#...", "......d.", "..#....#", "#...d...", "......#.", "..d.....", "#..."),
}

BEAKS = {
    "shut": ("..##", ".#ll", "####", ".###", "..#."),
    "open": ("..##", ".#ll", "####", "...o", ".###", "..##"),
}

MOODS = {
    "neutral": (SIT, "open", "shut", None),
    "happy": (SIT, "arc", "shut", None),
    "party": (FLAP, "arc", "shut", "confetti"),
    "sleepy": (SIT, "line", "shut", "zz"),
    "cheer": (FLAP, "arc", "shut", "sparkles"),
    "love": (SIT, "arc", "shut", "heart"),
    "sad": (SIT, "sad", "shut", "drop"),
    "surprised": (SIT, "wide", "open", "bang"),
    "curious": (SIT, "up", "shut", "ask"),
    "grumpy": (SIT, "angry", "shut", "anger"),
    "shy": (SIT, "down", "shut", None),
    "playful": (WAVE, "arc", "shut", "note"),
}
# Each eye is drawn from 2 columns left and 2 rows above the top left of the eye: brows, tears and blush too.
EYES = {
    "open": ("....", "....", "..##", "..##"),
    "arc": ("....", "....", "..##", ".#..#", "....", ".mm."),
    "line": ("....", "....", "....", ".####"),
    "wide": ("....", ".###", ".#o#", ".###"),
    "up": ("....", "..##", "..##"),
    "down": ("....", "....", "....", "..##", "....", ".mm."),
    "sad": ("....", ".#..", "..##", "..##", ".m..", ".m.."),
    "angry": ("....", "....#", ".###", "..##"),
    }


def frame(sheet, i):
    x, y = (i % COLS) * CELL, (i // COLS) * CELL
    return sheet.crop((x, y, x + CELL, y + CELL))


def luma(c):
    return 0.299 * c[0] + 0.587 * c[1] + 0.114 * c[2]


def tones(frames):
    colors = {img.getpixel((x, y))[:3] for img in frames for y in range(img.height) for x in range(img.width)
              if img.getpixel((x, y))[3] >= 128}
    return {c: next(level for top, level in BANDS if luma(c) < top) for c in colors}


def body(img, tone):
    return {(x, y): tone[img.getpixel((x, y))[:3]] for y in range(img.height) for x in range(img.width)
            if img.getpixel((x, y))[3] >= 128}


def stamp(px, rows, left, top):
    for dy, row in enumerate(rows):
        for dx, c in enumerate(row):
            if c != ".":
                px[left + dx, top + dy] = PIX[c]


def draw(bird, pose, eye, beak, symbols):
    px = dict(bird)
    stamp(px, CREST, 7, 3)
    stamp(px, TAIL, 16, 10)
    if pose == FLAP:
        px.update(WING_FLAMES)
    if pose == WAVE:
        stamp(px, WAVE, 13, 4)
    for y in range(FACE_TOP, FACE_TOP + 5):
        for x in range(7 + (y == FACE_TOP), 13 - (y in (FACE_TOP, FACE_TOP + 4))):
            px[x, y] = W
    stamp(px, EYES[eye], 8, FACE_TOP - 1)
    out = dict.fromkeys({(x + nx, y + ny) for x, y in px for nx, ny in ((1, 0), (-1, 0), (0, 1), (0, -1))}, K)
    out.update(px)
    stamp(out, BEAKS[beak], 7 - len(BEAKS[beak][0]), FACE_TOP)
    if symbols:
        rows = SYMBOLS[symbols]
        stamp(out, rows, X0 + WIDTH - len(rows[0]), Y0)
    img = Image.new("LA", (WIDTH, HEIGHT), (255, 0))
    for (x, y), level in out.items():
        if 0 <= x - X0 < WIDTH and 0 <= y - Y0 < HEIGHT:
            img.putpixel((x - X0, y - Y0), (level, 255))
    return img


def main():
    sheet = Image.open(sys.argv[1]).convert("RGBA")
    out = sys.argv[2]
    os.makedirs(out, exist_ok=True)
    frames = {i: frame(sheet, i) for i in (SIT, FLAP)}
    tone = tones(frames.values())
    birds = {i: body(img, tone) for i, img in frames.items()}
    # The sheet's own crest and tail sparks give way to the drawn ones.
    birds[SIT] = {(x, y): v for (x, y), v in birds[SIT].items() if y > 5 and not (x > 16 and y > 14)}
    birds[FLAP] = {(x, y): v for (x, y), v in birds[SIT].items() if y <= 10} | {
        (x, y): v for (x, y), v in birds[FLAP].items() if y >= 11 and not (x > 16 and y > 14)}
    birds[WAVE] = birds[SIT]
    for name, (pose, eye, beak, symbols) in MOODS.items():
        draw(birds[pose], pose, eye, beak, symbols).save(os.path.join(out, name + ".png"))


if __name__ == "__main__":
    main()
