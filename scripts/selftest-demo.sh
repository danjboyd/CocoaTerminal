#!/usr/bin/env sh
# SPDX-License-Identifier: LGPL-2.1-or-later
# Copyright (C) 2026 Daniel Boyd
set -eu

repo_dir=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
build_dir="$repo_dir/build"
screenshot_path="${COCOATERMINAL_SELFTEST_SCREENSHOT:-/tmp/coterminal-selftest.png}"
state_path="${COCOATERMINAL_SELFTEST_STATE:-/tmp/coterminal-selftest.txt}"

cmake -S "$repo_dir" -B "$build_dir" -G Ninja
cmake --build "$build_dir"
ctest --test-dir "$build_dir" --output-on-failure

rm -f "$screenshot_path" "$state_path"
"$build_dir/CocoaTerminalDemo" \
  --self-test \
  --scenario smoke \
  --screenshot "$screenshot_path" \
  --state "$state_path" \
  --exit-after-capture

test -s "$screenshot_path"
test -s "$state_path"
grep -q 'success=true' "$state_path"
grep -q 'scenario=smoke' "$state_path"
grep -q 'COT_SCENARIO_DONE:smoke' "$state_path"
grep -q 'theme_name=Alacritty Inspired Dark' "$state_path"
grep -q 'background_color=#181818' "$state_path"
grep -q 'foreground_color=#E6E1DC' "$state_path"

printf 'screenshot=%s\nstate=%s\n' "$screenshot_path" "$state_path"
