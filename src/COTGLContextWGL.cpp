// SPDX-License-Identifier: LGPL-2.1-or-later
// Copyright (C) 2026 Daniel Boyd
//
// The OpenGL renderer's context on Windows: a hidden window's WGL context. It only ever draws into the renderer's
// framebuffer object, never to the window.

#include "COTGLRendererInternal.h"

#if defined(COCOATERMINAL_GL_RENDERER) && defined(_WIN32)

#define WIN32_LEAN_AND_MEAN
#include <windows.h>

namespace cot {

namespace {

class WGLContext : public GLContext {
public:
  ~WGLContext() override {
    if (_context) {
      if (wglGetCurrentContext() == _context) wglMakeCurrent(NULL, NULL);
      wglDeleteContext(_context);
    }
    if (_dc) ReleaseDC(_window, _dc);
    if (_window) DestroyWindow(_window);
  }

  bool setUp(std::string *error) {
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
    _opengl32 = GetModuleHandleA("opengl32.dll");
    return true;
  }

  bool makeCurrent() override { return wglGetCurrentContext() == _context || wglMakeCurrent(_dc, _context); }

  void *proc(const char *name) override {
    // wglGetProcAddress gives what's past OpenGL 1.1 (and some drivers answer 1, 2, 3 or -1 for "no"); the 1.1
    // functions come from opengl32.dll itself.
    PROC p = wglGetProcAddress(name);
    intptr_t v = (intptr_t)p;
    if (v == 0 || v == 1 || v == 2 || v == 3 || v == -1) p = _opengl32 ? GetProcAddress(_opengl32, name) : NULL;
    return (void *)p;
  }

  std::string description() const override { return "WGL"; }

private:
  HWND _window = NULL;
  HDC _dc = NULL;
  HGLRC _context = NULL;
  HMODULE _opengl32 = NULL;
};

}  // namespace

std::unique_ptr<GLContext> MakeGLContext(std::string *error) {
  std::unique_ptr<WGLContext> context(new WGLContext);
  if (!context->setUp(error)) return nullptr;
  return context;
}

}  // namespace cot

#endif
