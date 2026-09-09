#!/usr/bin/env python3
"""Render exported SwiftTUI ANSI cells without adding presentation chrome."""

import argparse
from pathlib import Path
import re
import unicodedata

from PIL import Image, ImageDraw, ImageFont


PALETTE = [
    (0, 0, 0), (205, 49, 49), (13, 188, 121), (229, 229, 16),
    (36, 114, 200), (188, 63, 188), (17, 168, 205), (229, 229, 229),
    (102, 102, 102), (241, 76, 76), (35, 209, 139), (245, 245, 67),
    (59, 142, 234), (214, 112, 214), (41, 184, 219), (255, 255, 255),
]
DEFAULT_FOREGROUND = (229, 229, 229)
DEFAULT_BACKGROUND = (0, 0, 0)
CELL_WIDTH, CELL_HEIGHT = 10, 20
SGR = re.compile(r"\x1b\[([0-9;]*)m")


def indexed_color(index):
    if index < 16:
        return PALETTE[index]
    if index < 232:
        index -= 16
        levels = [0, 95, 135, 175, 215, 255]
        return levels[index // 36], levels[index // 6 % 6], levels[index % 6]
    return (8 + (index - 232) * 10,) * 3


def parse_cells(text):
    foreground, background = DEFAULT_FOREGROUND, DEFAULT_BACKGROUND
    bold = dim = underline = strike = False
    cells = []
    column = row = position = 0
    maximum_column = 0
    while position < len(text):
        match = SGR.match(text, position)
        if match:
            values = [int(value or 0) for value in match.group(1).split(";")]
            index = 0
            while index < len(values):
                value = values[index]
                if value == 0:
                    foreground, background = DEFAULT_FOREGROUND, DEFAULT_BACKGROUND
                    bold = dim = underline = strike = False
                elif value == 1:
                    bold = True
                elif value == 2:
                    dim = True
                elif value == 22:
                    bold = dim = False
                elif value in (4, 24):
                    underline = value == 4
                elif value in (9, 29):
                    strike = value == 9
                elif 30 <= value <= 37:
                    foreground = PALETTE[value - 30]
                elif 90 <= value <= 97:
                    foreground = PALETTE[value - 90 + 8]
                elif 40 <= value <= 47:
                    background = PALETTE[value - 40]
                elif 100 <= value <= 107:
                    background = PALETTE[value - 100 + 8]
                elif value == 39:
                    foreground = DEFAULT_FOREGROUND
                elif value == 49:
                    background = DEFAULT_BACKGROUND
                elif value in (38, 48) and index + 1 < len(values):
                    if values[index + 1] == 2 and index + 4 < len(values):
                        color = tuple(values[index + 2:index + 5])
                        index += 4
                    elif values[index + 1] == 5 and index + 2 < len(values):
                        color = indexed_color(values[index + 2])
                        index += 2
                    else:
                        raise ValueError("Unsupported ANSI color sequence")
                    if value == 38:
                        foreground = color
                    else:
                        background = color
                index += 1
            position = match.end()
            continue
        character = text[position]
        position += 1
        if character == "\n":
            maximum_column = max(maximum_column, column)
            column = 0
            row += 1
            continue
        if ord(character) < 32:
            raise ValueError(f"Unexpected control character: {character!r}")
        width = 0 if unicodedata.combining(character) else (2 if unicodedata.east_asian_width(character) in "WF" else 1)
        cells.append((column, row, character, width, foreground, background, bold, dim, underline, strike))
        column += width
    return cells, max(maximum_column, column), row + 1


def render(source, destination):
    cells, columns, rows = parse_cells(source.read_text(encoding="utf-8"))
    fonts = {
        False: ImageFont.truetype("/usr/share/fonts/truetype/dejavu/DejaVuSansMono.ttf", 15),
        True: ImageFont.truetype("/usr/share/fonts/truetype/dejavu/DejaVuSansMono-Bold.ttf", 15),
    }
    image = Image.new("RGB", (max(1, columns) * CELL_WIDTH, rows * CELL_HEIGHT), DEFAULT_BACKGROUND)
    draw = ImageDraw.Draw(image)
    for column, row, character, width, foreground, background, bold, dim, underline, strike in cells:
        x, y = column * CELL_WIDTH, row * CELL_HEIGHT
        if width:
            draw.rectangle((x, y, x + width * CELL_WIDTH - 1, y + CELL_HEIGHT - 1), fill=background)
        color = tuple(round((channel + background[index]) / 2) for index, channel in enumerate(foreground)) if dim else foreground
        draw.text((x, y + 1), character, font=fonts[bold], fill=color)
        if underline:
            draw.line((x, y + 18, x + width * CELL_WIDTH - 1, y + 18), fill=color)
        if strike:
            draw.line((x, y + 10, x + width * CELL_WIDTH - 1, y + 10), fill=color)
    image.save(destination)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("input_directory", type=Path)
    parser.add_argument("output_directory", type=Path)
    arguments = parser.parse_args()
    arguments.output_directory.mkdir(parents=True, exist_ok=True)
    for source in sorted(arguments.input_directory.glob("*.ansi")):
        destination = arguments.output_directory / (source.stem + ".png")
        render(source, destination)
        print(destination)


if __name__ == "__main__":
    main()
