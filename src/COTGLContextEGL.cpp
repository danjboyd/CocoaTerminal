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
#include <dlfcn.h>
#if defined(COCOATERMINAL_GLX)
#include <GL/glx.h>
#endif

namespace cot {

#if defined(COCOATERMINAL_GLX)
namespace {
// GLX looked up at run time, not linked: GNUstep's x11 back end loads libGL privately and only when OpenGL is asked
// for, so a program without a libGL still starts (and draws with Cairo). dlopen of the same library returns the copy
// the back end loaded, so the context it makes current is the one these functions see.
struct GLXFunctions {
  GLXContext (*getCurrentContext)() = nullptr;
  Display *(*getCurrentDisplay)() = nullptr;
  GLXDrawable (*getCurrentDrawable)() = nullptr;
  void *(*getProcAddress)(const GLubyte *) = nullptr;
  void *proc(const char *name) const {
    return getProcAddress != nullptr ? getProcAddress(reinterpret_cast<const GLubyte *>(name)) : nullptr;
  }
};

const GLXFunctions &TheGLX() {
  static const GLXFunctions functions = [] {
    GLXFunctions f;
    void *library = dlopen("libGL.so.1", RTLD_LAZY | RTLD_LOCAL);
    if (library == nullptr) library = dlopen("libGLX.so.0", RTLD_LAZY | RTLD_LOCAL);
    if (library != nullptr) {
      f.getCurrentContext = (GLXContext(*)())dlsym(library, "glXGetCurrentContext");
      f.getCurrentDisplay = (Display * (*)()) dlsym(library, "glXGetCurrentDisplay");
      f.getCurrentDrawable = (GLXDrawable(*)())dlsym(library, "glXGetCurrentDrawable");
      f.getProcAddress = (void *(*)(const GLubyte *))dlsym(library, "glXGetProcAddressARB");
    }
    return f;
  }();
  return functions;
}
}  // namespace
#endif


namespace {

// EGL looked up at run time, not linked, so a program built with the OpenGL renderer still starts where there is no
// libEGL (and then draws with Cairo). Each slot has its function's declared type.
struct EGLFunctions {
  decltype(&eglBindAPI) BindAPI = nullptr;
  decltype(&eglChooseConfig) ChooseConfig = nullptr;
  decltype(&eglCreateContext) CreateContext = nullptr;
  decltype(&eglCreatePbufferSurface) CreatePbufferSurface = nullptr;
  decltype(&eglDestroyContext) DestroyContext = nullptr;
  decltype(&eglDestroySurface) DestroySurface = nullptr;
  decltype(&eglGetCurrentContext) GetCurrentContext = nullptr;
  decltype(&eglGetCurrentDisplay) GetCurrentDisplay = nullptr;
  decltype(&eglGetDisplay) GetDisplay = nullptr;
  decltype(&eglGetProcAddress) GetProcAddress = nullptr;
  decltype(&eglInitialize) Initialize = nullptr;
  decltype(&eglMakeCurrent) MakeCurrent = nullptr;
  decltype(&eglSwapInterval) SwapInterval = nullptr;
  bool ok = false;
};

const EGLFunctions &EGLF() {
  static const EGLFunctions functions = [] {
    EGLFunctions f;
    void *library = dlopen("libEGL.so.1", RTLD_LAZY | RTLD_LOCAL);
    if (library == nullptr) return f;
    bool all = true;
    f.BindAPI = (decltype(f.BindAPI))dlsym(library, "eglBindAPI");
    all = all && f.BindAPI != nullptr;
    f.ChooseConfig = (decltype(f.ChooseConfig))dlsym(library, "eglChooseConfig");
    all = all && f.ChooseConfig != nullptr;
    f.CreateContext = (decltype(f.CreateContext))dlsym(library, "eglCreateContext");
    all = all && f.CreateContext != nullptr;
    f.CreatePbufferSurface = (decltype(f.CreatePbufferSurface))dlsym(library, "eglCreatePbufferSurface");
    all = all && f.CreatePbufferSurface != nullptr;
    f.DestroyContext = (decltype(f.DestroyContext))dlsym(library, "eglDestroyContext");
    all = all && f.DestroyContext != nullptr;
    f.DestroySurface = (decltype(f.DestroySurface))dlsym(library, "eglDestroySurface");
    all = all && f.DestroySurface != nullptr;
    f.GetCurrentContext = (decltype(f.GetCurrentContext))dlsym(library, "eglGetCurrentContext");
    all = all && f.GetCurrentContext != nullptr;
    f.GetCurrentDisplay = (decltype(f.GetCurrentDisplay))dlsym(library, "eglGetCurrentDisplay");
    all = all && f.GetCurrentDisplay != nullptr;
    f.GetDisplay = (decltype(f.GetDisplay))dlsym(library, "eglGetDisplay");
    all = all && f.GetDisplay != nullptr;
    f.GetProcAddress = (decltype(f.GetProcAddress))dlsym(library, "eglGetProcAddress");
    all = all && f.GetProcAddress != nullptr;
    f.Initialize = (decltype(f.Initialize))dlsym(library, "eglInitialize");
    all = all && f.Initialize != nullptr;
    f.MakeCurrent = (decltype(f.MakeCurrent))dlsym(library, "eglMakeCurrent");
    all = all && f.MakeCurrent != nullptr;
    f.SwapInterval = (decltype(f.SwapInterval))dlsym(library, "eglSwapInterval");
    all = all && f.SwapInterval != nullptr;
    f.ok = all;
    return f;
  }();
  return functions;
}


// The process's EGL display, initialised once and never terminated. EGL hands every caller the same display for a
// platform, and eglInitialize isn't counted: one context's eglTerminate invalidated every other view's context, which
// then couldn't be made current and fell back to Cairo (several terminals in one window, one of them closed).
struct SharedDisplay {
  EGLDisplay display = EGL_NO_DISPLAY;
  std::string platform = "EGL";
};

const SharedDisplay &TheDisplay() {
  static const SharedDisplay shared = [] {
    SharedDisplay result;
    if (!EGLF().ok) return result;
#ifdef EGL_PLATFORM_SURFACELESS_MESA
    auto getPlatformDisplay = (PFNEGLGETPLATFORMDISPLAYEXTPROC)EGLF().GetProcAddress("eglGetPlatformDisplayEXT");
    if (getPlatformDisplay) {
      result.display = getPlatformDisplay(EGL_PLATFORM_SURFACELESS_MESA, EGL_DEFAULT_DISPLAY, nullptr);
      result.platform = "EGL surfaceless";
    }
#endif
    if (result.display == EGL_NO_DISPLAY || !EGLF().Initialize(result.display, nullptr, nullptr)) {
      result.display = EGLF().GetDisplay(EGL_DEFAULT_DISPLAY);
      result.platform = "EGL";
      if (result.display == EGL_NO_DISPLAY || !EGLF().Initialize(result.display, nullptr, nullptr)) {
        result.display = EGL_NO_DISPLAY;
      }
    }
    return result;
  }();
  return shared;
}

class EGLGLContext : public GLContext {
public:
  ~EGLGLContext() override {
    if (_display != EGL_NO_DISPLAY) {
      if (EGLF().GetCurrentContext() == _context) {
        EGLF().MakeCurrent(_display, EGL_NO_SURFACE, EGL_NO_SURFACE, EGL_NO_CONTEXT);
      }
      if (_context != EGL_NO_CONTEXT) EGLF().DestroyContext(_display, _context);
      if (_surface != EGL_NO_SURFACE) EGLF().DestroySurface(_display, _surface);
      // Not eglTerminate: the display is the process's, and other views' contexts live on it.
    }
  }

