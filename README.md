# CocoaTerminal

CocoaTerminal is an embeddable Cocoa/AppKit terminal view for GNUstep and macOS. The project is intentionally small at the UI boundary and keeps terminal state in a portable core so the widget can be used by other applications as a library.

The first milestone targets GNUstep/Linux and macOS with a Unix PTY-backed shell, a minimal terminal grid, and a demo app. Windows/GNUstep support is represented by the process/session abstraction and will use ConPTY in a later milestone.

## Build

```sh
cmake -S . -B build -G Ninja
cmake --build build
ctest --test-dir build
```

On this machine, GNUstep is installed under `/usr/GNUstep` and `gnustep-config` is available at `/usr/GNUstep/System/Tools/gnustep-config`.

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
