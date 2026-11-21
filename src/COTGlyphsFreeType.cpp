// SPDX-License-Identifier: LGPL-2.1-or-later
// Copyright (C) 2026 Daniel Boyd
//
// Glyph bitmaps from FreeType, with fontconfig to find the font and what covers characters it lacks: the renderer's
// glyphs on Linux (and on Windows with COCOATERMINAL_GL_GLYPHS=freetype, to test it there). Subpixel coverage uses
// FreeType's LCD rendering with its default filter; colour emoji come from FT_LOAD_COLOR, whether the font has colour
// layers (COLR, Segoe UI Emoji) or colour bitmaps (CBDT, Noto Color Emoji).

#include "COTGLRendererInternal.h"

#if defined(COCOATERMINAL_GL_RENDERER)

#include <ft2build.h>
#include FT_FREETYPE_H
#include FT_LCD_FILTER_H
#include <fontconfig/fontconfig.h>

#include <algorithm>
#include <climits>
#include <cmath>
#include <cstdio>
#include <cstdlib>
#include <map>

namespace cot {

namespace {

class FreeTypeGlyphs : public GlyphSource {
  // One glyph's bitmap, placed relative to the run's pen origin.
  struct Piece {
    int x = 0, y = 0, width = 0, height = 0;
    bool colour = false;
    std::vector<std::uint8_t> rgba;
  };

public:
  ~FreeTypeGlyphs() override {
    for (auto &entry : _opened) FT_Done_Face(entry.second);
    if (_library) FT_Done_FreeType(_library);
  }

  bool setUp(const std::string &family, float pixelSize, bool clearType, std::string *error) {
    _family = family;
    _pixelSize = pixelSize;
    _clearType = clearType;
    if (FT_Init_FreeType(&_library) != 0) {
      *error = "FreeType didn't start";
      return false;
    }
    FT_Library_SetLcdFilter(_library, FT_LCD_FILTER_DEFAULT);  // fails harmlessly where FreeType renders LCD itself
    if (!FcInit()) {
      *error = "fontconfig didn't start";
      return false;
    }
    static const int weights[4] = {FC_WEIGHT_REGULAR, FC_WEIGHT_BOLD, FC_WEIGHT_REGULAR, FC_WEIGHT_BOLD};
    static const int slants[4] = {FC_SLANT_ROMAN, FC_SLANT_ROMAN, FC_SLANT_ITALIC, FC_SLANT_ITALIC};
    for (int style = 0; style < 4; style++) {
      FcPattern *pattern = FcPatternCreate();
      FcPatternAddString(pattern, FC_FAMILY, (const FcChar8 *)family.c_str());
      FcPatternAddInteger(pattern, FC_WEIGHT, weights[style]);
      FcPatternAddInteger(pattern, FC_SLANT, slants[style]);
      _faces[style] = match(pattern, style == 0 ? &_regularFamily : nullptr, style == 0 ? &_grayHinting : nullptr);
      FcPatternDestroy(pattern);
    }
    if (!_faces[0]) {
      *error = "fontconfig found no font for " + family;
      return false;
    }
    // COCOATERMINAL_GL_HINTING overrides fontconfig: none, slight, medium or full.
    if (const char *choice = getenv("COCOATERMINAL_GL_HINTING")) {
      std::string name = choice;
      if (name == "none") _grayHinting = FT_LOAD_NO_HINTING;
      else if (name == "slight") _grayHinting = FT_LOAD_TARGET_LIGHT;
      else if (name == "medium" || name == "full") _grayHinting = FT_LOAD_TARGET_NORMAL;
    }
    return true;
  }

  std::string description() const override {
    return std::string("FreeType ") + (_clearType ? "LCD" : "grayscale") + " (" + _regularFamily + ")";
  }

