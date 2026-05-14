#!/usr/bin/env sh
# SPDX-License-Identifier: LGPL-2.1-or-later
# Copyright (C) 2026 Daniel Boyd
set -eu

repo_dir=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
artifact_dir="${COCOATERMINAL_SCENARIO_DIR:-/tmp/coterminal-scenarios}"

"$repo_dir/scripts/test-demo-scenarios.sh"

printf '\nVisual review checklist:\n'
for scenario in smoke cursor cursor-block zoom-shortcuts exit-closes-demo terminal-env delete-editing mouse-no-leak ansi-colors unicode-width scrollback alternate-screen keyboard-input mouse-reporting tmux-mouse-resize tmux readline-editing fullscreen-app-baseline line-drawing-inverse vim resize resize-fullscreen-app; do
  printf '- %s: %s/%s.png\n' "$scenario" "$artifact_dir" "$scenario"
done
printf '\nExpected visual baseline: dark background, readable Intel One Mono text, no blank captures.\n'
printf 'Each state file records scenario capability and observation fields for review.\n'
