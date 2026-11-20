// SPDX-License-Identifier: LGPL-2.1-or-later
// Copyright (C) 2026 Daniel Boyd
//
// The OpenGL renderer, the same on every platform. The design follows Alacritty's renderer (written from its
// description, no code taken): an atlas of glyph bitmaps filled as glyphs are first needed, and per frame one
// instanced draw for every cell background and one for every glyph, positions snapped to whole pixels. Subpixel
// (ClearType/LCD) coverage is blended per colour channel with dual-source blending, as Alacritty does; grayscale
// uses the same path with equal channels. Every OpenGL function comes from the context, so no GL headers or import
// library are needed here.

#include "COTGLRenderer.h"
#include "COTGLRendererInternal.h"

#if defined(COCOATERMINAL_GL_RENDERER)

#include "COTBoxDrawing.h"

#include <algorithm>
#include <chrono>
#include <cmath>
#include <cstdio>
#include <cstdlib>
#include <cstring>
#include <map>

#if defined(_WIN32)
#define COT_GLAPI __stdcall
#else
#define COT_GLAPI
#endif

namespace cot {

namespace {

typedef unsigned int GLenum;
typedef unsigned int GLuint;
typedef int GLint;
typedef int GLsizei;
typedef float GLfloat;
typedef unsigned char GLboolean;
typedef unsigned int GLbitfield;
typedef char GLchar;
typedef std::ptrdiff_t GLsizeiptr;

enum : GLenum {
  kFalse = 0,
  kTriangleStrip = 0x0005,
  kTexture2D = 0x0DE1,
  kUnsignedByte = 0x1401,
  kFloat = 0x1406,
  kRGBA = 0x1908,
  kNearest = 0x2600,
  kTextureMagFilter = 0x2800,
  kTextureMinFilter = 0x2801,
  kColorBufferBit = 0x4000,
  kBlend = 0x0BE2,
  kUnpackAlignment = 0x0CF5,
  kPackAlignment = 0x0D05,
  kVersion = 0x1F02,
  kRenderer = 0x1F01,
  kNoError = 0,
  kArrayBuffer = 0x8892,
  kStreamDraw = 0x88E0,
  kFragmentShader = 0x8B30,
  kVertexShader = 0x8B31,
  kCompileStatus = 0x8B81,
  kLinkStatus = 0x8B82,
  kFramebuffer = 0x8D40,
  kRenderbuffer = 0x8D41,
  kColorAttachment0 = 0x8CE0,
  kFramebufferComplete = 0x8CD5,
  kRGBA8 = 0x8058,
  kSrc1Color = 0x88F9,
  kOneMinusSrc1Color = 0x88FA,
  kTexture0 = 0x84C0,
};

struct GL {
#define COT_GL_FN(ret, name, args) ret(COT_GLAPI *name) args = nullptr;
  COT_GL_FN(const unsigned char *, GetString, (GLenum))
  COT_GL_FN(GLenum, GetError, (void))
  COT_GL_FN(void, Viewport, (GLint, GLint, GLsizei, GLsizei))
  COT_GL_FN(void, ClearColor, (GLfloat, GLfloat, GLfloat, GLfloat))
  COT_GL_FN(void, Clear, (GLbitfield))
  COT_GL_FN(void, Enable, (GLenum))
  COT_GL_FN(void, Disable, (GLenum))
  COT_GL_FN(void, BlendFunc, (GLenum, GLenum))
  COT_GL_FN(void, PixelStorei, (GLenum, GLint))
  COT_GL_FN(void, ReadPixels, (GLint, GLint, GLsizei, GLsizei, GLenum, GLenum, void *))
  COT_GL_FN(void, GenTextures, (GLsizei, GLuint *))
  COT_GL_FN(void, BindTexture, (GLenum, GLuint))
  COT_GL_FN(void, TexParameteri, (GLenum, GLenum, GLint))
  COT_GL_FN(void, TexImage2D, (GLenum, GLint, GLint, GLsizei, GLsizei, GLint, GLenum, GLenum, const void *))
  COT_GL_FN(void, TexSubImage2D, (GLenum, GLint, GLint, GLint, GLsizei, GLsizei, GLenum, GLenum, const void *))
  COT_GL_FN(void, GenVertexArrays, (GLsizei, GLuint *))
  COT_GL_FN(void, BindVertexArray, (GLuint))
  COT_GL_FN(void, GenBuffers, (GLsizei, GLuint *))
  COT_GL_FN(void, BindBuffer, (GLenum, GLuint))
  COT_GL_FN(void, BufferData, (GLenum, GLsizeiptr, const void *, GLenum))
  COT_GL_FN(void, VertexAttribPointer, (GLuint, GLint, GLenum, GLboolean, GLsizei, const void *))
  COT_GL_FN(void, EnableVertexAttribArray, (GLuint))
  COT_GL_FN(void, VertexAttribDivisor, (GLuint, GLuint))
  COT_GL_FN(void, DrawArraysInstanced, (GLenum, GLint, GLsizei, GLsizei))
  COT_GL_FN(GLuint, CreateShader, (GLenum))
  COT_GL_FN(void, ShaderSource, (GLuint, GLsizei, const GLchar *const *, const GLint *))
  COT_GL_FN(void, CompileShader, (GLuint))
  COT_GL_FN(void, GetShaderiv, (GLuint, GLenum, GLint *))
  COT_GL_FN(void, GetShaderInfoLog, (GLuint, GLsizei, GLsizei *, GLchar *))
  COT_GL_FN(GLuint, CreateProgram, (void))
  COT_GL_FN(void, AttachShader, (GLuint, GLuint))
  COT_GL_FN(void, LinkProgram, (GLuint))
  COT_GL_FN(void, GetProgramiv, (GLuint, GLenum, GLint *))
  COT_GL_FN(void, GetProgramInfoLog, (GLuint, GLsizei, GLsizei *, GLchar *))
  COT_GL_FN(void, UseProgram, (GLuint))
  COT_GL_FN(GLint, GetUniformLocation, (GLuint, const GLchar *))
  COT_GL_FN(void, Uniform1i, (GLint, GLint))
  COT_GL_FN(void, Uniform1f, (GLint, GLfloat))
  COT_GL_FN(void, Uniform2f, (GLint, GLfloat, GLfloat))
  COT_GL_FN(void, ActiveTexture, (GLenum))
  COT_GL_FN(void, GenFramebuffers, (GLsizei, GLuint *))
  COT_GL_FN(void, BindFramebuffer, (GLenum, GLuint))
  COT_GL_FN(void, DeleteFramebuffers, (GLsizei, const GLuint *))
  COT_GL_FN(void, GenRenderbuffers, (GLsizei, GLuint *))
  COT_GL_FN(void, BindRenderbuffer, (GLenum, GLuint))
  COT_GL_FN(void, DeleteRenderbuffers, (GLsizei, const GLuint *))
  COT_GL_FN(void, RenderbufferStorage, (GLenum, GLenum, GLsizei, GLsizei))
  COT_GL_FN(void, FramebufferRenderbuffer, (GLenum, GLenum, GLenum, GLuint))
  COT_GL_FN(GLenum, CheckFramebufferStatus, (GLenum))
#undef COT_GL_FN