  bool setUp(std::string *error) {
    if (!EGLF().ok) {
      *error = "no libEGL";
      return false;
    }
    const SharedDisplay &shared = TheDisplay();
    _display = shared.display;
    _platform = shared.platform;
    if (_display == EGL_NO_DISPLAY) {
      *error = "no EGL display";
      return false;
    }
    if (!EGLF().BindAPI(EGL_OPENGL_API)) {
      *error = "EGL has no desktop OpenGL";
      return false;
    }
    const EGLint configAttributes[] = {EGL_SURFACE_TYPE, EGL_PBUFFER_BIT, EGL_RENDERABLE_TYPE, EGL_OPENGL_BIT,
                                       EGL_RED_SIZE, 8, EGL_GREEN_SIZE, 8, EGL_BLUE_SIZE, 8, EGL_NONE};
    EGLConfig config = nullptr;
    EGLint count = 0;
    if (!EGLF().ChooseConfig(_display, configAttributes, &config, 1, &count) || count < 1) {
      // The surfaceless platform may offer no pbuffer configs; any OpenGL config will do, with no surface at all.
      const EGLint anyAttributes[] = {EGL_RENDERABLE_TYPE, EGL_OPENGL_BIT, EGL_NONE};
      if (!EGLF().ChooseConfig(_display, anyAttributes, &config, 1, &count) || count < 1) {
        *error = "no EGL config for OpenGL";
        return false;
      }
    } else {
      const EGLint pbuffer[] = {EGL_WIDTH, 1, EGL_HEIGHT, 1, EGL_NONE};
      _surface = EGLF().CreatePbufferSurface(_display, config, pbuffer);
    }
    const EGLint contextAttributes[] = {EGL_CONTEXT_MAJOR_VERSION, 3, EGL_CONTEXT_MINOR_VERSION, 3,
                                        EGL_CONTEXT_OPENGL_PROFILE_MASK, EGL_CONTEXT_OPENGL_CORE_PROFILE_BIT, EGL_NONE};
    _context = EGLF().CreateContext(_display, config, EGL_NO_CONTEXT, contextAttributes);
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
    if (EGLF().GetCurrentContext() == _context) return true;
    return EGLF().MakeCurrent(_display, _surface, _surface, _context) == EGL_TRUE;
  }

