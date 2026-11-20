// SPDX-License-Identifier: LGPL-2.1-or-later
// Copyright (C) 2026 Daniel Boyd

#pragma once

#include <cstddef>
#include <cstdint>
#include <deque>
#include <functional>
#include <string>
#include <vector>

namespace cot {

struct TerminalColor {
  enum class Kind { Default, Palette, RGB };
  Kind kind = Kind::Default;
  int index = -1;
  int red = 0;
  int green = 0;
  int blue = 0;
};

struct TerminalAttributes {
  TerminalColor foreground;
  TerminalColor background;
  bool bold = false;
  bool dim = false;
  bool italic = false;
  bool underline = false;
  bool inverse = false;
  bool strike = false;
  bool blink = false;
  bool hidden = false;  // SGR 8 (conceal)

  bool operator==(const TerminalAttributes& other) const;
  bool operator!=(const TerminalAttributes& other) const { return !(*this == other); }
};

struct TerminalCell {
  std::string text = " ";
  int width = 1;
  bool continuation = false;
  TerminalAttributes attributes;
};

enum class TerminalCursorShape {
  Block = 1,
  Underline = 2,
  Bar = 3,
};

// libvterm (0.3) has no faint attribute: SGR 2 is dropped. FaintRewriter rewrites the byte stream so it survives as
// alternate font 1 (SGR 11), which libvterm keeps per cell: 2 becomes 11, 22 (normal intensity) becomes 22;10. Colour
// sub-parameters (38/48/58;5;n and ;2;r;g;b, and any colon form) pass untouched, and a sequence split across writes
// is held until it's whole.
class FaintRewriter {
public:
  std::string rewrite(const char* bytes, std::size_t length);
  static std::string rewriteParameters(const std::string& parameters);
private:
  enum class State { Ground, Escape, Csi } state_ = State::Ground;
  std::string pending_;
};

class TerminalGrid {
public:
  using OutputCallback = std::function<void(const char*, std::size_t)>;
  using TitleCallback = std::function<void(const std::string&)>;
  using BellCallback = std::function<void()>;
  using ClipboardWriteCallback = std::function<void(const std::string&)>;
  // A program asked for the clipboard (OSC 52 query). Answer with answerClipboardQuery, on the grid's thread, whenever
  // the text is in hand: reading a pasteboard can need another thread.
  using ClipboardQueryCallback = std::function<void(int mask)>;

  TerminalGrid(std::size_t columns, std::size_t rows);
  ~TerminalGrid();

  TerminalGrid(const TerminalGrid&) = delete;
  TerminalGrid& operator=(const TerminalGrid&) = delete;

  void setScrollbackLimit(std::size_t limit);
  void setOutputCallback(OutputCallback callback);
  void setTitleCallback(TitleCallback callback);
  void setBellCallback(BellCallback callback);
  void setClipboardWriteCallback(ClipboardWriteCallback callback);
  void setClipboardQueryCallback(ClipboardQueryCallback callback);
  void answerClipboardQuery(int mask, const std::string& value);

  void resize(std::size_t columns, std::size_t rows);
  void ingest(const char* bytes, std::size_t length);

  void mouseMove(int row, int col, int mod);
  void mouseButton(int button, bool pressed, int mod);
  void focusIn();
  void focusOut();

  std::size_t columns() const { return columns_; }
  std::size_t rows() const { return rows_; }
  const std::vector<std::vector<TerminalCell>>& visibleCells() const { return screen_; }
  const std::vector<std::string>& visibleLines() const { return visibleLines_; }
  std::size_t cursorColumn() const { return cursorCol_; }
  std::size_t cursorRow() const { return cursorRow_; }
  bool cursorVisible() const { return cursorVisible_; }
  TerminalCursorShape cursorShape() const { return cursorShape_; }
  std::string title() const { return title_; }

  std::size_t scrollbackLineCount() const { return scrollback_.size(); }
  const std::vector<TerminalCell>& scrollbackLine(std::size_t index) const { return scrollback_[index]; }

  // Viewport — 0 means show live screen; positive offsets pull lines from scrollback.
  std::size_t viewportOffset() const { return viewportOffset_; }
  std::size_t maxViewportOffset() const { return scrollback_.size(); }
  void setViewportOffset(std::size_t offset);
  void adjustViewportOffset(long delta);
  void scrollToBottom() { setViewportOffset(0); }

  std::vector<std::vector<TerminalCell>> viewportCells() const;
  std::vector<std::string> viewportLines() const;

  // Shell integration (OSC 133, as iTerm2, WezTerm and Windows Terminal read it): a shell that marks its prompt (A),
  // the command line (B), the command's output (C) and the end of the command with its exit status (D;n) lets the
  // terminal find prompts and a command's output. Marks on the alternate screen are ignored. Lines are numbered as in
  // findText: the scrollback (oldest first), then the screen's rows.
  struct ShellCommand {
    std::string command;   // the text between B and C (what was typed), trailing spaces dropped
    std::string output;    // the text between C and D, one '\n' between lines, trailing spaces dropped
    int exitStatus = -1;   // D's status, or -1 if the shell didn't give one
    std::size_t promptLine = 0;  // the line the command's prompt (A, or B without one) started on
    std::size_t outputLine = 0;  // the line its output started on
  };
  using CommandFinishedCallback = std::function<void(const ShellCommand&)>;
  void setCommandFinishedCallback(CommandFinishedCallback callback);
  // The lines where prompts start, oldest first (only those still held).
  std::vector<std::size_t> promptLines() const;
  // The most recent command the shell marked as finished; false if none is held (or its output scrolled away).
  bool lastFinishedCommand(ShellCommand* out) const;

