# CocoaTerminal

CocoaTerminal is an embeddable Cocoa/AppKit terminal view for GNUstep and macOS. The project is intentionally small at the UI boundary and keeps terminal state in a portable core so the widget can be used by other applications as a library.

It runs on GNUstep/Linux and macOS with a Unix PTY-backed shell, and on GNUstep/Windows (MSYS2) with a ConPTY-backed one.

## Build

```sh
cmake -S . -B build -G Ninja
cmake --build build
ctest --test-dir build
```

On this machine, GNUstep is installed under `/usr/GNUstep` and `gnustep-config` is available at `/usr/GNUstep/System/Tools/gnustep-config`.

### Windows (MSYS2 CLANG64)

Needs Windows 10 1809 or later (ConPTY) and MSYS2's CLANG64 GNUstep packages:

```sh
pacman -S --needed mingw-w64-clang-x86_64-{gnustep-base,gnustep-gui,gnustep-back,libvterm,cmake,ninja}
cmake -S . -B build-win -G Ninja \
  -DCMAKE_C_COMPILER=clang -DCMAKE_CXX_COMPILER=clang++ \
  -DCMAKE_OBJC_COMPILER=clang -DCMAKE_OBJCXX_COMPILER=clang++
cmake --build build-win
ctest --test-dir build-win
```

Run from a CLANG64 shell, or put `C:\msys64\clang64\bin` on `PATH` for the DLLs. The shell is `$SHELL` when that's a
Windows path, else `powershell.exe`; set `[shell] program` in the config for another (`cmd.exe`, `pwsh.exe`,
`C:\msys64\usr\bin\bash.exe`, `wsl.exe`).

Differences from Linux worth knowing:

- The session's output arrives from a reader thread; `-poll` does nothing.
- An exit status is the process's exit code, not a `waitpid` status.
- GNUstep's Windows build doesn't drain the main dispatch queue on its own, so the library hooks it into the main run
  loop when the first session is created.
