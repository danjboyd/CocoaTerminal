// SPDX-License-Identifier: LGPL-2.1-or-later
// Copyright (C) 2026 Daniel Boyd
//
// COTGLRenderer on Windows: a hidden window's WGL context drawing into a framebuffer object, and DirectWrite glyphs.
// The design follows Alacritty's renderer (written from its description, no code taken): an atlas of glyph bitmaps
// filled as glyphs are first needed, and per frame one instanced draw for every cell background and one for every
// glyph, positions snapped to whole pixels. Subpixel (ClearType) coverage is blended per colour channel with
// dual-source blending, as Alacritty does; grayscale uses the same path with equal channels.

#include "COTGLRenderer.h"
#include "COTBoxDrawing.h"

#if defined(_WIN32)

#define WIN32_LEAN_AND_MEAN
#include <windows.h>
#include <dwrite_2.h>
#include <GL/gl.h>

#include <algorithm>
#include <chrono>
#include <cmath>
#include <cstdio>
#include <cstdlib>
#include <cstring>
#include <map>
#include <tuple>

namespace cot {

namespace {

// ---- The OpenGL 3.3 functions opengl32.dll doesn't export.

typedef char GLchar;
typedef std::ptrdiff_t GLsizeiptr;
typedef std::ptrdiff_t GLintptr;

#define COT_GL_ARRAY_BUFFER 0x8892
#define COT_GL_STREAM_DRAW 0x88E0
#define COT_GL_FRAGMENT_SHADER 0x8B30
#define COT_GL_VERTEX_SHADER 0x8B31
#define COT_GL_COMPILE_STATUS 0x8B81
#define COT_GL_LINK_STATUS 0x8B82
#define COT_GL_FRAMEBUFFER 0x8D40
#define COT_GL_RENDERBUFFER 0x8D41
#define COT_GL_COLOR_ATTACHMENT0 0x8CE0
#define COT_GL_FRAMEBUFFER_COMPLETE 0x8CD5
#define COT_GL_RGBA8 0x8058
#define COT_GL_SRC1_COLOR 0x88F9
#define COT_GL_ONE_MINUS_SRC1_COLOR 0x88FA
#define COT_GL_TEXTURE0 0x84C0

struct GLFunctions {
#define COT_GL_FN(ret, name, args) ret(APIENTRY *name) args = nullptr;
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

