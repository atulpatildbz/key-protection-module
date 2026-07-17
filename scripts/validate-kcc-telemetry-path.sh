#!/usr/bin/env bash
#
# Validate the host journal socket and Fluent Bit path used by Rust KCC telemetry.

set -euo pipefail

readonly REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd -P)"
readonly RUNNER="${REPO_ROOT}/image/kps_runner.sh"
readonly FLUENT_BIT_CONFIG="${REPO_ROOT}/image/fluent-bit-kps.conf"
readonly JOURNAL_MOUNT="src=/run/systemd/journal/socket,dst=/run/systemd/journal/socket"

fail() {
  echo "FAIL: $*" >&2
  exit 1
}

grep -Fq "${JOURNAL_MOUNT}" "${RUNNER}" \
  || fail "kps_runner.sh does not bind the systemd journal socket into the agent container"

grep -Fq "Systemd_Filter _SYSTEMD_UNIT=keymanager.service" "${FLUENT_BIT_CONFIG}" \
  || fail "Fluent Bit does not tail keymanager.service"

grep -Fq "Systemd_Filter SYSLOG_IDENTIFIER=rust-kcc" "${FLUENT_BIT_CONFIG}" \
  || fail "Fluent Bit does not tail direct Rust KCC journal records"

grep -Fq "Systemd_Filter_Type Or" "${FLUENT_BIT_CONFIG}" \
  || fail "Fluent Bit does not OR the keymanager unit and Rust KCC identifier"

echo "KCC journal-to-Fluent-Bit telemetry path passed."
