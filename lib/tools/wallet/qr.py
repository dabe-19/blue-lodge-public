#!/usr/bin/env python3
"""
Pure-Python ISO/IEC 18004 QR Code Generator (Byte mode, ECC Level L, Versions 1..10).
Zero external dependencies. Produces:
  - matrix(text) -> list[list[bool]]
  - to_svg(text, border=2, scale=4) -> str
  - to_ansi(text, border=1) -> str
"""
from __future__ import annotations

from typing import List

# GF(256) with primitive polynomial 0x11D
_EXP = [0] * 512
_LOG = [0] * 256
_x = 1
for _i in range(255):
    _EXP[_i] = _x
    _LOG[_x] = _i
    _x <<= 1
    if _x & 0x100:
        _x ^= 0x11D
for _i in range(255, 512):
    _EXP[_i] = _EXP[_i - 255]


def _gf_mul(a: int, b: int) -> int:
    if a == 0 or b == 0:
        return 0
    return _EXP[_LOG[a] + _LOG[b]]


def _rs_gen_poly(degree: int) -> List[int]:
    poly = [1]
    for i in range(degree):
        nxt = [0] * (len(poly) + 1)
        root = _EXP[i]
        for j, c in enumerate(poly):
            nxt[j] ^= c
            nxt[j + 1] ^= _gf_mul(c, root)
        poly = nxt
    return poly


def _rs_encode(data: List[int], ec_len: int) -> List[int]:
    gen = _rs_gen_poly(ec_len)
    rem = [0] * ec_len
    for b in data:
        factor = b ^ rem[0]
        rem = rem[1:] + [0]
        for j in range(ec_len):
            rem[j] ^= _gf_mul(gen[j + 1], factor)
    return rem


# Version table for ECC Level L:
# version: (total_data_codewords, ec_codewords_per_block, num_blocks_g1, data_per_b1, num_blocks_g2, data_per_b2, alignment_centers)
_VERSIONS = {
    1: (19, 7, 1, 19, 0, 0, []),
    2: (34, 10, 1, 34, 0, 0, [6, 18]),
    3: (55, 15, 1, 55, 0, 0, [6, 22]),
    4: (80, 20, 1, 80, 0, 0, [6, 26]),
    5: (108, 26, 1, 108, 0, 0, [6, 30]),
    6: (136, 18, 2, 68, 0, 0, [6, 34]),
    7: (156, 20, 2, 78, 0, 0, [6, 22, 38]),
    8: (194, 24, 2, 97, 0, 0, [6, 24, 42]),
    9: (232, 30, 2, 116, 0, 0, [6, 26, 46]),
    10: (274, 18, 2, 68, 2, 69, [6, 28, 50]),
}


def _select_version(byte_len: int) -> int:
    for v, spec in _VERSIONS.items():
        cap = spec[0]
        header_bits = 4 + (8 if v < 10 else 16)
        max_bytes = (cap * 8 - header_bits) // 8
        if byte_len <= max_bytes:
            return v
    raise ValueError(f"QR payload too long ({byte_len} bytes; max 271 bytes)")


def _build_codewords(payload: bytes, version: int) -> List[int]:
    total_data, ec_per_block, nb1, db1, nb2, db2, _ = _VERSIONS[version]
    bits: List[int] = []

    def append_bits(val: int, length: int) -> None:
        for i in range(length - 1, -1, -1):
            bits.append((val >> i) & 1)

    # Byte mode indicator = 0100
    append_bits(0b0100, 4)
    append_bits(len(payload), 8 if version < 10 else 16)
    for b in payload:
        append_bits(b, 8)

    capacity_bits = total_data * 8
    term = min(4, capacity_bits - len(bits))
    append_bits(0, term)
    while len(bits) % 8 != 0:
        bits.append(0)

    data_bytes = [int("".join(str(b) for b in bits[i:i + 8]), 2) for i in range(0, len(bits), 8)]
    pad_seq = [0xEC, 0x11]
    idx = 0
    while len(data_bytes) < total_data:
        data_bytes.append(pad_seq[idx % 2])
        idx += 1

    blocks_data: List[List[int]] = []
    blocks_ec: List[List[int]] = []
    pos = 0
    for _ in range(nb1):
        blk = data_bytes[pos:pos + db1]
        pos += db1
        blocks_data.append(blk)
        blocks_ec.append(_rs_encode(blk, ec_per_block))
    for _ in range(nb2):
        blk = data_bytes[pos:pos + db2]
        pos += db2
        blocks_data.append(blk)
        blocks_ec.append(_rs_encode(blk, ec_per_block))

    interleaved: List[int] = []
    max_d = max(db1, db2)
    for i in range(max_d):
        for blk in blocks_data:
            if i < len(blk):
                interleaved.append(blk[i])
    for i in range(ec_per_block):
        for ec in blocks_ec:
            interleaved.append(ec[i])
    return interleaved


def _format_bits(ecl_bits: int, mask: int) -> int:
    data = (ecl_bits << 3) | mask
    rem = data << 10
    for i in range(14, 9, -1):
        if (rem >> i) & 1:
            rem ^= 0x537 << (i - 10)
    return ((data << 10) | rem) ^ 0x5412


def _version_bits(version: int) -> int:
    rem = version << 12
    for i in range(17, 11, -1):
        if (rem >> i) & 1:
            rem ^= 0x1F25 << (i - 12)
    return (version << 12) | rem


