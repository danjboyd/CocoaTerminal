// SPDX-License-Identifier: LGPL-2.1-or-later
// Copyright (C) 2026 Daniel Boyd
//
// X11 helpers for COTGLCheck, the counterparts of COTGLCheckWin.cpp: what the screen really shows, X resource counts,
// real mouse clicks and keys, and an off-screen OpenGL renderer (a GLX pbuffer context drawing into a framebuffer
// object, read back). Plain C++ so Xlib stays out of the Objective-C file.
//
// A window here is the X window of a GNUstep window (GSDisplayServer -windowDevice:), and points are in that X
// window's coordinates with a bottom-left origin, as the Win32 helpers take client coordinates. The helpers use the
// backend's own X connection (COTGLX11SetDisplay), so its requests are in order with GNUstep's.
//
// XTest (real input) and X-Resource (resource counts) are loaded at run time, so building needs only libX11 and GL
// headers; without them the input checks fail and the counts read 0.

#if !defined(_WIN32) && !defined(__APPLE__)
#include <X11/Xlib.h>
#include <X11/Xutil.h>
#include <X11/keysym.h>
#include <GL/gl.h>
#include <GL/glx.h>
#include <dlfcn.h>

#include <cstdio>
#include <cstring>

extern "C" {

static Display *gDisplay = NULL;

void COTGLX11SetDisplay(void *display) { gDisplay = (Display *)display; }

static Display *Dpy() {
  if (gDisplay == NULL) gDisplay = XOpenDisplay(NULL);
  return gDisplay;
}

// The point (x, y) in WINDOW, bottom-left origin, in root coordinates. Returns 0 if it isn't inside the window.
static int RootPoint(Window window, double x, double y, int *rx, int *ry) {
  Display *dpy = Dpy();
  XWindowAttributes a;
  Window child;
  if (dpy == NULL || window == None) return 0;
  XSync(dpy, False);
  if (!XGetWindowAttributes(dpy, window, &a)) return 0;
  int wx = (int)x, wy = a.height - (int)y - 1;
  if (wx < 0 || wy < 0 || wx >= a.width || wy >= a.height) return 0;
  return XTranslateCoordinates(dpy, window, DefaultRootWindow(dpy), wx, wy, rx, ry, &child);
}

// The colour the screen shows at a point of the window: read from the root window, so it is what X has composed
// there, child windows (GNUstep's OpenGL views) included. Another window on top would show instead (no compositor
// is assumed: on Xvfb there is none). Returns 0 if it can't be read.
int COTGLScreenPixel(void *window, double x, double y, unsigned char rgb[3]) {
  int rx, ry;
  if (!RootPoint((Window)(uintptr_t)window, x, y, &rx, &ry)) return 0;
  Display *dpy = Dpy();
  XImage *image = XGetImage(dpy, DefaultRootWindow(dpy), rx, ry, 1, 1, AllPlanes, ZPixmap);
  if (image == NULL) return 0;
  unsigned long pixel = XGetPixel(image, 0, 0);
  unsigned long masks[3] = {image->red_mask, image->green_mask, image->blue_mask};
  for (int i = 0; i < 3; i++) {
    unsigned long m = masks[i];
    int s = 0;
    while (m && !(m & 1)) { m >>= 1; s++; }
    rgb[i] = (unsigned char)(((pixel & masks[i]) >> s) * 255 / (m ? m : 1));
  }
  XDestroyImage(image);
  return 1;
}

// Saves the window as the screen shows it to a binary PPM, for looking at a failure.
int COTGLSaveWindow(void *window, const char *path) {
  Display *dpy = Dpy();
  XWindowAttributes a;
  if (dpy == NULL) return 0;
  XSync(dpy, False);
  if (!XGetWindowAttributes(dpy, (Window)(uintptr_t)window, &a)) return 0;
  int rx, ry;
  Window child;
  XTranslateCoordinates(dpy, (Window)(uintptr_t)window, DefaultRootWindow(dpy), 0, 0, &rx, &ry, &child);
  XImage *image = XGetImage(dpy, DefaultRootWindow(dpy), rx, ry, a.width, a.height, AllPlanes, ZPixmap);
  if (image == NULL) return 0;
  FILE *f = fopen(path, "wb");
  if (f) {
    fprintf(f, "P6\n%d %d\n255\n", a.width, a.height);
    for (int y = 0; y < a.height; y++)
      for (int x = 0; x < a.width; x++) {
        unsigned long p = XGetPixel(image, x, y);
        unsigned char c[3] = {(unsigned char)(p >> 16), (unsigned char)(p >> 8), (unsigned char)p};
        fwrite(c, 1, 3, f);
      }
    fclose(f);
  }
  XDestroyImage(image);
  return f != NULL;
}

// Whether the point is really visible on screen: the top-level window under it is this window's.
int COTGLPointVisible(void *window, double x, double y) {
  int rx, ry;
  if (!RootPoint((Window)(uintptr_t)window, x, y, &rx, &ry)) return 0;
  Display *dpy = Dpy();
  Window root = DefaultRootWindow(dpy), under = None, top = (Window)(uintptr_t)window, r, parent, *children;
  unsigned int n;
  int ix, iy;
  XTranslateCoordinates(dpy, root, root, rx, ry, &ix, &iy, &under);
  // The window's top-level ancestor (a window manager may have reparented it).
  while (XQueryTree(dpy, top, &r, &parent, &children, &n)) {
    if (children) XFree(children);
    if (parent == root || parent == None) break;
    top = parent;
  }
  return under == top;
}

// ---- Real input, through XTest.

typedef int (*FakeMotion)(Display *, int, int, int, unsigned long);
typedef int (*FakeButton)(Display *, unsigned int, Bool, unsigned long);
typedef int (*FakeKey)(Display *, unsigned int, Bool, unsigned long);

static void *XTest(const char *name) {
  static void *lib = NULL;
  if (lib == NULL) lib = dlopen("libXtst.so.6", RTLD_LAZY);
  return lib ? dlsym(lib, name) : NULL;
}

// A real left click at a point of the window.
int COTGLClick(void *window, double x, double y) {
  FakeMotion motion = (FakeMotion)XTest("XTestFakeMotionEvent");
  FakeButton button = (FakeButton)XTest("XTestFakeButtonEvent");
  int rx, ry;
  if (!motion || !button || !RootPoint((Window)(uintptr_t)window, x, y, &rx, &ry)) return 0;
  Display *dpy = Dpy();
  motion(dpy, DefaultScreen(dpy), rx, ry, 0);
  button(dpy, 1, True, 0);
  button(dpy, 1, False, 0);
  XFlush(dpy);
  return 1;
}

// A real key press of virtual key VK (a Win32 virtual-key code: 'A'-'Z', '0'-'9'), to whatever window has the focus.
int COTGLKey(void *window, unsigned short vk) {
  (void)window;
  FakeKey key = (FakeKey)XTest("XTestFakeKeyEvent");
  if (!key) return 0;
  Display *dpy = Dpy();
  KeySym sym = (vk >= 'A' && vk <= 'Z') ? (KeySym)(XK_a + (vk - 'A')) : (KeySym)vk;
  KeyCode code = XKeysymToKeycode(dpy, sym);
  if (code == 0) return 0;
  key(dpy, code, True, 0);
  key(dpy, code, False, 0);
  XFlush(dpy);
  return 1;
}

// ---- Resource counts: the X server's for this client (X-Resource), and private memory.

typedef struct { Atom resource_type; unsigned int count; } ResType;
typedef int (*QueryClientResources)(Display *, XID, int *, ResType **);

static double PrivateMB() {
  FILE *f = fopen("/proc/self/smaps_rollup", "r");
  char line[256];
  double kb = 0;
  if (!f) return 0;
  while (fgets(line, sizeof line, f)) {
    unsigned long v;
    if (sscanf(line, "Private_Clean: %lu kB", &v) == 1 || sscanf(line, "Private_Dirty: %lu kB", &v) == 1) kb += v;
  }
  fclose(f);
  return kb / 1024.0;
}

// The Win32 names, X11 meanings: *gdi: the client's pixmaps, GCs, pictures, colormaps and other non-window resources;
// *user: its windows; *handles: all its X resources; *privateMB: private memory (smaps_rollup). OWNER is any XID of the
// client, such as one of its windows.
void COTGLX11Resources(void *owner, unsigned long *gdi, unsigned long *user, unsigned long *handles,
                       double *privateMB) {
  static void *lib = NULL;
  *gdi = *user = *handles = 0;
  *privateMB = PrivateMB();
  if (lib == NULL) lib = dlopen("libXRes.so.1", RTLD_LAZY);
  QueryClientResources query = lib ? (QueryClientResources)dlsym(lib, "XResQueryClientResources") : NULL;
  Display *dpy = Dpy();
  ResType *types = NULL;
  int n = 0;
  if (!query || !dpy) return;
  XSync(dpy, False);
  if (!query(dpy, (XID)(uintptr_t)owner, &n, &types)) return;
  for (int i = 0; i < n; i++) {
    char *name = XGetAtomName(dpy, types[i].resource_type);
    if (name && strcmp(name, "WINDOW") == 0) *user += types[i].count;
    else *gdi += types[i].count;
    *handles += types[i].count;
    if (name) XFree(name);
  }
  XFree(types);
}

// How many child windows the window has: GNUstep's OpenGL views are child windows.
int COTGLChildWindowCount(void *window) {
  Display *dpy = Dpy();
  Window root, parent, *children = NULL;
  unsigned int n = 0;
  if (!dpy) return 0;
  XSync(dpy, False);
  if (!XQueryTree(dpy, (Window)(uintptr_t)window, &root, &parent, &children, &n)) return 0;
  if (children) XFree(children);
  return (int)n;
}

// ---- Off-screen OpenGL: a pbuffer context, drawing into a framebuffer object, read back to memory.

typedef void (*GenFramebuffers)(GLsizei, GLuint *);
typedef void (*BindFramebuffer)(GLenum, GLuint);
typedef void (*FramebufferRenderbuffer)(GLenum, GLenum, GLenum, GLuint);
typedef void (*GenRenderbuffers)(GLsizei, GLuint *);
typedef void (*BindRenderbuffer)(GLenum, GLuint);
typedef void (*RenderbufferStorage)(GLenum, GLenum, GLsizei, GLsizei);
typedef GLenum (*CheckFramebufferStatus)(GLenum);
typedef void (*DeleteFramebuffers)(GLsizei, const GLuint *);

#define COT_GL_FRAMEBUFFER 0x8D40
#define COT_GL_RENDERBUFFER 0x8D41
#define COT_GL_COLOR_ATTACHMENT0 0x8CE0
#define COT_GL_FRAMEBUFFER_COMPLETE 0x8CD5
#define COT_GL_RGBA8 0x8058
#define COT_GL_BGRA 0x80E1

struct COTGLOffscreen {
  GLXPbuffer pbuffer = None;
  GLXContext context = NULL;
  GLuint framebuffer = 0, colour = 0;
  int width = 0, height = 0;
  BindFramebuffer bindFramebuffer = NULL;
  DeleteFramebuffers deleteFramebuffers = NULL;
  DeleteFramebuffers deleteRenderbuffers = NULL;
  char renderer[256] = "";
};

void COTGLOffscreenDestroy(void *handle);

static void *Proc(const char *name) { return (void *)glXGetProcAddress((const GLubyte *)name); }

void *COTGLOffscreenCreate(int width, int height, char *message, int messageLength) {
  COTGLOffscreen *o = nullptr;
  auto fail = [&](const char *what) -> void * {
    snprintf(message, messageLength, "%s%s%s", what, o && o->renderer[0] ? " in " : "", o ? o->renderer : "");
    COTGLOffscreenDestroy(o);
    return NULL;
  };
  Display *dpy = Dpy();
  if (!dpy) return fail("no X display");
  int attributes[] = {GLX_DRAWABLE_TYPE, GLX_PBUFFER_BIT, GLX_RENDER_TYPE, GLX_RGBA_BIT, GLX_RED_SIZE, 8,
                      GLX_GREEN_SIZE, 8, GLX_BLUE_SIZE, 8, None};
  int count = 0;
  GLXFBConfig *configs = glXChooseFBConfig(dpy, DefaultScreen(dpy), attributes, &count);
  if (!configs || count == 0) return fail("no GLX pbuffer configuration");
  o = new COTGLOffscreen;
  int pbufferAttributes[] = {GLX_PBUFFER_WIDTH, 16, GLX_PBUFFER_HEIGHT, 16, None};
  o->pbuffer = glXCreatePbuffer(dpy, configs[0], pbufferAttributes);
  o->context = glXCreateNewContext(dpy, configs[0], GLX_RGBA_TYPE, NULL, True);
  XFree(configs);
  if (!o->pbuffer || !o->context || !glXMakeContextCurrent(dpy, o->pbuffer, o->pbuffer, o->context)) {
    return fail("glXCreateNewContext failed");
  }
  snprintf(o->renderer, sizeof o->renderer, "%s / %s", (const char *)glGetString(GL_RENDERER), (const char *)glGetString(GL_VERSION));
  auto gen = (GenFramebuffers)Proc("glGenFramebuffers");
  o->bindFramebuffer = (BindFramebuffer)Proc("glBindFramebuffer");
  o->deleteFramebuffers = (DeleteFramebuffers)Proc("glDeleteFramebuffers");
  o->deleteRenderbuffers = (DeleteFramebuffers)Proc("glDeleteRenderbuffers");
  auto genRenderbuffers = (GenRenderbuffers)Proc("glGenRenderbuffers");
  auto bindRenderbuffer = (BindRenderbuffer)Proc("glBindRenderbuffer");
  auto renderbufferStorage = (RenderbufferStorage)Proc("glRenderbufferStorage");
  auto framebufferRenderbuffer = (FramebufferRenderbuffer)Proc("glFramebufferRenderbuffer");
  auto check = (CheckFramebufferStatus)Proc("glCheckFramebufferStatus");
  if (!gen || !o->bindFramebuffer || !genRenderbuffers || !bindRenderbuffer || !renderbufferStorage ||
      !framebufferRenderbuffer || !check) {
    return fail("no framebuffer objects");
  }
  gen(1, &o->framebuffer);
  o->bindFramebuffer(COT_GL_FRAMEBUFFER, o->framebuffer);
  genRenderbuffers(1, &o->colour);
  bindRenderbuffer(COT_GL_RENDERBUFFER, o->colour);
  renderbufferStorage(COT_GL_RENDERBUFFER, COT_GL_RGBA8, width, height);
  framebufferRenderbuffer(COT_GL_FRAMEBUFFER, COT_GL_COLOR_ATTACHMENT0, COT_GL_RENDERBUFFER, o->colour);
  if (check(COT_GL_FRAMEBUFFER) != COT_GL_FRAMEBUFFER_COMPLETE) return fail("framebuffer incomplete");
  o->width = width;
  o->height = height;
  snprintf(message, messageLength, "%s", o->renderer);
  return o;
}

// The scene of COTGLCheckWin.cpp's COTGLOffscreenRender, read back as 32-bit BGRA, bottom row first.
void COTGLOffscreenRender(void *handle, float red, float green, float blue, int cells, unsigned char *pixels) {
  COTGLOffscreen *o = (COTGLOffscreen *)handle;
  glXMakeContextCurrent(Dpy(), o->pbuffer, o->pbuffer, o->context);
  o->bindFramebuffer(COT_GL_FRAMEBUFFER, o->framebuffer);
  glViewport(0, 0, o->width, o->height);
  glClearColor(red, green, blue, 1);
  glClear(GL_COLOR_BUFFER_BIT);
  glMatrixMode(GL_PROJECTION);
  glLoadIdentity();
  glOrtho(0, o->width, 0, o->height, -1, 1);
  glMatrixMode(GL_MODELVIEW);
  glLoadIdentity();
  if (cells > 0) {
    int columns = cells, rows = cells * o->height / (o->width ? o->width : 1) + 1;
    float w = (float)o->width / columns, h = (float)o->height / rows;
    glBegin(GL_QUADS);
    for (int r = 0; r < rows; r++)
      for (int c = 0; c < columns; c++) {
        if ((r + c) % 2) continue;
        glColor3f((c % 7) / 7.0f, (r % 5) / 5.0f, 0.5f);
        glVertex2f(c * w, r * h);
        glVertex2f(c * w + w, r * h);
        glVertex2f(c * w + w, r * h + h);
        glVertex2f(c * w, r * h + h);
      }
    glEnd();
  }
  glReadPixels(0, 0, o->width, o->height, COT_GL_BGRA, GL_UNSIGNED_BYTE, pixels);
}

void COTGLOffscreenDestroy(void *handle) {
  COTGLOffscreen *o = (COTGLOffscreen *)handle;
  if (!o) return;
  Display *dpy = Dpy();
  if (o->context && o->pbuffer && glXMakeContextCurrent(dpy, o->pbuffer, o->pbuffer, o->context)) {
    if (o->framebuffer && o->deleteFramebuffers) o->deleteFramebuffers(1, &o->framebuffer);
    if (o->colour && o->deleteRenderbuffers) o->deleteRenderbuffers(1, &o->colour);
  }
  glXMakeContextCurrent(dpy, None, None, NULL);
  if (o->context) glXDestroyContext(dpy, o->context);
  if (o->pbuffer) glXDestroyPbuffer(dpy, o->pbuffer);
  delete o;
}

}  // extern "C"
#endif
