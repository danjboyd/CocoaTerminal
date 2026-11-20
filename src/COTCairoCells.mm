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

#if defined(__APPLE__) || defined(_WIN32)

BOOL COTDrawCairoGlyphCell(const std::string &, std::uint32_t, BOOL, NSString *, CGFloat, NSRect, NSColor *) {
  return NO;  // Core Text draws these; GNUstep on Windows is left as it was
}

#else

#include <dlfcn.h>
#include <fontconfig/fontconfig.h>

#include <type_traits>
#include <unordered_map>

// The little of Cairo used here, declared rather than included so the build needs no Cairo headers: the library is
// GNUstep's backend's, found at run time.
namespace {
struct cairo_t;
struct cairo_surface_t;
struct cairo_font_face_t;
struct cairo_text_extents_t {
  double x_bearing, y_bearing, width, height, x_advance, y_advance;
};
struct cairo_font_extents_t {
  double ascent, descent, height, max_x_advance, max_y_advance;
};
const int CAIRO_FORMAT_ARGB32 = 0;

struct Cairo {
  cairo_surface_t *(*image_surface_create)(int, int, int);
  unsigned char *(*image_surface_get_data)(cairo_surface_t *);
  int (*image_surface_get_stride)(cairo_surface_t *);
  void (*surface_flush)(cairo_surface_t *);
  void (*surface_destroy)(cairo_surface_t *);
  cairo_t *(*create)(cairo_surface_t *);
  void (*destroy)(cairo_t *);
  int (*status)(cairo_t *);
  void (*set_font_face)(cairo_t *, cairo_font_face_t *);
  void (*set_font_size)(cairo_t *, double);
  void (*font_extents)(cairo_t *, cairo_font_extents_t *);
  void (*text_extents)(cairo_t *, const char *, cairo_text_extents_t *);
  void (*set_source_rgba)(cairo_t *, double, double, double, double);
  void (*move_to)(cairo_t *, double, double);
  void (*show_text)(cairo_t *, const char *);
  cairo_font_face_t *(*ft_font_face_create_for_pattern)(FcPattern *);
  int (*font_face_status)(cairo_font_face_t *);

