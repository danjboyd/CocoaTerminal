# Observe input policy and fixed grid

A host can show a terminal read only: output it receives from elsewhere, drawn in a `COTTerminalView`, with nothing able to go back.

## Configuration
- **Defaults are unchanged:** Interactive input, FollowView sizing, 80 columns by 24 rows.
- **Choosing a read-only view:** a host must explicitly set `inputPolicy = COTTerminalInputPolicyObserve` and `sizingPolicy = COTTerminalSizingPolicyFixedGrid`, and supply known dimensions. If the source's real size is unknown, the host should say so rather than fall back to these defaults.
- **Rejected at construction:**
  - a nil configuration;
  - unknown input or sizing policies;
  - dimensions outside 1...1000.
- **Frozen for the session's lifetime:** the policies and the size. Mutating or copying the configuration later can't promote a session to interactive or resize a fixed grid. A different authority needs a separate session.

## What Observe denies
- **Input:** both public input and the parser's replies (for example, answers to device queries) are refused before they reach the transport.
- **Clipboard:** protocol reads and writes (OSC 52) and local copy and paste are refused before the pasteboard is touched. A host using this minimal mode should label copy and paste as unavailable.
- **What stays:** selection and scrolling, which are local.

## Fixed grid
Resize calls are deliberate no-ops. The parser and PTY dimensions don't change with viewport or zoom changes, and the view's bounds never determine the grid.

## Output-only ingestion
`-ingestOutputData:` accepts data only for an Observe session. It parses on the terminal queue and publishes snapshots, so a host can show output without spawning a child.

It doesn't create a transport or authenticate a source. Observe also doesn't make an arbitrary started process safe to watch: a command's own effects are the host's responsibility.

## Tests
- **`CocoaTerminalObserverTests`:**
  - **Transport:** a disposable PTY pair is injected without a child. Parser queries, OSC 52 and input produce zero bytes on the slave side and zero pasteboard accesses. A private pasteboard spy keeps the test away from the real clipboard.
  - **Validation:** invalid configurations, policies and dimensions; configuration mutation and copy; parser and kernel PTY dimensions.
- **`--gui` mode** (needs a disposable X display): selection, copy and paste actions, key shortcuts, mouse reports, focus, non-square bounds and zoom.
- **`CocoaTerminalThemeTests`:** now checks each platform's own default font.

## Not covered here
Partial-write buffering, child reaping and termination, session recovery, and the Windows ConPTY prerequisites. Interactive embedding needs its own review and tests for those.
