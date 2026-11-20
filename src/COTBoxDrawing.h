// SPDX-License-Identifier: LGPL-2.1-or-later
// Copyright (C) 2026 Daniel Boyd

#pragma once

// Box drawing (U+2500-257F) and block elements (U+2580-259F) as rectangles in a cell, rather than glyphs from the
// font: a font's lines stop short of the cell's edges once there's line spacing, so boxes don't join. Alacritty and
// Windows Terminal draw these themselves for the same reason. Diagonals (U+2571-2573) are left to the font.

#include <cmath>
#include <cstdint>
#include <functional>

namespace cot {

// Calls rect(x0, y0, x1, y1, shade) for each piece of the character in the cell [x0, x1) x [y0, y1) (whole pixels,
// y down), shade 1 for the foreground or 0.25/0.5/0.75 for the shade characters (blend with the background). False if
// the character isn't one drawn here.
inline bool BoxDrawing(std::uint32_t c, float x0, float y0, float x1, float y1,
                       const std::function<void(float, float, float, float, float)> &rect) {
  float width = x1 - x0, height = y1 - y0;
  if (c >= 0x2580 && c <= 0x259F) {
    auto part = [&](float l, float t, float r, float b, float shade = 1) {
      rect(std::round(x0 + l * width), std::round(y0 + t * height), std::round(x0 + r * width), std::round(y0 + b * height), shade);
    };
    if (c == 0x2580) part(0, 0, 1, 0.5f);
    else if (c >= 0x2581 && c <= 0x2588) part(0, 1 - (c - 0x2580) / 8.0f, 1, 1);  // lower eighths up to full
    else if (c >= 0x2589 && c <= 0x258F) part(0, 0, (0x2590 - c) / 8.0f, 1);      // left seven eighths down to one
    else if (c == 0x2590) part(0.5f, 0, 1, 1);
    else if (c >= 0x2591 && c <= 0x2593) part(0, 0, 1, 1, (c - 0x2590) / 4.0f);  // light, medium, dark shade
    else if (c == 0x2594) part(0, 0, 1, 1 / 8.0f);
    else if (c == 0x2595) part(7 / 8.0f, 0, 1, 1);
    else {
      // Quadrants: bits for upper left, upper right, lower left, lower right.
      static const std::uint8_t quads[] = {0x4, 0x8, 0x1, 0x1 | 0x4 | 0x8, 0x1 | 0x8, 0x1 | 0x2 | 0x4, 0x1 | 0x2 | 0x8,
                                           0x2, 0x2 | 0x4, 0x2 | 0x4 | 0x8};
      std::uint8_t q = quads[c - 0x2596];
      if (q & 0x1) part(0, 0, 0.5f, 0.5f);
      if (q & 0x2) part(0.5f, 0, 1, 0.5f);
      if (q & 0x4) part(0, 0.5f, 0.5f, 1);
      if (q & 0x8) part(0.5f, 0.5f, 1, 1);
    }
    return true;
  }
  if (c < 0x2500 || c > 0x257F || (c >= 0x2571 && c <= 0x2573)) {
    return false;
  }

  // Each line character as the weight of its four arms: 0 none, 1 light, 2 heavy, 3 double. Packed left, right, up,
  // down, two bits each. Dashed lines are drawn solid; rounded corners as square ones.
  enum { N = 0, L = 1, H = 2, D = 3 };
  auto arms = [](int left, int right, int up, int down) { return (std::uint8_t)(left | right << 2 | up << 4 | down << 6); };
  static std::uint8_t table[0x80];
  static bool built = false;
  if (!built) {
    auto set = [&](std::uint32_t code, int left, int right, int up, int down) { table[code - 0x2500] = arms(left, right, up, down); };
    set(0x2500, L, L, N, N); set(0x2501, H, H, N, N); set(0x2502, N, N, L, L); set(0x2503, N, N, H, H);
    set(0x2504, L, L, N, N); set(0x2505, H, H, N, N); set(0x2506, N, N, L, L); set(0x2507, N, N, H, H);
    set(0x2508, L, L, N, N); set(0x2509, H, H, N, N); set(0x250A, N, N, L, L); set(0x250B, N, N, H, H);
    set(0x250C, N, L, N, L); set(0x250D, N, H, N, L); set(0x250E, N, L, N, H); set(0x250F, N, H, N, H);
    set(0x2510, L, N, N, L); set(0x2511, H, N, N, L); set(0x2512, L, N, N, H); set(0x2513, H, N, N, H);
    set(0x2514, N, L, L, N); set(0x2515, N, H, L, N); set(0x2516, N, L, H, N); set(0x2517, N, H, H, N);
    set(0x2518, L, N, L, N); set(0x2519, H, N, L, N); set(0x251A, L, N, H, N); set(0x251B, H, N, H, N);
    set(0x251C, N, L, L, L); set(0x251D, N, H, L, L); set(0x251E, N, L, H, L); set(0x251F, N, L, L, H);
    set(0x2520, N, L, H, H); set(0x2521, N, H, H, L); set(0x2522, N, H, L, H); set(0x2523, N, H, H, H);
    set(0x2524, L, N, L, L); set(0x2525, H, N, L, L); set(0x2526, L, N, H, L); set(0x2527, L, N, L, H);
    set(0x2528, L, N, H, H); set(0x2529, H, N, H, L); set(0x252A, H, N, L, H); set(0x252B, H, N, H, H);
    set(0x252C, L, L, N, L); set(0x252D, H, L, N, L); set(0x252E, L, H, N, L); set(0x252F, H, H, N, L);
    set(0x2530, L, L, N, H); set(0x2531, H, L, N, H); set(0x2532, L, H, N, H); set(0x2533, H, H, N, H);
    set(0x2534, L, L, L, N); set(0x2535, H, L, L, N); set(0x2536, L, H, L, N); set(0x2537, H, H, L, N);
    set(0x2538, L, L, H, N); set(0x2539, H, L, H, N); set(0x253A, L, H, H, N); set(0x253B, H, H, H, N);
    set(0x253C, L, L, L, L); set(0x253D, H, L, L, L); set(0x253E, L, H, L, L); set(0x253F, H, H, L, L);
    set(0x2540, L, L, H, L); set(0x2541, L, L, L, H); set(0x2542, L, L, H, H); set(0x2543, H, L, H, L);
    set(0x2544, L, H, H, L); set(0x2545, H, L, L, H); set(0x2546, L, H, L, H); set(0x2547, H, H, H, L);
    set(0x2548, H, H, L, H); set(0x2549, H, L, H, H); set(0x254A, L, H, H, H); set(0x254B, H, H, H, H);
    set(0x254C, L, L, N, N); set(0x254D, H, H, N, N); set(0x254E, N, N, L, L); set(0x254F, N, N, H, H);
    set(0x2550, D, D, N, N); set(0x2551, N, N, D, D); set(0x2552, N, D, N, L); set(0x2553, N, L, N, D);
    set(0x2554, N, D, N, D); set(0x2555, D, N, N, L); set(0x2556, L, N, N, D); set(0x2557, D, N, N, D);
    set(0x2558, N, D, L, N); set(0x2559, N, L, D, N); set(0x255A, N, D, D, N); set(0x255B, D, N, L, N);
    set(0x255C, L, N, D, N); set(0x255D, D, N, D, N); set(0x255E, N, D, L, L); set(0x255F, N, L, D, D);
    set(0x2560, N, D, D, D); set(0x2561, D, N, L, L); set(0x2562, L, N, D, D); set(0x2563, D, N, D, D);
    set(0x2564, D, D, N, L); set(0x2565, L, L, N, D); set(0x2566, D, D, N, D); set(0x2567, D, D, L, N);
    set(0x2568, L, L, D, N); set(0x2569, D, D, D, N); set(0x256A, D, D, L, L); set(0x256B, L, L, D, D);
    set(0x256C, D, D, D, D); set(0x256D, N, L, N, L); set(0x256E, L, N, N, L); set(0x256F, L, N, L, N);
    set(0x2570, N, L, L, N); set(0x2574, L, N, N, N); set(0x2575, N, N, L, N); set(0x2576, N, L, N, N);
    set(0x2577, N, N, N, L); set(0x2578, H, N, N, N); set(0x2579, N, N, H, N); set(0x257A, N, H, N, N);
    set(0x257B, N, N, N, H); set(0x257C, L, H, N, N); set(0x257D, N, N, L, H); set(0x257E, H, L, N, N);
    set(0x257F, N, N, H, L);
    built = true;
  }
  std::uint8_t a = table[c - 0x2500];
  if (a == 0) return false;
  int left = a & 3, right = (a >> 2) & 3, up = (a >> 4) & 3, down = (a >> 6) & 3;

  float light = std::fmax(1.0f, std::round(std::fmin(width, height) / 10.0f));
  float heavy = light * 2 + 1;
  auto thickness = [&](int weight) { return weight == H ? heavy : light; };
  // The centre, and the two lines of a double one at d either side of it, all on whole pixels.
  float mx = x0 + std::floor(width / 2), my = y0 + std::floor(height / 2);
  float d = light;
  int vertical = std::max(up, down), horizontal = std::max(left, right);
  // A single line meets a double one at the near line of the pair; at a single or heavy one, it runs over its width.
  float vReach = vertical == D ? d : (vertical ? thickness(vertical) / 2 : 0);
  float hReach = horizontal == D ? d : (horizontal ? thickness(horizontal) / 2 : 0);
  auto hLine = [&](float centre, float t, float from, float to) {
    float top = std::round(centre - t / 2);
    if (to > from) rect(std::round(from), top, std::round(to), top + t, 1);
  };
  auto vLine = [&](float centre, float t, float from, float to) {
    float l = std::round(centre - t / 2);
    if (to > from) rect(l, std::round(from), l + t, std::round(to), 1);
  };
  float dv = vertical == D ? d : 0, dh = horizontal == D ? d : 0;
  // Double arms: each of the two lines stops at the inner or the outer line across it, so corners nest and tees
  // leave the through-line unbroken. (With a single line across, both stop at it.)
  if (left == D) {
    hLine(my - d, light, x0, up ? mx - dv : (down ? mx + dv + light : mx + light));
    hLine(my + d, light, x0, down ? mx - dv : (up ? mx + dv + light : mx + light));
  } else if (left) {
    hLine(my, thickness(left), x0, mx + (vertical == D ? -d + light : vReach));
  }
  if (right == D) {
    hLine(my - d, light, up ? mx + dv : (down ? mx - dv : mx), x1);
    hLine(my + d, light, down ? mx + dv : (up ? mx - dv : mx), x1);
  } else if (right) {
    hLine(my, thickness(right), mx - (vertical == D ? -d : vReach), x1);
  }
  if (up == D) {
    vLine(mx - d, light, y0, left ? my - dh : (right ? my + dh + light : my + light));
    vLine(mx + d, light, y0, right ? my - dh : (left ? my + dh + light : my + light));
  } else if (up) {
    vLine(mx, thickness(up), y0, my + (horizontal == D ? -d + light : hReach));
  }
  if (down == D) {
    vLine(mx - d, light, left ? my + dh : (right ? my - dh : my), y1);
    vLine(mx + d, light, right ? my + dh : (left ? my - dh : my), y1);
  } else if (down) {
    vLine(mx, thickness(down), my - (horizontal == D ? -d : hReach), y1);
  }
  return true;
}

}  // namespace cot