def matrix(text: str) -> List[List[bool]]:
    payload = text.encode("utf-8")
    version = _select_version(len(payload))
    size = 17 + 4 * version
    grid: List[List[int]] = [[0] * size for _ in range(size)]
    is_func: List[List[bool]] = [[False] * size for _ in range(size)]

    def set_func(r: int, c: int, val: bool) -> None:
        if 0 <= r < size and 0 <= c < size:
            grid[r][c] = 1 if val else 0
            is_func[r][c] = True

    def place_finder(top: int, left: int) -> None:
        for dr in range(-1, 8):
            for dc in range(-1, 8):
                r, c = top + dr, left + dc
                if 0 <= r < size and 0 <= c < size:
                    in_outer = 0 <= dr <= 6 and 0 <= dc <= 6
                    on_border = dr in (0, 6) or dc in (0, 6)
                    in_center = 2 <= dr <= 4 and 2 <= dc <= 4
                    set_func(r, c, in_outer and (on_border or in_center))

    place_finder(0, 0)
    place_finder(0, size - 7)
    place_finder(size - 7, 0)

    # Timing patterns
    for i in range(8, size - 8):
        set_func(6, i, i % 2 == 0)
        set_func(i, 6, i % 2 == 0)

    # Alignment patterns
    centers = _VERSIONS[version][6]
    for r in centers:
        for c in centers:
            if (r == 6 and c in (6, centers[-1])) or (c == 6 and r == centers[-1]):
                continue
            for dr in range(-2, 3):
                for dc in range(-2, 3):
                    val = max(abs(dr), abs(dc)) in (0, 2)
                    set_func(r + dr, c + dc, val)

    # Dark module & reserved format areas
    set_func(4 * version + 9, 8, True)
    for i in range(9):
        if not is_func[8][i]:
            set_func(8, i, False)
        if not is_func[i][8]:
            set_func(i, 8, False)
    for i in range(8):
        set_func(8, size - 1 - i, False)
        set_func(size - 1 - i, 8, False)

    if version >= 7:
        vbits = _version_bits(version)
        for i in range(18):
            bit = bool((vbits >> i) & 1)
            r, c = i // 3, size - 11 + (i % 3)
            set_func(r, c, bit)
            set_func(c, r, bit)

    codewords = _build_codewords(payload, version)
    data_bits: List[int] = []
    for cw in codewords:
        for i in range(7, -1, -1):
            data_bits.append((cw >> i) & 1)

    # Place data bits in upward/downward 2-column zig-zag
    bit_idx = 0
    up = True
    col = size - 1
    while col > 0:
        if col == 6:
            col -= 1
        rows = range(size - 1, -1, -1) if up else range(size)
        for r in rows:
            for dc in (0, 1):
                c = col - dc
                if not is_func[r][c]:
                    bit = data_bits[bit_idx] if bit_idx < len(data_bits) else 0
                    bit_idx += 1
                    # Apply Mask 0: (r + c) % 2 == 0
                    if (r + c) % 2 == 0:
                        bit ^= 1
                    grid[r][c] = bit
        up = not up
        col -= 2

    # Write format information for ECL=L (01) and Mask=0 (000)
    fbits = _format_bits(0b01, 0)
    for i in range(6):
        set_func(8, i, bool((fbits >> i) & 1))
    set_func(8, 7, bool((fbits >> 6) & 1))
    set_func(8, 8, bool((fbits >> 7) & 1))
    set_func(7, 8, bool((fbits >> 8) & 1))
    for i in range(9, 15):
        set_func(14 - i, 8, bool((fbits >> i) & 1))

    for i in range(8):
        set_func(size - 1 - i, 8, bool((fbits >> i) & 1))
    for i in range(8, 15):
        set_func(8, size - 15 + i, bool((fbits >> i) & 1))

    return [[bool(cell) for cell in row] for row in grid]


def to_svg(text: str, border: int = 2, scale: int = 4) -> str:
    mat = matrix(text)
    n = len(mat)
    dim = (n + 2 * border) * scale
    rects: List[str] = []
    for r, row in enumerate(mat):
        for c, cell in enumerate(row):
            if cell:
                x = (c + border) * scale
                y = (r + border) * scale
                rects.append(f'<rect x="{x}" y="{y}" width="{scale}" height="{scale}"/>')
    body = "".join(rects)
    return (
        f'<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 {dim} {dim}" '
        f'width="{dim}" height="{dim}" shape-rendering="crispEdges">'
        f'<rect width="100%" height="100%" fill="#ffffff"/>'
        f'<g fill="#000000">{body}</g></svg>'
    )


def to_ansi(text: str, border: int = 1) -> str:
    mat = matrix(text)
    n = len(mat)
    padded: List[List[bool]] = [[False] * (n + 2 * border) for _ in range(border)]
    for row in mat:
        padded.append([False] * border + row + [False] * border)
    for _ in range(border):
        padded.append([False] * (n + 2 * border))
    if len(padded) % 2 == 1:
        padded.append([False] * (n + 2 * border))

    lines: List[str] = []
    for r in range(0, len(padded), 2):
        top = padded[r]
        bot = padded[r + 1]
        chars: List[str] = []
        for t, b in zip(top, bot):
            if t and b:
                chars.append("█")
            elif t and not b:
                chars.append("▀")
            elif not t and b:
                chars.append("▄")
            else:
                chars.append(" ")
        lines.append("".join(chars))
    return "\n".join(lines)

