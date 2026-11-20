// SPDX-License-Identifier: LGPL-2.1-or-later
// Copyright (C) 2026 Daniel Boyd
//
// Glyph bitmaps from DirectWrite, the rasteriser Windows Terminal and Alacritty use on Windows: ClearType coverage per
// colour channel (or grayscale), and colour emoji from DirectWrite's colour layers.

#include "COTGLRendererInternal.h"

#if defined(COCOATERMINAL_GL_RENDERER) && defined(_WIN32)

#define WIN32_LEAN_AND_MEAN
#include <windows.h>
#include <dwrite_2.h>

#include <algorithm>
#include <climits>
#include <cmath>
#include <cstdio>
#include <cstdlib>
#include <cstring>
#include <map>

namespace cot {

namespace {

std::wstring Widen(const std::string &utf8) {
  if (utf8.empty()) return std::wstring();
  int count = MultiByteToWideChar(CP_UTF8, 0, utf8.data(), (int)utf8.size(), NULL, 0);
  std::wstring wide((std::size_t)count, L'\0');
  MultiByteToWideChar(CP_UTF8, 0, utf8.data(), (int)utf8.size(), &wide[0], count);
  return wide;
}

// A base letter and its combining marks composed into one character where Unicode has one (e + U+0301 is é): there's
// no shaping here, so a separate mark would be drawn at its own advance, beside the letter.
std::string Composed(const std::string &utf8) {
  std::wstring wide = Widen(utf8);
  if (wide.size() < 2) return utf8;
  int length = NormalizeString(NormalizationC, wide.c_str(), (int)wide.size(), NULL, 0);
  if (length <= 0) return utf8;
  std::wstring out((std::size_t)length, L'\0');
  length = NormalizeString(NormalizationC, wide.c_str(), (int)wide.size(), &out[0], length);
  if (length <= 0) return utf8;
  out.resize((std::size_t)length);
  int bytes = WideCharToMultiByte(CP_UTF8, 0, out.c_str(), (int)out.size(), NULL, 0, NULL, NULL);
  std::string narrow((std::size_t)bytes, '\0');
  WideCharToMultiByte(CP_UTF8, 0, out.c_str(), (int)out.size(), &narrow[0], bytes, NULL, NULL);
  return narrow;
}

template <typename T> void Release(T *&p) {
  if (p) {
    p->Release();
    p = nullptr;
  }
}

// A glyph run analysis's coverage as red, green, blue triples. ClearType analyses give the 3x1 texture (a value per
// colour channel); grayscale ones only the 1x1 texture (one value), repeated here into all three.
bool Coverage(IDWriteGlyphRunAnalysis *analysis, bool clearType, RECT *bounds, std::vector<BYTE> *rgb) {
  DWRITE_TEXTURE_TYPE type = clearType ? DWRITE_TEXTURE_CLEARTYPE_3x1 : DWRITE_TEXTURE_ALIASED_1x1;
  if (FAILED(analysis->GetAlphaTextureBounds(type, bounds))) return false;
  int width = bounds->right - bounds->left, height = bounds->bottom - bounds->top;
  if (width <= 0 || height <= 0) return false;
  std::size_t pixels = (std::size_t)width * height;
  rgb->resize(pixels * 3);
  if (clearType) {
    return SUCCEEDED(analysis->CreateAlphaTexture(type, bounds, rgb->data(), (UINT32)rgb->size()));
  }
  std::vector<BYTE> single(pixels);
  if (FAILED(analysis->CreateAlphaTexture(type, bounds, single.data(), (UINT32)single.size()))) return false;
  for (std::size_t i = 0; i < pixels; i++) (*rgb)[3 * i] = (*rgb)[3 * i + 1] = (*rgb)[3 * i + 2] = single[i];
  return true;
}

class DirectWriteGlyphs : public GlyphSource {
public:
  ~DirectWriteGlyphs() override {
    for (auto &face : _faces) Release(face);
    for (auto &entry : _fallbackFaces) Release(entry.second);
    Release(_collection);
    Release(_factory);
  }