  bool load(GLContext &context, std::string *missing) {
#define COT_GL_LOAD(name)                                                     \
  name = reinterpret_cast<decltype(name)>(context.proc("gl" #name));          \
  if (name == nullptr) {                                                      \
    *missing = "gl" #name;                                                    \
    return false;                                                             \
  }
    COT_GL_LOAD(GetString) COT_GL_LOAD(GetError) COT_GL_LOAD(Viewport) COT_GL_LOAD(ClearColor) COT_GL_LOAD(Clear)
    COT_GL_LOAD(Enable) COT_GL_LOAD(Disable) COT_GL_LOAD(BlendFunc) COT_GL_LOAD(PixelStorei) COT_GL_LOAD(ReadPixels)
    COT_GL_LOAD(GenTextures) COT_GL_LOAD(BindTexture) COT_GL_LOAD(TexParameteri) COT_GL_LOAD(TexImage2D)
    COT_GL_LOAD(TexSubImage2D)
    return true;
  }

  bool load33(GLContext &context, std::string *missing) {
    COT_GL_LOAD(GenVertexArrays) COT_GL_LOAD(BindVertexArray) COT_GL_LOAD(GenBuffers) COT_GL_LOAD(BindBuffer)
    COT_GL_LOAD(BufferData) COT_GL_LOAD(VertexAttribPointer) COT_GL_LOAD(EnableVertexAttribArray)
    COT_GL_LOAD(VertexAttribDivisor) COT_GL_LOAD(DrawArraysInstanced) COT_GL_LOAD(CreateShader)
    COT_GL_LOAD(ShaderSource) COT_GL_LOAD(CompileShader) COT_GL_LOAD(GetShaderiv) COT_GL_LOAD(GetShaderInfoLog)
    COT_GL_LOAD(CreateProgram) COT_GL_LOAD(AttachShader) COT_GL_LOAD(LinkProgram) COT_GL_LOAD(GetProgramiv)
    COT_GL_LOAD(GetProgramInfoLog) COT_GL_LOAD(UseProgram) COT_GL_LOAD(GetUniformLocation) COT_GL_LOAD(Uniform1i)
    COT_GL_LOAD(Uniform1f) COT_GL_LOAD(Uniform2f) COT_GL_LOAD(ActiveTexture) COT_GL_LOAD(GenFramebuffers)
    COT_GL_LOAD(BindFramebuffer) COT_GL_LOAD(DeleteFramebuffers) COT_GL_LOAD(GenRenderbuffers)
    COT_GL_LOAD(BindRenderbuffer) COT_GL_LOAD(DeleteRenderbuffers) COT_GL_LOAD(RenderbufferStorage)
    COT_GL_LOAD(FramebufferRenderbuffer) COT_GL_LOAD(CheckFramebufferStatus)
#undef COT_GL_LOAD
    return true;
  }
};

// ---- Shaders. Pixel coordinates from the top-left; y isn't flipped into OpenGL's bottom-up convention, so the frame
// is upside down in the framebuffer and glReadPixels hands it back top row first, as the image wants.

const char *kRectVertex = R"(#version 330 core
layout(location = 0) in vec4 rect;    // x, y, width, height in pixels
layout(location = 1) in vec4 colour;
uniform vec2 viewport;
out vec4 vColour;
void main() {
  vec2 corner = vec2(gl_VertexID & 1, gl_VertexID >> 1);
  vec2 p = rect.xy + corner * rect.zw;
  gl_Position = vec4(p / viewport * 2.0 - 1.0, 0.0, 1.0);
  vColour = colour;
}
)";

const char *kRectFragment = R"(#version 330 core
in vec4 vColour;
out vec4 fragColour;
void main() { fragColour = vColour; }
)";

const char *kGlyphVertex = R"(#version 330 core
layout(location = 0) in vec4 rect;    // where the glyph's bitmap goes, in pixels
layout(location = 1) in vec4 source;  // where it is in the atlas, in pixels
layout(location = 2) in vec4 colour;  // text colour; alpha 2 marks a colour (emoji) glyph
uniform vec2 viewport;
uniform vec2 atlasSize;
out vec2 vTexture;
out vec4 vColour;
void main() {
  vec2 corner = vec2(gl_VertexID & 1, gl_VertexID >> 1);
  vec2 p = rect.xy + corner * rect.zw;
  gl_Position = vec4(p / viewport * 2.0 - 1.0, 0.0, 1.0);
  vTexture = (source.xy + corner * source.zw) / atlasSize;
  vColour = colour;
}
)";

// The blend is dst = colour * mask + dst * (1 - mask) per channel (dual-source). Enhanced contrast is the curve
// DirectWrite applies, a * (k + 1) / (a * k + 1); light text on a dark background gets a stronger one and a gamma lift,
// as stems otherwise look thin there. Both are tunable (COCOATERMINAL_GL_CONTRAST, COCOATERMINAL_GL_GAMMA).
const char *kGlyphFragment = R"(#version 330 core
in vec2 vTexture;
in vec4 vColour;
uniform sampler2D atlas;
uniform float contrast;
uniform float lightGamma;
uniform int grayscale;
layout(location = 0, index = 0) out vec4 fragColour;
layout(location = 0, index = 1) out vec4 fragMask;
vec3 enhance(vec3 a, float k) { return a * (k + 1.0) / (a * k + 1.0); }
void main() {
  vec4 t = texture(atlas, vTexture);
  if (vColour.a > 1.5) {  // colour glyph: premultiplied RGBA
    float a = t.a;
    fragColour = vec4(a > 0.0 ? t.rgb / a : vec3(0.0), 1.0);
    fragMask = vec4(a);
    return;
  }
  vec3 c = grayscale == 1 ? vec3(t.r) : t.rgb;
  float luminance = dot(vColour.rgb, vec3(0.30, 0.59, 0.11));
  float k = contrast * (luminance > 0.5 ? 1.5 : 1.0);
  c = clamp(enhance(c, k), 0.0, 1.0);
  if (luminance > 0.5) c = pow(c, vec3(1.0 / lightGamma));
  fragColour = vec4(vColour.rgb, 1.0);
  fragMask = vec4(c, max(c.r, max(c.g, c.b)));
}
)";

