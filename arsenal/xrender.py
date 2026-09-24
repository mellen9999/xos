#!/usr/bin/env python3
# xrender -- the shared engine behind every character renderer in the
# arsenal (atlas, view): tier detection, the semantic 8-colour palette, and
# a subpixel Canvas that packs braille (utf8) or plain ascii (not), down to
# a real vt320 with zero CSI escapes. no third-party library, stdlib only.
#
# tier ladder mirrors learn/lib/ui's _ui_tier exactly (colour/mono/none by
# TERM, NO_COLOR, tty-ness) plus a second, separate question ui does not have
# to ask: whether the terminal is utf8, which is what braille needs. a real
# vt320 is mono AND not utf8 -- that combination is the whole reason every
# tool built on this has an ascii floor and not just a fallback string.

# ---------------------------------------------------------------- tier ----
def detect_tier(term, no_color, is_tty):
    if term in ("vt50", "vt50h", "vt52") or term.startswith(("vt50-", "vt50h-", "vt52-")):
        tier, csi = "none", False
    elif term in ("dumb", ""):
        tier, csi = "none", False
    elif term.startswith(("vt241", "vt340", "vt525")):
        tier, csi = "colour", True
    elif term.startswith("vt") or term.endswith(("-m", "-mono", "-nc")):
        tier, csi = "mono", True
    else:
        tier, csi = "colour", True
    if no_color:
        tier, csi = "none", False
    if not is_tty:
        tier = "none"
    return tier, csi

def detect_utf8(env):
    for k in ("LC_ALL", "LC_CTYPE", "LANG"):
        v = env.get(k, "")
        if "utf-8" in v.lower() or "utf8" in v.lower():
            return True
    return False

# one meaning per colour, the terminal's own eight, never a 256 ramp -- same
# doctrine as learn/lib/ui: those always exist and arrive in the reader's own
# scheme. LAND is the quiet frame (D, 90), BORDER rides with it (dimmer still
# matters less than coast), WATER is the one slot ui never uses (blue, 34),
# CITY is live text (W), MARK is a point's own dot (bold on top of CITY on
# colour; mono has nothing bold to stack on, so it just reuses CITY), SEL is
# the one mark every attribute tier has (reverse). the names are atlas's, but
# the slots generalise -- a tool with no cities or coastlines just leaves the
# ones it does not need at "".
class Pal:
    def __init__(self, tier):
        if tier == "colour":
            self.N, self.LAND, self.BORDER, self.WATER, self.CITY, self.MARK, self.SEL = (
                "\033[0m", "\033[90m", "\033[90m", "\033[34m", "\033[37m", "\033[1;37m", "\033[7m")
        elif tier == "mono":
            # a vt320 has bold/underline/reverse and nothing else -- no colour
            # channel to lose, so every slot above collapses onto those three.
            self.N, self.LAND, self.BORDER, self.WATER, self.CITY, self.MARK, self.SEL = (
                "\033[0m", "", "", "", "\033[1m", "\033[1m", "\033[7m")
        else:
            self.N = self.LAND = self.BORDER = self.WATER = self.CITY = self.MARK = self.SEL = ""

# --------------------------------------------------------------- canvas ---
DOTS = [[0x01, 0x08], [0x02, 0x10], [0x04, 0x20], [0x40, 0x80]]  # braille bit order

class Canvas:
    """a cols x rows character grid backed by a subpixel bit/owner plane --
    2x4 subpixels per cell for braille (utf8), 1x1 (i.e. no subpixels at all)
    for plain ascii. plot()/line() draw into the subpixel plane; pack() packs
    it down to characters + a colour key per cell; to_text() is the final
    tier-aware assembly (zero escapes on tier "none", colour-run-length-
    encoded escapes otherwise). grid/cell_colour stay accessible after pack()
    so a caller can overlay cell-level marks (a city dot, a label) that never
    went through the subpixel plane at all.
    """
    def __init__(self, cols, rows, braille):
        self.cols, self.rows, self.braille = cols, rows, braille
        self.sx, self.sy = (2, 4) if braille else (1, 1)
        self.W, self.H = cols * self.sx, rows * self.sy
        self.bits = bytearray(self.W * self.H)
        self.owner = bytearray(self.W * self.H)  # 0 = untouched, else caller's key
        self.grid = [[" "] * cols for _ in range(rows)]
        self.cell_colour = [[""] * cols for _ in range(rows)]

    def plot(self, x, y, key):
        if 0 <= x < self.W and 0 <= y < self.H:
            i = y * self.W + x
            self.bits[i] = 1
            if key > self.owner[i]:
                self.owner[i] = key

    def line(self, x0, y0, x1, y1, key):  # bresenham
        x0, y0, x1, y1 = int(x0), int(y0), int(x1), int(y1)
        dx, dy = abs(x1 - x0), -abs(y1 - y0)
        sxx = 1 if x0 < x1 else -1
        syy = 1 if y0 < y1 else -1
        err = dx + dy
        while True:
            self.plot(x0, y0, key)
            if x0 == x1 and y0 == y1:
                break
            e2 = 2 * err
            if e2 >= dy:
                err += dy; x0 += sxx
            if e2 <= dx:
                err += dx; y0 += syy

    def pack(self, ascii_glyphs, colours):
        """glyphs/colours into self.grid/self.cell_colour from the subpixel
        plane. ascii_glyphs: {key: char} used only off braille. colours:
        {key: escape string} used on any tier above none."""
        cols, rows, W = self.cols, self.rows, self.W
        if self.braille:
            for cy in range(rows):
                for cx in range(cols):
                    b = 0
                    own = 0
                    for dyi in range(4):
                        for dxi in range(2):
                            i = (cy * 4 + dyi) * W + (cx * 2 + dxi)
                            if self.bits[i]:
                                b |= DOTS[dyi][dxi]
                                own = max(own, self.owner[i])
                    if b:
                        self.grid[cy][cx] = chr(0x2800 + b)
                        self.cell_colour[cy][cx] = colours.get(own, "")
        else:
            for cy in range(rows):
                for cx in range(cols):
                    i = cy * W + cx
                    if self.bits[i]:
                        own = self.owner[i]
                        self.grid[cy][cx] = ascii_glyphs[own]
                        self.cell_colour[cy][cx] = colours.get(own, "")

    def to_text(self, tier, reset):
        """the final row assembly: plain and rstripped on tier none (zero
        escapes, ever), colour-run-length-encoded otherwise -- one reset/
        set pair per colour change, not per cell."""
        lines = []
        for cy in range(self.rows):
            if tier == "none":
                lines.append("".join(self.grid[cy]).rstrip())
                continue
            out, cur = [], ""
            for cx in range(self.cols):
                c = self.cell_colour[cy][cx]
                if c != cur:
                    if cur:
                        out.append(reset)
                    if c:
                        out.append(c)
                    cur = c
                out.append(self.grid[cy][cx])
            if cur:
                out.append(reset)
            lines.append("".join(out).rstrip())
        return "\n".join(lines)