  FcPattern *(*FcPatternCreate)(void);
  void (*FcPatternDestroy)(FcPattern *);
  FcBool (*FcPatternAddString)(FcPattern *, const char *, const FcChar8 *);
  FcBool (*FcPatternAddBool)(FcPattern *, const char *, FcBool);
  FcBool (*FcPatternAddCharSet)(FcPattern *, const char *, const FcCharSet *);
  FcResult (*FcPatternGetCharSet)(const FcPattern *, const char *, int, FcCharSet **);
  FcCharSet *(*FcCharSetCreate)(void);
  void (*FcCharSetDestroy)(FcCharSet *);
  FcBool (*FcCharSetAddChar)(FcCharSet *, FcChar32);
  FcBool (*FcCharSetHasChar)(const FcCharSet *, FcChar32);
  FcBool (*FcConfigSubstitute)(FcConfig *, FcPattern *, FcMatchKind);
  void (*FcDefaultSubstitute)(FcPattern *);
  FcPattern *(*FcFontMatch)(FcConfig *, FcPattern *, FcResult *);
};

void *Library(const char *name) {
  void *library = dlopen(name, RTLD_LAZY | RTLD_NOLOAD);
  return library ? library : dlopen(name, RTLD_LAZY);
}

const Cairo *LoadCairo() {
  static Cairo cairo;
  static int loaded = -1;
  if (loaded >= 0) return loaded ? &cairo : nullptr;
  loaded = 0;
  void *c = Library("libcairo.so.2"), *fc = Library("libfontconfig.so.1");
  if (!c || !fc) return nullptr;
  bool ok = true;
  auto get = [&](void *library, auto &fn, const char *name) {
    fn = reinterpret_cast<typename std::remove_reference<decltype(fn)>::type>(dlsym(library, name));
    ok = ok && fn != nullptr;
  };
  get(c, cairo.image_surface_create, "cairo_image_surface_create");
  get(c, cairo.image_surface_get_data, "cairo_image_surface_get_data");
  get(c, cairo.image_surface_get_stride, "cairo_image_surface_get_stride");
  get(c, cairo.surface_flush, "cairo_surface_flush");
  get(c, cairo.surface_destroy, "cairo_surface_destroy");
  get(c, cairo.create, "cairo_create");
  get(c, cairo.destroy, "cairo_destroy");
  get(c, cairo.status, "cairo_status");
  get(c, cairo.set_font_face, "cairo_set_font_face");
  get(c, cairo.set_font_size, "cairo_set_font_size");
  get(c, cairo.font_extents, "cairo_font_extents");
  get(c, cairo.text_extents, "cairo_text_extents");
  get(c, cairo.set_source_rgba, "cairo_set_source_rgba");
  get(c, cairo.move_to, "cairo_move_to");
  get(c, cairo.show_text, "cairo_show_text");
  get(c, cairo.ft_font_face_create_for_pattern, "cairo_ft_font_face_create_for_pattern");
  get(c, cairo.font_face_status, "cairo_font_face_status");
  get(fc, cairo.FcPatternCreate, "FcPatternCreate");
  get(fc, cairo.FcPatternDestroy, "FcPatternDestroy");
  get(fc, cairo.FcPatternAddString, "FcPatternAddString");
  get(fc, cairo.FcPatternAddBool, "FcPatternAddBool");
  get(fc, cairo.FcPatternAddCharSet, "FcPatternAddCharSet");
  get(fc, cairo.FcPatternGetCharSet, "FcPatternGetCharSet");
  get(fc, cairo.FcCharSetCreate, "FcCharSetCreate");
  get(fc, cairo.FcCharSetDestroy, "FcCharSetDestroy");
  get(fc, cairo.FcCharSetAddChar, "FcCharSetAddChar");
  get(fc, cairo.FcCharSetHasChar, "FcCharSetHasChar");
  get(fc, cairo.FcConfigSubstitute, "FcConfigSubstitute");
  get(fc, cairo.FcDefaultSubstitute, "FcDefaultSubstitute");
  get(fc, cairo.FcFontMatch, "FcFontMatch");
  if (!ok) return nullptr;
  loaded = 1;
  return &cairo;
}

// fontconfig's font for the character: for emoji a colour one first (Noto Color Emoji), then one like the terminal's,
// then any. The first that really has the character, as a Cairo face; nullptr if none has it. Cached.
cairo_font_face_t *FaceFor(const Cairo &cairo, std::uint32_t character, bool emoji, const std::string &family) {
  static std::unordered_map<std::string, cairo_font_face_t *> faces;
  std::string key = std::to_string(character) + (emoji ? " e " : " t ") + family;
  auto found = faces.find(key);
  if (found != faces.end()) return found->second;
  cairo_font_face_t *face = nullptr;
  for (int attempt = emoji ? 0 : 1; attempt < 3 && !face; attempt++) {
    FcPattern *pattern = cairo.FcPatternCreate();
#ifdef FC_COLOR
    if (attempt == 0) cairo.FcPatternAddBool(pattern, FC_COLOR, FcTrue);
#else
    if (attempt == 0) cairo.FcPatternAddBool(pattern, "color", FcTrue);
#endif
    if (attempt == 1 && !family.empty()) cairo.FcPatternAddString(pattern, FC_FAMILY, (const FcChar8 *)family.c_str());
    FcCharSet *wanted = cairo.FcCharSetCreate();
    cairo.FcCharSetAddChar(wanted, character);
    cairo.FcPatternAddCharSet(pattern, FC_CHARSET, wanted);
    cairo.FcConfigSubstitute(nullptr, pattern, FcMatchPattern);
    cairo.FcDefaultSubstitute(pattern);
    FcResult result;
    FcPattern *match = cairo.FcFontMatch(nullptr, pattern, &result);
    FcCharSet *has = nullptr;
    if (match && cairo.FcPatternGetCharSet(match, FC_CHARSET, 0, &has) == FcResultMatch && cairo.FcCharSetHasChar(has, character)) {
      face = cairo.ft_font_face_create_for_pattern(match);  // keeps what it needs of the pattern
      if (face && cairo.font_face_status(face) != 0) face = nullptr;
    }
    if (match) cairo.FcPatternDestroy(match);
    cairo.FcPatternDestroy(pattern);
    cairo.FcCharSetDestroy(wanted);
  }
  faces[key] = face;
  return face;
}

// The text without variation selectors (U+FE0E, U+FE0F): a font without them would draw them as boxes.
std::string WithoutVariationSelectors(const std::string &text) {
  std::string out;
  for (std::size_t i = 0; i < text.size(); i++) {
    if (i + 2 < text.size() && (unsigned char)text[i] == 0xEF && (unsigned char)text[i + 1] == 0xB8 &&
        ((unsigned char)text[i + 2] == 0x8E || (unsigned char)text[i + 2] == 0x8F)) {
      i += 2;
      continue;
    }
    out += text[i];
  }
  return out;
}

// The cell drawn by Cairo: premultiplied RGBA, fitted to width x height pixels and centred. nil without a font.
NSBitmapImageRep *Rasterise(const Cairo &cairo, const std::string &text, std::uint32_t character, bool emoji,
                            const std::string &family, double pixelSize, int width, int height, NSColor *foreground) {
  cairo_font_face_t *face = FaceFor(cairo, character, emoji, family);
  if (!face) return nil;
  std::string drawable = WithoutVariationSelectors(text);
  cairo_surface_t *surface = cairo.image_surface_create(CAIRO_FORMAT_ARGB32, width, height);
  cairo_t *cr = cairo.create(surface);
  cairo.set_font_face(cr, face);
  cairo.set_font_size(cr, pixelSize);
  cairo_font_extents_t font;
  cairo_text_extents_t ink;
  cairo.font_extents(cr, &font);
  cairo.text_extents(cr, drawable.c_str(), &ink);
  // Emoji fonts are bigger than the terminal's: shrink to fit the cell, so the grid never shifts.
  double lineHeight = font.ascent + font.descent;
  double scale = fmin(1.0, fmin(ink.x_advance > 0 ? width / ink.x_advance : 1.0, lineHeight > 0 ? height / lineHeight : 1.0));
  if (scale < 0.999) {
    cairo.set_font_size(cr, pixelSize * scale);
    cairo.font_extents(cr, &font);
    cairo.text_extents(cr, drawable.c_str(), &ink);
    lineHeight = font.ascent + font.descent;
  }
  NSColor *rgb = [foreground colorUsingColorSpaceName:NSCalibratedRGBColorSpace] ?: [NSColor whiteColor];
  cairo.set_source_rgba(cr, [rgb redComponent], [rgb greenComponent], [rgb blueComponent], [rgb alphaComponent]);
  cairo.move_to(cr, (width - ink.x_advance) / 2, (height - lineHeight) / 2 + font.ascent);
  cairo.show_text(cr, drawable.c_str());
  bool ok = cairo.status(cr) == 0;
  cairo.surface_flush(surface);
  NSBitmapImageRep *image = nil;
  if (ok) {
    image = [[[NSBitmapImageRep alloc] initWithBitmapDataPlanes:NULL pixelsWide:width pixelsHigh:height bitsPerSample:8
                                                samplesPerPixel:4 hasAlpha:YES isPlanar:NO colorSpaceName:NSDeviceRGBColorSpace
                                                    bytesPerRow:width * 4 bitsPerPixel:32] autorelease];
    const unsigned char *from = cairo.image_surface_get_data(surface);
    int stride = cairo.image_surface_get_stride(surface);
    unsigned char *to = [image bitmapData];
    bool any = false;
    for (int y = 0; y < height; y++) {
      const std::uint32_t *row = (const std::uint32_t *)(from + (std::size_t)y * stride);  // ARGB, native endian
      for (int x = 0; x < width; x++) {
        std::uint32_t p = row[x];
        unsigned char *out = to + ((std::size_t)y * width + x) * 4;
        out[0] = (p >> 16) & 0xFF;
        out[1] = (p >> 8) & 0xFF;
        out[2] = p & 0xFF;
        out[3] = (p >> 24) & 0xFF;
        any = any || out[3] != 0;
      }
    }
    if (!any) image = nil;  // the font had no glyph after all: let GNUstep try
  }
  cairo.destroy(cr);
  cairo.surface_destroy(surface);
  return image;
}
}  // namespace