  bool setUp(const std::string &familyName, float pixelSize, bool clearType, std::string *error) {
    _pixelSize = pixelSize;
    _clearType = clearType;
    if (FAILED(DWriteCreateFactory(DWRITE_FACTORY_TYPE_SHARED, __uuidof(IDWriteFactory2),
                                   reinterpret_cast<IUnknown **>(&_factory)))) {
      *error = "DirectWrite 2 isn't available (Windows 8.1 or later)";
      return false;
    }
    _factory->GetSystemFontCollection(&_collection, FALSE);
    UINT32 index = 0;
    BOOL exists = FALSE;
    _collection->FindFamilyName(Widen(familyName).c_str(), &index, &exists);
    if (!exists) {
      *error = "font family " + familyName + " not found by DirectWrite";
      return false;
    }
    IDWriteFontFamily *family = nullptr;
    _collection->GetFontFamily(index, &family);
    _faces[0] = faceFor(family, DWRITE_FONT_WEIGHT_NORMAL, DWRITE_FONT_STYLE_NORMAL);
    _faces[1] = faceFor(family, DWRITE_FONT_WEIGHT_BOLD, DWRITE_FONT_STYLE_NORMAL);
    _faces[2] = faceFor(family, DWRITE_FONT_WEIGHT_NORMAL, DWRITE_FONT_STYLE_ITALIC);
    _faces[3] = faceFor(family, DWRITE_FONT_WEIGHT_BOLD, DWRITE_FONT_STYLE_ITALIC);
    Release(family);
    if (!_faces[0]) {
      *error = "no regular face in " + familyName;
      return false;
    }
    return true;
  }

  std::string description() const override {
    return std::string("DirectWrite ") + (_clearType ? "ClearType" : "grayscale");
  }

