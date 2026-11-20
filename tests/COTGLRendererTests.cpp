// SPDX-License-Identifier: LGPL-2.1-or-later
// Copyright (C) 2026 Daniel Boyd
//
// The OpenGL renderer draws what a frame says: backgrounds and the block cursor in their exact colours, box drawing
// right to the cell's edges (so lines join), text in the text colour, and emoji in colour. Skips, passing, where
// there's no OpenGL 3.3 with framebuffers (Windows' own software OpenGL, a build without the renderer); Mesa's
// llvmpipe is enough (put its opengl32.dll beside the test on Windows, GALLIUM_DRIVER=llvmpipe).

#include "../src/COTGLRenderer.h"

#include <cstdio>
#include <cstdlib>
#include <string>
#include <vector>

namespace {

int failures = 0;

void expect(bool condition, const std::string &message) {
  if (!condition) {
    std::fprintf(stderr, "FAIL: %s\n", message.c_str());
    failures++;
  }
}

struct Image {
  int width, height;
  std::vector<std::uint8_t> rgba;
  std::uint32_t at(int x, int y) const {
    const std::uint8_t *p = &rgba[4 * ((std::size_t)y * width + x)];
    return ((std::uint32_t)p[0] << 16) | ((std::uint32_t)p[1] << 8) | p[2];
  }
};

std::string Hex(std::uint32_t rgb) {
  char buffer[16];
  std::snprintf(buffer, sizeof buffer, "#%06x", rgb);
  return buffer;
}

}  // namespace

int main() {
#if defined(_WIN32)
  const char *family = "Consolas";
#else
  const char *family = "DejaVu Sans Mono";
#endif
  std::string error;
  auto renderer = cot::GLRenderer::create(family, 17.0f, cot::GLRenderer::Antialiasing::Grayscale, &error);
  if (!renderer) {
    std::printf("skipped: %s\n", error.c_str());
    return 0;
  }
  std::printf("%s\n", renderer->description().c_str());

  // 8 x 3 cells of 10 x 20 pixels, from (5, 5).
  cot::GLFrame frame;
  frame.columns = 8;
  frame.rows = 3;
  frame.cellWidth = 10;
  frame.cellHeight = 20;
  frame.baseline = 15;
  frame.originX = 5;
  frame.originY = 5;
  frame.pixelWidth = 5 + 8 * 10 + 5;
  frame.pixelHeight = 5 + 3 * 20 + 5;
  frame.background = 0x101010;
  frame.cells.resize(24);
  for (auto &cell : frame.cells) cell.foreground = 0xF0F0F0;
  // Row 0: "M" on red, a blank on green, then ─ ─ (box drawing, which must reach both edges of its cells).
  frame.cells[0].text = "M";
  frame.cells[0].background = 0xC00000;
  frame.cells[0].drawBackground = true;
  frame.cells[1].background = 0x00C000;
  frame.cells[1].drawBackground = true;
  frame.cells[2].text = "\xE2\x94\x80";
  frame.cells[3].text = "\xE2\x94\x80";
  frame.cells[4].text = "\xE2\x96\x88";  // █ full block: the whole cell
  // Row 1: a rocket (wide, colour) and the block cursor on column 3.
  frame.cells[8].text = "\xF0\x9F\x9A\x80";
  frame.cells[8].width = 2;
  frame.cells[9].width = 0;
  frame.cursorStyle = cot::GLCursorStyle::Block;
  frame.cursorRow = 1;
  frame.cursorColumn = 3;
  frame.cursorColour = 0x0000F0;
  frame.cursorTextColour = 0x101010;

  Image image{frame.pixelWidth, frame.pixelHeight, std::vector<std::uint8_t>((std::size_t)frame.pixelWidth * frame.pixelHeight * 4)};
  bool rendered = renderer->render(frame, image.rgba.data(), &error);
  expect(rendered, "render failed: " + error);
  if (!rendered) return 1;

  auto cellX = [&](int column) { return 5 + column * 10; };
  auto cellY = [&](int row) { return 5 + row * 20; };
  // Backgrounds: exact, edge to edge.
  expect(image.at(1, 1) == 0x101010, "margin should be the frame background, got " + Hex(image.at(1, 1)));
  expect(image.at(cellX(1) + 1, cellY(0) + 1) == 0x00C000, "cell 1 background green, got " + Hex(image.at(cellX(1) + 1, cellY(0) + 1)));
  expect(image.at(cellX(1) + 9, cellY(0) + 19) == 0x00C000, "green reaches the cell's far corner");
  expect(image.at(cellX(0), cellY(0)) == 0xC00000, "red background from the cell's first pixel");
  // Text: some pixel of the M is light, on red.
  bool lit = false;
  for (int y = cellY(0); y < cellY(1); y++)
    for (int x = cellX(0); x < cellX(1); x++) lit = lit || ((image.at(x, y) >> 8 & 0xFF) > 0x80);
  expect(lit, "the M should put light pixels on its red cell");
  // Box drawing: the horizontal line touches both edges of both cells, so ─ ─ is unbroken.
  int lineY = -1;
  for (int y = cellY(0); y < cellY(1); y++) {
    if (image.at(cellX(2) + 5, y) == 0xF0F0F0) lineY = y;
  }
  expect(lineY >= 0, "─ draws a line in its cell");
  if (lineY >= 0) {
    for (int x = cellX(2); x < cellX(4); x++) {
      if (image.at(x, lineY) != 0xF0F0F0) {
        expect(false, "─ ─ is broken at x=" + std::to_string(x) + ": " + Hex(image.at(x, lineY)));
        break;
      }
    }
  }
  expect(image.at(cellX(4), cellY(0)) == 0xF0F0F0 && image.at(cellX(4) + 9, cellY(0) + 19) == 0xF0F0F0, "█ fills its cell");
  // The block cursor's cell is the cursor colour.
  expect(image.at(cellX(3) + 1, cellY(1) + 1) == 0x0000F0, "block cursor colour, got " + Hex(image.at(cellX(3) + 1, cellY(1) + 1)));
  // The rocket: some saturated colour in its two cells (an emoji font may be missing: then it's blank, not grey).
  int coloured = 0, grey = 0;
  for (int y = cellY(1); y < cellY(2); y++)
    for (int x = cellX(0); x < cellX(2); x++) {
      std::uint32_t c = image.at(x, y);
      int r = c >> 16, g = (c >> 8) & 0xFF, b = c & 0xFF;
      int spread = std::max(r, std::max(g, b)) - std::min(r, std::min(g, b));
      if (spread > 60) coloured++;
      else if (c != 0x101010) grey++;
    }
  if (coloured == 0 && grey == 0) {
    std::printf("note: no emoji font drew the rocket\n");
  } else {
    expect(coloured > 10, "the rocket should be in colour (" + std::to_string(coloured) + " coloured pixels)");
  }

  if (failures == 0) std::printf("CocoaTerminalGLRendererTests passed\n");
  return failures == 0 ? 0 : 1;
}