  bool usingAlternateScreen() const { return usingAlternateScreen_; }
  bool hasUsedAlternateScreen() const { return hasUsedAlternateScreen_; }
  bool hasColorSpans() const { return hasColorSpans_; }
  bool hasUnicode() const { return hasUnicode_; }
  bool mouseReportingEnabled() const { return mouseMode_ != 0; }
  bool mouseButtonMotionReportingEnabled() const { return mouseMode_ >= 2; }
  bool mouseAnyMotionReportingEnabled() const { return mouseMode_ >= 3; }
  bool sgrMouseModeEnabled() const { return sgrMouseModeEnabled_; }
  bool alternateScrollModeEnabled() const { return alternateScrollModeEnabled_; }
  bool bracketedPasteEnabled() const { return bracketedPasteEnabled_; }
  bool focusReportingEnabled() const { return focusReportingEnabled_; }

  void getAndClearDirtyRows(std::vector<bool>& out);
  bool fullRedrawPending() const { return fullRedrawPending_; }
  void clearFullRedrawPending() { fullRedrawPending_ = false; }

  void sendInput(const char* bytes, std::size_t length);

private:
  void initVTerm();
  void destroyVTerm();
  void rebuildVisibleCells();
  void rebuildDirtyVisibleCells();
  void rebuildVisibleRow(std::size_t row);
  void snoopPrivateModes(const char* bytes, std::size_t length);
  FaintRewriter faint_;
  void appendScrollback(std::vector<TerminalCell> line);
  TerminalCell cellFromVTermOpaque(const void* src) const;
  TerminalCell makeBlankCell() const;
  void markRowDirty(int row);
  void markAllDirty();

  int onDamage(int startRow, int endRow);
  int onMoveCursor(int row, int col, int visible);
  int onSetTermProp(int prop, const void* val);
  int onBell();
  int onResize(int rows, int cols);
  int onScrollbackPush(int cols, const void* cells);
  int onScrollbackPop(int cols, void* cells);
  int onScrollbackClear();
  void onOutput(const char* s, std::size_t len);
  int onSelectionSet(int mask, const void* fragmentPtr);
  int onSelectionQuery(int mask);
  int onOSC(int command, const void* fragmentPtr);
  void onShellMark(const std::string& payload);

  // A shell integration mark: where (an id that doesn't change as scrollback is dropped: lineBase_ plus the line's
  // number), which mark, and D's exit status.
  struct ShellMark {
    std::uint64_t lineId = 0;
    std::size_t column = 0;
    char kind = 0;
    int exitStatus = -1;
  };
  std::uint64_t cursorLineId() const { return lineBase_ + scrollback_.size() + cursorRow_; }
  std::string textBetween(std::uint64_t fromId, std::size_t fromColumn, std::uint64_t toId, std::size_t toColumn) const;
  void dropMarksBefore(std::uint64_t lineId);
  bool buildCommand(std::size_t finishIndex, ShellCommand* out) const;
  std::deque<ShellMark> marks_;
  std::vector<ShellMark> finishedPending_;
  std::uint64_t lineBase_ = 0;  // lines dropped from the front of the scrollback so far
  std::string oscAccumulator_;
  CommandFinishedCallback commandFinishedCallback_;

  void* vt_ = nullptr;
  void* screenPtr_ = nullptr;

  std::size_t columns_;
  std::size_t rows_;
  std::size_t cursorCol_ = 0;
  std::size_t cursorRow_ = 0;
  bool cursorVisible_ = true;
  TerminalCursorShape cursorShape_ = TerminalCursorShape::Block;
  bool usingAlternateScreen_ = false;
  bool hasUsedAlternateScreen_ = false;
  bool hasColorSpans_ = false;
  bool hasUnicode_ = false;
  int mouseMode_ = 0;
  bool sgrMouseModeEnabled_ = false;
  bool alternateScrollModeEnabled_ = true;
  bool bracketedPasteEnabled_ = false;
  bool focusReportingEnabled_ = false;
  std::string title_;

  std::vector<std::vector<TerminalCell>> screen_;
  std::vector<std::string> visibleLines_;
  std::deque<std::vector<TerminalCell>> scrollback_;
  std::size_t scrollbackLimit_ = 10000;

  std::size_t viewportOffset_ = 0;
  std::vector<bool> dirtyRows_;
  bool fullRedrawPending_ = true;

  OutputCallback outputCallback_;
  TitleCallback titleCallback_;
  BellCallback bellCallback_;
  ClipboardWriteCallback clipboardWriteCallback_;
  ClipboardQueryCallback clipboardQueryCallback_;
  std::string clipboardAccumulator_;
  std::vector<char> clipboardBuffer_;

  enum class SnoopState { Ground, Escape, Csi };
  SnoopState snoopState_ = SnoopState::Ground;
  std::string snoopBuffer_;

  friend struct GridTrampolines;
};

} // namespace cot