  bool rasterise(const std::string &text, int style, float spanWidth, float cellHeight, GlyphBitmap *out) override {
    bool emoji = false;
    std::vector<std::uint32_t> codePoints;
    for (std::uint32_t cp : DecodeUTF8(text)) {
      if (cp == 0xFE0F) emoji = true;
      if (cp == 0xFE0E || cp == 0xFE0F || cp == 0x200D) continue;
      if (cp >= 0x1F000) emoji = true;
      codePoints.push_back(cp);
    }
    if (codePoints.empty()) return false;
    FT_Face face = emoji ? nullptr : (_faces[style] ? _faces[style] : _faces[0]);
    if (face && !covers(face, codePoints)) face = nullptr;
    bool fallback = false;
    if (!face) {
      face = fallbackFace(codePoints, emoji);
      if (!face) return false;
      fallback = true;
      if (FT_HAS_COLOR(face)) emoji = true;
    }

    // Size: the terminal's, or for a fallback font whatever fits the cell (emoji are wider than a cell at our size).
    float size = _pixelSize;
    float bitmapScale = 1.0f;  // a colour bitmap font has fixed sizes: render at one, then scale the bitmap
    if (!FT_IS_SCALABLE(face) && face->num_fixed_sizes > 0) {
      int best = 0;
      for (int i = 1; i < face->num_fixed_sizes; i++) {
        if (std::abs(face->available_sizes[i].y_ppem / 64.0f - size) < std::abs(face->available_sizes[best].y_ppem / 64.0f - size))
          best = i;
      }
      FT_Select_Size(face, best);
      float strike = face->available_sizes[best].y_ppem / 64.0f;
      bitmapScale = size / strike;
    } else {
      FT_Set_Char_Size(face, 0, (FT_F26Dot6)std::lround(size * 64), 72, 72);
    }
    if (fallback) {
      float advance = 0;
      for (std::uint32_t cp : codePoints) {
        if (FT_Load_Glyph(face, FT_Get_Char_Index(face, cp), FT_LOAD_DEFAULT | (emoji ? FT_LOAD_COLOR : 0)) == 0)
          advance += face->glyph->advance.x / 64.0f;
      }
      float height = face->size->metrics.height / 64.0f;
      float fit = std::min({1.0f, spanWidth / std::max(advance * bitmapScale, 1.0f), cellHeight / std::max(height * bitmapScale, 1.0f)});
      if (FT_IS_SCALABLE(face) && fit < 1.0f) {
        FT_Set_Char_Size(face, 0, (FT_F26Dot6)std::lround(size * fit * 64), 72, 72);
      } else {
        bitmapScale *= fit;
      }
    }

    // Each glyph rendered and composited at its pen position. A combining mark left over is drawn over its letter.
    std::vector<Piece> pieces;
    float pen = 0;
    for (std::size_t i = 0; i < codePoints.size(); i++) {
      FT_UInt index = FT_Get_Char_Index(face, codePoints[i]);
      FT_Int32 flags = FT_LOAD_DEFAULT;
      if (emoji && FT_HAS_COLOR(face)) flags |= FT_LOAD_COLOR;
      else flags |= _clearType ? FT_LOAD_TARGET_LCD : _grayHinting;
      if (FT_Load_Glyph(face, index, flags) != 0) continue;
      FT_GlyphSlot slot = face->glyph;
      bool colourGlyph = (flags & FT_LOAD_COLOR) && slot->format == FT_GLYPH_FORMAT_BITMAP &&
                         slot->bitmap.pixel_mode == FT_PIXEL_MODE_BGRA;
      if (slot->format != FT_GLYPH_FORMAT_BITMAP) {
        FT_Render_Mode mode = (flags & FT_LOAD_COLOR) ? FT_RENDER_MODE_NORMAL : (_clearType ? FT_RENDER_MODE_LCD : FT_RENDER_MODE_NORMAL);
        if (FT_Render_Glyph(slot, mode) != 0) continue;
        colourGlyph = slot->bitmap.pixel_mode == FT_PIXEL_MODE_BGRA;
      }
      bool markOverLetter = i > 0 && IsCombiningMark(codePoints[i]) && slot->advance.x > 0;
      float x = markOverLetter ? pen - _lastAdvance : pen;
      Piece piece = convert(slot, colourGlyph);
      piece.x = (int)std::lround(x) + slot->bitmap_left;
      piece.y = -slot->bitmap_top;
      if (!markOverLetter) {
        _lastAdvance = slot->advance.x / 64.0f;
        pen += _lastAdvance;
      }
      if (piece.width > 0 && piece.height > 0) pieces.push_back(std::move(piece));
    }
    if (pieces.empty()) return false;

    int left = INT_MAX, top = INT_MAX, right = INT_MIN, bottom = INT_MIN;
    bool colour = false;
    for (const Piece &p : pieces) {
      left = std::min(left, p.x);
      top = std::min(top, p.y);
      right = std::max(right, p.x + p.width);
      bottom = std::max(bottom, p.y + p.height);
      colour = colour || p.colour;
    }
    int width = right - left, height = bottom - top;
    std::vector<std::uint8_t> rgba((std::size_t)width * height * 4, 0);
    for (const Piece &p : pieces) {
      for (int y = 0; y < p.height; y++)
        for (int x = 0; x < p.width; x++) {
          const std::uint8_t *src = &p.rgba[4 * ((std::size_t)y * p.width + x)];
          std::uint8_t *dst = &rgba[4 * ((std::size_t)(p.y - top + y) * width + (p.x - left + x))];
          if (p.colour) {  // premultiplied over
            for (int k = 0; k < 4; k++) dst[k] = (std::uint8_t)std::min(255, src[k] + dst[k] * (255 - src[3]) / 255);
          } else {  // coverage: the most of either; colour glyphs elsewhere in the run would keep theirs
            for (int k = 0; k < 4; k++) dst[k] = std::max(dst[k], src[k]);
          }
        }
    }
    if (bitmapScale < 0.999f || bitmapScale > 1.001f) {
      scale(rgba, width, height, bitmapScale, &left, &top);
    }
    out->width = width;
    out->height = height;
    out->left = left;
    out->top = top;
    out->colour = colour;
    out->rgba = std::move(rgba);
    if (getenv("COCOATERMINAL_GL_DEBUG")) {
      fprintf(stderr, "[gl] FreeType %s: %zu code point(s), %s %s, %dx%d%s\n", text.c_str(), codePoints.size(),
              fallback ? "fallback" : "terminal", face->family_name ? face->family_name : "?", width, height,
              colour ? " colour" : "");
    }
    return true;
  }

private:
  // The face fontconfig matches, opened once per file and index.
  // `hintingOut`: the FreeType load flags for grayscale text that fontconfig's settings for this font ask for (its
  // hinting, hintstyle and autohint, as Cairo reads them): slight is FreeType's light hinting, which snaps only
  // vertically; medium and full snap stems horizontally too.
  FT_Face match(FcPattern *pattern, std::string *familyOut, FT_Int32 *hintingOut = nullptr) {
    FcConfigSubstitute(nullptr, pattern, FcMatchPattern);
    FcDefaultSubstitute(pattern);
    FcResult result;
    FcPattern *found = FcFontMatch(nullptr, pattern, &result);
    if (!found) return nullptr;
    FT_Face face = open(found);
    if (familyOut) {
      FcChar8 *name = nullptr;
      if (FcPatternGetString(found, FC_FAMILY, 0, &name) == FcResultMatch) *familyOut = (const char *)name;
    }
    if (hintingOut) {
      FcBool hinting = FcTrue, autohint = FcFalse;
      int style = FC_HINT_SLIGHT;
      FcPatternGetBool(found, FC_HINTING, 0, &hinting);
      FcPatternGetBool(found, FC_AUTOHINT, 0, &autohint);
      FcPatternGetInteger(found, FC_HINT_STYLE, 0, &style);
      if (!hinting || style == FC_HINT_NONE) *hintingOut = FT_LOAD_NO_HINTING;
      else *hintingOut = (style == FC_HINT_SLIGHT ? FT_LOAD_TARGET_LIGHT : FT_LOAD_TARGET_NORMAL) | (autohint ? FT_LOAD_FORCE_AUTOHINT : 0);
    }
    FcPatternDestroy(found);
    return face;
  }

