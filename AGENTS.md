# CocoaTerminal Agent Context

## Project Purpose

CocoaTerminal is an embeddable Cocoa/AppKit terminal widget library targeting GNUstep first, using the GNUstep version installed on this machine, while keeping current macOS support. The repository should also include a demo app that consumes the library for testing and can grow into a standalone terminal.

The library should follow the spirit of Alacritty: fast, minimal, practical, and focused on excellent font rendering. It should support the behavior expected from a modern terminal emulator, including PTY-backed shells, ANSI/VT handling, scrollback, alternate screen, keyboard and mouse input, paste behavior, resize propagation, and host application embedding.

## Current Local Toolchain

- GNUstep GUI: 0.32.0
- GNUstep Base: 1.31.1
- `gnustep-config`: `/usr/GNUstep/System/Tools/gnustep-config`
- CMake: available
- Ninja: available
- Clang: available

`gnustep-config` may not be on `PATH`; prefer pkg-config or the explicit path above.

## Architecture Direction

- Build system: CMake.
- Language split:
  - Objective-C++ for AppKit/GNUstep integration.
  - C++ for the terminal state/core where that keeps parsing/rendering logic portable.
- Dependency policy:
  - Prefer system libraries.
  - Allow optional vendoring for small terminal-core dependencies, especially a VT parser, if a system package is unavailable.
- Platform priority:
  - Implement Unix/macOS PTY support first.
  - Include a Windows/GNUstep process adapter interface and ConPTY placeholder, but do not block the first milestone on Windows implementation.

## Public Surface Goals

- `COTTerminalView`: embeddable `NSView` subclass.
- `COTTerminalSession`: shell/process lifecycle and terminal state owner.
- `COTTerminalConfiguration`: font, colors, scrollback, shell command, environment, and keyboard capture policy.
- `COTTerminalDelegate`: process exit, title changes, bell, and host integration events.

When focused, the terminal view should capture terminal-relevant keyboard shortcuts by default instead of passing them through to the host GUI. Hosts should be able to configure or override this.

## Git/GitHub Notes

Project-local Git identity should be:

- Daniel Boyd <danieljboyd@icloud.com>

GitHub operations should use:

- danjboyd

Detailed local account notes belong in `.codex-local.md`, which is intentionally gitignored.