double Milliseconds(std::chrono::steady_clock::time_point since) {
  return std::chrono::duration<double, std::milli>(std::chrono::steady_clock::now() - since).count();
}

struct Glyph {
  int x = 0, y = 0, width = 0, height = 0;  // in the atlas
  int left = 0, top = 0;                    // bitmap's top-left from the pen position on the baseline
  bool colour = false;
  bool empty = true;
};

class Renderer : public GLRenderer {
public:
  bool setUp(std::unique_ptr<GLContext> context, std::unique_ptr<GlyphSource> glyphs, bool clearType, std::string *error) {
    _context = std::move(context);
    _source = std::move(glyphs);
    _clearType = clearType;
    if (const char *c = getenv("COCOATERMINAL_GL_CONTRAST")) _contrast = (float)atof(c);
    else _contrast = clearType ? 0.5f : 1.0f;
    if (const char *g = getenv("COCOATERMINAL_GL_GAMMA")) _lightGamma = (float)atof(g);
    std::string missing;
    if (!_context->makeCurrent() || !_gl.load(*_context, &missing)) {
      *error = missing.empty() ? "can't make the OpenGL context current" : "OpenGL has no " + missing;
      return false;
    }
    const char *version = (const char *)_gl.GetString(kVersion);
    const char *renderer = (const char *)_gl.GetString(kRenderer);
    _description = std::string("OpenGL ") + (version ? version : "?") + " on " + (renderer ? renderer : "?") + " (" +
                   _context->description() + "); " + _source->description();
    int major = version ? atoi(version) : 0;
    const char *dot = version ? strchr(version, '.') : nullptr;
    int minor = dot ? atoi(dot + 1) : 0;
    if (major < 3 || (major == 3 && minor < 3)) {
      *error = "needs OpenGL 3.3; have " + _description;
      return false;
    }
    if (!_gl.load33(*_context, &missing)) {
      *error = "OpenGL has no " + missing + " (" + _description + ")";
      return false;
    }
    return setUpPrograms(error);
  }

