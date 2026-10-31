#!/bin/zsh
# Builds and runs the unit tests: app/src (minus main.swift, whose top-level code is the
# app's own entry point) compiled together with app/tests into one binary.
#   usage: ./test.sh [--coverage] [suite-name-filter]
#
# Plain swiftc, for the same reason build.sh uses it: SwiftPM's test support doesn't work on
# this toolchain (the swift-testing macro plugin can't be resolved, and
# `swift test --enable-code-coverage` fails outright). app/tests/Harness.swift is the harness.
#
# --coverage re-compiles with instrumentation and prints an llvm-cov report. The report
# covers the files compiled into the test binary, so main.swift never appears in it.
set -euo pipefail
# zsh treats a glob that matches nothing as an error; the profraw cleanup below relies on it
# simply expanding to nothing on the first run.
setopt null_glob
here="${0:a:h}"
build="$here/build/tests"
bin="$build/NovieTests"

coverage=0
filter=()
for argument in "$@"; do
  case "$argument" in
    --coverage) coverage=1 ;;
    -*) echo "unknown option: $argument (usage: ./test.sh [--coverage] [filter])"; exit 1 ;;
    *) filter+=("$argument") ;;
  esac
done

mkdir -p "$build"

# main.swift holds the app's top-level code, which would clash with the tests' own entry point
sources=("$here"/app/src/*.swift)
sources=("${sources[@]:#*/main.swift}")
sources+=("$here"/app/tests/*.swift)
(( ${#sources} >= 2 )) || { echo "no sources found under $here/app"; exit 1 }

flags=(-target arm64-apple-macos26.0)
if (( coverage )); then
  flags+=(-profile-generate -profile-coverage-mapping)
fi

echo "==> building tests"
swiftc "${flags[@]}" -o "$bin" "${sources[@]}"

echo "==> running tests"
if (( coverage )); then
  rm -f "$build"/*.profraw "$build/tests.profdata"
  set +e
  LLVM_PROFILE_FILE="$build/tests.profraw" "$bin" "${filter[@]}"
  test_status=$?
  set -e
  xcrun llvm-profdata merge -sparse "$build/tests.profraw" -o "$build/tests.profdata"
  echo ""
  echo "==> coverage (app/src only)"
  xcrun llvm-cov report "$bin" \
    -instr-profile="$build/tests.profdata" \
    -ignore-filename-regex='app/tests/.*' \
    "$here"/app/src/*.swift
  echo ""
  echo "line-by-line gaps:  xcrun llvm-cov show $bin -instr-profile=$build/tests.profdata <file>"
  exit $test_status
fi

exec "$bin" "${filter[@]}"
