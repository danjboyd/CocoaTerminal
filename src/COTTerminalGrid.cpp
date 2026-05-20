// SPDX-License-Identifier: LGPL-2.1-or-later
// Copyright (C) 2026 Daniel Boyd

#include "COTTerminalGrid.h"

#include <vterm.h>

#include <algorithm>
#include <cstdlib>
#include <cstring>

namespace cot {

namespace {

constexpr std::size_t kMaximumTerminalColumns = 1000;
constexpr std::size_t kMaximumTerminalRows = 1000;

void appendUtf8(std::string& out, uint32_t codepoint) {
  if (codepoint <= 0x7f) {
    out.push_back(static_cast<char>(codepoint));
  } else if (codepoint <= 0x7ff) {
    out.push_back(static_cast<char>(0xc0 | (codepoint >> 6)));
    out.push_back(static_cast<char>(0x80 | (codepoint & 0x3f)));
  } else if (codepoint <= 0xffff) {
    out.push_back(static_cast<char>(0xe0 | (codepoint >> 12)));
    out.push_back(static_cast<char>(0x80 | ((codepoint >> 6) & 0x3f)));
    out.push_back(static_cast<char>(0x80 | (codepoint & 0x3f)));
  } else {
    out.push_back(static_cast<char>(0xf0 | (codepoint >> 18)));
    out.push_back(static_cast<char>(0x80 | ((codepoint >> 12) & 0x3f)));
    out.push_back(static_cast<char>(0x80 | ((codepoint >> 6) & 0x3f)));
    out.push_back(static_cast<char>(0x80 | (codepoint & 0x3f)));
  }
}

bool colorEquals(const TerminalColor& lhs, const TerminalColor& rhs) {
  return lhs.kind == rhs.kind && lhs.index == rhs.index && lhs.red == rhs.red &&
         lhs.green == rhs.green && lhs.blue == rhs.blue;
}

} // namespace

bool TerminalAttributes::operator==(const TerminalAttributes& other) const {
  return colorEquals(foreground, other.foreground) && colorEquals(background, other.background) &&
         bold == other.bold && dim == other.dim && italic == other.italic &&
         underline == other.underline && inverse == other.inverse && strike == other.strike &&
         blink == other.blink;
}

struct GridTrampolines {
  static int damage(VTermRect rect, void* user) {
    return static_cast<TerminalGrid*>(user)->onDamage(rect.start_row, rect.end_row);
  }
  static int moverect(VTermRect /*dest*/, VTermRect /*src*/, void* user) {
    static_cast<TerminalGrid*>(user)->markAllDirty();
    return 1;
  }
  static int movecursor(VTermPos pos, VTermPos oldpos, int visible, void* user) {
    TerminalGrid* grid = static_cast<TerminalGrid*>(user);
    grid->onDamage(oldpos.row, oldpos.row + 1);
    grid->onDamage(pos.row, pos.row + 1);
    return grid->onMoveCursor(pos.row, pos.col, visible);
  }
  static int settermprop(VTermProp prop, VTermValue* val, void* user) {
    return static_cast<TerminalGrid*>(user)->onSetTermProp(static_cast<int>(prop), val);
  }
  static int bell(void* user) {
    return static_cast<TerminalGrid*>(user)->onBell();
  }
  static int resize(int rows, int cols, void* user) {
    return static_cast<TerminalGrid*>(user)->onResize(rows, cols);
  }
  static int sb_pushline(int cols, const VTermScreenCell* cells, void* user) {
    return static_cast<TerminalGrid*>(user)->onScrollbackPush(cols, cells);
  }
  static int sb_popline(int cols, VTermScreenCell* cells, void* user) {
    return static_cast<TerminalGrid*>(user)->onScrollbackPop(cols, cells);
  }
  static int sb_clear(void* user) {
    return static_cast<TerminalGrid*>(user)->onScrollbackClear();
  }
  static void output(const char* s, size_t len, void* user) {
    static_cast<TerminalGrid*>(user)->onOutput(s, len);
  }
  static int selectionSet(VTermSelectionMask mask, VTermStringFragment frag, void* user) {
    return static_cast<TerminalGrid*>(user)->onSelectionSet(static_cast<int>(mask), &frag);
  }
  static int selectionQuery(VTermSelectionMask mask, void* user) {
    return static_cast<TerminalGrid*>(user)->onSelectionQuery(static_cast<int>(mask));
  }
};

static const VTermSelectionCallbacks kSelectionCallbacks = {
  GridTrampolines::selectionSet,
  GridTrampolines::selectionQuery,
};

static const VTermScreenCallbacks kScreenCallbacks = {
  GridTrampolines::damage,
  GridTrampolines::moverect,
  GridTrampolines::movecursor,
  GridTrampolines::settermprop,
  GridTrampolines::bell,
  GridTrampolines::resize,
  GridTrampolines::sb_pushline,
  GridTrampolines::sb_popline,
  GridTrampolines::sb_clear,
};

TerminalGrid::TerminalGrid(std::size_t columns, std::size_t rows)
    : columns_(std::max<std::size_t>(columns, 1)),
      rows_(std::max<std::size_t>(rows, 1)) {
  screen_.assign(rows_, std::vector<TerminalCell>(columns_, makeBlankCell()));
  visibleLines_.assign(rows_, std::string(columns_, ' '));
  dirtyRows_.assign(rows_, true);
  fullRedrawPending_ = true;
  initVTerm();
  rebuildVisibleCells();
}

TerminalGrid::~TerminalGrid() {
  destroyVTerm();
}

void TerminalGrid::initVTerm() {
  VTerm* vt = vterm_new(static_cast<int>(rows_), static_cast<int>(columns_));
  vterm_set_utf8(vt, 1);

  VTermScreen* screen = vterm_obtain_screen(vt);
  vterm_screen_enable_altscreen(screen, 1);
  vterm_screen_set_callbacks(screen, &kScreenCallbacks, this);
  vterm_screen_set_damage_merge(screen, VTERM_DAMAGE_ROW);
  vterm_screen_reset(screen, 1);

  VTermState* state = vterm_obtain_state(vt);
  VTermColor fg;
  VTermColor bg;
  vterm_color_indexed(&fg, 7);
  fg.type |= VTERM_COLOR_DEFAULT_FG;
  vterm_color_indexed(&bg, 0);
  bg.type |= VTERM_COLOR_DEFAULT_BG;
  vterm_state_set_default_colors(state, &fg, &bg);

  vterm_output_set_callback(vt, GridTrampolines::output, this);

  clipboardBuffer_.assign(64 * 1024, 0);
  vterm_state_set_selection_callbacks(state, &kSelectionCallbacks, this,
                                      clipboardBuffer_.data(), clipboardBuffer_.size());

  vt_ = vt;
  screenPtr_ = screen;
}

void TerminalGrid::destroyVTerm() {
  if (vt_ != nullptr) {
    vterm_free(static_cast<VTerm*>(vt_));
    vt_ = nullptr;
    screenPtr_ = nullptr;
  }
}

void TerminalGrid::setScrollbackLimit(std::size_t limit) {
  scrollbackLimit_ = limit;
  while (scrollback_.size() > scrollbackLimit_) {
    scrollback_.pop_front();
  }
}

void TerminalGrid::setOutputCallback(OutputCallback callback) {
  outputCallback_ = std::move(callback);
}

void TerminalGrid::setTitleCallback(TitleCallback callback) {
  titleCallback_ = std::move(callback);
}

void TerminalGrid::setBellCallback(BellCallback callback) {
  bellCallback_ = std::move(callback);
}

void TerminalGrid::setClipboardWriteCallback(ClipboardWriteCallback callback) {
  clipboardWriteCallback_ = std::move(callback);
}

void TerminalGrid::setClipboardReadCallback(ClipboardReadCallback callback) {
  clipboardReadCallback_ = std::move(callback);
}

void TerminalGrid::resize(std::size_t columns, std::size_t rows) {
  if (vt_ == nullptr) {
    return;
  }
  std::size_t newCols = std::min(std::max<std::size_t>(columns, 1), kMaximumTerminalColumns);
  std::size_t newRows = std::min(std::max<std::size_t>(rows, 1), kMaximumTerminalRows);
  if (newCols == columns_ && newRows == rows_) {
    return;
  }
  vterm_set_size(static_cast<VTerm*>(vt_), static_cast<int>(newRows), static_cast<int>(newCols));
  columns_ = newCols;
  rows_ = newRows;
  dirtyRows_.assign(rows_, true);
  markAllDirty();
  rebuildVisibleCells();
}

void TerminalGrid::ingest(const char* bytes, std::size_t length) {
  if (length == 0 || vt_ == nullptr) {
    return;
  }
  for (std::size_t i = 0; i < length; ++i) {
    if (static_cast<unsigned char>(bytes[i]) >= 0x80) {
      hasUnicode_ = true;
      break;
    }
  }
  snoopPrivateModes(bytes, length);
  vterm_input_write(static_cast<VTerm*>(vt_), bytes, length);
  vterm_screen_flush_damage(static_cast<VTermScreen*>(screenPtr_));
  rebuildDirtyVisibleCells();
}

void TerminalGrid::snoopPrivateModes(const char* bytes, std::size_t length) {
  auto applyParam = [&](int value, bool enabled) {
    if (value == 1006) {
      sgrMouseModeEnabled_ = enabled;
    } else if (value == 1007) {
      alternateScrollModeEnabled_ = enabled;
    } else if (value == 2004) {
      bracketedPasteEnabled_ = enabled;
    } else if (value == 1004) {
      focusReportingEnabled_ = enabled;
    }
  };

  for (std::size_t i = 0; i < length; ++i) {
    const unsigned char b = static_cast<unsigned char>(bytes[i]);
    switch (snoopState_) {
    case SnoopState::Ground:
      if (b == 0x1b) {
        snoopState_ = SnoopState::Escape;
      }
      break;
    case SnoopState::Escape:
      if (b == '[') {
        snoopState_ = SnoopState::Csi;
        snoopBuffer_.clear();
      } else {
        snoopState_ = SnoopState::Ground;
      }
      break;
    case SnoopState::Csi:
      if (b >= 0x40 && b <= 0x7e) {
        if ((b == 'h' || b == 'l') && !snoopBuffer_.empty() && snoopBuffer_[0] == '?') {
          const bool enabled = (b == 'h');
          std::string params = snoopBuffer_.substr(1);
          std::string current;
          for (char c : params) {
            if (c == ';' || c == ':') {
              if (!current.empty()) {
                applyParam(std::atoi(current.c_str()), enabled);
              }
              current.clear();
            } else if (c >= '0' && c <= '9') {
              current.push_back(c);
            }
          }
          if (!current.empty()) {
            applyParam(std::atoi(current.c_str()), enabled);
          }
        }
        snoopState_ = SnoopState::Ground;
      } else {
        snoopBuffer_.push_back(static_cast<char>(b));
      }
      break;
    }
  }
}

void TerminalGrid::sendInput(const char* bytes, std::size_t length) {
  if (outputCallback_ && length > 0) {
    outputCallback_(bytes, length);
  }
}

void TerminalGrid::mouseMove(int row, int col, int mod) {
  vterm_mouse_move(static_cast<VTerm*>(vt_), row, col, static_cast<VTermModifier>(mod));
}

void TerminalGrid::mouseButton(int button, bool pressed, int mod) {
  vterm_mouse_button(static_cast<VTerm*>(vt_), button, pressed, static_cast<VTermModifier>(mod));
}

void TerminalGrid::focusIn() {
  VTermState* state = vterm_obtain_state(static_cast<VTerm*>(vt_));
  vterm_state_focus_in(state);
}

void TerminalGrid::focusOut() {
  VTermState* state = vterm_obtain_state(static_cast<VTerm*>(vt_));
  vterm_state_focus_out(state);
}

void TerminalGrid::markRowDirty(int row) {
  if (row < 0 || static_cast<std::size_t>(row) >= rows_) {
    return;
  }
  dirtyRows_[static_cast<std::size_t>(row)] = true;
}

void TerminalGrid::markAllDirty() {
  std::fill(dirtyRows_.begin(), dirtyRows_.end(), true);
  fullRedrawPending_ = true;
}

void TerminalGrid::getAndClearDirtyRows(std::vector<bool>& out) {
  out = dirtyRows_;
  std::fill(dirtyRows_.begin(), dirtyRows_.end(), false);
}

TerminalCell TerminalGrid::makeBlankCell() const {
  TerminalCell cell;
  cell.text = " ";
  cell.width = 1;
  cell.continuation = false;
  return cell;
}

TerminalCell TerminalGrid::cellFromVTermOpaque(const void* srcPtr) const {
  const VTermScreenCell& src = *static_cast<const VTermScreenCell*>(srcPtr);
  TerminalCell cell;
  cell.text.clear();
  bool any = false;
  for (int i = 0; i < VTERM_MAX_CHARS_PER_CELL; ++i) {
    if (src.chars[i] == 0) {
      break;
    }
    appendUtf8(cell.text, src.chars[i]);
    any = true;
  }
  if (!any) {
    cell.text = " ";
  }
  cell.width = std::max(1, static_cast<int>(src.width));
  cell.continuation = false;
  cell.attributes.bold = src.attrs.bold != 0;
  cell.attributes.italic = src.attrs.italic != 0;
  cell.attributes.underline = src.attrs.underline != 0;
  cell.attributes.inverse = src.attrs.reverse != 0;
  cell.attributes.strike = src.attrs.strike != 0;
  cell.attributes.blink = src.attrs.blink != 0;
  cell.attributes.dim = src.attrs.conceal != 0;

  auto convertColor = [](const VTermColor& src, bool foreground) {
    TerminalColor color;
    bool isDefault = foreground ? VTERM_COLOR_IS_DEFAULT_FG(&src) : VTERM_COLOR_IS_DEFAULT_BG(&src);
    if (isDefault) {
      color.kind = TerminalColor::Kind::Default;
      return color;
    }
    if (VTERM_COLOR_IS_INDEXED(&src)) {
      if (src.indexed.idx < 16) {
        color.kind = TerminalColor::Kind::Palette;
        color.index = src.indexed.idx;
        return color;
      }
      VTermColor rgb = src;
      rgb.type = VTERM_COLOR_RGB;
      int idx = src.indexed.idx;
      if (idx >= 16 && idx < 232) {
        int c = idx - 16;
        int r = c / 36;
        int g = (c / 6) % 6;
        int b = c % 6;
        auto channel = [](int v) { return v == 0 ? 0 : 55 + v * 40; };
        color.kind = TerminalColor::Kind::RGB;
        color.red = channel(r);
        color.green = channel(g);
        color.blue = channel(b);
      } else if (idx >= 232) {
        int v = 8 + (idx - 232) * 10;
        color.kind = TerminalColor::Kind::RGB;
        color.red = v;
        color.green = v;
        color.blue = v;
      } else {
        color.kind = TerminalColor::Kind::Palette;
        color.index = idx;
      }
      return color;
    }
    color.kind = TerminalColor::Kind::RGB;
    color.red = src.rgb.red;
    color.green = src.rgb.green;
    color.blue = src.rgb.blue;
    return color;
  };

  cell.attributes.foreground = convertColor(src.fg, true);
  cell.attributes.background = convertColor(src.bg, false);
  return cell;
}

void TerminalGrid::rebuildVisibleCells() {
  if (screen_.size() != rows_) {
    screen_.assign(rows_, std::vector<TerminalCell>(columns_, makeBlankCell()));
  }
  for (auto& row : screen_) {
    if (row.size() != columns_) {
      row.assign(columns_, makeBlankCell());
    }
  }
  if (visibleLines_.size() != rows_) {
    visibleLines_.assign(rows_, std::string(columns_, ' '));
  }

  bool sawColor = false;
  for (std::size_t r = 0; r < rows_; ++r) {
    std::string lineText;
    lineText.reserve(columns_);
    std::size_t c = 0;
    while (c < columns_) {
      VTermScreenCell raw;
      std::memset(&raw, 0, sizeof(raw));
      VTermPos pos = { static_cast<int>(r), static_cast<int>(c) };
      vterm_screen_get_cell(static_cast<VTermScreen*>(screenPtr_), pos, &raw);
      TerminalCell cell = cellFromVTermOpaque(&raw);
      int width = cell.width;
      screen_[r][c] = cell;
      lineText += cell.text;
      for (int i = 0; i < cell.text.size(); ++i) {
        (void)i;
      }
      for (int offset = 1; offset < width && c + offset < columns_; ++offset) {
        TerminalCell continuation;
        continuation.text = " ";
        continuation.width = 0;
        continuation.continuation = true;
        continuation.attributes = cell.attributes;
        screen_[r][c + offset] = continuation;
      }
      if (cell.attributes.foreground.kind != TerminalColor::Kind::Default ||
          cell.attributes.background.kind != TerminalColor::Kind::Default) {
        sawColor = true;
      }
      c += std::max(1, width);
    }
    while (lineText.size() < columns_) {
      lineText.push_back(' ');
    }
    visibleLines_[r] = lineText;
  }
  if (sawColor) {
    hasColorSpans_ = true;
  }
}

void TerminalGrid::rebuildDirtyVisibleCells() {
  if (fullRedrawPending_ || screen_.size() != rows_ || visibleLines_.size() != rows_) {
    rebuildVisibleCells();
    return;
  }
  if (dirtyRows_.size() != rows_) {
    dirtyRows_.assign(rows_, true);
    fullRedrawPending_ = true;
    rebuildVisibleCells();
    return;
  }
  for (std::size_t row = 0; row < rows_; ++row) {
    if (dirtyRows_[row]) {
      rebuildVisibleRow(row);
    }
  }
}

void TerminalGrid::rebuildVisibleRow(std::size_t row) {
  if (row >= rows_) {
    return;
  }
  if (screen_.size() != rows_) {
    screen_.assign(rows_, std::vector<TerminalCell>(columns_, makeBlankCell()));
  }
  if (visibleLines_.size() != rows_) {
    visibleLines_.assign(rows_, std::string(columns_, ' '));
  }
  if (screen_[row].size() != columns_) {
    screen_[row].assign(columns_, makeBlankCell());
  }

  std::string lineText;
  lineText.reserve(columns_);
  bool sawColor = false;
  std::size_t column = 0;
  while (column < columns_) {
    VTermScreenCell raw;
    std::memset(&raw, 0, sizeof(raw));
    VTermPos pos = { static_cast<int>(row), static_cast<int>(column) };
    vterm_screen_get_cell(static_cast<VTermScreen*>(screenPtr_), pos, &raw);
    TerminalCell cell = cellFromVTermOpaque(&raw);
    int width = cell.width;
    screen_[row][column] = cell;
    lineText += cell.text;
    for (int offset = 1; offset < width && column + offset < columns_; ++offset) {
      TerminalCell continuation;
      continuation.text = " ";
      continuation.width = 0;
      continuation.continuation = true;
      continuation.attributes = cell.attributes;
      screen_[row][column + offset] = continuation;
    }
    if (cell.attributes.foreground.kind != TerminalColor::Kind::Default ||
        cell.attributes.background.kind != TerminalColor::Kind::Default) {
      sawColor = true;
    }
    column += std::max(1, width);
  }
  while (lineText.size() < columns_) {
    lineText.push_back(' ');
  }
  visibleLines_[row] = lineText;
  if (sawColor) {
    hasColorSpans_ = true;
  }
}

void TerminalGrid::appendScrollback(std::vector<TerminalCell> line) {
  if (scrollbackLimit_ == 0) {
    return;
  }
  scrollback_.push_back(std::move(line));
  while (scrollback_.size() > scrollbackLimit_) {
    scrollback_.pop_front();
  }
  if (viewportOffset_ > scrollback_.size()) {
    viewportOffset_ = scrollback_.size();
  }
}

void TerminalGrid::setViewportOffset(std::size_t offset) {
  if (offset > scrollback_.size()) {
    offset = scrollback_.size();
  }
  viewportOffset_ = offset;
  markAllDirty();
}

void TerminalGrid::adjustViewportOffset(long delta) {
  long current = static_cast<long>(viewportOffset_);
  long next = current + delta;
  if (next < 0) {
    next = 0;
  }
  setViewportOffset(static_cast<std::size_t>(next));
}

std::vector<std::vector<TerminalCell>> TerminalGrid::viewportCells() const {
  if (viewportOffset_ == 0) {
    return screen_;
  }
  std::vector<std::vector<TerminalCell>> result;
  result.reserve(rows_);
  std::size_t fromScrollback = std::min(viewportOffset_, scrollback_.size());
  std::size_t startIndex = scrollback_.size() - fromScrollback;
  for (std::size_t i = 0; i < fromScrollback && result.size() < rows_; ++i) {
    std::vector<TerminalCell> line = scrollback_[startIndex + i];
    if (line.size() < columns_) {
      line.resize(columns_, makeBlankCell());
    } else if (line.size() > columns_) {
      line.resize(columns_);
    }
    result.push_back(std::move(line));
  }
  std::size_t liveRows = rows_ - result.size();
  for (std::size_t r = 0; r < liveRows && r < screen_.size(); ++r) {
    result.push_back(screen_[r]);
  }
  while (result.size() < rows_) {
    result.push_back(std::vector<TerminalCell>(columns_, makeBlankCell()));
  }
  return result;
}

std::vector<std::string> TerminalGrid::viewportLines() const {
  if (viewportOffset_ == 0) {
    return visibleLines_;
  }
  auto cells = viewportCells();
  std::vector<std::string> result;
  result.reserve(cells.size());
  for (const auto& row : cells) {
    std::string line;
    line.reserve(columns_);
    for (const auto& cell : row) {
      if (!cell.continuation) {
        line += cell.text;
      }
    }
    while (line.size() < columns_) {
      line.push_back(' ');
    }
    result.push_back(std::move(line));
  }
  return result;
}

int TerminalGrid::onDamage(int startRow, int endRow) {
  for (int row = startRow; row < endRow; ++row) {
    markRowDirty(row);
  }
  return 1;
}

int TerminalGrid::onMoveCursor(int row, int col, int visible) {
  markRowDirty(static_cast<int>(cursorRow_));
  cursorRow_ = row >= 0 ? static_cast<std::size_t>(row) : 0;
  cursorCol_ = col >= 0 ? static_cast<std::size_t>(col) : 0;
  markRowDirty(static_cast<int>(cursorRow_));
  if (visible == 0) {
    cursorVisible_ = false;
  } else if (visible == 1) {
    cursorVisible_ = true;
  }
  return 1;
}

int TerminalGrid::onSetTermProp(int propRaw, const void* valPtr) {
  VTermProp prop = static_cast<VTermProp>(propRaw);
  const VTermValue* val = static_cast<const VTermValue*>(valPtr);
  switch (prop) {
  case VTERM_PROP_CURSORVISIBLE:
    cursorVisible_ = val->boolean != 0;
    break;
  case VTERM_PROP_ALTSCREEN:
    usingAlternateScreen_ = val->boolean != 0;
    if (usingAlternateScreen_) {
      hasUsedAlternateScreen_ = true;
    }
    markAllDirty();
    break;
  case VTERM_PROP_TITLE:
  case VTERM_PROP_ICONNAME:
    if (val->string.initial) {
      title_.clear();
    }
    title_.append(val->string.str, val->string.len);
    if (val->string.final && titleCallback_) {
      titleCallback_(title_);
    }
    break;
  case VTERM_PROP_CURSORSHAPE:
    switch (val->number) {
    case VTERM_PROP_CURSORSHAPE_BLOCK:
      cursorShape_ = TerminalCursorShape::Block;
      break;
    case VTERM_PROP_CURSORSHAPE_UNDERLINE:
      cursorShape_ = TerminalCursorShape::Underline;
      break;
    case VTERM_PROP_CURSORSHAPE_BAR_LEFT:
      cursorShape_ = TerminalCursorShape::Bar;
      break;
    default:
      break;
    }
    break;
  case VTERM_PROP_MOUSE:
    mouseMode_ = val->number;
    break;
  case VTERM_PROP_FOCUSREPORT:
    focusReportingEnabled_ = val->boolean != 0;
    break;
  default:
    break;
  }
  return 1;
}

int TerminalGrid::onBell() {
  if (bellCallback_) {
    bellCallback_();
  }
  return 1;
}

int TerminalGrid::onResize(int rows, int cols) {
  rows_ = std::max(1, rows);
  columns_ = std::max(1, cols);
  dirtyRows_.assign(rows_, true);
  fullRedrawPending_ = true;
  return 1;
}

int TerminalGrid::onScrollbackPush(int cols, const void* cellsPtr) {
  const VTermScreenCell* cells = static_cast<const VTermScreenCell*>(cellsPtr);
  std::vector<TerminalCell> line;
  line.reserve(static_cast<std::size_t>(cols));
  for (int c = 0; c < cols; ++c) {
    line.push_back(cellFromVTermOpaque(&cells[c]));
  }
  appendScrollback(std::move(line));
  return 1;
}

int TerminalGrid::onScrollbackPop(int cols, void* cellsPtr) {
  VTermScreenCell* cells = static_cast<VTermScreenCell*>(cellsPtr);
  if (scrollback_.empty()) {
    return 0;
  }
  std::vector<TerminalCell> line = std::move(scrollback_.back());
  scrollback_.pop_back();
  int n = std::min(static_cast<int>(line.size()), cols);
  for (int c = 0; c < n; ++c) {
    std::memset(&cells[c], 0, sizeof(cells[c]));
    const TerminalCell& src = line[static_cast<std::size_t>(c)];
    cells[c].width = std::max(1, src.width);
    cells[c].attrs.bold = src.attributes.bold ? 1 : 0;
    cells[c].attrs.italic = src.attributes.italic ? 1 : 0;
    cells[c].attrs.underline = src.attributes.underline ? VTERM_UNDERLINE_SINGLE : 0;
    cells[c].attrs.reverse = src.attributes.inverse ? 1 : 0;
    cells[c].attrs.strike = src.attributes.strike ? 1 : 0;
    cells[c].attrs.blink = src.attributes.blink ? 1 : 0;
    if (!src.text.empty()) {
      const unsigned char* p = reinterpret_cast<const unsigned char*>(src.text.data());
      std::size_t remaining = src.text.size();
      int slot = 0;
      while (remaining > 0 && slot < VTERM_MAX_CHARS_PER_CELL) {
        uint32_t codepoint = 0;
        int consumed = 1;
        if ((p[0] & 0x80) == 0) {
          codepoint = p[0];
        } else if ((p[0] & 0xe0) == 0xc0 && remaining >= 2) {
          codepoint = ((p[0] & 0x1f) << 6) | (p[1] & 0x3f);
          consumed = 2;
        } else if ((p[0] & 0xf0) == 0xe0 && remaining >= 3) {
          codepoint = ((p[0] & 0x0f) << 12) | ((p[1] & 0x3f) << 6) | (p[2] & 0x3f);
          consumed = 3;
        } else if ((p[0] & 0xf8) == 0xf0 && remaining >= 4) {
          codepoint = ((p[0] & 0x07) << 18) | ((p[1] & 0x3f) << 12) |
                      ((p[2] & 0x3f) << 6) | (p[3] & 0x3f);
          consumed = 4;
        }
        cells[c].chars[slot++] = codepoint;
        p += consumed;
        remaining -= consumed;
      }
    }
    if (src.attributes.foreground.kind == TerminalColor::Kind::Default) {
      cells[c].fg.type = VTERM_COLOR_RGB | VTERM_COLOR_DEFAULT_FG;
    } else if (src.attributes.foreground.kind == TerminalColor::Kind::Palette) {
      vterm_color_indexed(&cells[c].fg, static_cast<uint8_t>(src.attributes.foreground.index));
    } else {
      vterm_color_rgb(&cells[c].fg,
                      static_cast<uint8_t>(src.attributes.foreground.red),
                      static_cast<uint8_t>(src.attributes.foreground.green),
                      static_cast<uint8_t>(src.attributes.foreground.blue));
    }
    if (src.attributes.background.kind == TerminalColor::Kind::Default) {
      cells[c].bg.type = VTERM_COLOR_RGB | VTERM_COLOR_DEFAULT_BG;
    } else if (src.attributes.background.kind == TerminalColor::Kind::Palette) {
      vterm_color_indexed(&cells[c].bg, static_cast<uint8_t>(src.attributes.background.index));
    } else {
      vterm_color_rgb(&cells[c].bg,
                      static_cast<uint8_t>(src.attributes.background.red),
                      static_cast<uint8_t>(src.attributes.background.green),
                      static_cast<uint8_t>(src.attributes.background.blue));
    }
  }
  return 1;
}

int TerminalGrid::onScrollbackClear() {
  scrollback_.clear();
  return 1;
}

void TerminalGrid::onOutput(const char* s, std::size_t len) {
  if (outputCallback_) {
    outputCallback_(s, len);
  }
}

int TerminalGrid::onSelectionSet(int /*mask*/, const void* fragmentPtr) {
  const VTermStringFragment* frag = static_cast<const VTermStringFragment*>(fragmentPtr);
  if (frag->initial) {
    clipboardAccumulator_.clear();
  }
  if (frag->len > 0 && frag->str != nullptr) {
    clipboardAccumulator_.append(frag->str, frag->len);
  }
  if (frag->final) {
    if (clipboardWriteCallback_) {
      clipboardWriteCallback_(clipboardAccumulator_);
    }
    clipboardAccumulator_.clear();
  }
  return 1;
}

int TerminalGrid::onSelectionQuery(int maskRaw) {
  if (!clipboardReadCallback_) {
    return 0;
  }
  std::string value = clipboardReadCallback_();
  VTermStringFragment frag;
  std::memset(&frag, 0, sizeof(frag));
  frag.str = value.data();
  frag.len = value.size();
  frag.initial = true;
  frag.final = true;
  VTermState* state = vterm_obtain_state(static_cast<VTerm*>(vt_));
  vterm_state_send_selection(state, static_cast<VTermSelectionMask>(maskRaw), frag);
  return 1;
}

} // namespace cot
