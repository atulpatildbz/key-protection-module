#!/usr/bin/env bash
#
# Reject ad-hoc formatting, output, and telemetry in production Rust KCC code.
# All KCC failure events must pass through km_common/src/telemetry.rs.

set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd -P)"
SAFE_FIXTURE="scripts/testdata/rust-kcc-telemetry-guard/safe"
UNSAFE_FIXTURES="scripts/testdata/rust-kcc-telemetry-guard/unsafe"
TRUSTED_FIXTURES="scripts/testdata/rust-kcc-telemetry-guard/trusted"
TELEMETRY_MODULE="km_common/src/telemetry.rs"

FORBIDDEN_PATTERN='(^|[^[:alnum:]_])(print|println|eprint|eprintln|dbg|format|format_args|write|writeln|trace|debug|info|warn|error|event|span)[[:space:]]*!|std::panic::set_hook[[:space:]]*\('
DIRECT_FORMAT_PATTERN='(^|[^[:alnum:]_])(print|println|eprint|eprintln|dbg|format|format_args|write|writeln)[[:space:]]*!'
LOGGING_PATTERN='(^|[^[:alnum:]_])(trace|debug|info|warn|error|event|span)[[:space:]]*!'

scan_files() {
  local failed=0
  local file
  local violations

  while IFS= read -r file; do
    if [[ "$file" == "$TELEMETRY_MODULE" ]]; then
      continue
    fi

    violations="$(rg -n --pcre2 "$FORBIDDEN_PATTERN" "$file" || true)"
    if [[ -n "$violations" ]]; then
      echo "Forbidden Rust formatting/logging in $file:" >&2
      echo "$violations" >&2
      failed=1
    fi
  done

  if [[ "$failed" -ne 0 ]]; then
    echo "Route failure telemetry through $TELEMETRY_MODULE and redact secret-bearing types." >&2
    return 1
  fi
}

scan_path() {
  local path="$1"

  if [[ -f "$path" ]]; then
    printf '%s\n' "$path" | scan_files
  else
    rg --files "$path" -g '*.rs' | sort | scan_files
  fi
}

scan_telemetry_module() {
  local path="$1"
  local logging_count
  local approved_logging_count
  local hook_count
  local direct_formatting

  logging_count="$(rg -o --pcre2 "$LOGGING_PATTERN" "$path" | wc -l | tr -d ' ')"
  approved_logging_count="$(rg -o 'tracing::error[[:space:]]*!' "$path" | wc -l | tr -d ' ')"
  hook_count="$(rg -o 'std::panic::set_hook[[:space:]]*\(' "$path" | wc -l | tr -d ' ')"
  direct_formatting="$(rg -n --pcre2 "$DIRECT_FORMAT_PATTERN" "$path" || true)"

  if [[ "$logging_count" -ne 1 || "$approved_logging_count" -ne 1 ]]; then
    echo "Trusted telemetry boundary must contain exactly one tracing::error! event: $path" >&2
    return 1
  fi
  if [[ "$hook_count" -ne 1 ]]; then
    echo "Trusted telemetry boundary must contain exactly one sanitized panic hook: $path" >&2
    return 1
  fi
  if [[ -n "$direct_formatting" ]]; then
    echo "Trusted telemetry boundary contains forbidden direct formatting/output:" >&2
    echo "$direct_formatting" >&2
    return 1
  fi
}

self_test() {
  local fixture

  scan_path "$SAFE_FIXTURE"
  scan_telemetry_module "$TRUSTED_FIXTURES/safe_telemetry.rs"

  for fixture in "$UNSAFE_FIXTURES"/*.rs; do
    if scan_path "$fixture" >/dev/null 2>&1; then
      echo "Validator failed to reject unsafe fixture: $fixture" >&2
      return 1
    fi
  done
  if scan_telemetry_module "$TRUSTED_FIXTURES/unsafe_telemetry.rs" >/dev/null 2>&1; then
    echo "Validator failed to reject unsafe trusted-boundary fixture" >&2
    return 1
  fi

  echo "Rust KCC telemetry validator self-test passed."
}

scan_production_tree() {
  {
    rg --files km_common/src -g '*.rs'
    rg --files key_protection_service/key_custody_core/src -g '*.rs'
    rg --files workload_service/key_custody_core/src -g '*.rs'
  } | sort -u | scan_files

  scan_telemetry_module "$TELEMETRY_MODULE"
  echo "Rust KCC telemetry guardrails passed."
}

cd "$REPO_ROOT"

case "${1:-}" in
  "")
    scan_production_tree
    ;;
  --self-test)
    self_test
    ;;
  --scan)
    if [[ "$#" -ne 2 ]]; then
      echo "usage: $0 --scan <file-or-directory>" >&2
      exit 2
    fi
    scan_path "$2"
    ;;
  *)
    echo "usage: $0 [--self-test | --scan <file-or-directory>]" >&2
    exit 2
    ;;
esac