  bool rasterise(const std::string &text, int style, float spanWidth, float cellHeight, GlyphBitmap *out) override {
    std::vector<std::uint32_t> all = DecodeUTF8(Composed(text));
    bool emoji = false;
    std::vector<UINT32> codePoints;
    for (std::uint32_t cp : all) {
      if (cp == 0xFE0F) emoji = true;
      if (cp == 0xFE0E || cp == 0xFE0F || cp == 0x200D) continue;  // presentation selectors and joiners: no glyph
      if (cp >= 0x1F000) emoji = true;
      codePoints.push_back(cp);
    }
    if (codePoints.empty()) return false;
    IDWriteFontFace *face = emoji ? nullptr : (_faces[style] ? _faces[style] : _faces[0]);
    std::vector<UINT16> indices(codePoints.size());
    if (face) {
      face->GetGlyphIndices(codePoints.data(), (UINT32)codePoints.size(), indices.data());
      if (std::any_of(indices.begin(), indices.end(), [](UINT16 i) { return i == 0; })) face = nullptr;
    }
    if (!face) {
      face = fallbackFace(codePoints);
      if (!face) return false;  // nothing has it: leave the cell blank rather than draw a box
      face->GetGlyphIndices(codePoints.data(), (UINT32)codePoints.size(), indices.data());
      if (face == _fallbackFaces[L"Segoe UI Emoji"]) emoji = true;  // only the emoji font has it: draw it in colour
    }

    DWRITE_FONT_METRICS metrics;
    face->GetMetrics(&metrics);
    std::vector<DWRITE_GLYPH_METRICS> glyphMetrics(indices.size());
    face->GetDesignGlyphMetrics(indices.data(), (UINT32)indices.size(), glyphMetrics.data(), FALSE);
    float emSize = _pixelSize;
    // A glyph from another font can be wider or taller than the cell (emoji are): shrink it to fit, as the Cairo
    // view does with its fallback font.
    if (face != _faces[style] && face != _faces[0]) {
      float width = 0;
      for (auto &m : glyphMetrics) width += m.advanceWidth * emSize / metrics.designUnitsPerEm;
      float height = (metrics.ascent + metrics.descent) * emSize / metrics.designUnitsPerEm;
      emSize *= std::min({1.0f, spanWidth / std::max(width, 1.0f), cellHeight / std::max(height, 1.0f)});
    }
    std::vector<FLOAT> advances;
    for (auto &m : glyphMetrics) advances.push_back(m.advanceWidth * emSize / metrics.designUnitsPerEm);
    // A combining mark left after composing would land after its letter. A monospace font gives the mark a cell of its
    // own, drawn centred, so it goes over the letter if the letter doesn't advance; a mark with no advance is drawn
    // back over the letter already.
    for (std::size_t i = 1; i < codePoints.size(); i++) {
      if (IsCombiningMark(codePoints[i]) && advances[i] > 0) advances[i - 1] = 0;
    }

    DWRITE_GLYPH_RUN run = {};
    run.fontFace = face;
    run.fontEmSize = emSize;
    run.glyphCount = (UINT32)indices.size();
    run.glyphIndices = indices.data();
    run.glyphAdvances = advances.data();

    // Colour glyphs (emoji): DirectWrite splits them into single-colour layers; each is rasterised and composited.
    IDWriteColorGlyphRunEnumerator *layers = nullptr;
    HRESULT colour = emoji ? _factory->TranslateColorGlyphRun(0, 0, &run, nullptr, DWRITE_MEASURING_MODE_NATURAL, nullptr,
                                                              0, &layers)
                           : E_NOTIMPL;
    if (getenv("COCOATERMINAL_GL_DEBUG")) {
      fprintf(stderr, "[gl] DirectWrite %s: %zu code point(s), %s face, emoji=%d, colour layers hr=0x%08lx, em %.1f\n",
              text.c_str(), codePoints.size(), face == _faces[style] || face == _faces[0] ? "terminal" : "fallback", emoji,
              (unsigned long)colour, emSize);
    }
    if (SUCCEEDED(colour)) {
      bool ok = rasteriseColour(layers, out);
      Release(layers);
      return ok;
    }

    DWRITE_TEXT_ANTIALIAS_MODE antialias = _clearType ? DWRITE_TEXT_ANTIALIAS_MODE_CLEARTYPE : DWRITE_TEXT_ANTIALIAS_MODE_GRAYSCALE;
    IDWriteGlyphRunAnalysis *analysis = nullptr;
    if (FAILED(_factory->CreateGlyphRunAnalysis(&run, nullptr, DWRITE_RENDERING_MODE_NATURAL_SYMMETRIC,
                                                DWRITE_MEASURING_MODE_NATURAL, DWRITE_GRID_FIT_MODE_ENABLED, antialias, 0, 0,
                                                &analysis))) {
      return false;
    }
    RECT bounds;
    std::vector<BYTE> coverage;
    bool got = Coverage(analysis, _clearType, &bounds, &coverage);
    Release(analysis);
    if (!got) return false;
    out->width = bounds.right - bounds.left;
    out->height = bounds.bottom - bounds.top;
    out->left = bounds.left;
    out->top = bounds.top;
    out->colour = false;
    out->rgba.resize((std::size_t)out->width * out->height * 4);
    for (std::size_t i = 0, n = (std::size_t)out->width * out->height; i < n; i++) {
      out->rgba[4 * i] = coverage[3 * i];
      out->rgba[4 * i + 1] = coverage[3 * i + 1];
      out->rgba[4 * i + 2] = coverage[3 * i + 2];
      out->rgba[4 * i + 3] = std::max({coverage[3 * i], coverage[3 * i + 1], coverage[3 * i + 2]});
    }
    return true;
  }

private:
  IDWriteFontFace *faceFor(IDWriteFontFamily *family, DWRITE_FONT_WEIGHT weight, DWRITE_FONT_STYLE style) {
    IDWriteFont *font = nullptr;
    IDWriteFontFace *face = nullptr;
    if (SUCCEEDED(family->GetFirstMatchingFont(weight, DWRITE_FONT_STRETCH_NORMAL, style, &font))) {
      font->CreateFontFace(&face);
      Release(font);
    }
    return face;
  }

  // A face of another family that has every code point, for what the terminal's font lacks.
  IDWriteFontFace *fallbackFace(const std::vector<UINT32> &codePoints) {
    static const wchar_t *kFamilies[] = {L"Segoe UI Emoji", L"Segoe UI Symbol", L"Cambria Math", L"Segoe UI",
                                         L"Microsoft YaHei", L"MS Gothic", L"Malgun Gothic", L"Nirmala UI",
                                         L"Segoe UI Historic", L"Ebrima", L"Leelawadee UI"};
    for (const wchar_t *name : kFamilies) {
      IDWriteFontFace *&cached = _fallbackFaces[name];
      if (!cached) {
        UINT32 index = 0;
        BOOL exists = FALSE;
        _collection->FindFamilyName(name, &index, &exists);
        if (!exists) continue;
        IDWriteFontFamily *family = nullptr;
        _collection->GetFontFamily(index, &family);
        cached = faceFor(family, DWRITE_FONT_WEIGHT_NORMAL, DWRITE_FONT_STYLE_NORMAL);
        Release(family);
        if (!cached) continue;
      }
      std::vector<UINT16> indices(codePoints.size());
      cached->GetGlyphIndices(codePoints.data(), (UINT32)codePoints.size(), indices.data());
      if (std::all_of(indices.begin(), indices.end(), [](UINT16 i) { return i != 0; })) return cached;
    }
    return nullptr;
  }