  FT_Face open(FcPattern *font) {
    FcChar8 *file = nullptr;
    int index = 0;
    if (FcPatternGetString(font, FC_FILE, 0, &file) != FcResultMatch) return nullptr;
    FcPatternGetInteger(font, FC_INDEX, 0, &index);
    std::string key = std::string((const char *)file) + "#" + std::to_string(index);
    auto existing = _opened.find(key);
    if (existing != _opened.end()) return existing->second;
    FT_Face face = nullptr;
    if (FT_New_Face(_library, (const char *)file, index, &face) != 0) return nullptr;
    _opened[key] = face;
    return face;
  }

  static bool covers(FT_Face face, const std::vector<std::uint32_t> &codePoints) {
    for (std::uint32_t cp : codePoints) {
      if (FT_Get_Char_Index(face, cp) == 0) return false;
    }
    return true;
  }

  // Whatever fontconfig says covers the characters, preferring a colour font for emoji.
  FT_Face fallbackFace(const std::vector<std::uint32_t> &codePoints, bool emoji) {
    std::string key;
    for (std::uint32_t cp : codePoints) key += std::to_string(cp) + ",";
    key += emoji ? "e" : "t";
    auto cached = _fallbacks.find(key);
    if (cached != _fallbacks.end()) return cached->second;
    FcPattern *pattern = FcPatternCreate();
    FcCharSet *set = FcCharSetCreate();
    for (std::uint32_t cp : codePoints) FcCharSetAddChar(set, cp);
    FcPatternAddCharSet(pattern, FC_CHARSET, set);
    FcPatternAddString(pattern, FC_FAMILY, (const FcChar8 *)_family.c_str());
#ifdef FC_COLOR
    if (emoji) FcPatternAddBool(pattern, FC_COLOR, FcTrue);
#endif
    FcConfigSubstitute(nullptr, pattern, FcMatchPattern);
    FcDefaultSubstitute(pattern);
    FcResult result;
    FcCharSet *coverage = nullptr;
    FcFontSet *sorted = FcFontSort(nullptr, pattern, FcFalse, &coverage, &result);
    FT_Face chosen = nullptr;
    for (int i = 0; sorted && i < sorted->nfont && !chosen; i++) {
      FcPattern *candidate = FcFontRenderPrepare(nullptr, pattern, sorted->fonts[i]);
      if (!candidate) continue;
      FT_Face face = open(candidate);
      FcPatternDestroy(candidate);
      if (face && covers(face, codePoints) && (!emoji || FT_HAS_COLOR(face) || i > 40)) chosen = face;
    }
    if (!chosen && emoji) {  // no colour font has it: any font will do
      for (int i = 0; sorted && i < sorted->nfont && !chosen; i++) {
        FcPattern *candidate = FcFontRenderPrepare(nullptr, pattern, sorted->fonts[i]);
        if (!candidate) continue;
        FT_Face face = open(candidate);
        FcPatternDestroy(candidate);
        if (face && covers(face, codePoints)) chosen = face;
      }
    }
    if (sorted) FcFontSetDestroy(sorted);
    if (coverage) FcCharSetDestroy(coverage);
    FcCharSetDestroy(set);
    FcPatternDestroy(pattern);
    _fallbacks[key] = chosen;
    return chosen;
  }

