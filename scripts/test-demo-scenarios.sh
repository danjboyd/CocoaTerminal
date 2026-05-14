#!/usr/bin/env sh
# SPDX-License-Identifier: LGPL-2.1-or-later
# Copyright (C) 2026 Daniel Boyd
set -eu

repo_dir=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
build_dir="$repo_dir/build"
artifact_dir="${COCOATERMINAL_SCENARIO_DIR:-/tmp/coterminal-scenarios}"

required_scenarios="smoke cursor cursor-block zoom-shortcuts exit-closes-demo terminal-env delete-editing mouse-no-leak ansi-colors unicode-width scrollback alternate-screen keyboard-input mouse-reporting tmux-mouse-resize tmux readline-editing fullscreen-app-baseline line-drawing-inverse vim resize resize-fullscreen-app ctrl-letter-bytes cmd-letter-bytes-gnustep tmux-ctrl-a-split"

cmake -S "$repo_dir" -B "$build_dir" -G Ninja
cmake --build "$build_dir"
ctest --test-dir "$build_dir" --output-on-failure

rm -rf "$artifact_dir"
mkdir -p "$artifact_dir"

run_scenario() {
  scenario="$1"
  expected="$2"
  screenshot_path="$artifact_dir/$scenario.png"
  state_path="$artifact_dir/$scenario.txt"

  "$build_dir/CocoaTerminalDemo" \
    --self-test \
    --scenario "$scenario" \
    --screenshot "$screenshot_path" \
    --state "$state_path" \
    --exit-after-capture

  test -s "$screenshot_path"
  test -s "$state_path"
  grep -q "success=true" "$state_path"
  grep -q "scenario=$scenario" "$state_path"
  grep -q "COT_SCENARIO_DONE:$scenario" "$state_path"
  grep -q "scenario_expected_status=$expected" "$state_path"
  grep -q "capability_color_spans=true" "$state_path"
  grep -q "capability_unicode_width=true" "$state_path"
  grep -q "capability_scrollback=true" "$state_path"
  grep -q "capability_alternate_screen=true" "$state_path"
  grep -q "capability_keyboard_injection=true" "$state_path"
  grep -q "capability_mouse_reporting=true" "$state_path"
  grep -q "capability_runtime_resize=true" "$state_path"

  case "$scenario" in
    ansi-colors)
      grep -q "observed_color_spans=true" "$state_path"
      ;;
    unicode-width)
      grep -q "observed_unicode=true" "$state_path"
      ;;
    scrollback)
      if ! awk -F= '/^observed_scrollback_lines=/ { exit !($2 > 0) }' "$state_path"; then
        printf 'FAIL  %s expected observed scrollback lines\n' "$scenario"
        exit 1
      fi
      ;;
    alternate-screen)
      grep -q "observed_alternate_screen=true" "$state_path"
      ;;
    cursor)
      grep -q "cursor_visible=true" "$state_path"
      ;;
    cursor-block)
      grep -q "cursor_visible=true" "$state_path"
      grep -q "cursor_visible_by_escape=true" "$state_path"
      grep -q "cursor_style=block" "$state_path"
      ;;
    zoom-shortcuts)
      awk -F= '
        /^zoom_baseline_size=/ { baseline=$2 }
        /^zoom_after_in=/ { zin=$2 }
        /^zoom_after_out=/ { zout=$2 }
        /^zoom_after_reset=/ { reset=$2 }
        END { exit !(zin > baseline && zout > baseline && reset == baseline) }
      ' "$state_path"
      grep -q "last_input_actions=sendShortcut ctrl+=|sendShortcut ctrl++|sendShortcut ctrl+-|sendShortcut ctrl+0" "$state_path"
      ;;
    exit-closes-demo)
      grep -q "running=false" "$state_path"
      ;;
    terminal-env)
      grep -q "term_value=xterm-256color" "$state_path"
      grep -q "colorterm_value=truecolor" "$state_path"
      ;;
    delete-editing)
      grep -q "delete_edit_result=ab" "$state_path"
      ;;
    mouse-no-leak)
      grep -q "mouse_reports_suppressed=true" "$state_path"
      grep -q "mouse_reports_suppressed_count=2" "$state_path"
      if grep -q '64;72;16M64;72;16M' "$state_path"; then
        printf 'FAIL  %s leaked mouse escape text\n' "$scenario"
        exit 1
      fi
      ;;
    mouse-reporting)
      grep -q "observed_mouse_reporting=true" "$state_path"
      grep -q "observed_mouse_button_motion=true" "$state_path"
      grep -q "observed_sgr_mouse=true" "$state_path"
      grep -q "mouse_reports_sent=4" "$state_path"
      ;;
    tmux-mouse-resize)
      grep -q "observed_mouse_reporting=true" "$state_path"
      grep -q "observed_mouse_button_motion=true" "$state_path"
      grep -q "observed_sgr_mouse=true" "$state_path"
      grep -q "mouse_reports_sent=3" "$state_path"
      ;;
    tmux)
      if grep -q "COT_SCENARIO_SKIP:tmux" "$state_path"; then
        printf 'SKIP  %s missing tmux\n' "$scenario"
        return
      fi
      grep -q "observed_alternate_screen=true" "$state_path"
      ;;
    readline-editing)
      grep -q "readline_result=abXc" "$state_path"
      ;;
    fullscreen-app-baseline)
      grep -q "observed_alternate_screen=true" "$state_path"
      grep -q "cursor_visible_by_escape=true" "$state_path"
      ;;
    line-drawing-inverse)
      grep -q "┌───┐" "$state_path"
      grep -q "│ hi │" "$state_path"
      grep -q "└───┘" "$state_path"
      grep -q "inverse-status" "$state_path"
      ;;
    resize-fullscreen-app)
      grep -q "observed_alternate_screen=true" "$state_path"
      awk -F= '
        /^resize_before_columns=/ { bc=$2 }
        /^resize_before_rows=/ { br=$2 }
        /^resize_after_columns=/ { ac=$2 }
        /^resize_after_rows=/ { ar=$2 }
        END { exit !(ac > bc && ar > br) }
      ' "$state_path"
      ;;
    ctrl-letter-bytes)
      grep -q "BYTES=01 03" "$state_path"
      grep -q "last_input_actions=sendCtrlKey a|sendCtrlKey c" "$state_path"
      ;;
    cmd-letter-bytes-gnustep)
      grep -q "BYTES=01 03" "$state_path"
      grep -q "last_input_actions=dispatchCmdKey a|dispatchCmdKey c" "$state_path"
      ;;
    tmux-ctrl-a-split)
      if grep -q "COT_SCENARIO_SKIP:tmux-ctrl-a-split" "$state_path"; then
        printf 'SKIP  %s missing tmux\n' "$scenario"
        return
      fi
      grep -q "MARKER=SPLIT_OK" "$state_path"
      ;;
  esac

  if [ "$expected" = "pass" ]; then
    printf 'PASS  %s screenshot=%s state=%s\n' "$scenario" "$screenshot_path" "$state_path"
  else
    printf 'XFAIL %s screenshot=%s state=%s\n' "$scenario" "$screenshot_path" "$state_path"
    sed -n 's/^scenario_expected_reason=/      reason=/p' "$state_path"
  fi
}

for scenario in $required_scenarios; do
  run_scenario "$scenario" pass
done

printf 'artifacts=%s\n' "$artifact_dir"
