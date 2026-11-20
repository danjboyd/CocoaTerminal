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

  // Lowering the scrollback limit while lines are held drops the oldest at once, and pulls a scrolled-back
  // viewport in to what's left.
  cot::TerminalGrid trimGrid(8, 2);
  trimGrid.setScrollbackLimit(100);
  const char *many = "1\r\n2\r\n3\r\n4\r\n5\r\n6\r\n7\r\n8\r\n9\r\n";
  trimGrid.ingest(many, std::char_traits<char>::length(many));
  expect(trimGrid.scrollbackLineCount() == 8, "expected eight lines of scrollback before trimming");
  trimGrid.setViewportOffset(6);
  expect(trimGrid.viewportOffset() == 6, "expected the viewport scrolled back six lines");
  trimGrid.setScrollbackLimit(3);
  expect(trimGrid.scrollbackLineCount() == 3, "expected the scrollback trimmed to the new limit");
  expect(trimGrid.viewportOffset() == 3, "expected the viewport pulled in to the trimmed scrollback");
  trimGrid.setScrollbackLimit(50);
  expect(trimGrid.scrollbackLineCount() == 3, "raising the limit keeps what's there");

  // Shell integration (OSC 133): prompts, and the last command's text, output and exit status.
  {
    cot::TerminalGrid shellGrid(30, 4);
    shellGrid.setScrollbackLimit(100);
    std::vector<cot::TerminalGrid::ShellCommand> finished;
    shellGrid.setCommandFinishedCallback([&](const cot::TerminalGrid::ShellCommand &c) { finished.push_back(c); });
    // Prompt "$ ", command "ls", output two lines, status 0; then "false" with no output, status 1; then a prompt.
    const char *session =
        "\033]133;A\007$ \033]133;B\007ls\r\n\033]133;C\007a.txt\r\nb.txt\r\n\033]133;D;0\007"
        "\033]133;A\033\\$ \033]133;B\033\\false\r\n\033]133;C\033\\\033]133;D;1\033\\"
        "\033]133;A\007$ \033]133;B\007";
    shellGrid.ingest(session, std::char_traits<char>::length(session));
    // Lines: 0 "$ ls", 1 "a.txt", 2 "b.txt", 3 "$ false", 4 "$ " (one line in the scrollback: 4 rows).
    std::vector<std::size_t> prompts = shellGrid.promptLines();
    expect(prompts.size() == 3 && prompts[0] == 0 && prompts[1] == 3 && prompts[2] == 4, "three prompts, at lines 0, 3, 4");
    expect(finished.size() == 2, "two commands finished, reported as they did");
    expect(finished.size() == 2 && finished[0].command == "ls" && finished[0].output == "a.txt\nb.txt" &&
               finished[0].exitStatus == 0 && finished[0].promptLine == 0 && finished[0].outputLine == 1,
           "ls: its command line, two lines of output and status 0");
    cot::TerminalGrid::ShellCommand last;
    expect(shellGrid.lastFinishedCommand(&last) && last.command == "false" && last.output.empty() &&
               last.exitStatus == 1 && last.promptLine == 3,
           "the last finished command: false, no output, status 1 (ST-terminated marks)");
    // Dropping the scrollback's one line ("$ ls") drops its prompt; the others are renumbered and still right.
    shellGrid.setScrollbackLimit(0);
    prompts = shellGrid.promptLines();
    expect(prompts.size() == 2 && prompts[0] == 2 && prompts[1] == 3,
           "trimming the scrollback drops the first prompt and renumbers the others");
    expect(shellGrid.lastFinishedCommand(&last) && last.command == "false" && last.promptLine == 2,
           "the last command still found after trimming");
    // Marks on the alternate screen (a full-screen program printing them) are ignored.
    const char *alternate = "\033[?1049h\033]133;A\007x\033[?1049l";
    shellGrid.ingest(alternate, std::char_traits<char>::length(alternate));
    expect(shellGrid.promptLines().size() == 2, "no prompt from the alternate screen");
    // A D with no exit status.
    cot::TerminalGrid plain(20, 3);
    const char *noStatus = "\033]133;C\007out\r\n\033]133;D\007";
    plain.ingest(noStatus, std::char_traits<char>::length(noStatus));
    expect(plain.lastFinishedCommand(&last) && last.output == "out" && last.exitStatus == -1 && last.command.empty(),
           "a D without a status gives -1, and no B no command text");
  }

  // SGR 2 (faint) survives libvterm as alternate font 1; 22 ends it; 8 hides; colour sub-parameters pass untouched.
  expect(cot::FaintRewriter::rewriteParameters("2") == "11", "2 -> 11");
  expect(cot::FaintRewriter::rewriteParameters("1;2;31") == "1;11;31", "1;2;31 -> 1;11;31");
  expect(cot::FaintRewriter::rewriteParameters("22") == "22;10", "22 -> 22;10");
  expect(cot::FaintRewriter::rewriteParameters("38;2;2;2;2") == "38;2;2;2;2", "38;2;r;g;b untouched");
  expect(cot::FaintRewriter::rewriteParameters("48;5;2;2") == "48;5;2;11", "48;5;n then a 2");
  expect(cot::FaintRewriter::rewriteParameters("38:2::2:2:2") == "38:2::2:2:2", "colon colour untouched");
  expect(cot::FaintRewriter::rewriteParameters("") == "", "an empty SGR stays empty (reset)");
  cot::TerminalGrid dimGrid(16, 2);
  const char *dim = "\033[2mA\033[22mB\033[1;2mC\033[0mD\033[8mE\033[0m\033[38;2;2;2;2mF";
  dimGrid.ingest(dim, std::char_traits<char>::length(dim));
  // A sequence split across writes is held until it's whole.
  dimGrid.ingest("\033[", 2);
  dimGrid.ingest("2mG", 3);
  const auto &dimCells = dimGrid.visibleCells()[0];
  expect(dimCells[0].text == "A" && dimCells[0].attributes.dim, "SGR 2: A is dim");
  expect(dimCells[1].text == "B" && !dimCells[1].attributes.dim, "SGR 22 ends it: B isn't");
  expect(dimCells[2].text == "C" && dimCells[2].attributes.dim && dimCells[2].attributes.bold, "1;2: C is bold and dim");
  expect(dimCells[3].text == "D" && !dimCells[3].attributes.dim && !dimCells[3].attributes.bold, "SGR 0 resets: D");
  expect(dimCells[4].text == "E" && dimCells[4].attributes.hidden && !dimCells[4].attributes.dim, "SGR 8: E hidden, not dim");
  expect(dimCells[5].text == "F" && !dimCells[5].attributes.dim && !dimCells[5].attributes.hidden &&
         dimCells[5].attributes.foreground.red == 2 && dimCells[5].attributes.foreground.blue == 2,
         "38;2;2;2;2: F is rgb(2,2,2), not dim");
  expect(dimCells[6].text == "G" && dimCells[6].attributes.dim, "a split ESC [ 2 m still dims G");

  // OSC 52 query: the grid asks and returns at once (the host may need another thread for the pasteboard); the reply
  // goes out when the host answers.
  cot::TerminalGrid clipGrid(20, 2);
  std::string clipReply;
  int queriedMask = -1;
  clipGrid.setOutputCallback([&](const char *bytes, std::size_t length) { clipReply.append(bytes, length); });
  clipGrid.setClipboardQueryCallback([&](int mask) { queriedMask = mask; });
  clipGrid.ingest("\033]52;c;?\a", 9);
  expect(queriedMask >= 0, "an OSC 52 query reaches the host");
  expect(clipReply.empty(), "nothing is sent before the host answers");
  clipGrid.answerClipboardQuery(queriedMask, "HELLO");
  expect(clipReply.find("52;c;SEVMTE8=") != std::string::npos, "the answer is the text in base64: " + clipReply);

  return 0;
}