  // A rendered glyph as RGBA: coverage (RGB per channel for LCD, equal for grayscale, A the most) or premultiplied
  // colour from BGRA.
  static Piece convert(FT_GlyphSlot slot, bool colourGlyph) {
    const FT_Bitmap &b = slot->bitmap;
    Piece piece;
    piece.colour = colourGlyph;
    int width = b.pixel_mode == FT_PIXEL_MODE_LCD ? (int)b.width / 3 : (int)b.width;
    int height = (int)b.rows;
    piece.width = width;
    piece.height = height;
    piece.rgba.assign((std::size_t)width * height * 4, 0);
    for (int y = 0; y < height; y++) {
      const unsigned char *row = b.buffer + (b.pitch >= 0 ? (std::ptrdiff_t)y * b.pitch : (std::ptrdiff_t)(height - 1 - y) * -b.pitch);
      for (int x = 0; x < width; x++) {
        std::uint8_t *dst = &piece.rgba[4 * ((std::size_t)y * width + x)];
        switch (b.pixel_mode) {
        case FT_PIXEL_MODE_BGRA:
          dst[0] = row[4 * x + 2];
          dst[1] = row[4 * x + 1];
          dst[2] = row[4 * x];
          dst[3] = row[4 * x + 3];
          break;
        case FT_PIXEL_MODE_LCD:
          dst[0] = row[3 * x];
          dst[1] = row[3 * x + 1];
          dst[2] = row[3 * x + 2];
          dst[3] = std::max({dst[0], dst[1], dst[2]});
          break;
        case FT_PIXEL_MODE_MONO:
          dst[0] = dst[1] = dst[2] = dst[3] = (row[x >> 3] & (0x80 >> (x & 7))) ? 255 : 0;
          break;
        default:  // FT_PIXEL_MODE_GRAY
          dst[0] = dst[1] = dst[2] = dst[3] = row[x];
          break;
        }
      }
    }
    return piece;
  }

