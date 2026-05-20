// SPDX-License-Identifier: LGPL-2.1-or-later
// Copyright (C) 2026 Daniel Boyd

#include "../src/COTTerminalGrid.h"

#include <cstdlib>
#include <iostream>
#include <string>
#include <vector>

namespace {

void expectLine(const cot::TerminalGrid &grid, std::size_t row, const std::string &expected) {
  const auto &lines = grid.visibleLines();
  if (row >= lines.size() || lines[row] != expected) {
    std::cerr << "Expected row " << row << " to be [" << expected << "] but got ["
              << (row < lines.size() ? lines[row] : std::string("<missing>")) << "]\n";
    std::exit(1);
  }
}

void expect(bool condition, const std::string &message) {
  if (!condition) {
    std::cerr << message << "\n";
    std::exit(1);
  }
}

std::vector<bool> takeDirty(cot::TerminalGrid &grid) {
  std::vector<bool> dirty;
  grid.getAndClearDirtyRows(dirty);
  grid.clearFullRedrawPending();
  return dirty;
}

std::size_t dirtyCount(const std::vector<bool> &dirty) {
  std::size_t count = 0;
  for (bool row : dirty) {
    if (row) {
      count += 1;
    }
  }
  return count;
}

} // namespace

int main() {
  cot::TerminalGrid grid(8, 3);

  const char *hello = "hello";
  grid.ingest(hello, 5);
  expectLine(grid, 0, "hello   ");

  const char *next = "\rbye\r\nok";
  grid.ingest(next, 8);
  expectLine(grid, 0, "byelo   ");
  expectLine(grid, 1, "ok      ");

  const char *clear = "\033[2J\033[Hx";
  grid.ingest(clear, std::char_traits<char>::length(clear));
  expectLine(grid, 0, "x       ");
  expectLine(grid, 1, "        ");

  grid.resize(4, 2);
  expectLine(grid, 0, "x   ");
  expectLine(grid, 1, "    ");

  cot::TerminalGrid dirtyGrid(8, 3);
  takeDirty(dirtyGrid);
  dirtyGrid.ingest("x", 1);
  std::vector<bool> dirty = takeDirty(dirtyGrid);
  expect(dirty.size() == 3, "expected dirty row vector to match visible rows");
  expect(dirty[0] && dirtyCount(dirty) == 1, "expected single-cell input to dirty only row 0");
  dirtyGrid.ingest("\033[B", 3);
  dirty = takeDirty(dirtyGrid);
  expect(dirty[0] && dirty[1], "expected cursor movement to dirty old and new cursor rows");
  dirtyGrid.resize(10, 4);
  expect(dirtyGrid.fullRedrawPending(), "expected resize to request a full redraw");
  dirty = takeDirty(dirtyGrid);
  expect(dirty.size() == 4 && dirtyCount(dirty) == 4, "expected resize to dirty all visible rows");

  cot::TerminalGrid colorGrid(16, 2);
  const char *color = "\033[31mred\033[0m";
  colorGrid.ingest(color, 12);
  expect(colorGrid.hasColorSpans(), "expected color spans after SGR input");
  expect(colorGrid.visibleCells()[0][0].attributes.foreground.kind == cot::TerminalColor::Kind::Palette,
         "expected palette foreground on styled cell");
  expect(colorGrid.visibleCells()[0][0].attributes.foreground.index == 1,
         "expected red palette index on styled cell");

  cot::TerminalGrid unicodeGrid(20, 2);
  const char *unicode = "box ┌─┐";
  unicodeGrid.ingest(unicode, std::char_traits<char>::length(unicode));
  expect(unicodeGrid.hasUnicode(), "expected unicode input to be observed");
  expectLine(unicodeGrid, 0, "box ┌─┐             ");

  cot::TerminalGrid scrollGrid(8, 3);
  const char *scroll = "1\r\n2\r\n3\r\n4\r\n";
  scrollGrid.ingest(scroll, std::char_traits<char>::length(scroll));
  expect(scrollGrid.scrollbackLineCount() > 0, "expected scrollback after overflowing rows");

  cot::TerminalGrid alternateGrid(20, 3);
  const char *alternate = "main\033[?1049halt\033[?1049lback";
  alternateGrid.ingest(alternate, std::char_traits<char>::length(alternate));
  expect(alternateGrid.hasUsedAlternateScreen(), "expected alternate screen usage to be tracked");
  expect(!alternateGrid.usingAlternateScreen(), "expected alternate screen to be inactive after reset");

  cot::TerminalGrid eraseGrid(12, 2);
  const char *erase = "abcdef\r\033[3C\033[K";
  eraseGrid.ingest(erase, std::char_traits<char>::length(erase));
  expectLine(eraseGrid, 0, "abc         ");

  cot::TerminalGrid deleteGrid(12, 2);
  const char *deleteChars = "abcdef\r\033[2C\033[P";
  deleteGrid.ingest(deleteChars, std::char_traits<char>::length(deleteChars));
  expectLine(deleteGrid, 0, "abdef       ");

  cot::TerminalGrid appGrid(12, 3);
  const char *appSequences = "abc\0337\r\nxy\0338Z\033[?25l";
  appGrid.ingest(appSequences, std::char_traits<char>::length(appSequences));
  expectLine(appGrid, 0, "abcZ        ");
  expect(!appGrid.cursorVisible(), "expected DECTCEM hide cursor to be tracked");
  appGrid.ingest("\033[?25h", 6);
  expect(appGrid.cursorVisible(), "expected DECTCEM show cursor to be tracked");

  cot::TerminalGrid eraseDisplayGrid(8, 3);
  const char *eraseDisplay = "111\r\n222\r\n333\033[H\033[J";
  eraseDisplayGrid.ingest(eraseDisplay, std::char_traits<char>::length(eraseDisplay));
  expectLine(eraseDisplayGrid, 0, "        ");
  expectLine(eraseDisplayGrid, 1, "        ");
  expectLine(eraseDisplayGrid, 2, "        ");

  cot::TerminalGrid mouseGrid(12, 2);
  const char *mouseModes = "\033[?1000h\033[?1002h\033[?1006h\033[?1007l";
  mouseGrid.ingest(mouseModes, std::char_traits<char>::length(mouseModes));
  expect(mouseGrid.mouseReportingEnabled(), "expected mouse reporting to be enabled");
  expect(mouseGrid.mouseButtonMotionReportingEnabled(), "expected button-motion mouse reporting");
  expect(mouseGrid.sgrMouseModeEnabled(), "expected SGR mouse mode");
  expect(!mouseGrid.alternateScrollModeEnabled(), "expected alternate scroll to be disabled");
  const char *mouseModesOff = "\033[?1000l\033[?1002l\033[?1006l";
  mouseGrid.ingest(mouseModesOff, std::char_traits<char>::length(mouseModesOff));
  expect(!mouseGrid.mouseReportingEnabled(), "expected mouse reporting to be disabled");
  expect(!mouseGrid.mouseButtonMotionReportingEnabled(), "expected button-motion mouse reporting to be disabled");
  expect(!mouseGrid.sgrMouseModeEnabled(), "expected SGR mouse mode to be disabled");

  cot::TerminalGrid lineDrawingGrid(12, 3);
  const char *lineDrawing = "\033(0lqk\r\nx x\r\nmqj\033(B";
  lineDrawingGrid.ingest(lineDrawing, std::char_traits<char>::length(lineDrawing));
  expectLine(lineDrawingGrid, 0, "┌─┐         ");
  expectLine(lineDrawingGrid, 1, "│ │         ");

  return 0;
}