  bool render(const GLFrame &frame, std::uint8_t *pixels, std::string *error) override {
    auto start = std::chrono::steady_clock::now();
    _timing = GLTiming();
    if (!_context->makeCurrent()) {
      *error = "can't make the OpenGL context current";
      return false;
    }
    if (!sizeFramebuffer(frame.pixelWidth, frame.pixelHeight, error)) return false;

    // Batches: backgrounds (and a block cursor), glyphs, then lines and box drawing over the glyphs.
    std::vector<float> rects, glyphs, lines;
    rects.reserve((std::size_t)frame.rows * frame.columns * 8);
    glyphs.reserve((std::size_t)frame.rows * frame.columns * 12);
    auto colour = [](std::uint32_t rgb, float alpha, std::vector<float> &out) {
      out.push_back(((rgb >> 16) & 0xFF) / 255.0f);
      out.push_back(((rgb >> 8) & 0xFF) / 255.0f);
      out.push_back((rgb & 0xFF) / 255.0f);
      out.push_back(alpha);
    };
    auto rect = [&](std::vector<float> &out, float x0, float y0, float x1, float y1, std::uint32_t rgb) {
      out.push_back(x0);
      out.push_back(y0);
      out.push_back(x1 - x0);
      out.push_back(y1 - y0);
      colour(rgb, 1.0f, out);
    };
    auto columnX = [&](int column) { return std::round(frame.originX + column * frame.cellWidth); };
    auto rowY = [&](int row) { return std::round(frame.originY + row * frame.cellHeight); };

    bool cursorBlock = frame.cursorStyle == GLCursorStyle::Block;
    for (int row = 0; row < frame.rows; row++) {
      for (int column = 0; column < frame.columns; column++) {
        const GLCell &cell = frame.cells[(std::size_t)row * frame.columns + column];
        if (cell.width == 0) continue;
        float x0 = columnX(column), x1 = columnX(column + cell.width), y0 = rowY(row), y1 = rowY(row + 1);
        bool underCursor = cursorBlock && row == frame.cursorRow && column == frame.cursorColumn;
        if (underCursor) {
          rect(rects, x0, y0, x1, y1, frame.cursorColour);
        } else if (cell.drawBackground) {
          rect(rects, x0, y0, x1, y1, cell.background);
        }
        std::uint32_t textColour = underCursor ? frame.cursorTextColour : cell.foreground;
        std::uint32_t behind = underCursor ? frame.cursorColour : (cell.drawBackground ? cell.background : frame.background);
        float baselineY = y0 + std::round(frame.baseline);
        if (cell.underline) rect(lines, x0, baselineY + 2, x1, baselineY + 3, cell.foreground);
        if (cell.strike) {
          float y = y0 + std::round(frame.cellHeight * 0.55f);
          rect(lines, x0, y, x1, y + 1, cell.foreground);
        }
        // Box drawing and block elements: rectangles, so lines meet across cells.
        if (cell.text.size() == 3 && (unsigned char)cell.text[0] == 0xE2 &&
            ((unsigned char)cell.text[1] >= 0x94 && (unsigned char)cell.text[1] <= 0x96)) {
          std::uint32_t code = ((std::uint32_t)(cell.text[0] & 0x0F) << 12) | ((std::uint32_t)(cell.text[1] & 0x3F) << 6) |
                               (std::uint32_t)(cell.text[2] & 0x3F);
          bool drawn = BoxDrawing(code, x0, y0, x1, y1, [&](float l, float t, float r, float b, float shade) {
            std::uint32_t c = textColour;
            if (shade < 1) {
              auto mix = [&](int shift) {
                float f = ((textColour >> shift) & 0xFF) * shade + ((behind >> shift) & 0xFF) * (1 - shade);
                return (std::uint32_t)std::lround(f) << shift;
              };
              c = mix(16) | mix(8) | mix(0);
            }
            if (r > l && b > t) rect(lines, l, t, r, b, c);
          });
          if (drawn) continue;
        }
        if (!cell.text.empty() && cell.text != " ") {
          const Glyph &g = glyph(cell, frame.cellWidth * cell.width, frame.cellHeight);
          if (!g.empty) {
            glyphs.push_back(x0 + g.left);
            glyphs.push_back(baselineY + g.top);
            glyphs.push_back((float)g.width);
            glyphs.push_back((float)g.height);
            glyphs.push_back((float)g.x);
            glyphs.push_back((float)g.y);
            glyphs.push_back((float)g.width);
            glyphs.push_back((float)g.height);
            colour(textColour, g.colour ? 2.0f : 1.0f, glyphs);
          }
        }
      }
    }
    if (frame.cursorStyle == GLCursorStyle::Beam || frame.cursorStyle == GLCursorStyle::Underline) {
      float x0 = columnX(frame.cursorColumn), y0 = rowY(frame.cursorRow), y1 = rowY(frame.cursorRow + 1);
      if (frame.cursorStyle == GLCursorStyle::Beam) rect(lines, x0, y0, x0 + 2, y1, frame.cursorColour);
      else rect(lines, x0, y1 - 2, columnX(frame.cursorColumn + 1), y1, frame.cursorColour);
    }
    uploadAtlas();
    _timing.prepare = Milliseconds(start);

    auto drawStart = std::chrono::steady_clock::now();
    _gl.Viewport(0, 0, frame.pixelWidth, frame.pixelHeight);
    _gl.ClearColor(((frame.background >> 16) & 0xFF) / 255.0f, ((frame.background >> 8) & 0xFF) / 255.0f,
                   (frame.background & 0xFF) / 255.0f, 1.0f);
    _gl.Clear(kColorBufferBit);
    drawRects(rects, frame);
    drawGlyphs(glyphs, frame);
    drawRects(lines, frame);
    _timing.draw = Milliseconds(drawStart);

    auto readStart = std::chrono::steady_clock::now();
    _gl.PixelStorei(kPackAlignment, 1);
    _gl.ReadPixels(0, 0, frame.pixelWidth, frame.pixelHeight, kRGBA, kUnsignedByte, pixels);
    _timing.readback = Milliseconds(readStart);
    _timing.atlasGlyphs = _glyphs.size();
    GLenum glError = _gl.GetError();
    if (glError != kNoError) {
      *error = "OpenGL error " + std::to_string(glError);
      return false;
    }
    return true;
  }