  // Shrinks a colour bitmap (emoji from a fixed-size font) by averaging the source pixels under each target pixel.
  static void scale(std::vector<std::uint8_t> &rgba, int &width, int &height, float factor, int *left, int *top) {
    int w = std::max(1, (int)std::lround(width * factor)), h = std::max(1, (int)std::lround(height * factor));
    std::vector<std::uint8_t> out((std::size_t)w * h * 4);
    for (int y = 0; y < h; y++)
      for (int x = 0; x < w; x++) {
        int sx0 = (int)(x / factor), sy0 = (int)(y / factor);
        int sx1 = std::min(width, std::max(sx0 + 1, (int)((x + 1) / factor)));
        int sy1 = std::min(height, std::max(sy0 + 1, (int)((y + 1) / factor)));
        unsigned sum[4] = {0, 0, 0, 0}, n = 0;
        for (int sy = sy0; sy < sy1; sy++)
          for (int sx = sx0; sx < sx1; sx++) {
            for (int k = 0; k < 4; k++) sum[k] += rgba[4 * ((std::size_t)sy * width + sx) + k];
            n++;
          }
        for (int k = 0; k < 4; k++) out[4 * ((std::size_t)y * w + x) + k] = (std::uint8_t)(n ? sum[k] / n : 0);
      }
    *left = (int)std::lround(*left * factor);
    *top = (int)std::lround(*top * factor);
    rgba = std::move(out);
    width = w;
    height = h;
  }

  FT_Library _library = nullptr;
  FT_Face _faces[4] = {nullptr, nullptr, nullptr, nullptr};
  std::map<std::string, FT_Face> _opened;
  std::map<std::string, FT_Face> _fallbacks;
  std::string _family, _regularFamily;
  float _pixelSize = 13;
  float _lastAdvance = 0;
  bool _clearType = true;
  FT_Int32 _grayHinting = FT_LOAD_TARGET_LIGHT;  // from fontconfig (see -match), or COCOATERMINAL_GL_HINTING
};

}  // namespace

std::unique_ptr<GlyphSource> MakeFreeTypeGlyphs(const std::string &family, float pixelSize, bool clearType, std::string *error) {
  std::unique_ptr<FreeTypeGlyphs> glyphs(new FreeTypeGlyphs);
  if (!glyphs->setUp(family, pixelSize, clearType, error)) return nullptr;
  return glyphs;
}

}  // namespace cot

#endif
