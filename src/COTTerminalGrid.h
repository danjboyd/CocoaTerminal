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

class TerminalGrid {
public:
  using OutputCallback = std::function<void(const char*, std::size_t)>;
  using TitleCallback = std::function<void(const std::string&)>;
  using BellCallback = std::function<void()>;

  TerminalGrid(std::size_t columns, std::size_t rows);
  ~TerminalGrid();

  TerminalGrid(const TerminalGrid&) = delete;
  TerminalGrid& operator=(const TerminalGrid&) = delete;

  void setScrollbackLimit(std::size_t limit);
  void setOutputCallback(OutputCallback callback);
  void setTitleCallback(TitleCallback callback);
  void setBellCallback(BellCallback callback);

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
  void snoopPrivateModes(const char* bytes, std::size_t length);
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

  enum class SnoopState { Ground, Escape, Csi };
  SnoopState snoopState_ = SnoopState::Ground;
  std::string snoopBuffer_;

  friend struct GridTrampolines;
};

} // namespace cot