  bool load(std::string *missing) {
#define COT_GL_LOAD(name)                                                                  \
  name = reinterpret_cast<decltype(name)>(wglGetProcAddress("gl" #name));                  \
  if (name == nullptr) {                                                                   \
    *missing = "gl" #name;                                                                 \
    return false;                                                                          \
  }
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

const char *kRectVertex = R"(#version 330
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

const char *kRectFragment = R"(#version 330
in vec4 vColour;
out vec4 fragColour;
void main() { fragColour = vColour; }
)";

const char *kGlyphVertex = R"(#version 330
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

// Coverage comes from DirectWrite's ClearType texture (red, green, blue coverage; equal in grayscale). The blend is
// dst = colour * mask + dst * (1 - mask) per channel (dual-source). Enhanced contrast is the curve DirectWrite
// applies, a * (k + 1) / (a * k + 1); light text on a dark background gets a stronger one and a gamma lift, as stems
// otherwise look thin there. Both are tunable (COCOATERMINAL_GL_CONTRAST, COCOATERMINAL_GL_GAMMA).
const char *kGlyphFragment = R"(#version 330
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

std::wstring Widen(const std::string &utf8) {
  if (utf8.empty()) return std::wstring();
  int count = MultiByteToWideChar(CP_UTF8, 0, utf8.data(), (int)utf8.size(), NULL, 0);
  std::wstring wide((std::size_t)count, L'\0');
  MultiByteToWideChar(CP_UTF8, 0, utf8.data(), (int)utf8.size(), &wide[0], count);
  return wide;
}

std::vector<UINT32> CodePoints(const std::string &utf8) {
  std::vector<UINT32> out;
  for (std::size_t i = 0; i < utf8.size();) {
    unsigned char c = (unsigned char)utf8[i];
    UINT32 cp;
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

struct Glyph {
  int x = 0, y = 0, width = 0, height = 0;  // in the atlas
  int left = 0, top = 0;                    // bitmap's top-left from the pen position on the baseline
  bool colour = false;
  bool empty = true;
};

class WindowsGLRenderer : public GLRenderer {
public:
  ~WindowsGLRenderer() override {
    for (auto &face : _faces) Release(face);
    for (auto &entry : _fallbackFaces) Release(entry.second);
    Release(_collection);
    Release(_factory);
    if (_context) {
      wglMakeCurrent(NULL, NULL);
      wglDeleteContext(_context);
    }
    if (_dc) ReleaseDC(_window, _dc);
    if (_window) DestroyWindow(_window);
  }

  bool setUp(const std::string &family, float pixelSize, Antialiasing antialiasing, std::string *error) {
    _pixelSize = pixelSize;
    _antialiasing = antialiasing;
    if (const char *c = getenv("COCOATERMINAL_GL_CONTRAST")) _contrast = (float)atof(c);
    else _contrast = antialiasing == Antialiasing::ClearType ? 0.5f : 1.0f;
    if (const char *g = getenv("COCOATERMINAL_GL_GAMMA")) _lightGamma = (float)atof(g);
    return setUpContext(error) && setUpFonts(family, error) && setUpPrograms(error);
  }

  bool render(const GLFrame &frame, std::uint8_t *pixels, std::string *error) override {
    auto start = std::chrono::steady_clock::now();
    _timing = GLTiming();
    if (!wglMakeCurrent(_dc, _context)) {
      *error = "wglMakeCurrent failed";
      return false;
    }
    if (!sizeFramebuffer(frame.pixelWidth, frame.pixelHeight, error)) return false;

    // Batches: backgrounds (and a block cursor), glyphs, then lines drawn over the glyphs.
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
        // Box drawing and block elements: rectangles, so lines meet across cells.
        if (cell.text.size() == 3 && (unsigned char)cell.text[0] == 0xE2 && ((unsigned char)cell.text[1] == 0x94 ||
                                                                            (unsigned char)cell.text[1] == 0x95 ||
                                                                            (unsigned char)cell.text[1] == 0x96)) {
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
          if (drawn) {
            if (cell.underline) rect(lines, x0, y0 + std::round(frame.baseline) + 2, x1, y0 + std::round(frame.baseline) + 3, cell.foreground);
            continue;
          }
        }
        if (!cell.text.empty() && cell.text != " ") {
          const Glyph &g = glyph(cell, frame.cellWidth * cell.width, frame.cellHeight);
          if (!g.empty) {
            float baselineY = y0 + std::round(frame.baseline);
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
        if (cell.underline) {
          float y = y0 + std::round(frame.baseline) + 2;
          rect(lines, x0, y, x1, y + 1, cell.foreground);
        }
        if (cell.strike) {
          float y = y0 + std::round(frame.cellHeight * 0.55f);
          rect(lines, x0, y, x1, y + 1, cell.foreground);
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
    glViewport(0, 0, frame.pixelWidth, frame.pixelHeight);
    glClearColor(((frame.background >> 16) & 0xFF) / 255.0f, ((frame.background >> 8) & 0xFF) / 255.0f,
                 (frame.background & 0xFF) / 255.0f, 1.0f);
    glClear(GL_COLOR_BUFFER_BIT);
    drawRects(rects, frame);
    drawGlyphs(glyphs, frame);
    drawRects(lines, frame);
    _timing.draw = Milliseconds(drawStart);

    auto readStart = std::chrono::steady_clock::now();
    glPixelStorei(GL_PACK_ALIGNMENT, 1);
    glReadPixels(0, 0, frame.pixelWidth, frame.pixelHeight, GL_RGBA, GL_UNSIGNED_BYTE, pixels);
    _timing.readback = Milliseconds(readStart);
    _timing.atlasGlyphs = _glyphs.size();
    GLenum glError = glGetError();
    if (glError != GL_NO_ERROR) {
      *error = "OpenGL error " + std::to_string(glError);
      return false;
    }
    return true;
  }

  std::string description() const override { return _description; }
  const GLTiming &lastTiming() const override { return _timing; }

private:
  // ---- Context and framebuffer.

  bool setUpContext(std::string *error) {
    WNDCLASSA wc = {};
    wc.lpfnWndProc = DefWindowProcA;
    wc.hInstance = GetModuleHandleA(NULL);
    wc.lpszClassName = "COTGLRenderer";
    RegisterClassA(&wc);
    _window = CreateWindowA("COTGLRenderer", "", WS_POPUP, 0, 0, 16, 16, NULL, NULL, wc.hInstance, NULL);
    if (!_window) {
      *error = "CreateWindow failed";
      return false;
    }
    _dc = GetDC(_window);
    PIXELFORMATDESCRIPTOR pfd = {sizeof pfd, 1, PFD_DRAW_TO_WINDOW | PFD_SUPPORT_OPENGL | PFD_DOUBLEBUFFER, PFD_TYPE_RGBA, 32};
    int format = ChoosePixelFormat(_dc, &pfd);
    if (format == 0 || !SetPixelFormat(_dc, format, &pfd)) {
      *error = "no OpenGL pixel format";
      return false;
    }
    _context = wglCreateContext(_dc);
    if (!_context || !wglMakeCurrent(_dc, _context)) {
      *error = "wglCreateContext failed";
      return false;
    }
    const char *version = (const char *)glGetString(GL_VERSION);
    const char *renderer = (const char *)glGetString(GL_RENDERER);
    int major = version ? atoi(version) : 0;
    const char *dot = version ? strchr(version, '.') : nullptr;
    int minor = dot ? atoi(dot + 1) : 0;
    _description = std::string("OpenGL ") + (version ? version : "?") + " on " + (renderer ? renderer : "?");
    if (major < 3 || (major == 3 && minor < 3)) {
      *error = "needs OpenGL 3.3; have " + _description;
      return false;
    }
    std::string missing;
    if (!_gl.load(&missing)) {
      *error = "OpenGL has no " + missing + " (" + _description + ")";
      return false;
    }
    return true;
  }

  bool sizeFramebuffer(int width, int height, std::string *error) {
    if (_framebuffer && width == _fbWidth && height == _fbHeight) {
      _gl.BindFramebuffer(COT_GL_FRAMEBUFFER, _framebuffer);
      return true;
    }
    if (_framebuffer) {
      _gl.DeleteFramebuffers(1, &_framebuffer);
      _gl.DeleteRenderbuffers(1, &_renderbuffer);
    }
    _gl.GenFramebuffers(1, &_framebuffer);
    _gl.BindFramebuffer(COT_GL_FRAMEBUFFER, _framebuffer);
    _gl.GenRenderbuffers(1, &_renderbuffer);
    _gl.BindRenderbuffer(COT_GL_RENDERBUFFER, _renderbuffer);
    _gl.RenderbufferStorage(COT_GL_RENDERBUFFER, COT_GL_RGBA8, width, height);
    _gl.FramebufferRenderbuffer(COT_GL_FRAMEBUFFER, COT_GL_COLOR_ATTACHMENT0, COT_GL_RENDERBUFFER, _renderbuffer);
    if (_gl.CheckFramebufferStatus(COT_GL_FRAMEBUFFER) != COT_GL_FRAMEBUFFER_COMPLETE) {
      *error = "framebuffer incomplete at " + std::to_string(width) + "x" + std::to_string(height);
      return false;
    }
    _fbWidth = width;
    _fbHeight = height;
    return true;
  }

  // ---- Programs and the two draws.

  GLuint compile(GLenum type, const char *source, std::string *error) {
    GLuint shader = _gl.CreateShader(type);
    _gl.ShaderSource(shader, 1, &source, nullptr);
    _gl.CompileShader(shader);
    GLint ok = 0;
    _gl.GetShaderiv(shader, COT_GL_COMPILE_STATUS, &ok);
    if (!ok) {
      char log[1024] = "";
      _gl.GetShaderInfoLog(shader, sizeof log, nullptr, log);
      *error = std::string("shader: ") + log;
      return 0;
    }
    return shader;
  }

  GLuint link(const char *vertex, const char *fragment, std::string *error) {
    GLuint v = compile(COT_GL_VERTEX_SHADER, vertex, error);
    if (!v) return 0;
    GLuint f = compile(COT_GL_FRAGMENT_SHADER, fragment, error);
    if (!f) return 0;
    GLuint program = _gl.CreateProgram();
    _gl.AttachShader(program, v);
    _gl.AttachShader(program, f);
    _gl.LinkProgram(program);
    GLint ok = 0;
    _gl.GetProgramiv(program, COT_GL_LINK_STATUS, &ok);
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
    glGenTextures(1, &_atlasTexture);
    glBindTexture(GL_TEXTURE_2D, _atlasTexture);
    glTexParameteri(GL_TEXTURE_2D, GL_TEXTURE_MIN_FILTER, GL_NEAREST);
    glTexParameteri(GL_TEXTURE_2D, GL_TEXTURE_MAG_FILTER, GL_NEAREST);
    _atlasPixels.assign((std::size_t)kAtlasSize * kAtlasSize * 4, 0);
    glTexImage2D(GL_TEXTURE_2D, 0, COT_GL_RGBA8, kAtlasSize, kAtlasSize, 0, GL_RGBA, GL_UNSIGNED_BYTE, _atlasPixels.data());
    return true;
  }

  void drawRects(const std::vector<float> &data, const GLFrame &frame) {
    if (data.empty()) return;
    glDisable(GL_BLEND);
    _gl.UseProgram(_rectProgram);
    _gl.Uniform2f(_gl.GetUniformLocation(_rectProgram, "viewport"), (float)frame.pixelWidth, (float)frame.pixelHeight);
    _gl.BindBuffer(COT_GL_ARRAY_BUFFER, _rectBuffer);
    _gl.BufferData(COT_GL_ARRAY_BUFFER, (GLsizeiptr)(data.size() * sizeof(float)), data.data(), COT_GL_STREAM_DRAW);
    const GLsizei stride = 8 * sizeof(float);
    _gl.VertexAttribPointer(0, 4, GL_FLOAT, GL_FALSE, stride, (const void *)0);
    _gl.VertexAttribPointer(1, 4, GL_FLOAT, GL_FALSE, stride, (const void *)(4 * sizeof(float)));
    for (GLuint i = 0; i < 2; i++) {
      _gl.EnableVertexAttribArray(i);
      _gl.VertexAttribDivisor(i, 1);
    }
    _gl.DrawArraysInstanced(GL_TRIANGLE_STRIP, 0, 4, (GLsizei)(data.size() / 8));
  }

  void drawGlyphs(const std::vector<float> &data, const GLFrame &frame) {
    if (data.empty()) return;
    glEnable(GL_BLEND);
    glBlendFunc(COT_GL_SRC1_COLOR, COT_GL_ONE_MINUS_SRC1_COLOR);
    _gl.UseProgram(_glyphProgram);
    _gl.Uniform2f(_gl.GetUniformLocation(_glyphProgram, "viewport"), (float)frame.pixelWidth, (float)frame.pixelHeight);
    _gl.Uniform2f(_gl.GetUniformLocation(_glyphProgram, "atlasSize"), (float)kAtlasSize, (float)kAtlasSize);
    _gl.Uniform1f(_gl.GetUniformLocation(_glyphProgram, "contrast"), _contrast);
    _gl.Uniform1f(_gl.GetUniformLocation(_glyphProgram, "lightGamma"), _lightGamma);
    _gl.Uniform1i(_gl.GetUniformLocation(_glyphProgram, "grayscale"), _antialiasing == Antialiasing::Grayscale ? 1 : 0);
    _gl.Uniform1i(_gl.GetUniformLocation(_glyphProgram, "atlas"), 0);
    _gl.ActiveTexture(COT_GL_TEXTURE0);
    glBindTexture(GL_TEXTURE_2D, _atlasTexture);
    _gl.BindBuffer(COT_GL_ARRAY_BUFFER, _glyphBuffer);
    _gl.BufferData(COT_GL_ARRAY_BUFFER, (GLsizeiptr)(data.size() * sizeof(float)), data.data(), COT_GL_STREAM_DRAW);
    const GLsizei stride = 12 * sizeof(float);
    for (GLuint i = 0; i < 3; i++) {
      _gl.VertexAttribPointer(i, 4, GL_FLOAT, GL_FALSE, stride, (const void *)(i * 4 * sizeof(float)));
      _gl.EnableVertexAttribArray(i);
      _gl.VertexAttribDivisor(i, 1);
    }
    _gl.DrawArraysInstanced(GL_TRIANGLE_STRIP, 0, 4, (GLsizei)(data.size() / 12));
    glDisable(GL_BLEND);
  }

  // ---- Fonts and glyphs.

  IDWriteFontFace *faceFor(IDWriteFontFamily *family, DWRITE_FONT_WEIGHT weight, DWRITE_FONT_STYLE style) {
    IDWriteFont *font = nullptr;
    IDWriteFontFace *face = nullptr;
    if (SUCCEEDED(family->GetFirstMatchingFont(weight, DWRITE_FONT_STRETCH_NORMAL, style, &font))) {
      font->CreateFontFace(&face);
      Release(font);
    }
    return face;
  }

  bool setUpFonts(const std::string &familyName, std::string *error) {
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
    _description += std::string("; DirectWrite ") + (_antialiasing == Antialiasing::ClearType ? "ClearType" : "grayscale");
    return true;
  }

  // A face of another family that has every code point, for what the terminal's font lacks. Emoji presentation
  // (U+FE0F, or an emoji from the supplementary planes) asks Segoe UI Emoji first.
  IDWriteFontFace *fallbackFace(const std::vector<UINT32> &codePoints, bool emoji) {
    static const wchar_t *kFamilies[] = {L"Segoe UI Emoji", L"Segoe UI Symbol", L"Cambria Math", L"Segoe UI",
                                         L"Microsoft YaHei", L"MS Gothic", L"Malgun Gothic", L"Nirmala UI",
                                         L"Segoe UI Historic", L"Ebrima", L"Leelawadee UI"};
    for (const wchar_t *name : kFamilies) {
      if (!emoji && wcscmp(name, L"Segoe UI Emoji") == 0) continue;
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

  static constexpr int kAtlasSize = 2048;

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
    Glyph g = rasterise(cell.text, style, spanWidth, cellHeight);
    _timing.glyphsRasterised++;
    const Glyph &stored = _glyphs.emplace(key, g).first->second;
    if (ascii) _ascii[style][(unsigned char)cell.text[0]] = &stored;
    return stored;
  }

  // A base letter and its combining marks composed into one character where Unicode has one (e + U+0301 is é):
  // the renderer doesn't shape, so a separate mark would be drawn at its own advance, beside the letter.
  static std::string Composed(const std::string &utf8) {
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

  Glyph rasterise(const std::string &text, int style, float spanWidth, float cellHeight) {
    Glyph g;
    std::vector<UINT32> all = CodePoints(Composed(text));
    bool emoji = false;
    std::vector<UINT32> codePoints;
    for (UINT32 cp : all) {
      if (cp == 0xFE0F) emoji = true;
      if (cp == 0xFE0E || cp == 0xFE0F || cp == 0x200D) continue;  // presentation selectors and joiners: no glyph
      if (cp >= 0x1F000) emoji = true;
      codePoints.push_back(cp);
    }
    if (codePoints.empty()) return g;
    IDWriteFontFace *face = emoji ? nullptr : (_faces[style] ? _faces[style] : _faces[0]);
    std::vector<UINT16> indices(codePoints.size());
    if (face) {
      face->GetGlyphIndices(codePoints.data(), (UINT32)codePoints.size(), indices.data());
      if (std::any_of(indices.begin(), indices.end(), [](UINT16 i) { return i == 0; })) face = nullptr;
    }
    if (!face) {
      face = fallbackFace(codePoints, true);
      if (!face) return g;  // nothing has it: leave the cell blank rather than draw a box
      face->GetGlyphIndices(codePoints.data(), (UINT32)codePoints.size(), indices.data());
      if (face == _fallbackFaces[L"Segoe UI Emoji"]) emoji = true;  // only the emoji font has it: draw it in colour
    }

    // Advances from the font, at our size.
    DWRITE_FONT_METRICS metrics;
    face->GetMetrics(&metrics);
    std::vector<DWRITE_GLYPH_METRICS> glyphMetrics(indices.size());
    face->GetDesignGlyphMetrics(indices.data(), (UINT32)indices.size(), glyphMetrics.data(), FALSE);
    float emSize = _pixelSize;
    auto runWidth = [&](float size) {
      float w = 0;
      for (auto &m : glyphMetrics) w += m.advanceWidth * size / metrics.designUnitsPerEm;
      return w;
    };
    // A glyph from another font can be wider or taller than the cell (emoji are): shrink it to fit, as the Cairo
    // view does with its fallback font.
    if (face != _faces[style] && face != _faces[0]) {
      float width = runWidth(emSize);
      float height = (metrics.ascent + metrics.descent) * emSize / metrics.designUnitsPerEm;
      float scale = std::min({1.0f, spanWidth / std::max(width, 1.0f), cellHeight / std::max(height, 1.0f)});
      emSize *= scale;
    }
    std::vector<FLOAT> advances;
    for (auto &m : glyphMetrics) advances.push_back(m.advanceWidth * emSize / metrics.designUnitsPerEm);
    // A combining mark left after composing: with no shaping it would land after its letter. A monospace font gives
    // the mark a cell of its own, drawn centred, so it goes over the letter if the letter doesn't advance; a mark with
    // no advance is drawn back over the letter already.
    auto combining = [](UINT32 cp) {
      return (cp >= 0x0300 && cp <= 0x036F) || (cp >= 0x1AB0 && cp <= 0x1AFF) || (cp >= 0x1DC0 && cp <= 0x1DFF) ||
             (cp >= 0x20D0 && cp <= 0x20FF) || (cp >= 0xFE20 && cp <= 0xFE2F);
    };
    for (std::size_t i = 1; i < codePoints.size(); i++) {
      if (combining(codePoints[i]) && advances[i] > 0) advances[i - 1] = 0;
    }

    DWRITE_GLYPH_RUN run = {};
    run.fontFace = face;
    run.fontEmSize = emSize;
    run.glyphCount = (UINT32)indices.size();
    run.glyphIndices = indices.data();
    run.glyphAdvances = advances.data();

    // Colour glyphs (emoji): DirectWrite splits them into single-colour layers; each is rasterised and composited.
    IDWriteColorGlyphRunEnumerator *layers = nullptr;
    HRESULT colourResult = emoji ? _factory->TranslateColorGlyphRun(0, 0, &run, nullptr, DWRITE_MEASURING_MODE_NATURAL,
                                                                     nullptr, 0, &layers)
                                 : E_NOTIMPL;
    if (getenv("COCOATERMINAL_GL_DEBUG")) {
      fprintf(stderr, "[gl] glyph %s: %zu code point(s), %s face, emoji=%d, colour layers hr=0x%08lx, em %.1f\n", text.c_str(),
              codePoints.size(), face == _faces[style] || face == _faces[0] ? "terminal" : "fallback", emoji,
              (unsigned long)colourResult, emSize);
    }
    if (SUCCEEDED(colourResult)) {
      g = rasteriseColour(layers);
      Release(layers);
      return g;
    }

    DWRITE_TEXT_ANTIALIAS_MODE antialias =
        _antialiasing == Antialiasing::ClearType ? DWRITE_TEXT_ANTIALIAS_MODE_CLEARTYPE : DWRITE_TEXT_ANTIALIAS_MODE_GRAYSCALE;
    IDWriteGlyphRunAnalysis *analysis = nullptr;
    if (FAILED(_factory->CreateGlyphRunAnalysis(&run, nullptr, DWRITE_RENDERING_MODE_NATURAL_SYMMETRIC,
                                                DWRITE_MEASURING_MODE_NATURAL, DWRITE_GRID_FIT_MODE_ENABLED, antialias, 0, 0,
                                                &analysis))) {
      return g;
    }
    RECT bounds;
    std::vector<BYTE> coverage;
    bool got = Coverage(analysis, _antialiasing == Antialiasing::ClearType, &bounds, &coverage);
    Release(analysis);
    if (!got) return g;
    int width = bounds.right - bounds.left, height = bounds.bottom - bounds.top;
    std::vector<std::uint8_t> rgba((std::size_t)width * height * 4);
    for (std::size_t i = 0, n = (std::size_t)width * height; i < n; i++) {
      rgba[4 * i] = coverage[3 * i];
      rgba[4 * i + 1] = coverage[3 * i + 1];
      rgba[4 * i + 2] = coverage[3 * i + 2];
      rgba[4 * i + 3] = std::max({coverage[3 * i], coverage[3 * i + 1], coverage[3 * i + 2]});
    }
    if (!place(width, height, rgba, g)) return g;
    g.left = bounds.left;
    g.top = bounds.top;
    return g;
  }

  Glyph rasteriseColour(IDWriteColorGlyphRunEnumerator *layers) {
    Glyph g;
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
    if (parts.empty() || width <= 0 || height <= 0) return g;
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
    std::vector<std::uint8_t> rgba(premultiplied.size());
    for (std::size_t i = 0; i < premultiplied.size(); i++) rgba[i] = (std::uint8_t)std::lround(std::clamp(premultiplied[i], 0.0f, 1.0f) * 255);
    if (!place(width, height, rgba, g)) return g;
    g.left = all.left;
    g.top = all.top;
    g.colour = true;
    return g;
  }

  // Shelf packing into the atlas. When it's full it starts again; glyphs already handed out this frame stay valid
  // because the pixels are only overwritten on the next upload, and everything is re-rasterised as it's needed.
  bool place(int width, int height, const std::vector<std::uint8_t> &rgba, Glyph &g) {
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
      _atlasDirty = true;
    }
    g.x = _shelfX;
    g.y = _shelfY;
    g.width = width;
    g.height = height;
    g.empty = false;
    for (int y = 0; y < height; y++) {
      std::memcpy(&_atlasPixels[4 * ((std::size_t)(g.y + y) * kAtlasSize + g.x)], &rgba[4 * (std::size_t)y * width], (std::size_t)width * 4);
    }
    _dirtyTop = std::min(_dirtyTop, g.y);
    _dirtyBottom = std::max(_dirtyBottom, g.y + height);
    _atlasDirty = true;
    _shelfX += width + 1;
    _shelfHeight = std::max(_shelfHeight, height);
    return true;
  }

  void uploadAtlas() {
    if (!_atlasDirty) return;
    glBindTexture(GL_TEXTURE_2D, _atlasTexture);
    glPixelStorei(GL_UNPACK_ALIGNMENT, 1);
    int top = std::min(_dirtyTop, kAtlasSize), bottom = std::max(top, std::min(_dirtyBottom, kAtlasSize));
    if (_dirtyTop > _dirtyBottom) {  // cleared: the whole atlas
      top = 0;
      bottom = kAtlasSize;
    }
    glTexSubImage2D(GL_TEXTURE_2D, 0, 0, top, kAtlasSize, bottom - top, GL_RGBA, GL_UNSIGNED_BYTE,
                    &_atlasPixels[4 * (std::size_t)top * kAtlasSize]);
    _atlasDirty = false;
    _dirtyTop = kAtlasSize;
    _dirtyBottom = 0;
  }

  HWND _window = NULL;
  HDC _dc = NULL;
  HGLRC _context = NULL;
  GLFunctions _gl;
  std::string _description;
  GLTiming _timing;
  GLuint _framebuffer = 0, _renderbuffer = 0;
  int _fbWidth = 0, _fbHeight = 0;
  GLuint _rectProgram = 0, _glyphProgram = 0, _vertexArray = 0, _rectBuffer = 0, _glyphBuffer = 0, _atlasTexture = 0;
  IDWriteFactory2 *_factory = nullptr;
  IDWriteFontCollection *_collection = nullptr;
  IDWriteFontFace *_faces[4] = {nullptr, nullptr, nullptr, nullptr};
  std::map<std::wstring, IDWriteFontFace *> _fallbackFaces;
  float _pixelSize = 13;
  float _contrast = 1.0f, _lightGamma = 1.2f;
  Antialiasing _antialiasing = Antialiasing::ClearType;
  std::map<std::pair<std::string, int>, Glyph> _glyphs;  // node-based: references stay valid as it grows
  const Glyph *_ascii[4][128] = {};
  std::vector<std::uint8_t> _atlasPixels;
  int _shelfX = 0, _shelfY = 0, _shelfHeight = 0;
  bool _atlasDirty = false;
  int _dirtyTop = kAtlasSize, _dirtyBottom = 0;
};

}  // namespace

std::unique_ptr<GLRenderer> GLRenderer::create(const std::string &fontFamily, float pixelSize, Antialiasing antialiasing,
                                               std::string *error) {
  std::unique_ptr<WindowsGLRenderer> renderer(new WindowsGLRenderer);
  if (!renderer->setUp(fontFamily, pixelSize, antialiasing, error)) return nullptr;
  return renderer;
}

}  // namespace cot

#else

namespace cot {
// Not on this platform yet (Linux needs an EGL or GLX context and FreeType glyphs): the view draws with Cairo.
std::unique_ptr<GLRenderer> GLRenderer::create(const std::string &, float, Antialiasing, std::string *error) {
  if (error) *error = "the OpenGL renderer is Windows-only so far";
  return nullptr;
}
}  // namespace cot

#endif
