# Proposed Buganizer Tasks: Keymanager Observability & Logging Integration

This document outlines the proposed Buganizer tasks to implement the logging and observability stack for the Key Custody Core (KCC) and Workload Service Daemon (WSD), focusing on KCC/WSD logging, FFI trace propagation, and Fluent Bit setup on the KPS VM.

**Target Component:** `Cloud Platform > Cloud Security > Platform > Confidential Compute > Confidential Space` (Component ID: `1166820`)

---

## 1. Rust KCC Logging & Trace Propagation (Phase 1)

### Task 1: Integrate `tracing-journald` and telemetry setup in Rust KCC
*   **Title:** [Telemetry] Setup Rust KCC `tracing-journald` logging to systemd-journal socket
*   **Priority:** P1
*   **Description:**
    Configure the Rust Key Custody Core (`km_common`) to write non-blocking structured logs directly to `/run/systemd/journal/socket` using the `tracing-journald` crate (or equivalent).
    
    **Requirements:**
    *   Add `tracing`, `tracing-subscriber`, and `tracing-journald` to `km_common` dependencies in `Cargo.toml`.
    *   Initialize `tracing_subscriber` to serialize events to JSON and write datagrams directly to `/run/systemd/journal/socket`.
    *   Ensure logging is non-blocking (e.g. if the socket buffer fills, logs are dropped immediately instead of stalling cryptographic operations).
    *   Verify that core cryptographic operations under seccomp sandbox are not blocked.

### Task 2: Implement FFI Trace Propagation Bridge
*   **Title:** [Telemetry] Implement thread-local trace propagation across Go-Rust FFI
*   **Priority:** P1
*   **Description:**
    Implement correlation ID (Trace ID / Span ID) propagation across the Go-to-Rust FFI boundary to allow tracing span associations.
    
    **Requirements:**
    *   In Rust `km_common/src/telemetry.rs`, implement `set_thread_trace_context(trace_id, span_id)` using thread-local storage.
    *   In Rust `tracing_subscriber` setup, associate the thread-local trace context as the parent trace for logs generated in that thread.
    *   In Go `kps_key_custody_core_cgo.go` and `ws_key_custody_core_cgo.go`, implement wrappers for `set_thread_trace_context` and call it before invoking cryptographic FFI calls.
    *   Verify that span attributes propagate correctly from Go to Rust threads.

---

## 2. Go Telemetry Library & Service Integration (Phase 1)

### Task 3: Create reusable Go telemetry library
*   **Title:** [Telemetry] Implement reusable telemetry package in keymanager
*   **Priority:** P2
*   **Description:**
    Create a reusable internal Go package to standardize OpenTelemetry and structured logging setup across subsystems.
    
    **Requirements:**
    *   Create a new directory/package `keymanager/internal/telemetry`.
    *   Configure `slog` with standard OpenTelemetry handler (e.g., using `go.opentelemetry.io/contrib/bridges/otelslog`).
    *   Expose standard instrumentation wrappers (e.g., `WrapHTTPHandler`).
    *   Support dynamic endpoint injection from environment variables.

### Task 4: Instrument WSD and KPS with structured logging and RPC metrics
*   **Title:** [Telemetry] Configure structured logging and metrics in WSD and KPS
*   **Priority:** P2
*   **Description:**
    Configure WSD and KPS services to use structured JSON logging and collect RPC performance metrics.
    
    **Requirements:**
    *   Initialize the shared Go telemetry package in `workload_service` and `key_protection_service` main entry points.
    *   Use `slog` for structured JSON output to stdout/stderr.
    *   Wrap RPC endpoints in WSD and KPS with `otelgrpc` interceptors to track latency and request volume.
    *   Add key lifecycle metrics:
        *   `kps_active_keys_total`
        *   `wsd_active_keys_total`
        *   `key_destruction_total` (tagged by reason)

---

## 3. Data Protection & Redaction Safeguards (Phase 3)

### Task 5: Implement cryptographic secret redaction in Rust logs
*   **Title:** [Telemetry] Implement type-safe Debug/Display redaction for cryptographic structures
*   **Priority:** P1
*   **Description:**
    Ensure no sensitive data (e.g., plaintext keys, shared secrets) ever escapes via logs or panics.
    
    **Requirements:**
    *   Implement custom `Debug` and `Display` traits for sensitive Rust structs (such as `Vault` and `SecretBox`) to return `[REDACTED]`.
    *   Override the startup panic hook (`std::panic::set_hook`) to sanitize stack traces and strip out sensitive variables.
    *   Establish a CI/CD linter/static check to block direct logging or formatting of unredacted cryptographic types.

---

## 4. Fluent Bit Configuration & Guest OS Image Integration (Phase 2)

### Task 6: Design Fluent Bit configuration for KPS VM
*   **Title:** [Telemetry] Configure Fluent Bit for KPS VM telemetry relay
*   **Priority:** P1
*   **Description:**
    Create the Fluent Bit configuration file (`fluent-bit.conf`) to collect and relay KPS guest telemetry.
    
    **Requirements:**
    *   Tails the local systemd journal.
    *   Collects guest performance metrics via built-in input plugins (`cpu`, `mem`, `netif`).
    *   Configures output to forward logs in plain-text over TCP to the Workload VM's Fluent Bit TCP port (`50050`).
    *   Caps local memory buffering strictly to `32MB` (`Mem_Buf_Limit 32M`) to prevent out-of-memory states on network drops.
    *   Injects OTel attributes like `service.name = key_protection_service` and the volatile `kps_boot_token` to log records.

### Task 7: Integrate Fluent Bit into KPS VM guest image
*   **Title:** [Telemetry] Package and enable Fluent Bit service in KPS guest OS image
*   **Priority:** P1
*   **Description:**
    Integrate the Fluent Bit service and configuration files into the KPS guest OS image build pipeline.
    
    **Requirements:**
    *   Define `fluent-bit.service` systemd service unit.
    *   Update `image/cloudbuild.yaml` to copy Fluent Bit config and service files to the workspace preloader build directory.
    *   Update `image/entrypoint.sh` to copy `fluent-bit.service` and configuration to `/etc/systemd/system/` and `/etc/fluent-bit/` respectively.
    *   Modify `entrypoint.sh` to enable and start `fluent-bit.service` on boot.

---

## 5. Verification & Testing Tasks

### Task 8: Implement non-blocking socket stress testing and FFI propagation tests
*   **Title:** [Telemetry] Implement telemetry stress and integration tests
*   **Priority:** P2
*   **Description:**
    Implement tests to verify non-blocking behaviors under log floods and correct span propagation.
    
    **Requirements:**
    *   **KCC Stress Test:** Verify that flooding Rust KCC with logs and filling up `/run/systemd/journal/socket` does not block or latency-impact cryptographic execution.
    *   **FFI Propagation Test:** Verify that trace context attaches parent trace IDs to logs generated inside Rust FFI execution threads.
    *   **Redaction Assertion:** Add unit tests asserting that stringifying `Vault` or `SecretBox` returns `[REDACTED]`.
    *   **End-to-End Pipeline Test:** Set up integration test to assert KCC log output reaches a mock OTLP exporter through KPS Fluent Bit.