  std::string description() const override { return _description; }
  const GLTiming &lastTiming() const override { return _timing; }

private:
  static constexpr int kAtlasSize = 2048;

  bool sizeFramebuffer(int width, int height, std::string *error) {
    if (_framebuffer && width == _fbWidth && height == _fbHeight) {
      _gl.BindFramebuffer(kFramebuffer, _framebuffer);
      return true;
    }
    if (_framebuffer) {
      _gl.DeleteFramebuffers(1, &_framebuffer);
      _gl.DeleteRenderbuffers(1, &_renderbuffer);
    }
    _gl.GenFramebuffers(1, &_framebuffer);
    _gl.BindFramebuffer(kFramebuffer, _framebuffer);
    _gl.GenRenderbuffers(1, &_renderbuffer);
    _gl.BindRenderbuffer(kRenderbuffer, _renderbuffer);
    _gl.RenderbufferStorage(kRenderbuffer, kRGBA8, width, height);
    _gl.FramebufferRenderbuffer(kFramebuffer, kColorAttachment0, kRenderbuffer, _renderbuffer);
    if (_gl.CheckFramebufferStatus(kFramebuffer) != kFramebufferComplete) {
      *error = "framebuffer incomplete at " + std::to_string(width) + "x" + std::to_string(height);
      return false;
    }
    _fbWidth = width;
    _fbHeight = height;
    return true;
  }

