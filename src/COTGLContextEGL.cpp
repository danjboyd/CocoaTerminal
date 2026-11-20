// SPDX-License-Identifier: LGPL-2.1-or-later
// Copyright (C) 2026 Daniel Boyd
//
// The OpenGL renderer's context on Linux: EGL with no window, as the renderer only draws into its own framebuffer
// object. Tries Mesa's surfaceless platform first (no display server needed), then the default display with a 1x1
// pbuffer. Asks for OpenGL 3.3 core.

#include "COTGLRendererInternal.h"

#if defined(COCOATERMINAL_GL_RENDERER) && !defined(_WIN32) && !defined(__APPLE__)

#include <EGL/egl.h>
#include <EGL/eglext.h>

namespace cot {

namespace {

class EGLGLContext : public GLContext {
public:
  ~EGLGLContext() override {
    if (_display != EGL_NO_DISPLAY) {
      eglMakeCurrent(_display, EGL_NO_SURFACE, EGL_NO_SURFACE, EGL_NO_CONTEXT);
      if (_context != EGL_NO_CONTEXT) eglDestroyContext(_display, _context);
      if (_surface != EGL_NO_SURFACE) eglDestroySurface(_display, _surface);
      eglTerminate(_display);
    }
  }

  bool setUp(std::string *error) {
#ifdef EGL_PLATFORM_SURFACELESS_MESA
    auto getPlatformDisplay = (PFNEGLGETPLATFORMDISPLAYEXTPROC)eglGetProcAddress("eglGetPlatformDisplayEXT");
    if (getPlatformDisplay) {
      _display = getPlatformDisplay(EGL_PLATFORM_SURFACELESS_MESA, EGL_DEFAULT_DISPLAY, nullptr);
      _platform = "EGL surfaceless";
    }
#endif
    if (_display == EGL_NO_DISPLAY || !eglInitialize(_display, nullptr, nullptr)) {
      _display = eglGetDisplay(EGL_DEFAULT_DISPLAY);
      _platform = "EGL";
      if (_display == EGL_NO_DISPLAY || !eglInitialize(_display, nullptr, nullptr)) {
        *error = "no EGL display";
        return false;
      }
    }
    if (!eglBindAPI(EGL_OPENGL_API)) {
      *error = "EGL has no desktop OpenGL";
      return false;
    }
    const EGLint configAttributes[] = {EGL_SURFACE_TYPE, EGL_PBUFFER_BIT, EGL_RENDERABLE_TYPE, EGL_OPENGL_BIT,
                                       EGL_RED_SIZE, 8, EGL_GREEN_SIZE, 8, EGL_BLUE_SIZE, 8, EGL_NONE};
    EGLConfig config = nullptr;
    EGLint count = 0;
    if (!eglChooseConfig(_display, configAttributes, &config, 1, &count) || count < 1) {
      // The surfaceless platform may offer no pbuffer configs; any OpenGL config will do, with no surface at all.
      const EGLint anyAttributes[] = {EGL_RENDERABLE_TYPE, EGL_OPENGL_BIT, EGL_NONE};
      if (!eglChooseConfig(_display, anyAttributes, &config, 1, &count) || count < 1) {
        *error = "no EGL config for OpenGL";
        return false;
      }
    } else {
      const EGLint pbuffer[] = {EGL_WIDTH, 1, EGL_HEIGHT, 1, EGL_NONE};
      _surface = eglCreatePbufferSurface(_display, config, pbuffer);
    }
    const EGLint contextAttributes[] = {EGL_CONTEXT_MAJOR_VERSION, 3, EGL_CONTEXT_MINOR_VERSION, 3,
                                        EGL_CONTEXT_OPENGL_PROFILE_MASK, EGL_CONTEXT_OPENGL_CORE_PROFILE_BIT, EGL_NONE};
    _context = eglCreateContext(_display, config, EGL_NO_CONTEXT, contextAttributes);
    if (_context == EGL_NO_CONTEXT) {
      *error = "EGL couldn't make an OpenGL 3.3 core context";
      return false;
    }
    if (!makeCurrent()) {
      *error = "eglMakeCurrent failed";
      return false;
    }
    return true;
  }

  bool makeCurrent() override {
    if (eglGetCurrentContext() == _context) return true;
    return eglMakeCurrent(_display, _surface, _surface, _context) == EGL_TRUE;
  }

  void *proc(const char *name) override { return (void *)eglGetProcAddress(name); }

  std::string description() const override { return _platform; }

private:
  EGLDisplay _display = EGL_NO_DISPLAY;
  EGLSurface _surface = EGL_NO_SURFACE;
  EGLContext _context = EGL_NO_CONTEXT;
  std::string _platform = "EGL";
};

}  // namespace

std::unique_ptr<GLContext> MakeGLContext(std::string *error) {
  std::unique_ptr<EGLGLContext> context(new EGLGLContext);
  if (!context->setUp(error)) return nullptr;
  return context;
}

bool SetCurrentSwapInterval(int interval) {
  EGLDisplay display = eglGetCurrentDisplay();
  return display != EGL_NO_DISPLAY && eglSwapInterval(display, interval) == EGL_TRUE;
}

// GNUstep's NSOpenGLView on X11 uses GLX, not EGL: drawing into it needs a GLX version of this, not written yet.
std::unique_ptr<GLContext> MakeCurrentGLContext(std::string *error) {
  *error = "drawing into an NSOpenGLView isn't done on this platform yet (needs GLX)";
  return nullptr;
}

}  // namespace cot

#endif