  bool rasteriseColour(IDWriteColorGlyphRunEnumerator *layers, GlyphBitmap *out) {
    struct Layer {
      RECT bounds;
      std::vector<BYTE> coverage;
      DWRITE_COLOR_F colour;
      bool textColour;
    };
    std::vector<Layer> parts;
    RECT all = {INT_MAX, INT_MAX, INT_MIN, INT_MIN};
    BOOL more = FALSE;
    while (SUCCEEDED(layers->MoveNext(&more)) && more) {
      const DWRITE_COLOR_GLYPH_RUN *layer = nullptr;
      if (FAILED(layers->GetCurrentRun(&layer))) break;
      IDWriteGlyphRunAnalysis *analysis = nullptr;
      if (FAILED(_factory->CreateGlyphRunAnalysis(&layer->glyphRun, nullptr, DWRITE_RENDERING_MODE_NATURAL_SYMMETRIC,
                                                  DWRITE_MEASURING_MODE_NATURAL, DWRITE_GRID_FIT_MODE_DISABLED,
                                                  DWRITE_TEXT_ANTIALIAS_MODE_GRAYSCALE, layer->baselineOriginX,
                                                  layer->baselineOriginY, &analysis))) {
        continue;
      }
      Layer part;
      if (Coverage(analysis, false, &part.bounds, &part.coverage)) {
        part.colour = layer->runColor;
        part.textColour = layer->paletteIndex == 0xFFFF;
        all.left = std::min(all.left, part.bounds.left);
        all.top = std::min(all.top, part.bounds.top);
        all.right = std::max(all.right, part.bounds.right);
        all.bottom = std::max(all.bottom, part.bounds.bottom);
        parts.push_back(std::move(part));
      }
      Release(analysis);
    }
    int width = all.right - all.left, height = all.bottom - all.top;
    if (parts.empty() || width <= 0 || height <= 0) return false;
    std::vector<float> premultiplied((std::size_t)width * height * 4, 0.0f);
    for (const Layer &part : parts) {
      int w = part.bounds.right - part.bounds.left;
      int h = part.bounds.bottom - part.bounds.top;
      float r = part.textColour ? 1.0f : part.colour.r, gr = part.textColour ? 1.0f : part.colour.g;
      float b = part.textColour ? 1.0f : part.colour.b, a = part.textColour ? 1.0f : part.colour.a;
      for (int y = 0; y < h; y++)
        for (int x = 0; x < w; x++) {
          float c = part.coverage[3 * ((std::size_t)y * w + x)] / 255.0f * a;
          float *dst = &premultiplied[4 * ((std::size_t)(y + part.bounds.top - all.top) * width + (x + part.bounds.left - all.left))];
          dst[0] = r * c + dst[0] * (1 - c);
          dst[1] = gr * c + dst[1] * (1 - c);
          dst[2] = b * c + dst[2] * (1 - c);
          dst[3] = c + dst[3] * (1 - c);
        }
    }
    out->width = width;
    out->height = height;
    out->left = all.left;
    out->top = all.top;
    out->colour = true;
    out->rgba.resize(premultiplied.size());
    for (std::size_t i = 0; i < premultiplied.size(); i++) {
      out->rgba[i] = (std::uint8_t)std::lround(std::clamp(premultiplied[i], 0.0f, 1.0f) * 255);
    }
    return true;
  }

  IDWriteFactory2 *_factory = nullptr;
  IDWriteFontCollection *_collection = nullptr;
  IDWriteFontFace *_faces[4] = {nullptr, nullptr, nullptr, nullptr};
  std::map<std::wstring, IDWriteFontFace *> _fallbackFaces;
  float _pixelSize = 13;
  bool _clearType = true;
};

}  // namespace

std::unique_ptr<GlyphSource> MakeDirectWriteGlyphs(const std::string &family, float pixelSize, bool clearType, std::string *error) {
  std::unique_ptr<DirectWriteGlyphs> glyphs(new DirectWriteGlyphs);
  if (!glyphs->setUp(family, pixelSize, clearType, error)) return nullptr;
  return glyphs;
}

}  // namespace cot

#endif
