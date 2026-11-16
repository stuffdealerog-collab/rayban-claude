#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""Рисует иконку приложения: четыре линии метро сходятся на фарфоровой пересадке.

Запуск: python3 scripts/design/make_app_icon.py
Нужен Pillow. Цвета — из RayBanClaude/Design/Theme.swift.
"""
from PIL import Image, ImageDraw

SIZE = 1024
SCALE = 4  # рисуем вчетверо крупнее и уменьшаем — так края гладкие
S = SIZE * SCALE

GROUND = (0x0B, 0x12, 0x30)
SCARLET = (0xE0, 0x2A, 0x38)
COBALT = (0x2A, 0x63, 0xFF)
GREEN = (0x2C, 0xC5, 0x61)
AMBER = (0xFF, 0xC2, 0x0E)
PORCELAIN = (0xF7, 0xF6, 0xF2)

image = Image.new("RGB", (S, S), GROUND)
draw = ImageDraw.Draw(image)


def line(points, color, width=88):
    scaled = [(x * SCALE, y * SCALE) for x, y in points]
    draw.line(scaled, fill=color, width=width * SCALE, joint="curve")
    radius = width * SCALE / 2
    for x, y in scaled:  # скруглённые стыки
        draw.ellipse([x - radius, y - radius, x + radius, y + radius], fill=color)


C = SIZE / 2
# Линии выходят за край: иконка — фрагмент схемы, а не значок в рамке.
line([(C, -80), (C, SIZE + 80)], AMBER)
line([(-80, 834), (190, 834), (834, 190), (SIZE + 80, 190)], GREEN)
line([(-80, 190), (190, 190), (834, 834), (SIZE + 80, 834)], COBALT)
line([(-80, C), (SIZE + 80, C)], SCARLET)

# Пересадка: фарфоровый диск в кольце эмали.
hub = 176
ring = 46
draw.ellipse([(C - hub) * SCALE, (C - hub) * SCALE, (C + hub) * SCALE, (C + hub) * SCALE], fill=GROUND)
draw.ellipse(
    [(C - hub + ring) * SCALE, (C - hub + ring) * SCALE, (C + hub - ring) * SCALE, (C + hub - ring) * SCALE],
    fill=PORCELAIN,
)

image = image.resize((SIZE, SIZE), Image.LANCZOS)
out = "RayBanClaude/Resources/Assets.xcassets/AppIcon.appiconset/AppIcon.png"
image.save(out)
print("saved", out)
