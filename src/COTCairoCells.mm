// SPDX-License-Identifier: LGPL-2.1-or-later
// Copyright (C) 2026 Daniel Boyd

#import "COTCairoCells.h"

#include <math.h>

#include "COTBoxDrawing.h"

NSRect COTSnappedCellRect(NSRect rect) {
  CGFloat left = round(NSMinX(rect)), right = round(NSMaxX(rect));
  CGFloat bottom = round(NSMinY(rect)), top = round(NSMaxY(rect));
  return NSMakeRect(left, bottom, right - left, top - bottom);
}

BOOL COTDrawBoxCell(std::uint32_t character, NSRect cell, NSColor *foreground, NSColor *background) {
  if (character < 0x2500 || character > 0x259F) return NO;
  NSRect snapped = COTSnappedCellRect(cell);
  // COTBoxDrawing's y runs down: flip the view's y (up) so the cell's top edge is y0.
  float x0 = (float)NSMinX(snapped), x1 = (float)NSMaxX(snapped);
  float y0 = (float)-NSMaxY(snapped), y1 = (float)-NSMinY(snapped);
  return cot::BoxDrawing(character, x0, y0, x1, y1, [&](float l, float t, float r, float b, float shade) {
    if (r <= l || b <= t) return;
    NSColor *colour = shade < 1 ? ([background blendedColorWithFraction:shade ofColor:foreground] ?: foreground) : foreground;
    [colour setFill];
    NSRectFill(NSMakeRect(l, -b, r - l, b - t));
  }) ? YES : NO;
}
