#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""
生成 MWB (macOS) 应用图标。

设计意图：
  - 沿用 Mouse Without Borders 的视觉母题：**多块屏幕 + 一个跨屏的光标**；
  - 同时明确体现「Mac 端」：Big Sur 圆角 squircle 外形、左侧屏幕做成 Mac 显示器
    （带刘海 + 红黄绿窗口灯 + 底座），光标用的是 macOS 经典箭头形状；
  - 右侧屏幕用 2×2 窗格表示被控制的 Windows 机器；
  - 两屏之间一条虚线弧表示「鼠标从这里穿过去」。

输出：App/AppIcon.icns（同时保留 1024 PNG 供预览）。
用 Pillow 纯绘制，不依赖网络与外部素材。

用法：python3 make_icon.py
"""

import os
import subprocess
import sys

from PIL import Image, ImageDraw, ImageFilter

HERE = os.path.dirname(os.path.abspath(__file__))
S = 1024                      # 画布边长
OUT_ICNS = os.path.join(HERE, "AppIcon.icns")
PREVIEW_PNG = os.path.join(HERE, "AppIcon-preview.png")

# 调色板（MWB 的蓝 + macOS 的质感）
BLUE_TOP = (0x3B, 0x82, 0xF6)
BLUE_BOT = (0x12, 0x33, 0x6E)
INK = (0x07, 0x18, 0x33)        # 光标描边用的深蓝
WHITE = (0xFF, 0xFF, 0xFF)


def lerp(a, b, t):
    return tuple(int(round(a[i] + (b[i] - a[i]) * t)) for i in range(3))


def rounded_mask(size, box, radius):
    m = Image.new("L", (size, size), 0)
    ImageDraw.Draw(m).rounded_rectangle(box, radius=radius, fill=255)
    return m


def gradient_bg(size, box, top, bot):
    g = Image.new("RGB", (size, size), bot)
    d = ImageDraw.Draw(g)
    y0, y1 = box[1], box[3]
    for y in range(y0, y1):
        t = (y - y0) / max(1, (y1 - y0))
        d.line([(box[0], y), (box[2], y)], fill=lerp(top, bot, t))
    return g


def cursor_points(cx, cy, h):
    """macOS 经典箭头轮廓（指向左上），按高度 h 缩放并平移到 (cx, cy) 为箭头尖端。"""
    unit = [
        (0.00, 0.00),
        (0.00, 0.86),
        (0.22, 0.65),
        (0.36, 1.02),
        (0.50, 0.95),
        (0.36, 0.59),
        (0.64, 0.59),
    ]
    k = h / 1.02
    return [(cx + x * k, cy + y * k) for (x, y) in unit]


def draw_monitor(d, box, kind):
    """一台显示器：外框 + 屏幕 + 底座。kind = 'mac' | 'win'。"""
    x0, y0, x1, y1 = box
    w = x1 - x0
    r = int(w * 0.09)

    # 屏幕外框（玻璃质感：半透明白底 + 亮边）
    d.rounded_rectangle(box, radius=r, fill=(255, 255, 255, 46))
    d.rounded_rectangle(box, radius=r, outline=(255, 255, 255, 235), width=max(6, int(w * 0.032)))

    inner = (x0 + int(w * 0.075), y0 + int(w * 0.085), x1 - int(w * 0.075), y1 - int(w * 0.085))
    d.rounded_rectangle(inner, radius=int(r * 0.55), fill=(9, 26, 54, 215))

    if kind == "mac":
        # 顶部刘海
        nw = int(w * 0.20)
        nx = (x0 + x1) // 2
        ny = inner[1]
        d.rounded_rectangle((nx - nw // 2, ny - int(w * 0.012), nx + nw // 2, ny + int(w * 0.062)),
                            radius=int(w * 0.028), fill=(9, 26, 54, 255))
        # 红黄绿窗口灯
        cy = inner[1] + int(w * 0.115)
        for i, c in enumerate([(255, 95, 87), (255, 189, 46), (39, 201, 63)]):
            cxx = inner[0] + int(w * 0.135) + i * int(w * 0.115)
            rr = int(w * 0.032)
            d.ellipse((cxx - rr, cy - rr, cxx + rr, cy + rr), fill=c)
        # 表示 macOS 侧的内容线条
        ly = inner[1] + int(w * 0.28)
        for i in range(3):
            d.rounded_rectangle(
                (inner[0] + int(w * 0.13), ly + i * int(w * 0.115),
                 inner[0] + int(w * 0.13) + int(w * (0.62 - i * 0.13)),
                 ly + i * int(w * 0.115) + int(w * 0.045)),
                radius=int(w * 0.022), fill=(255, 255, 255, 105))
    else:
        # 2×2 窗格 —— 泛指被控制的 Windows 桌面
        pad = int(w * 0.11)
        gap = int(w * 0.055)
        gw = (inner[2] - inner[0] - pad * 2 - gap) // 2
        gh = (inner[3] - inner[1] - pad * 2 - gap) // 2
        for row in range(2):
            for col in range(2):
                bx = inner[0] + pad + col * (gw + gap)
                by = inner[1] + pad + row * (gh + gap)
                d.rounded_rectangle((bx, by, bx + gw, by + gh),
                                    radius=int(w * 0.022), fill=(255, 255, 255, 120))

    # 底座
    neck_w = int(w * 0.11)
    nx = (x0 + x1) // 2
    d.rounded_rectangle((nx - neck_w // 2, y1, nx + neck_w // 2, y1 + int(w * 0.075)),
                        radius=int(w * 0.02), fill=(255, 255, 255, 205))
    base_w = int(w * 0.46)
    d.rounded_rectangle((nx - base_w // 2, y1 + int(w * 0.055), nx + base_w // 2, y1 + int(w * 0.105)),
                        radius=int(w * 0.03), fill=(255, 255, 255, 205))


def build():
    box = (58, 58, S - 58, S - 58)
    radius = int((box[2] - box[0]) * 0.225)

    base = Image.new("RGBA", (S, S), (0, 0, 0, 0))
    mask = rounded_mask(S, box, radius)

    # 背景渐变
    bg = gradient_bg(S, box, BLUE_TOP, BLUE_BOT).convert("RGBA")

    # 左上高光，增加 macOS 图标的立体感
    glow = Image.new("L", (S, S), 0)
    ImageDraw.Draw(glow).ellipse((-320, -420, 760, 520), fill=95)
    glow = glow.filter(ImageFilter.GaussianBlur(90))
    bg = Image.composite(Image.new("RGBA", (S, S), (255, 255, 255, 255)), bg, glow.point(lambda v: int(v * 0.55)))

    base = Image.alpha_composite(base, Image.composite(bg, Image.new("RGBA", (S, S), (0, 0, 0, 0)), mask))

    layer = Image.new("RGBA", (S, S), (0, 0, 0, 0))
    d = ImageDraw.Draw(layer)

    # 两台显示器（左 Mac / 右 Win），中间留出光标穿过的通道
    draw_monitor(d, (128, 320, 470, 648), "mac")
    draw_monitor(d, (554, 320, 896, 648), "win")

    # 跨屏虚线弧：从左屏右缘绕到右屏左缘
    arc = Image.new("RGBA", (S, S), (0, 0, 0, 0))
    ad = ImageDraw.Draw(arc)
    ad.arc((300, 196, 724, 560), start=200, end=340, fill=(255, 255, 255, 170), width=14)
    # 用虚线遮罩叠一层，做出「虚线」感
    dash = Image.new("L", (S, S), 0)
    dd = ImageDraw.Draw(dash)
    dd.arc((300, 196, 724, 560), start=200, end=340, fill=255, width=14)
    px = dash.load()
    for y in range(S):
        for x in range(S):
            if px[x, y] and ((x + y) // 26) % 2 == 1:
                px[x, y] = 0
    arc.putalpha(Image.composite(arc.getchannel("A"), Image.new("L", (S, S), 0), dash))
    layer = Image.alpha_composite(layer, arc)

    # 光标：先画深色描边再画白色主体，落在两屏之间的通道上
    body = Image.new("RGBA", (S, S), (0, 0, 0, 0))
    bd = ImageDraw.Draw(body)
    pts = cursor_points(486, 300, 300)
    bd.polygon([(x + 17, y + 19) for (x, y) in pts], fill=INK)          # 投影
    layer = Image.alpha_composite(layer, body)

    stroke = Image.new("RGBA", (S, S), (0, 0, 0, 0))
    sd = ImageDraw.Draw(stroke)
    sd.polygon(pts, fill=INK)
    sd.line(pts + [pts[0]], fill=INK, width=34, joint="curve")
    layer = Image.alpha_composite(layer, stroke)

    fill = Image.new("RGBA", (S, S), (0, 0, 0, 0))
    fd = ImageDraw.Draw(fill)
    fd.polygon(pts, fill=WHITE)
    layer = Image.alpha_composite(layer, fill)

    out = Image.alpha_composite(base, layer)
    out = Image.composite(out, Image.new("RGBA", (S, S), (0, 0, 0, 0)), mask)
    return out


def make_icns(img):
    iconset = os.path.join(HERE, "AppIcon.iconset")
    os.makedirs(iconset, exist_ok=True)
    pairs = [(16, 1), (16, 2), (32, 1), (32, 2), (128, 1), (128, 2),
             (256, 1), (256, 2), (512, 1), (512, 2)]
    for size, scale in pairs:
        px = size * scale
        name = f"icon_{size}x{size}{'@2x' if scale == 2 else ''}.png"
        img.resize((px, px), Image.LANCZOS).save(os.path.join(iconset, name))
    subprocess.run(["iconutil", "-c", "icns", iconset, "-o", OUT_ICNS], check=True)
    print("已生成:", OUT_ICNS)


def main():
    img = build()
    img.save(PREVIEW_PNG)
    print("预览:", PREVIEW_PNG)
    make_icns(img)
    # 组装完就删掉中间的 iconset（Resilio 卷上删不掉也没关系，不影响结果）
    try:
        import shutil
        shutil.rmtree(os.path.join(HERE, "AppIcon.iconset"), ignore_errors=True)
    except Exception:
        pass
    return 0


if __name__ == "__main__":
    sys.exit(main())