  GLuint compile(GLenum type, const char *source, std::string *error) {
    GLuint shader = _gl.CreateShader(type);
    _gl.ShaderSource(shader, 1, &source, nullptr);
    _gl.CompileShader(shader);
    GLint ok = 0;
    _gl.GetShaderiv(shader, kCompileStatus, &ok);
    if (!ok) {
      char log[1024] = "";
      _gl.GetShaderInfoLog(shader, sizeof log, nullptr, log);
      *error = std::string("shader: ") + log;
      return 0;
    }
    return shader;
  }

  GLuint link(const char *vertex, const char *fragment, std::string *error) {
    GLuint v = compile(kVertexShader, vertex, error);
    if (!v) return 0;
    GLuint f = compile(kFragmentShader, fragment, error);
    if (!f) return 0;
    GLuint program = _gl.CreateProgram();
    _gl.AttachShader(program, v);
    _gl.AttachShader(program, f);
    _gl.LinkProgram(program);
    GLint ok = 0;
    _gl.GetProgramiv(program, kLinkStatus, &ok);
    if (!ok) {
      char log[1024] = "";
      _gl.GetProgramInfoLog(program, sizeof log, nullptr, log);
      *error = std::string("link: ") + log;
      return 0;
    }
    return program;
  }

  bool setUpPrograms(std::string *error) {
    _rectProgram = link(kRectVertex, kRectFragment, error);
    if (!_rectProgram) return false;
    _glyphProgram = link(kGlyphVertex, kGlyphFragment, error);
    if (!_glyphProgram) return false;
    _gl.GenVertexArrays(1, &_vertexArray);
    _gl.BindVertexArray(_vertexArray);
    _gl.GenBuffers(1, &_rectBuffer);
    _gl.GenBuffers(1, &_glyphBuffer);
    _gl.GenTextures(1, &_atlasTexture);
    _gl.BindTexture(kTexture2D, _atlasTexture);
    _gl.TexParameteri(kTexture2D, kTextureMinFilter, kNearest);
    _gl.TexParameteri(kTexture2D, kTextureMagFilter, kNearest);
    _atlasPixels.assign((std::size_t)kAtlasSize * kAtlasSize * 4, 0);
    _gl.TexImage2D(kTexture2D, 0, kRGBA8, kAtlasSize, kAtlasSize, 0, kRGBA, kUnsignedByte, _atlasPixels.data());
    return true;
  }

  void drawRects(const std::vector<float> &data, const GLFrame &frame) {
    if (data.empty()) return;
    _gl.Disable(kBlend);
    _gl.UseProgram(_rectProgram);
    _gl.Uniform2f(_gl.GetUniformLocation(_rectProgram, "viewport"), (float)frame.pixelWidth, (float)frame.pixelHeight);
    _gl.BindBuffer(kArrayBuffer, _rectBuffer);
    _gl.BufferData(kArrayBuffer, (GLsizeiptr)(data.size() * sizeof(float)), data.data(), kStreamDraw);
    const GLsizei stride = 8 * sizeof(float);
    for (GLuint i = 0; i < 2; i++) {
      _gl.VertexAttribPointer(i, 4, kFloat, kFalse, stride, (const void *)(i * 4 * sizeof(float)));
      _gl.EnableVertexAttribArray(i);
      _gl.VertexAttribDivisor(i, 1);
    }
    _gl.DrawArraysInstanced(kTriangleStrip, 0, 4, (GLsizei)(data.size() / 8));
  }

