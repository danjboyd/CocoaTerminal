// SPDX-License-Identifier: LGPL-2.1-or-later
// Copyright (C) 2026 Daniel Boyd
//
// Win32 helpers for COTGLCheck: what the screen really shows, handle counts, real mouse clicks, and an off-screen
// OpenGL renderer (its own hidden window and context, drawing into a framebuffer object and read back). Plain C so
// <windows.h> stays out of the Objective-C file.

#if defined(_WIN32)
#define WIN32_LEAN_AND_MEAN
#include <windows.h>
#include <psapi.h>
#include <GL/gl.h>

#include <cstdio>
#include <cstring>
#include <vector>

extern "C" {

// The colour the screen shows at a point given in the window's client coordinates, bottom-left origin (GNUstep's
// window base coordinates). Returns 0 if it can't be read.
//
// It reads the window as the compositor has it (PrintWindow with PW_RENDERFULLCONTENT: the window and its child
// windows, as they'd appear if nothing covered them), so another window on top doesn't spoil the check.
int COTGLScreenPixel(void *window, double x, double y, unsigned char rgb[3]) {
  HWND hwnd = (HWND)window;
  RECT client, frame;
  if (!GetClientRect(hwnd, &client) || !GetWindowRect(hwnd, &frame)) return 0;
  POINT p = {(LONG)x, (LONG)((client.bottom - client.top) - y - 1)};
  if (!ClientToScreen(hwnd, &p)) return 0;
  int width = frame.right - frame.left, height = frame.bottom - frame.top;
  int px = p.x - frame.left, py = p.y - frame.top;
  if (px < 0 || py < 0 || px >= width || py >= height) return 0;
  HDC screen = GetDC(NULL);
  HDC memory = CreateCompatibleDC(screen);
  HBITMAP bitmap = CreateCompatibleBitmap(screen, width, height);
  HGDIOBJ old = SelectObject(memory, bitmap);
  BOOL printed = PrintWindow(hwnd, memory, 2 /* PW_RENDERFULLCONTENT */);
  COLORREF c = printed ? GetPixel(memory, px, py) : CLR_INVALID;
  SelectObject(memory, old);
  DeleteObject(bitmap);
  DeleteDC(memory);
  ReleaseDC(NULL, screen);
  if (c == CLR_INVALID) return 0;
  rgb[0] = GetRValue(c);
  rgb[1] = GetGValue(c);
  rgb[2] = GetBValue(c);
  return 1;
}

// Saves the window as the compositor has it (see COTGLScreenPixel) to a 24-bit BMP, for looking at a failure.
int COTGLSaveWindow(void *window, const char *path) {
  HWND hwnd = (HWND)window;
  RECT frame;
  if (!GetWindowRect(hwnd, &frame)) return 0;
  int width = frame.right - frame.left, height = frame.bottom - frame.top;
  HDC screen = GetDC(NULL);
  HDC memory = CreateCompatibleDC(screen);
  BITMAPINFO info = {};
  info.bmiHeader.biSize = sizeof info.bmiHeader;
  info.bmiHeader.biWidth = width;
  info.bmiHeader.biHeight = height;
  info.bmiHeader.biPlanes = 1;
  info.bmiHeader.biBitCount = 24;
  HBITMAP bitmap = CreateCompatibleBitmap(screen, width, height);
  HGDIOBJ old = SelectObject(memory, bitmap);
  PrintWindow(hwnd, memory, 2);
  SelectObject(memory, old);
  int stride = (width * 3 + 3) & ~3;
  std::vector<unsigned char> pixels((size_t)stride * height);
  GetDIBits(memory, bitmap, 0, height, pixels.data(), &info, DIB_RGB_COLORS);
  void *bits = pixels.data();
  old = SelectObject(memory, bitmap);
  BITMAPFILEHEADER file = {};
  file.bfType = 0x4D42;
  file.bfOffBits = sizeof file + sizeof info.bmiHeader;
  file.bfSize = file.bfOffBits + stride * height;
  FILE *f = fopen(path, "wb");
  if (f) {
    fwrite(&file, sizeof file, 1, f);
    fwrite(&info.bmiHeader, sizeof info.bmiHeader, 1, f);
    fwrite(bits, (size_t)stride * height, 1, f);
    fclose(f);
  }
  SelectObject(memory, old);
  DeleteObject(bitmap);
  DeleteDC(memory);
  ReleaseDC(NULL, screen);
  return f != NULL;
}

// Whether the point (client coordinates, bottom-left origin) is really visible on screen: the window under it is
// this one or a child of it. Real clicks and keys only make sense then.
int COTGLPointVisible(void *window, double x, double y) {
  HWND hwnd = (HWND)window;
  RECT client;
  if (!GetClientRect(hwnd, &client)) return 0;
  POINT p = {(LONG)x, (LONG)((client.bottom - client.top) - y - 1)};
  ClientToScreen(hwnd, &p);
  HWND under = WindowFromPoint(p);
  return under == hwnd || IsChild(hwnd, under);
}

// A real left click (SendInput) at a point in the window's client coordinates, bottom-left origin.
int COTGLClick(void *window, double x, double y) {
  HWND hwnd = (HWND)window;
  RECT client;
  if (!GetClientRect(hwnd, &client)) return 0;
  POINT p = {(LONG)x, (LONG)((client.bottom - client.top) - y - 1)};
  ClientToScreen(hwnd, &p);
  SetForegroundWindow(hwnd);
  SetCursorPos(p.x, p.y);
  INPUT in[2] = {};
  in[0].type = INPUT_MOUSE;
  in[0].mi.dwFlags = MOUSEEVENTF_LEFTDOWN;
  in[1].type = INPUT_MOUSE;
  in[1].mi.dwFlags = MOUSEEVENTF_LEFTUP;
  return SendInput(2, in, sizeof(INPUT)) == 2;
}

// A real key press (SendInput) of virtual key vk, to whatever window has the focus.
int COTGLKey(void *window, unsigned short vk) {
  SetForegroundWindow((HWND)window);
  INPUT in[2] = {};
  in[0].type = INPUT_KEYBOARD;
  in[0].ki.wVk = vk;
  in[1].type = INPUT_KEYBOARD;
  in[1].ki.wVk = vk;
  in[1].ki.dwFlags = KEYEVENTF_KEYUP;
  return SendInput(2, in, sizeof(INPUT)) == 2;
}

void COTGLResources(unsigned long *gdi, unsigned long *user, unsigned long *handles, double *privateMB) {
  HANDLE self = GetCurrentProcess();
  *gdi = GetGuiResources(self, GR_GDIOBJECTS);
  *user = GetGuiResources(self, GR_USEROBJECTS);
  DWORD count = 0;
  GetProcessHandleCount(self, &count);
  *handles = count;
  PROCESS_MEMORY_COUNTERS_EX counters = {};
  counters.cb = sizeof counters;
  GetProcessMemoryInfo(self, reinterpret_cast<PROCESS_MEMORY_COUNTERS *>(&counters), sizeof counters);
  *privateMB = counters.PrivateUsage / 1048576.0;
}

// How many child windows the window has: GNUstep's OpenGL views are child windows.
static BOOL CALLBACK CountChild(HWND, LPARAM count) {
  ++*(int *)count;
  return TRUE;
}
int COTGLChildWindowCount(void *window) {
  int count = 0;
  EnumChildWindows((HWND)window, CountChild, (LPARAM)&count);
  return count;
}

// ---- Off-screen OpenGL: a hidden window's context, drawing into a framebuffer object, read back to memory.

typedef void(APIENTRY *GenFramebuffers)(GLsizei, GLuint *);
typedef void(APIENTRY *BindFramebuffer)(GLenum, GLuint);
typedef void(APIENTRY *FramebufferRenderbuffer)(GLenum, GLenum, GLenum, GLuint);
typedef void(APIENTRY *GenRenderbuffers)(GLsizei, GLuint *);
typedef void(APIENTRY *BindRenderbuffer)(GLenum, GLuint);
typedef void(APIENTRY *RenderbufferStorage)(GLenum, GLenum, GLsizei, GLsizei);
typedef GLenum(APIENTRY *CheckFramebufferStatus)(GLenum);

#define COT_GL_FRAMEBUFFER 0x8D40
#define COT_GL_RENDERBUFFER 0x8D41
#define COT_GL_COLOR_ATTACHMENT0 0x8CE0
#define COT_GL_FRAMEBUFFER_COMPLETE 0x8CD5
#define COT_GL_RGBA8 0x8058
#define COT_GL_BGRA 0x80E1

struct COTGLOffscreen {
  HWND hwnd = NULL;
  HDC dc = NULL;
  HGLRC context = NULL;
  GLuint framebuffer = 0, colour = 0;
  int width = 0, height = 0;
  BindFramebuffer bindFramebuffer = NULL;
  GenRenderbuffers genRenderbuffers = NULL;
  BindRenderbuffer bindRenderbuffer = NULL;
  RenderbufferStorage renderbufferStorage = NULL;
  FramebufferRenderbuffer framebufferRenderbuffer = NULL;
  char renderer[256] = "";
};

void COTGLOffscreenDestroy(void *handle);

void *COTGLOffscreenCreate(int width, int height, char *message, int messageLength) {
  COTGLOffscreen *o = nullptr;
  auto fail = [&](const char *what) -> void * {
    snprintf(message, messageLength, "%s%s%s", what, o && o->renderer[0] ? " in " : "", o ? o->renderer : "");
    COTGLOffscreenDestroy(o);
    return NULL;
  };
  WNDCLASSA wc = {};
  wc.lpfnWndProc = DefWindowProcA;
  wc.hInstance = GetModuleHandleA(NULL);
  wc.lpszClassName = "COTGLOffscreen";
  RegisterClassA(&wc);
  o = new COTGLOffscreen;
  o->hwnd = CreateWindowA("COTGLOffscreen", "", WS_POPUP, 0, 0, 16, 16, NULL, NULL, wc.hInstance, NULL);
  if (!o->hwnd) return fail("CreateWindow failed");
  o->dc = GetDC(o->hwnd);
  PIXELFORMATDESCRIPTOR pfd = {sizeof pfd, 1, PFD_DRAW_TO_WINDOW | PFD_SUPPORT_OPENGL | PFD_DOUBLEBUFFER, PFD_TYPE_RGBA, 32};
  SetPixelFormat(o->dc, ChoosePixelFormat(o->dc, &pfd), &pfd);
  o->context = wglCreateContext(o->dc);
  if (!o->context || !wglMakeCurrent(o->dc, o->context)) return fail("wglCreateContext failed");
  snprintf(o->renderer, sizeof o->renderer, "%s / %s", (const char *)glGetString(GL_RENDERER), (const char *)glGetString(GL_VERSION));
  auto gen = (GenFramebuffers)wglGetProcAddress("glGenFramebuffers");
  o->bindFramebuffer = (BindFramebuffer)wglGetProcAddress("glBindFramebuffer");
  o->genRenderbuffers = (GenRenderbuffers)wglGetProcAddress("glGenRenderbuffers");
  o->bindRenderbuffer = (BindRenderbuffer)wglGetProcAddress("glBindRenderbuffer");
  o->renderbufferStorage = (RenderbufferStorage)wglGetProcAddress("glRenderbufferStorage");
  o->framebufferRenderbuffer = (FramebufferRenderbuffer)wglGetProcAddress("glFramebufferRenderbuffer");
  auto check = (CheckFramebufferStatus)wglGetProcAddress("glCheckFramebufferStatus");
  if (!gen || !o->bindFramebuffer || !o->genRenderbuffers || !o->renderbufferStorage || !check) {
    return fail("no framebuffer objects");
  }
  gen(1, &o->framebuffer);
  o->bindFramebuffer(COT_GL_FRAMEBUFFER, o->framebuffer);
  o->genRenderbuffers(1, &o->colour);
  o->bindRenderbuffer(COT_GL_RENDERBUFFER, o->colour);
  o->renderbufferStorage(COT_GL_RENDERBUFFER, COT_GL_RGBA8, width, height);
  o->framebufferRenderbuffer(COT_GL_FRAMEBUFFER, COT_GL_COLOR_ATTACHMENT0, COT_GL_RENDERBUFFER, o->colour);
  if (check(COT_GL_FRAMEBUFFER) != COT_GL_FRAMEBUFFER_COMPLETE) return fail("framebuffer incomplete");
  o->width = width;
  o->height = height;
  snprintf(message, messageLength, "%s", o->renderer);
  return o;
}

// Draws a test scene (clear colour plus a grid of coloured quads, like a terminal's cells) into the framebuffer and
// reads it back as 32-bit BGRA, bottom row first, into pixels (width * height * 4 bytes).
void COTGLOffscreenRender(void *handle, float red, float green, float blue, int cells, unsigned char *pixels) {
  COTGLOffscreen *o = (COTGLOffscreen *)handle;
  wglMakeCurrent(o->dc, o->context);
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
  wglMakeCurrent(NULL, NULL);
  if (o->context) wglDeleteContext(o->context);
  if (o->dc) ReleaseDC(o->hwnd, o->dc);
  if (o->hwnd) DestroyWindow(o->hwnd);
  delete o;
}

}  // extern "C"
#endif