- Windows' built-in ConPTY forwards a mouse-mode request (`CSI ? 1000 h` and friends) only from a program that reads
  VT input (tmux, vim, MSYS2's shells, ssh, WSL); from others it's dropped. It also drops a clipboard query (OSC 52
  `?`), and an OSC 52 write from PowerShell.
- Ship Microsoft's own ConPTY beside the program to avoid that: `conpty.dll` and `OpenConsole.exe` from the
  `Microsoft.Windows.Console.ConPTY` NuGet package (MIT; tested with 1.25.261109001), as Windows Terminal does. When
  `conpty.dll` sits next to the executable it's used instead of the built-in functions; it passes every sequence
  through as the program wrote it. `COCOATERMINAL_CONPTY=system` forces the built-in one, or set it to a
  `conpty.dll`'s full path.
- `COCOATERMINAL_RENDERER=gl` draws with OpenGL instead of Cairo (experimental). It needs OpenGL 3.3 with framebuffer
  objects; without that (Windows' own software OpenGL is 1.1) the view draws with Cairo and says why on stderr. Glyphs
  come from DirectWrite (ClearType, or `COCOATERMINAL_GL_ANTIALIAS=grayscale`), or FreeType with
  `COCOATERMINAL_GL_GLYPHS=freetype`; colour emoji included. Box drawing and block elements are drawn as exact
  rectangles so they join. Built on Windows by default (CMake `COCOATERMINAL_GL_RENDERER`); on Linux it's off until
  its EGL context has been tried there, and needs `egl`, `freetype2` and `fontconfig`. To try it on a machine with no
  OpenGL 3.3, put Mesa's `opengl32.dll` (with `libgallium_wgl.dll` and its LLVM) beside the program and set
  `GALLIUM_DRIVER=llvmpipe`. The frame is rendered off
  screen and drawn as an image: GNUstep's `NSOpenGLView` is a child window on Windows that ignores hiding, clipping and
  views drawn over it (`bench/COTGLCheck.mm`). `COCOATERMINAL_GL_CONTRAST` and `COCOATERMINAL_GL_GAMMA` tune text
  weight; `COCOATERMINAL_PERF_LOG=1` prints per-frame timings.
- MSYS2's own programs (`cat`, `sh`) write to a console slowly (about 0.2 MB/s here, against about 2 MB/s for `type`
  in `cmd.exe`): that's the Cygwin console layer, whichever ConPTY is used.
- MSYS2's `gnustep-gui.pc` omits `-lgnustep-gui`; the CMake build adds it.

## Demo Configuration

`CocoaTerminalDemo` reads an optional TOML config file using Alacritty's
schema for the keys we support. Search order:

1. `$COCOATERMINAL_CONFIG` if set
2. `$XDG_CONFIG_HOME/cocoaterminal/config.toml` (or `~/.config/cocoaterminal/config.toml`)
3. `~/.config/alacritty/alacritty.toml` (fallback — your existing Alacritty file works)

Supported keys:

```toml
[font]
size = 13.0
normal.family = "Intel One Mono"

[shell]
program = "/usr/bin/tmux"
args = []

[colors.primary]
foreground = "#e6e1dc"
background = "#181818"

[colors.cursor]
cursor = "#79c7c5"

[window]
opacity = 1.0

[scrolling]
history = 10000
```

`terminal.shell.program` / `terminal.shell.args` (newer Alacritty schema)
are also accepted. Unknown keys are ignored. See
[`demo/config.example.toml`](demo/config.example.toml) for an annotated
starter file.

## Demo Test Harness

The demo app can test the library through the full GUI path and write its own screenshots.

```sh
./scripts/selftest-demo.sh
./scripts/test-demo-scenarios.sh
```

`selftest-demo.sh` is the fast smoke check. `test-demo-scenarios.sh` runs a broader matrix covering filled block cursor rendering, Ctrl zoom shortcuts, demo exit behavior, PTY environment defaults, delete/editing behavior, mouse no-leak behavior, color, Unicode, scrollback, alternate screen, keyboard, mouse reporting and drag delivery, tmux, readline, Vim, and fullscreen resize scenarios. Each scenario must pass and writes capability/observation fields into its state file.

Scenario artifacts are written to `/tmp/coterminal-scenarios` by default. Each scenario writes a PNG screenshot and a text state report.

The runner takes `COCOATERMINAL_BUILD_DIR`, `COCOATERMINAL_SKIP_BUILD=1` (use an existing build),
`COCOATERMINAL_SCENARIOS` (a space-separated subset) and `COCOATERMINAL_SCENARIO_DIR`. On Windows, run it from MSYS2's
bash with `MSYSTEM=CLANG64`: the scenarios' scripts run in MSYS2's `sh` on ConPTY (tmux, vim and python3 come from MSYS2),
or in `$COCOATERMINAL_SCENARIO_SHELL`. A scenario's deadline is 5 seconds (20 on Windows, where a login shell is slow to
start), or `$COCOATERMINAL_SCENARIO_TIMEOUT`.

## Layout

- `include/CocoaTerminal/`: public library headers.
- `src/`: library implementation.
- `demo/`: demo executable consuming the library.
- `tests/`: focused core and API tests.

## License

CocoaTerminal is distributed under the **GNU Lesser General Public License,
version 2.1 or later** (`LGPL-2.1-or-later`), matching GNUstep's library
license. See [`COPYING.LESSER`](COPYING.LESSER) for the full text.

CocoaTerminal links to [libvterm](https://www.leonerd.org.uk/code/libvterm/)
(MIT licensed) at runtime via the system `libvterm0` package. MIT is
compatible with LGPL: there is no need to relicense, and host applications
that link CocoaTerminal can choose their own license, subject to LGPL's
requirements (e.g. dynamic linking, ability to relink).