  void drawGlyphs(const std::vector<float> &data, const GLFrame &frame) {
    if (data.empty()) return;
    _gl.Enable(kBlend);
    _gl.BlendFunc(kSrc1Color, kOneMinusSrc1Color);
    _gl.UseProgram(_glyphProgram);
    _gl.Uniform2f(_gl.GetUniformLocation(_glyphProgram, "viewport"), (float)frame.pixelWidth, (float)frame.pixelHeight);
    _gl.Uniform2f(_gl.GetUniformLocation(_glyphProgram, "atlasSize"), (float)kAtlasSize, (float)kAtlasSize);
    _gl.Uniform1f(_gl.GetUniformLocation(_glyphProgram, "contrast"), _contrast);
    _gl.Uniform1f(_gl.GetUniformLocation(_glyphProgram, "lightGamma"), _lightGamma);
    _gl.Uniform1i(_gl.GetUniformLocation(_glyphProgram, "grayscale"), _clearType ? 0 : 1);
    _gl.Uniform1i(_gl.GetUniformLocation(_glyphProgram, "atlas"), 0);
    _gl.ActiveTexture(kTexture0);
    _gl.BindTexture(kTexture2D, _atlasTexture);
    _gl.BindBuffer(kArrayBuffer, _glyphBuffer);
    _gl.BufferData(kArrayBuffer, (GLsizeiptr)(data.size() * sizeof(float)), data.data(), kStreamDraw);
    const GLsizei stride = 12 * sizeof(float);
    for (GLuint i = 0; i < 3; i++) {
      _gl.VertexAttribPointer(i, 4, kFloat, kFalse, stride, (const void *)(i * 4 * sizeof(float)));
      _gl.EnableVertexAttribArray(i);
      _gl.VertexAttribDivisor(i, 1);
    }
    _gl.DrawArraysInstanced(kTriangleStrip, 0, 4, (GLsizei)(data.size() / 12));
    _gl.Disable(kBlend);
  }

  const Glyph &glyph(const GLCell &cell, float spanWidth, float cellHeight) {
    int style = (cell.bold ? 1 : 0) | (cell.italic ? 2 : 0);
    // Most cells are plain ASCII: a direct table, not a string-keyed lookup.
    bool ascii = cell.text.size() == 1 && (unsigned char)cell.text[0] < 0x80;
    if (ascii) {
      const Glyph *cached = _ascii[style][(unsigned char)cell.text[0]];
      if (cached) return *cached;
    }
    auto key = std::make_pair(cell.text, style);
    auto found = _glyphs.find(key);
    if (found != _glyphs.end()) return found->second;
    Glyph g;
    GlyphBitmap bitmap;
    if (_source->rasterise(cell.text, style, spanWidth, cellHeight, &bitmap) && bitmap.width > 0 && bitmap.height > 0 &&
        place(bitmap, g)) {
      g.left = bitmap.left;
      g.top = bitmap.top;
      g.colour = bitmap.colour;
    }
    _timing.glyphsRasterised++;
    const Glyph &stored = _glyphs.emplace(key, g).first->second;
    if (ascii) _ascii[style][(unsigned char)cell.text[0]] = &stored;
    return stored;
  }

  // Shelf packing into the atlas. When it's full it starts again and everything is rasterised again as it's needed.
  bool place(const GlyphBitmap &bitmap, Glyph &g) {
    int width = bitmap.width, height = bitmap.height;
    if (width > kAtlasSize || height > kAtlasSize) return false;
    if (_shelfX + width > kAtlasSize) {
      _shelfX = 0;
      _shelfY += _shelfHeight + 1;
      _shelfHeight = 0;
    }
    if (_shelfY + height > kAtlasSize) {
      _glyphs.clear();
      std::memset(_ascii, 0, sizeof _ascii);
      _shelfX = _shelfY = _shelfHeight = 0;
      std::fill(_atlasPixels.begin(), _atlasPixels.end(), 0);
      _dirtyTop = 0;
      _dirtyBottom = kAtlasSize;
    }
    g.x = _shelfX;
    g.y = _shelfY;
    g.width = width;
    g.height = height;
    g.empty = false;
    for (int y = 0; y < height; y++) {
      std::memcpy(&_atlasPixels[4 * ((std::size_t)(g.y + y) * kAtlasSize + g.x)], &bitmap.rgba[4 * (std::size_t)y * width],
                  (std::size_t)width * 4);
    }
    _dirtyTop = std::min(_dirtyTop, g.y);
    _dirtyBottom = std::max(_dirtyBottom, g.y + height);
    _shelfX += width + 1;
    _shelfHeight = std::max(_shelfHeight, height);
    return true;
  }

