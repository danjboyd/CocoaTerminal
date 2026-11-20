// SPDX-License-Identifier: LGPL-2.1-or-later
// Copyright (C) 2026 Daniel Boyd

#pragma once

// An OpenGL renderer for the terminal's cells, after Alacritty's design: glyphs rasterised once into an atlas, then
// each frame two batched passes (cell backgrounds, then glyphs). Either straight into an NSOpenGLView's window (when
// GNUstep's NSOpenGLView hides and clips its child window with the view: see bench/COTGLCheck.mm), or into an
// off-screen framebuffer, read back into memory the view draws as an image.
//
// Plain C++, so platform headers stay out of the Objective-C view. Windows only for now: WGL for the context and
// DirectWrite for glyphs, the rasteriser Windows Terminal and Alacritty use there.

#include <cstddef>
#include <cstdint>
#include <memory>
#include <string>
#include <vector>

namespace cot {

struct GLCell {
  std::string text;        // UTF-8, already composed; empty or " " draws no glyph
  std::uint32_t foreground;  // 0xRRGGBB
  std::uint32_t background;  // 0xRRGGBB
  std::uint8_t width = 1;    // cells it covers (2 for wide characters)
  bool bold = false, italic = false, underline = false, strike = false;
  bool drawBackground = false;  // false: the frame's background shows
};

enum class GLCursorStyle { None, Block, Beam, Underline };

struct GLFrame {
  int columns = 0, rows = 0;
  int pixelWidth = 0, pixelHeight = 0;  // the view's size in pixels
  float originX = 0, originY = 0;       // the first cell's top-left, from the view's top-left
  float cellWidth = 0, cellHeight = 0;
  float baseline = 0;                   // from a cell's top
  std::uint32_t background = 0;
  std::vector<GLCell> cells;            // rows * columns, row-major; a wide cell's continuation is width 0
  GLCursorStyle cursorStyle = GLCursorStyle::None;
  int cursorColumn = 0, cursorRow = 0;
  std::uint32_t cursorColour = 0;
  std::uint32_t cursorTextColour = 0;   // the glyph under a block cursor
};

struct GLTiming {
  double prepare = 0;   // building the batches, rasterising new glyphs
  double draw = 0;      // issuing the two passes
  double readback = 0;  // glReadPixels, which waits for the GPU to finish
  std::size_t glyphsRasterised = 0, atlasGlyphs = 0;
};

class GLRenderer {
public:
  enum class Antialiasing { Grayscale, ClearType };
  // Own: the renderer's own hidden context, drawing off screen. Current: the context current when create and render
  // are called (an NSOpenGLView's), which owns the renderer's OpenGL objects: make a new renderer if it changes.
  enum class Context { Own, Current };

  // The font as a family name and a size in pixels. Null and a message on failure (no OpenGL 3.3 with framebuffers,
  // font not found); the view then draws with Cairo.
  static std::unique_ptr<GLRenderer> create(const std::string &fontFamily, float pixelSize, Antialiasing antialiasing,
                                            std::string *error, Context context = Context::Own);
  virtual ~GLRenderer() = default;

  // Draws the frame and reads it back into pixels: pixelWidth * pixelHeight RGBA bytes, top row first, the layout an
  // NSBitmapImageRep wants. With pixels null, draws into the current context's default framebuffer (a window's)
  // instead, for the caller to swap; no readback. False and a message on failure.
  virtual bool render(const GLFrame &frame, std::uint8_t *pixels, std::string *error) = 0;

  // The current context's swap interval: 1 waits for the display's refresh, 0 doesn't (for measuring). False if the
  // driver won't.
  static bool setSwapInterval(int interval);

  virtual std::string description() const = 0;  // "OpenGL 4.6 on llvmpipe; DirectWrite ClearType"
  virtual const GLTiming &lastTiming() const = 0;
};

}  // namespace cot