BOOL COTDrawCairoGlyphCell(const std::string &text, std::uint32_t character, BOOL emoji, NSString *family,
                           CGFloat pixelSize, NSRect cell, NSColor *foreground) {
  const Cairo *cairo = LoadCairo();
  if (!cairo) return NO;
  NSRect snapped = COTSnappedCellRect(cell);
  int width = (int)NSWidth(snapped), height = (int)NSHeight(snapped);
  if (width <= 0 || height <= 0 || pixelSize <= 0) return NO;
  static NSMutableDictionary *cache;
  if (!cache) cache = [[NSMutableDictionary alloc] init];
  NSString *key = [NSString stringWithFormat:@"%s|%d|%@|%.2f|%dx%d|%@", text.c_str(), (int)emoji, family ?: @"",
                                             (double)pixelSize, width, height, foreground];
  id image = [cache objectForKey:key];
  if (!image) {
    if ([cache count] > 2048) [cache removeAllObjects];
    image = Rasterise(*cairo, text, character, emoji, family ? std::string([family UTF8String]) : std::string(),
                      pixelSize, width, height, foreground) ?: (id)[NSNull null];
    [cache setObject:image forKey:key];
  }
  if (image == [NSNull null]) return NO;
  return [(NSBitmapImageRep *)image drawInRect:snapped fromRect:NSZeroRect operation:NSCompositeSourceOver fraction:1.0
                                respectFlipped:YES hints:nil];
}

#endif