  void uploadAtlas() {
    if (_dirtyTop >= _dirtyBottom) return;
    _gl.BindTexture(kTexture2D, _atlasTexture);
    _gl.PixelStorei(kUnpackAlignment, 1);
    _gl.TexSubImage2D(kTexture2D, 0, 0, _dirtyTop, kAtlasSize, _dirtyBottom - _dirtyTop, kRGBA, kUnsignedByte,
                      &_atlasPixels[4 * (std::size_t)_dirtyTop * kAtlasSize]);
    _dirtyTop = kAtlasSize;
    _dirtyBottom = 0;
  }

  std::unique_ptr<GLContext> _context;
  std::unique_ptr<GlyphSource> _source;
  GL _gl;
  std::string _description;
  GLTiming _timing;
  bool _clearType = true;
  float _contrast = 1.0f, _lightGamma = 1.2f;
  GLuint _framebuffer = 0, _renderbuffer = 0;
  int _fbWidth = 0, _fbHeight = 0;
  GLuint _rectProgram = 0, _glyphProgram = 0, _vertexArray = 0, _rectBuffer = 0, _glyphBuffer = 0, _atlasTexture = 0;
  std::map<std::pair<std::string, int>, Glyph> _glyphs;  // node-based: references stay valid as it grows
  const Glyph *_ascii[4][128] = {};
  std::vector<std::uint8_t> _atlasPixels;
  int _shelfX = 0, _shelfY = 0, _shelfHeight = 0;
  int _dirtyTop = kAtlasSize, _dirtyBottom = 0;
};

}  // namespace

std::unique_ptr<GLRenderer> GLRenderer::create(const std::string &fontFamily, float pixelSize, Antialiasing antialiasing,
                                               std::string *error) {
  bool clearType = antialiasing == Antialiasing::ClearType;
  std::unique_ptr<GLContext> context = MakeGLContext(error);
  if (!context) return nullptr;
  std::unique_ptr<GlyphSource> glyphs;
  const char *choice = getenv("COCOATERMINAL_GL_GLYPHS");
#if defined(_WIN32)
  if (choice != nullptr && strcmp(choice, "freetype") == 0) glyphs = MakeFreeTypeGlyphs(fontFamily, pixelSize, clearType, error);
  else glyphs = MakeDirectWriteGlyphs(fontFamily, pixelSize, clearType, error);
#else
  (void)choice;
  glyphs = MakeFreeTypeGlyphs(fontFamily, pixelSize, clearType, error);
#endif
  if (!glyphs) return nullptr;
  std::unique_ptr<Renderer> renderer(new Renderer);
  if (!renderer->setUp(std::move(context), std::move(glyphs), clearType, error)) return nullptr;
  return renderer;
}

std::vector<std::uint32_t> DecodeUTF8(const std::string &utf8) {
  std::vector<std::uint32_t> out;
  for (std::size_t i = 0; i < utf8.size();) {
    unsigned char c = (unsigned char)utf8[i];
    std::uint32_t cp;
    int extra;
    if (c < 0x80) { cp = c; extra = 0; }
    else if ((c >> 5) == 6) { cp = c & 0x1F; extra = 1; }
    else if ((c >> 4) == 14) { cp = c & 0x0F; extra = 2; }
    else if ((c >> 3) == 30) { cp = c & 0x07; extra = 3; }
    else { i++; continue; }
    if (i + extra >= utf8.size() && extra > 0) break;  // cut off mid-sequence
    for (int k = 1; k <= extra; k++) cp = (cp << 6) | ((unsigned char)utf8[i + k] & 0x3F);
    out.push_back(cp);
    i += 1 + extra;
  }
  return out;
}

bool IsCombiningMark(std::uint32_t cp) {
  return (cp >= 0x0300 && cp <= 0x036F) || (cp >= 0x1AB0 && cp <= 0x1AFF) || (cp >= 0x1DC0 && cp <= 0x1DFF) ||
         (cp >= 0x20D0 && cp <= 0x20FF) || (cp >= 0xFE20 && cp <= 0xFE2F);
}

}  // namespace cot

#else

namespace cot {
// Built without the renderer (COCOATERMINAL_GL_RENDERER off): the view draws with Cairo.
std::unique_ptr<GLRenderer> GLRenderer::create(const std::string &, float, Antialiasing, std::string *error) {
  if (error) *error = "built without the OpenGL renderer (COCOATERMINAL_GL_RENDERER=OFF)";
  return nullptr;
}
}  // namespace cot

#endif
