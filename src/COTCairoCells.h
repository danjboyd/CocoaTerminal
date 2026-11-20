// SPDX-License-Identifier: LGPL-2.1-or-later
// Copyright (C) 2026 Daniel Boyd

#pragma once

// Cells the Cairo renderer (COTTerminalView's drawRect:) draws itself rather than as text through GNUstep, as the
// OpenGL renderer does: box drawing and block elements as rectangles.

#import <AppKit/AppKit.h>

#include <cstdint>

// A cell rectangle on whole device pixels: each edge rounded on its own, so neighbouring cells (and rows) share edges
// rather than overlapping or leaving a hairline between them.
NSRect COTSnappedCellRect(NSRect rect);

// Box drawing (U+2500-257F) and block elements (U+2580-259F) in `cell` (view coordinates, y up), with the OpenGL
// renderer's geometry (COTBoxDrawing.h): filled rectangles on whole pixels, the shades blended with `background`.
// NO, drawing nothing, if the character isn't one of these.
BOOL COTDrawBoxCell(std::uint32_t character, NSRect cell, NSColor *foreground, NSColor *background);