  void *proc(const char *name) override { return (void *)EGLF().GetProcAddress(name); }

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
  EGLDisplay display = EGLF().ok ? EGLF().GetCurrentDisplay() : EGL_NO_DISPLAY;
  if (display != EGL_NO_DISPLAY) {
    return EGLF().SwapInterval(display, interval) == EGL_TRUE;
  }
#if defined(COCOATERMINAL_GLX)
  // An NSOpenGLView's GLX context: the EXT interval for its current drawable, else Mesa's.
  const GLXFunctions &glx = TheGLX();
  if (glx.getCurrentContext != nullptr && glx.getCurrentContext() != NULL) {
    typedef void (*SwapIntervalEXT)(Display *, GLXDrawable, int);
    typedef int (*SwapIntervalMESA)(unsigned int);
    auto ext = (SwapIntervalEXT)glx.proc("glXSwapIntervalEXT");
    if (ext != nullptr && glx.getCurrentDisplay != nullptr && glx.getCurrentDrawable != nullptr) {
      ext(glx.getCurrentDisplay(), glx.getCurrentDrawable(), interval);
      return true;
    }
    auto mesa = (SwapIntervalMESA)glx.proc("glXSwapIntervalMESA");
    return mesa != nullptr && interval >= 0 && mesa((unsigned int)interval) == 0;
  }
#endif
  return false;
}

#if defined(COCOATERMINAL_GLX)
// GNUstep's NSOpenGLView on X11 draws with GLX: the view makes its context current before it draws, so the renderer
// uses that one (as on Windows with WGL) and only checks it's still current.
class CurrentGLXContext : public GLContext {
public:
  explicit CurrentGLXContext(GLXContext context) : _context(context) {}
  bool makeCurrent() override { return TheGLX().getCurrentContext() == _context; }
  void *proc(const char *name) override { return TheGLX().proc(name); }
  std::string description() const override { return "GLX (NSOpenGLView)"; }

private:
  GLXContext _context;
};

std::unique_ptr<GLContext> MakeCurrentGLContext(std::string *error) {
  const GLXFunctions &glx = TheGLX();
  if (glx.getCurrentContext == nullptr) {
    *error = "no libGL with GLX";
    return nullptr;
  }
  GLXContext current = glx.getCurrentContext();
  if (current == NULL) {
    *error = "no GLX context is current";
    return nullptr;
  }
  return std::unique_ptr<GLContext>(new CurrentGLXContext(current));
}
#else
std::unique_ptr<GLContext> MakeCurrentGLContext(std::string *error) {
  *error = "built without GLX (pkg-config gl not found), so OpenGL can't draw into an NSOpenGLView";
  return nullptr;
}
#endif

}  // namespace cot

#endif
