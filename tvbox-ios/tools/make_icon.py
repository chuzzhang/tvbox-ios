#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""生成 1024x1024 AppIcon（纯标准库，不依赖 Pillow）。"""
import os
import zlib
import struct

SIZE = 1024
BG = (11, 14, 19, 255)
SCREEN = (59, 130, 246, 255)
GLYPH = (255, 255, 255, 255)


def new_canvas():
    return [[BG for _ in range(SIZE)] for _ in range(SIZE)]


def blend(px, color):
    a = color[3] / 255.0
    r = int(color[0] * a + px[0] * (1 - a))
    g = int(color[1] * a + px[1] * (1 - a))
    b = int(color[2] * a + px[2] * (1 - a))
    return (r, g, b, 255)


def rounded_rect(canvas, x0, y0, x1, y1, radius, color):
    for y in range(int(y0), int(y1)):
        for x in range(int(x0), int(x1)):
            # 圆角判定
            cx = min(max(x, x0 + radius), x1 - radius)
            cy = min(max(y, y0 + radius), y1 - radius)
            dx = x - cx
            dy = y - cy
            if dx * dx + dy * dy <= radius * radius:
                canvas[y][x] = blend(canvas[y][x], color)


def rect(canvas, x0, y0, x1, y1, color):
    for y in range(int(y0), int(y1)):
        for x in range(int(x0), int(x1)):
            canvas[y][x] = blend(canvas[y][x], color)


def triangle(canvas, p1, p2, p3, color):
    def sign(a, b, c):
        return (a[0] - c[0]) * (b[1] - c[1]) - (b[0] - c[0]) * (a[1] - c[1])

    xs = [p1[0], p2[0], p3[0]]
    ys = [p1[1], p2[1], p3[1]]
    for y in range(min(ys), max(ys)):
        for x in range(min(xs), max(xs)):
            pt = (x + 0.5, y + 0.5)
            d1 = sign(pt, p1, p2)
            d2 = sign(pt, p2, p3)
            d3 = sign(pt, p3, p1)
            neg = (d1 < 0) or (d2 < 0) or (d3 < 0)
            pos = (d1 > 0) or (d2 > 0) or (d3 > 0)
            if not (neg and pos):
                canvas[y][x] = blend(canvas[y][x], color)


def line(canvas, p1, p2, width, color):
    dx = p2[0] - p1[0]
    dy = p2[1] - p1[1]
    steps = max(abs(int(dx)), abs(int(dy))) * 2 or 1
    half = width / 2.0
    for i in range(steps + 1):
        t = i / steps
        cx = p1[0] + dx * t
        cy = p1[1] + dy * t
        for y in range(int(cy - half), int(cy + half) + 1):
            for x in range(int(cx - half), int(cx + half) + 1):
                if 0 <= x < SIZE and 0 <= y < SIZE:
                    if (x - cx) ** 2 + (y - cy) ** 2 <= half * half:
                        canvas[y][x] = blend(canvas[y][x], color)


def write_png(path, canvas):
    raw = bytearray()
    for row in canvas:
        raw.append(0)
        for px in row:
            raw.extend(px)

    def chunk(tag, data):
        c = struct.pack('>I', len(data)) + tag + data
        return c + struct.pack('>I', zlib.crc32(tag + data) & 0xFFFFFFFF)

    png = b'\x89PNG\r\n\x1a\n'
    png += chunk(b'IHDR', struct.pack('>IIBBBBB', SIZE, SIZE, 8, 6, 0, 0, 0))
    png += chunk(b'IDAT', zlib.compress(bytes(raw), 9))
    png += chunk(b'IEND', b'')
    with open(path, 'wb') as f:
        f.write(png)


def main():
    root = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
    out_dir = os.path.join(root, 'Assets.xcassets', 'AppIcon.appiconset')
    os.makedirs(out_dir, exist_ok=True)

    c = new_canvas()
    # 机身
    rounded_rect(c, 72, 132, 952, 892, 96, (24, 28, 36, 255))
    # 屏幕
    rounded_rect(c, 152, 252, 872, 712, 44, SCREEN)
    # 屏幕内高光（上圆角、下方压平，避免出现胶囊形）
    rounded_rect(c, 152, 252, 872, 380, 44, (110, 168, 255, 255))
    rect(c, 152, 340, 872, 380, (110, 168, 255, 255))
    # 播放三角
    triangle(c, (432, 380), (432, 592), (648, 486), GLYPH)
    # 底座
    rounded_rect(c, 402, 742, 622, 800, 26, (60, 66, 80, 255))
    # 天线
    line(c, (392, 200), (472, 274), 22, (60, 66, 80, 255))
    line(c, (632, 200), (552, 274), 22, (60, 66, 80, 255))

    path = os.path.join(out_dir, 'icon-1024.png')
    write_png(path, c)
    print('wrote', path, os.path.getsize(path), 'bytes')


if __name__ == '__main__':
    main()
