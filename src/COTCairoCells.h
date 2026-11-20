// SPDX-License-Identifier: LGPL-2.1-or-later
// Copyright (C) 2026 Daniel Boyd

#pragma once

// Cells the Cairo renderer (COTTerminalView's drawRect:) draws itself rather than as text through GNUstep, as the
// OpenGL renderer does: box drawing and block elements as rectangles, and emoji (and anything else above U+FFFF)
// rasterised by Cairo straight from fontconfig's font.

#import <AppKit/AppKit.h>

#include <cstdint>
#include <string>

// A cell rectangle on whole device pixels: each edge rounded on its own, so neighbouring cells (and rows) share edges
// rather than overlapping or leaving a hairline between them.
NSRect COTSnappedCellRect(NSRect rect);

// Box drawing (U+2500-257F) and block elements (U+2580-259F) in `cell` (view coordinates, y up), with the OpenGL
// renderer's geometry (COTBoxDrawing.h): filled rectangles on whole pixels, the shades blended with `background`.
// NO, drawing nothing, if the character isn't one of these.
BOOL COTDrawBoxCell(std::uint32_t character, NSRect cell, NSColor *foreground, NSColor *background);

// The cell's text (UTF-8; its first character `character`) drawn by Cairo into `cell`, fitted and centred: with a
// colour font when `emoji` and fontconfig has one that covers it, else with any font that does (`family` preferred),
// in `foreground`. For what GNUstep's Cairo backend can't draw: its glyphs are UTF-16 units, so nothing above U+FFFF
// (🚀) comes out. NO, drawing nothing, without Cairo or fontconfig (looked up at run time, as GNUstep's backend has
// them loaded) or a font with the character; and always on macOS and Windows.
BOOL COTDrawCairoGlyphCell(const std::string &text, std::uint32_t character, BOOL emoji, NSString *family,
                           CGFloat pixelSize, NSRect cell, NSColor *foreground);
