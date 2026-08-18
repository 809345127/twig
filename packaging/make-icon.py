#!/usr/bin/env python3
"""生成 twig 的应用图标。

图案就是 twig 自己的主题：一条主干 + 一条分出去又汇回来的支线，
也就是提交图上最典型的那个形状。

只用标准库：手写 PNG 编码（zlib + struct），抗锯齿用有向距离场
（算每个像素到图形边缘的距离，再拿距离当透明度），
比超采样快得多，边缘也更干净。
"""

import math
import struct
import sys
import zlib

SIZE = 1024

# —— 配色（跟界面深色主题同一套）——
BG_TOP = (0x2B, 0x33, 0x3E)      # 背景渐变上端
BG_BOTTOM = (0x1B, 0x21, 0x28)   # 背景渐变下端
TRUNK = (0x53, 0x9B, 0xF5)       # 主干：蓝
BRANCH = (0x57, 0xAB, 0x5A)      # 支线：绿
DOT_EDGE = (0x1B, 0x21, 0x28)    # 圆点描边（挖出背景色，让点从线里跳出来）


def rounded_rect_sdf(x, y, cx, cy, half_w, half_h, r):
    """圆角矩形的有向距离：负数在内部，正数在外部。"""
    dx = abs(x - cx) - (half_w - r)
    dy = abs(y - cy) - (half_h - r)
    ax, ay = max(dx, 0.0), max(dy, 0.0)
    return math.hypot(ax, ay) + min(max(dx, dy), 0.0) - r


def segment_sdf(x, y, x1, y1, x2, y2):
    """点到线段的距离。"""
    vx, vy = x2 - x1, y2 - y1
    wx, wy = x - x1, y - y1
    denom = vx * vx + vy * vy
    t = 0.0 if denom == 0 else max(0.0, min(1.0, (wx * vx + wy * vy) / denom))
    return math.hypot(wx - t * vx, wy - t * vy)


def polyline_sdf(x, y, pts):
    """点到折线的距离（曲线先采样成折线）。"""
    best = float("inf")
    for i in range(len(pts) - 1):
        d = segment_sdf(x, y, pts[i][0], pts[i][1], pts[i + 1][0], pts[i + 1][1])
        if d < best:
            best = d
    return best


def bezier(p0, p1, p2, p3, steps=48):
    """三次贝塞尔采样成折线。"""
    out = []
    for i in range(steps + 1):
        t = i / steps
        u = 1 - t
        bx = (u ** 3) * p0[0] + 3 * (u ** 2) * t * p1[0] + 3 * u * (t ** 2) * p2[0] + (t ** 3) * p3[0]
        by = (u ** 3) * p0[1] + 3 * (u ** 2) * t * p1[1] + 3 * u * (t ** 2) * p2[1] + (t ** 3) * p3[1]
        out.append((bx, by))
    return out


def blend(dst, src, alpha):
    """把 src 按 alpha 叠到 dst 上。"""
    return tuple(int(round(d + (s - d) * alpha)) for d, s in zip(dst, src))


def coverage(dist, edge=0.7):
    """距离 → 覆盖率（0~1），edge 是过渡带宽度，用来做抗锯齿。"""
    if dist <= -edge:
        return 1.0
    if dist >= edge:
        return 0.0
    return (edge - dist) / (2 * edge)


def build():
    # 图形几何：内容区域缩在画布里，四周留白，符合 macOS 图标的观感
    margin = SIZE * 0.085
    half = (SIZE - 2 * margin) / 2
    cx = cy = SIZE / 2
    corner = half * 0.46

    trunk_x = SIZE * 0.385
    trunk_top, trunk_bottom = SIZE * 0.235, SIZE * 0.775
    trunk_w = SIZE * 0.026

    # 支线：从主干分出去，绕一圈再汇回主干
    fork_out = SIZE * 0.355
    fork_in = SIZE * 0.655
    side_x = SIZE * 0.625
    branch_pts = (
        bezier((trunk_x, fork_out), (trunk_x, fork_out + SIZE * 0.06),
               (side_x, fork_out + SIZE * 0.02), (side_x, SIZE * 0.505))
        + bezier((side_x, SIZE * 0.505), (side_x, fork_in - SIZE * 0.02),
                 (trunk_x, fork_in - SIZE * 0.06), (trunk_x, fork_in))
    )
    branch_w = SIZE * 0.022

    dots = [
        (trunk_x, SIZE * 0.265, SIZE * 0.052, TRUNK),
        (trunk_x, SIZE * 0.50, SIZE * 0.052, TRUNK),
        (trunk_x, SIZE * 0.745, SIZE * 0.052, TRUNK),
        (side_x, SIZE * 0.505, SIZE * 0.046, BRANCH),
    ]

    rows = []
    for py in range(SIZE):
        y = py + 0.5
        # 背景竖向渐变
        t = py / (SIZE - 1)
        bg = tuple(int(round(a + (b - a) * t)) for a, b in zip(BG_TOP, BG_BOTTOM))

        row = bytearray()
        for px in range(SIZE):
            x = px + 0.5

            # 1) 圆角矩形底板：决定这个像素的整体不透明度
            plate = coverage(rounded_rect_sdf(x, y, cx, cy, half, half, corner))
            if plate <= 0.0:
                row += b"\x00\x00\x00\x00"
                continue

            color = bg

            # 2) 主干
            d = segment_sdf(x, y, trunk_x, trunk_top, trunk_x, trunk_bottom) - trunk_w
            a = coverage(d)
            if a > 0:
                color = blend(color, TRUNK, a)

            # 3) 支线
            d = polyline_sdf(x, y, branch_pts) - branch_w
            a = coverage(d)
            if a > 0:
                color = blend(color, BRANCH, a)

            # 4) 圆点：先描一圈背景色把线挖断，再填色
            for dx0, dy0, r, c in dots:
                dd = math.hypot(x - dx0, y - dy0)
                a = coverage(dd - (r + SIZE * 0.012))
                if a > 0:
                    color = blend(color, DOT_EDGE, a)
                a = coverage(dd - r)
                if a > 0:
                    color = blend(color, c, a)

            alpha = int(round(plate * 255))
            row += bytes((color[0], color[1], color[2], alpha))

        rows.append(bytes(row))
    return rows


def write_png(path, rows):
    raw = b"".join(b"\x00" + r for r in rows)

    def chunk(tag, data):
        c = struct.pack(">I", len(data)) + tag + data
        return c + struct.pack(">I", zlib.crc32(tag + data) & 0xFFFFFFFF)

    ihdr = struct.pack(">IIBBBBB", SIZE, SIZE, 8, 6, 0, 0, 0)  # 8bit RGBA
    png = (b"\x89PNG\r\n\x1a\n"
           + chunk(b"IHDR", ihdr)
           + chunk(b"IDAT", zlib.compress(raw, 9))
           + chunk(b"IEND", b""))
    with open(path, "wb") as f:
        f.write(png)


if __name__ == "__main__":
    out = sys.argv[1] if len(sys.argv) > 1 else "icon.png"
    write_png(out, build())
    print("wrote", out)
