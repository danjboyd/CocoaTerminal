// SPDX-License-Identifier: LGPL-2.1-or-later
// Copyright (C) 2026 Daniel Boyd

#pragma once

// The OpenGL renderer's parts: a context to draw in (WGL on Windows, EGL elsewhere) and a source of glyph bitmaps
// (DirectWrite on Windows, FreeType with fontconfig elsewhere, and on Windows when COCOATERMINAL_GL_GLYPHS=freetype).
// The renderer itself (COTGLRenderer.cpp) is the same everywhere.

#include <cstdint>
#include <memory>
#include <string>
#include <vector>

namespace cot {

struct GlyphBitmap {
  int width = 0, height = 0;
  int left = 0, top = 0;  // the bitmap's top-left from the pen position on the baseline (top is negative above it)
  bool colour = false;    // premultiplied RGBA (emoji); otherwise coverage in RGB (equal in grayscale), A = max
  std::vector<std::uint8_t> rgba;
};

class GlyphSource {
public:
  virtual ~GlyphSource() = default;
  // The glyph for one cell's text (UTF-8; may be a letter and its marks, or end in U+FE0F for emoji presentation),
  // style bit 1 bold, bit 2 italic. Something that doesn't fit the cell (an emoji) is scaled to spanWidth x
  // cellHeight. False if no font has it: the cell is left blank.
  virtual bool rasterise(const std::string &text, int style, float spanWidth, float cellHeight, GlyphBitmap *out) = 0;
  virtual std::string description() const = 0;
};

class GLContext {
public:
  virtual ~GLContext() = default;
  virtual bool makeCurrent() = 0;
  virtual void *proc(const char *name) = 0;  // any OpenGL function, 1.1 ones included
  virtual std::string description() const = 0;
};

std::unique_ptr<GLContext> MakeGLContext(std::string *error);
std::unique_ptr<GlyphSource> MakeDirectWriteGlyphs(const std::string &family, float pixelSize, bool clearType, std::string *error);
std::unique_ptr<GlyphSource> MakeFreeTypeGlyphs(const std::string &family, float pixelSize, bool clearType, std::string *error);

// Shared by the glyph sources.
std::vector<std::uint32_t> DecodeUTF8(const std::string &utf8);
bool IsCombiningMark(std::uint32_t c);

}  // namespace cot
