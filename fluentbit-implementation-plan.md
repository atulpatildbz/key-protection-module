# Fluent Bit on the KPS Guest VM — Implementation Plan

Scope: Tasks 6 and 7 of [`fluentbitplan.md`](fluentbitplan.md), KPS-side only.

This document records what we are building, what we considered and rejected, and what
follows. It supersedes Tasks 6 and 7 of `fluentbitplan.md` where the two disagree; the
disagreements are called out explicitly in [Corrections to the original plan](#corrections-to-the-original-plan).

---

## Background: what the code actually does today

Facts established by reading the tree, not assumed:

*   **The KPS agent runs inside a containerd container, not on the VM.**
    `image/keymanager.service` → `image/kps_runner.sh` → `ctr run --rm -net-host --mount
    type=bind,src=/tmp/container_launcher/,dst=/run/container_launcher/`. The only bind
    mount is `/run/container_launcher`.

*   **Logs already reach the journal.** `ctr run` is foreground, so the container's
    stdout/stderr is inherited by `kps_runner.sh`, which is `ExecStart=` of a `Type=simple`
    unit. systemd captures it into journald. `cmd/agent/main.go` writes via stdlib `log`,
    and `attestation_agent` (native, `image/attestation.service`) does too. Both units are
    already populating the journal with no code change.

*   **ACOS ships the Fluent Bit binary at `/usr/bin/fluent-bit`.** Read directly from COS's
    `project-lakitu/app-admin/fluent-bit` package (ebuild `fluent-bit-4.2.2`), whose
    `fluent-bit.service` has `ExecStart=/usr/bin/fluent-bit -c /etc/fluent-bit/fluent-bit.conf`.
    go-tpm-tools relies on the same thing: it ships **only** a `.conf` — no binary, no unit.

*   **`docker-events-collector-fluent-bit.service` does not run Fluent Bit.** Despite the
    name, its `ExecStart` is `/usr/bin/docker events`; it pipes Docker events into the journal
    and `Requires=docker.socket`. go-tpm-tools masks it (`bc_cloudbuild.yaml:193`); we leave
    the mask commented out (`image/cloudbuild.yaml:193`). Either way it is unrelated to our
    config, and leaving it alone is harmless.

*   **Network topology.** The KPS guest is `192.168.100.3/24` with next hop `192.168.100.1`
    (`image/network_setup.sh`). The workload VM (`bc-guest`) is `192.168.100.2/24` with no
    gateway line (`go-tpm-tools/launcher/image/bc-guest/bc_network_setup.sh`). `.1` is the
    VMM's virtual router, not a host. This is a private virtio tap link, **not** a GCE
    subnet — GCE never sees `192.168.100.0/24`.

*   **`kps_boot_token` is already implemented, and is not a boot ID.**
    `key_protection_service/server.go:97` mints `uuid.New().String()` once per KPS *process*
    start. It is returned by the `Heartbeat` RPC (`grpc_server.go:166`, `api.proto:83`). WSD
    caches it and, on mismatch, calls `cleanupState()` → `DestroyAllKeys()`
    (`workload_service/server.go:947-954`). It is an epoch/restart detector for KPS's
    in-memory key state.

*   **`image/cloudbuild.yaml` is invoked by nothing in this repo.** Root `cloudbuild.yaml`
    has 13 steps and never calls it. Nothing in CI builds the guest image, boots it, or
    exercises `entrypoint.sh`.

*   **The workload VM's output is `stackdriver` with `Match *`.** Any record arriving at
    `.2` is swept into Cloud Logging. The Fluent Bit `stackdriver` output derives the Cloud
    Logging `logName` from the record's tag — which is why CS launcher logs appear under
    `confidential-space-launcher`, that repo's `Tag` value.

---

## What we are building

### 1. New file: `image/fluent-bit-kps.conf`

```ini
[SERVICE]
    flush           1
    daemon          Off
    log_level       info
    storage.metrics on

[INPUT]
    Name           systemd
    Tag            kps.keymanager
    Systemd_Filter _SYSTEMD_UNIT=keymanager.service
    DB             /var/log/google-fluentbit/kps-keymanager.log.db
    Read_From_Tail False
    Mem_Buf_Limit  32M

[INPUT]
    Name           systemd
    Tag            kps.attestation
    Systemd_Filter _SYSTEMD_UNIT=attestation.service
    DB             /var/log/google-fluentbit/kps-attestation.log.db
    Read_From_Tail False
    Mem_Buf_Limit  32M

[FILTER]
    Name  modify
    Match kps.*
    Add   service.name key_protection_service

[OUTPUT]
    Name        forward
    Match       kps.*
    Host        192.168.100.2
    Port        24224
    Retry_Limit False
```

### 2. New file: `image/fluent-bit-kps.service`

```ini
[Unit]
Description=Fluent Bit log relay for Key Protection Service
After=network.target systemd-networkd.service
Wants=network.target

[Service]
Type=simple
ExecStartPre=/bin/mkdir -p /var/log/google-fluentbit
ExecStart=/usr/bin/fluent-bit -c /etc/fluent-bit/fluent-bit-kps.conf
Restart=on-failure
RestartSec=10

[Install]
WantedBy=multi-user.target
```

We use the base image's Fluent Bit **binary** but not its **unit**. The stock
`fluent-bit.service` (COS `project-lakitu/app-admin/fluent-bit`) exists to upload to Cloud
Logging, and everything above its `ExecStart` is plumbing for that job:

```ini
ConditionPathExists=/etc/cloud-api-domains            # gates on metadata we cannot reach
EnvironmentFile=/etc/fluent-bit/fluent_bit_defaults   # CLOUD_LOGGING_BASE_URL, unused by us
ExecCondition=/bin/sh -c '... sudo sed -i "s#CLOUD_LOGGING_BASE_URL=...#" ...'
Wants=docker-events-collector-fluent-bit.service get-cloud-api-domains.service  # the latter is masked
ExecStart=/usr/bin/fluent-bit -c /etc/fluent-bit/fluent-bit.conf
```

`/etc/cloud-api-domains` is written by `get-cloud-api-domains.service`, which we mask
(`image/cloudbuild.yaml:166,180`) and which queries `metadata.google.internal` — unreachable
from the KPS VM. **A unit whose `Condition*=` fails is skipped, and systemd reports the start
job as _successful_.** So the stock unit can never run here, and reusing it would mean
fabricating `/etc/cloud-api-domains` to satisfy a precondition for an upload we never perform.

Owning the unit means: no fabricated file, no clobbering of COS's `fluent-bit.conf`, no
inherited Cloud Logging plumbing, and no masking — the stock unit stays inert on its own
failed `Condition`. `image/entrypoint.sh` already installs two unit files, so a third is this
repo's existing idiom.

We deliberately do **not** `systemctl mask fluent-bit.service`: `logging-agent.target` has
`Requires=fluent-bit.service`, and a masked `Requires=` dependency fails that target, whereas
a condition-skipped one does not. Masking would trade an inert unit for a new failure mode.

### 3. `image/entrypoint.sh`

Install the unit and config alongside the other `cp`s; enable and start the relay at the end
of `main()`.

```bash
cp /usr/share/oem/kps/fluent-bit-kps.service /etc/systemd/system/fluent-bit-kps.service
mkdir -p /etc/fluent-bit
cp /usr/share/oem/kps/fluent-bit-kps.conf /etc/fluent-bit/fluent-bit-kps.conf
# ... after keymanager.service and attestation.service are started:
systemctl enable fluent-bit-kps.service
systemctl start fluent-bit-kps.service
systemctl is-active --quiet fluent-bit-kps.service || <fail loudly to /dev/console>
```

**Why the `is-active` assertion.** `Type=simple` reports a successful start once the binary
is exec'd, so a config Fluent Bit rejects on load would otherwise go unnoticed.

**Why it runs last.** The units do not feed Fluent Bit directly — they write to journald,
which persists the journal to disk, and Fluent Bit reads that journal. Since
`Read_From_Tail False` makes it read from the beginning rather than skipping to the end,
a Fluent Bit that starts after `keymanager.service` still collects that unit's startup
logs. (The cursor DB is a separate mechanism: it prevents a *re-*start from re-reading the
whole journal and duplicating records.) So nothing is lost by starting last, and in exchange
the `is-active` failure path cannot prevent the KPS from serving keys — the relay's health
must not gate the service's availability. This also matches go-tpm-tools, whose
`bcentrypoint.sh` starts `fluent-bit.service` on its last line.

**One process, not one per input.** The two `[INPUT]` stanzas are read by a single
`fluent-bit` process. Adding inputs later adds stanzas, not units or processes.

### 4. `image/cloudbuild.yaml`

One line in the `PrepareOEMInstallDir` step:

```bash
cp ./image/fluent-bit-kps.conf /workspace/oem-install/kps/fluent-bit-kps.conf
cp ./image/fluent-bit-kps.service /workspace/oem-install/kps/fluent-bit-kps.service
```

### 5. CI

A new `image-config` job runs two scripts. Neither needs a VM or a receiver.

#### `scripts/validate-systemd-units.sh`

`systemd-analyze verify` over `image/*.service`, in a digest-pinned Debian container.
`containerd.service` and each unit's `Exec*` binaries are stubbed, since they exist only on
the KPS VM and `verify` treats both as errors.

**`verify`'s exit code is not enough.** It warns and exits 0 on exactly the mistakes that
matter:

| Mutation | exit code | output |
| --- | --- | --- |
| `Restartt=on-failure` | **0** ❌ | `Unknown key 'Restartt' ... ignoring.` |
| `Type=simpl` | **0** ❌ | `Failed to parse service type, ignoring: simpl` |
| `Requires=nonexistent.service` | 1 | `Failed to create ... not found` |
| `[Servce]` section header | 1 | — |
| `ExecStart=usr/bin/fluent-bit` | 1 | `Neither a valid executable name nor an absolute path` |

A clean unit emits **nothing**, so the script fails on any output as well as any non-zero
exit. Verified against all five mutations above plus a typo in the pre-existing
`keymanager.service`; the unmodified units pass.

This also covers `keymanager.service` and `attestation.service`, which nothing checked before.

#### `scripts/validate-fluentbit-config.sh`

**The Fluent Bit docs are wrong about `--dry-run`.** They claim that as of 4.2 it performs
"full property validation ... unknown or misspelled plugin property names are caught during
validation." Measured against `fluent/fluent-bit:4.2.7`, it does not:

| Mutation | `--dry-run` | Real startup |
| --- | --- | --- |
| `Name systemdd` (bad plugin) | **exit 1** | exit 1 |
| `Mem_Buf_Limitt 32M` (bad property) | exit 0 ❌ | **exit 1** |
| `Hostt 192.168.100.2` (bad property) | exit 0 ❌ | **exit 1** |

This matters specifically for us: a typo'd `Mem_Buf_Limit` passes `--dry-run` and ships with
Fluent Bit's default *unbounded* per-input memory buffering — the exact OOM path this design
exists to prevent. So the script does both:

1.  `--dry-run` for section syntax and plugin names.
2.  A real ~8s startup, asserting no `unknown configuration property` / `initialization failed`,
    and asserting the intended pipeline materialized (`systemd.0`, `systemd.1`, `forward.0`).

Connection failures to `192.168.100.2` during the startup check are expected and ignored.
The Fluent Bit image is pinned by digest, because both `--dry-run`'s behavior and startup
property rejection are version-dependent.

Note that `Mem_Buf_Limit` and `Tag` do not appear in the `systemd` input's own allowed-property
list (`path, max_fields, max_entries, systemd_filter_type, systemd_filter, read_from_tail,
lowercase, strip_underscores, db.sync, db`). They are core input properties handled by the
engine, and are accepted — confirmed by a clean startup.

### 6. Manual smoke (runbook, not a test)

Boot the **debug** image (`HARDENED_COMMANDS` masks `sshd.service`; `DEBUG_COMMANDS` does
not), then:

*   `systemctl is-active fluent-bit-kps.service` reports `active`.
*   `journalctl -u fluent-bit-kps` shows connection-refused retries to `192.168.100.2:24224`.
    This is the expected steady state until the receiver exists, and it proves the inputs
    are reading — Fluent Bit only retries chunks it has ingested.
*   No `[warn] [input] ... paused (mem buf overlimit)` at normal log volume.
*   `systemctl status fluent-bit.service` reports the stock unit as inactive, skipped by its
    `ConditionPathExists`. Two running `fluent-bit` processes would mean something regressed.

---

## Corrections to the original plan

| `fluentbitplan.md` says | Reality | Disposition |
| --- | --- | --- |
| Task 7: "Define `fluent-bit.service` systemd service unit" | ACOS ships the binary and a unit, but that unit gates on Cloud Logging preconditions this VM can never satisfy | **Kept, renamed.** We ship `fluent-bit-kps.service` and reuse only the binary. |
| Task 6: inject the "volatile `kps_boot_token`" as a log attribute | The token is minted at runtime *inside the container* and changes on every agent restart, without Fluent Bit restarting | **Moved to Task 4.** The agent must stamp its own logs. |
| Task 6: forward to the Workload VM on port `50050` | `50050` is the KPS gRPC port in five places in this repo. Fluent Bit's `forward` input defaults to `24224` | **Changed to 24224.** |
| Task 6: forward to "the Workload VM" (address unstated) | Workload VM is `.2`; `.1` is the VMM's router | **`192.168.100.2`.** |
| Task 6: `Mem_Buf_Limit 32M` listed among output concerns | `Mem_Buf_Limit` is an `[INPUT]` property | **Placed on both inputs.** |
| Task 6: collect `cpu`, `mem`, `netif` | These emit log records, not metrics; `netif` needs an interface name nothing pins | **Deferred.** See [Next steps](#next-steps). |
| Task 6: "plain-text over TCP" | Plain text discards the structure Tasks 1–4 exist to produce | **`forward` (msgpack).** |
| Task 7: copy config to `/etc/fluent-bit/` and enable the service on boot | A unit skipped by a failed `Condition` reports a *successful* start job, so a start alone proves nothing | **`entrypoint.sh` enables our own unit and asserts `is-active`.** |
| Task 1: Rust writes to `/run/systemd/journal/socket` | That socket is not mounted into the container | **Out of scope here**; blocks Task 1 as written. |

---

## Decisions, and the alternatives we rejected

### Sequencing: Fluent Bit first, before any Rust/Go telemetry work

Both KPS units already write to the journal, so the relay can be built and observed against
today's plaintext logs with zero code change. It de-risks the base-image and network
unknowns before we invest in tracing.

*   **Rejected — Rust KCC telemetry first (Tasks 1+2).** Without a mounted journal socket
    those logs go nowhere new, and with no collector there is nothing to observe end-to-end.
*   **Rejected — Go telemetry library first (Tasks 3+4).** Improves the payload flowing
    through the existing stdout→journal path, but still relays nothing off the VM.
*   **Rejected — redaction first (Task 5).** Safety-first ordering is defensible, but no
    secret can leak through a pipeline that does not exist yet.

### Packaging: stock binary, our own unit and config path

No OEM size cost, and the binary is already in the measured base image. The unit is ours
because the stock one is Cloud Logging infrastructure that cannot start on this VM (see
[§2](#2-new-file-imagefluent-bit-kpsservice)).

This was originally decided the other way — mirror go-tpm-tools exactly, clobber
`/etc/fluent-bit/fluent-bit.conf`, start the stock unit. That was reversed on discovering
`ConditionPathExists=/etc/cloud-api-domains`. The go-tpm-tools resemblance was in the file
layout, not the mechanism: their workload VM uses that unit for its intended purpose (it
reads `/etc/cloud-api-domains`, uploads to `stackdriver`, needs `CLOUD_LOGGING_BASE_URL`);
ours does none of those things.

*   **Rejected — bundle a static binary in the OEM partition.** ~30–60MB against a fixed
    `--oem-fs-size=500M` that already holds the KPS container `image.tar`; and we would own
    building and refreshing a musl build with systemd input support.
*   **Rejected — run Fluent Bit as a container via `ctr`.** Largest OEM footprint; needs
    host journal and host net mounts; `cpu`/`mem`/`netif` would measure the container's
    namespace rather than the VM.
*   **Rejected — reuse the stock unit, fabricating `/etc/cloud-api-domains`.** Write the
    three lines `get_cloud_api_domains` emits on a default GCE instance
    (`API_DOMAIN=googleapis.com`, `ARTIFACT_REGISTRY_DOMAIN=pkg.dev`, `PROJECT_PREFIX=`),
    which makes the unit's `ExecCondition` a no-op. Smallest diff, and the content is the
    benign case — an *empty* file would satisfy `ConditionPathExists` but send `ExecCondition`
    down its `sudo sed` branch, rewriting `fluent_bit_defaults` with a malformed URL. Rejected
    because it asserts a cloud-API config on a VM with no cloud-API path, on a file COS owns,
    and stays load-bearing on `ExecCondition`'s comparison never changing.
*   **Rejected — drop-in override on the stock unit.**
    `/etc/systemd/system/fluent-bit.service.d/10-kps.conf` with `[Unit] ConditionPathExists=`
    and `[Service] ExecCondition=` (empty assignment resets each list). Fabricates nothing,
    but owns part of a unit without owning the unit, still inherits `EnvironmentFile` and the
    `Wants=` on a masked unit, still clobbers COS's `fluent-bit.conf`, and a COS change to `ExecStart`
    would silently change our behavior.
*   **Rejected — `systemctl mask fluent-bit.service`.** Belt-and-braces against two Fluent Bit
    processes, but `logging-agent.target` has `Requires=fluent-bit.service`: a masked
    `Requires=` fails that target, while a condition-skipped one does not. Trades an inert
    unit for a new failure mode.
*   **Accepted risk — no assertion that the base image still ships the Fluent Bit binary.**
    See [Residual risks](#residual-risks).

### Transport: `forward` to `192.168.100.2:24224`

Fluent Bit's native fb→fb transport. Preserves the `Tag` and every structured field, so the
workload VM's existing `[OUTPUT] stackdriver Match *` picks them up with structure intact
and `severity_key` still functional. `24224` is the registered default for a `forward`
input, so the go-tpm-tools side needs no `Port` line.

*   **Rejected — `tcp` + `Format json_lines`.** More universal receiver, but the `Tag` is
    not carried on the wire, so source-unit routing on the workload VM would require
    embedding the tag into the payload.
*   **Rejected — `tcp` + `Format none` (literal "plain-text", as Task 6 words it).** Throws
    away severity, structured fields, and trace IDs — contradicting Tasks 1–4.
*   **Rejected — port `50050`.** Legal (different host), but collides with the KPS gRPC port
    used in `key_protection_service/server.go`, `cmd/agent/main.go`, `workload_service/server.go`,
    `image/entrypoint.sh`, and `tests/run_grpc_wsd_e2e.sh`.
*   **Rejected — `192.168.100.1`.** That is the VMM's virtual router, per
    `bc_network_setup.sh`. Logs sent there go nowhere.
*   **Rejected — serial console / virtio-vsock.** Avoids the network dependency entirely,
    but needs VMM-side support invisible from this repo.
*   **Rejected — `stdout` only, deferring the address.** Verifiable today, but records the
    intended topology nowhere in-tree and requires a second image build and rollout.

### Input scope: `keymanager.service` and `attestation.service` only

Two `Systemd_Filter` lines (they OR together within an input). Mirrors the go-tpm-tools
precedent, exports the minimum out of the confidential boundary, and structurally cannot
feed back on Fluent Bit's own error logs.

The security stake is concrete: our records forward to `.2`, where `Match *` sweeps
everything into Cloud Logging in a project outside the confidential boundary. Whatever we
tail, we export.

*   **Rejected — whole journal (what Task 6 literally says).** Widest confidential-boundary
    export — kernel and containerd internals — and it would ingest Fluent Bit's own output,
    so a forward-failure storm becomes an amplifying loop.
*   **Rejected — whole journal minus `fluent-bit.service` via a `grep` filter.** Breaks the
    loop, but still exports kernel messages.
*   **Rejected — adding `containerd.service`.** Would cover the realistic failure mode
    (containerd cannot import `image.tar`, so `keymanager.service` dies), at the cost of
    chatty logs. Reconsider if boot failures prove hard to debug.

**Accepted consequence:** if `keymanager.service` never starts, we collect nothing about
why. In hardened mode `sshd` is masked, so the debug image's serial console is the fallback.

### Tags: `kps.keymanager` and `kps.attestation`, two inputs

The tag becomes the Cloud Logging `logName`. Two tags give operators two distinct logNames
to grant and route separately, and let a future receiver `Match kps.*` or just one of them.

*   **Rejected — single input, `Tag key-protection-service`.** One stanza, one logName,
    units still distinguishable via `_SYSTEMD_UNIT` (`Strip_Underscores` defaults off).
    Simpler, but coarser routing.
*   **Rejected — `Tag confidential-space-kps`.** Sorts beside `confidential-space-launcher`,
    but says "confidential space" about a VM nested *inside* one.
*   **Rejected — `Tag kps`.** A three-letter logName in someone else's project.

### Buffering: `Mem_Buf_Limit 32M` per input, memory-only, `Retry_Limit False`

`Retry_Limit False` (verified: `False` and `no_limits` are equivalent; the default is `1`)
means chunks accumulate until `Mem_Buf_Limit`, at which point Fluent Bit invokes the input's
`pause` callback.

`plugins/in_systemd/systemd.c` registers `.cb_pause`/`.cb_resume` (lines 789–790) which call
`flb_input_collector_pause/resume`, and saves the journal cursor to the DB after each append
(lines 467–472). So under backpressure the plugin **stops reading the journal** rather than
discarding entries, and resumes from its cursor. The Fluent Bit docs' warning that "some
input plugins are prone to data loss after `mem_buf_limit` capacity is reached" applies to
inputs whose source keeps arriving while paused (`tcp`, `forward`, `syslog`); journald is
durable on disk. **The DB is therefore not optional** — it is what makes the guarantee hold
across a Fluent Bit restart.

Failure mode is "stall and recover": bounded RSS, no loss, automatic backfill when a
receiver appears — bounded by journald's own retention.

*   **Rejected — `storage.type filesystem` + `storage.max_chunks_up`.** This is the *only*
    true global memory ceiling Fluent Bit offers, and it survives restarts and long outages.
    Rejected because it writes guest log content to the confidential VM's protected stateful
    partition (`cos.protected_stateful_partition=m`), adds `storage.pause_on_chunks_overlimit`
    and `storage.total_limit_size` to reason about, and introduces a disk-space failure mode.
*   **Rejected — finite `Retry_Limit`.** Never wedges, but silently drops records on any
    transient blip once a receiver exists.
*   **Rejected — no `Mem_Buf_Limit`.** Fluent Bit's default is unbounded per-input memory
    buffering. On a sustained outage the KPS VM OOMs, killing `keymanager.service`, failing
    heartbeats, and triggering `DestroyAllKeys()` on the workload side.

**On the budget.** `Mem_Buf_Limit` is per-input and **there is no global memory cap in
Fluent Bit** — `storage.max_chunks_up` explicitly does not govern memory-only buffering. We
treat `32M` as a per-plugin guardrail and accept an `N × 32M` total (≈64MB today) rather
than dividing a fixed budget, so adding an input never forces re-tuning the existing ones.

*   **Rejected — 16M + 16M.** Holds the 32MB total, but `attestation.service` emits roughly
    one line per 30s (`heartbeatInterval`, `workload_service/server.go:43`) and will never
    approach 16M, while `keymanager` — the unbounded input — stalls at half the headroom it
    could have. Every new input forces a re-division.
*   **Rejected — 24M keymanager + 8M attestation.** Same total, sized by actual rate, but
    two magic numbers needing revision once Task 4 changes the volume profile.

### Cursor DB: `/var/log/google-fluentbit/`, `Read_From_Tail False`

Matches the go-tpm-tools path, so anyone debugging either VM looks in the same place.
`Read_From_Tail False` captures agent startup logs regardless of unit ordering.
`entrypoint.sh` does `mkdir -p` first, since we cannot confirm the stock COS Fluent Bit
package creates the directory on the `cchost` base image.

Note `/var` is on the stateful partition, which boots encrypted under a key that does not
survive reboot. So `/var/log` and `/run` (tmpfs) have **identical lifetimes here**: both
survive a service restart, neither survives a reboot.

*   **Rejected — `/run/fluent-bit/`.** Functionally equivalent, avoids any stateful-partition
    write, but diverges from the sibling repo for no gain.
*   **Rejected — no DB.** A Fluent Bit restart would re-read the whole journal, duplicating
    every forwarded record — an amplifying storm under a crash loop.
*   **Rejected — `Read_From_Tail True`.** Would skip the agent's startup logs if
    `fluent-bit-kps.service` starts after `keymanager.service`, making correctness depend on
    unit ordering. Those are exactly the logs needed when the agent fails to come up.

### Activation: `enable` + `start`, last, with an `is-active` assertion

`enable` + `start` matches how `entrypoint.sh` already treats `keymanager.service` and
`attestation.service`. Because we own `fluent-bit-kps.service` and nothing else starts it,
the no-op-if-already-running hazard that would force `restart` does not arise.

*   **Rejected — `restart`.** Idempotent, and necessary if we had reused the stock unit
    (which COS might already have started with its own config, making `start` a silent
    no-op). Unnecessary once the unit is ours.
*   **Rejected — start before `keymanager` / `attestation`.** Would make the pipeline live for
    their first logs, but with `Read_From_Tail False` nothing is missed anyway, and the
    `is-active` failure path would then abort `entrypoint.sh` before the KPS ever serves keys
    — trading availability for observability.
*   **Rejected — no `is-active` assertion.** `entrypoint.sh` has no `set -e` and no
    boot-failure path today, so adding one is a real behavioral change. Accepted anyway: the
    `ConditionPathExists` bug was exactly this class of silent failure, and `Type=simple`
    reports success once the binary is exec'd regardless of whether it loads the config.

For getting past the stock unit's `ConditionPathExists`:

*   **Rejected — unmask `get-cloud-api-domains.service`.** Literal mechanism parity with
    go-tpm-tools, whose workload VM is a real GCE instance. The KPS VM sits on a private
    virtual bridge created by the host hypervisor, with no external NIC and no route to the
    GCE network or the metadata server; the host passes the physical NIC through to the
    workload VM, so it cannot proxy metadata either. The service's own `ExecCondition` greps
    DMI for `Google Compute Engine`; if that fails it is skipped and writes nothing, and if
    it passes, `get_cloud_api_domains` retries `metadata.google.internal` up to 1000 times,
    hits `TimeoutStartSec=5min`, and exits before writing the file. Either way Fluent Bit
    stays skipped, and `fluent-bit.service` has `After=` on it, so we would also add a
    five-minute boot stall. It would also re-add the hardening surface the mask removed.
The fabricate-the-file and drop-in alternatives are covered under
[Packaging](#packaging-stock-binary-our-own-unit-and-config-path); owning the unit makes both
unnecessary.

### Firewall: no `iptables` change in this landing

`forward` is outbound. The only firewall rule in either repo is the `INPUT ACCEPT` in
`image/entrypoint.sh` (`--dports 50050,50051`); there is no
`-P OUTPUT DROP`, no `-P INPUT DROP`, no loopback or conntrack rule. Under the default
ACCEPT policy an egress ACCEPT rule would grant nothing, so none is added.

The *intended* posture — drop all traffic by default, allowing only ingress gRPC from the
workload VM plus loopback — is not yet implemented anywhere in the tree. When it lands it
must account for this relay. See [Next steps](#next-steps).

### Directory: `mkdir -p /etc/fluent-bit` only

`fluent-bit-kps.service` creates `/var/log/google-fluentbit` itself via `ExecStartPre`, the
same way the stock unit does, so `entrypoint.sh` no longer needs to.

### Verification: CI config + unit validation, plus a documented manual smoke

The checks catch the class of error that silently bricks logging at boot, cost seconds, and
need no VM. Both were verified against mutations of the real files rather than assumed to
work: four for the config (bad plugin name, typo'd `Mem_Buf_Limit`, typo'd `Host`, a deleted
`[INPUT]` stanza) and six for the units (unknown directive, invalid value, unresolvable
dependency, malformed section, relative `ExecStart`, and a typo in `keymanager.service`).
All fail; the unmodified files pass.

Both tools share a failure mode worth remembering: **`fluent-bit --dry-run` and
`systemd-analyze verify` each accept misspelled properties and exit 0.** Neither exit code is
a sufficient gate on its own.

*   **Rejected — review only.** Consistent with how `entrypoint.sh`, `keymanager.service`,
    `kps_runner.sh`, and `network_setup.sh` ship today (nothing tests any of them), but the
    first signal of a malformed config would be a nested confidential VM that boots without
    logs and without `sshd`.
*   **Rejected — lint plus a temporary `stdout` output.** Would actually prove collection
    end-to-end on the KPS side, but reverses the transport decision, doubles journal writes,
    and "temporary" stanzas tend to become permanent.
*   **Rejected — full E2E now.** Task 8's "KCC log output reaches a mock OTLP exporter
    through KPS Fluent Bit" is blocked on the receiver.

---

## Residual risks

*   **The validator's Fluent Bit version may not match the VM's.** We pin
    `fluent/fluent-bit:4.2.7`; COS's ebuild is `fluent-bit-4.2.2`. Close, but not identical,
    and ACOS could diverge. The validator catches typos, not version skew.

*   **The `is-active` assertion is the only guard on unit activation.** It is checked once,
    at boot, after `systemctl restart`. Nothing detects a Fluent Bit that starts and later
    dies (the stock unit has `Restart=on-failure`, `RestartSec=10`, so it would retry).

*   **A default-drop firewall will silence the relay.** Under `-P OUTPUT DROP` the `forward`
    output cannot reach `192.168.100.2:24224`, and because `Retry_Limit False` makes it stall
    on backpressure rather than exit, the symptom is "logs stopped" with no error. Under
    `-P INPUT DROP` it additionally needs a conntrack `ESTABLISHED,RELATED` rule for the
    handshake's return packets, since the existing INPUT rule matches only `--dports 50050,50051`.

*   **We depend on the base image's `/usr/bin/fluent-bit`.** `fluent-bit-kps.service` hardcodes
    that path, taken from the stock unit's `ExecStart`. If an ACOS bump moves or drops the
    binary, the unit fails to start — loudly, via the `is-active` assertion, which is the
    intended behavior. Declined as scope: a build-time check that the base image still ships it.

*   **We now own a systemd unit.** `fluent-bit-kps.service` must track any COS change to the
    Fluent Bit binary's path or invocation. In exchange it is immune to COS changing the stock
    unit's conditions, environment, or `ExecStart`.

*   **Nothing verifies the `Systemd_Filter` values are correct.** A wrong unit name passes
    both the dry-run and the startup check, and yields zero records forever. With
    forward-only output and no receiver, that state is indistinguishable from the expected
    one. Only the manual smoke closes this, and a runbook is not a test.

*   **No assertion that the base image still ships Fluent Bit.** If an ACOS bump removes
    `fluent-bit.service`, `systemctl restart` fails, `entrypoint.sh` runs without `set -e`,
    and boot continues silently with no logging. Considered and consciously declined as
    scope; revisit if base-image bumps prove disruptive.

*   **The receiver is a contract we are writing one half of.** `192.168.100.2:24224` and the
    `kps.*` tags require a matching stanza in go-tpm-tools that does not exist yet.

*   **Sustained backpressure is the launch state, not an edge case.** Until the receiver
    lands, both inputs will fill and pause, and the KPS VM emits connection-refused retries
    into its own journal — which we do not collect, by design.

---

## Next steps

**Immediately after this lands, in this repo:**

1.  **Task 4 — stamp `kps_boot_token` on agent logs.** The value already exists as
    `grpcServer.bootToken`. Once `cmd/agent/main.go` uses structured logging, attach it to
    every record; it flows through journald → our `systemd` input → `forward` for free. It
    is safe to log: it is already sent to WSD over `insecure.NewCredentials()` gRPC.
2.  **Task 4 — `key_destruction_total{reason}`.** Two call sites:
    `workload_service/server.go:950` (`token_mismatch`) and `:976` (`heartbeat_failure`).
    This is what "telemetry from boot token mismatch" actually asks for.
3.  **Tasks 3+4 — structured logging.** Replace stdlib `log` in `cmd/agent/main.go`,
    `workload_service/server.go`, and `keymanager/attestation_service/server/main.go` with
    `slog` JSON to stdout. It reaches the journal unchanged and arrives at the receiver as
    structured fields rather than an opaque `MESSAGE` string.

**Cross-cutting, owned elsewhere:**

*   **When the default-drop firewall lands,** it must allow egress to
    `192.168.100.2:24224/tcp` and return traffic for it. The described posture (drop by
    default; allow only ingress gRPC from the workload VM and loopback) would otherwise
    silence the relay without an error. Nothing in the tree implements that posture yet —
    `image/entrypoint.sh:45` is the only rule, and it is an `INPUT ACCEPT` under an already-ACCEPT
    policy.

**Blocked on go-tpm-tools:**

4.  **Add the receiver.** A `[INPUT] Name forward` stanza in
    `launcher/image/fluent-bit-cs.conf`, plus an inbound allow for `24224` on
    `192.168.100.2`. The existing `[OUTPUT] stackdriver Match *` then carries KPS records to
    Cloud Logging under logNames `kps.keymanager` and `kps.attestation`.
5.  **Then enable the real E2E test** (Task 8's final bullet), which is currently unbuildable.

**Deferred, and worth revisiting deliberately:**

6.  **Guest metrics.** Not via `cpu`/`mem`/`netif` into `stackdriver` — those arrive as log
    entries and bill as log ingestion. If guest host metrics are wanted, use Fluent Bit's
    real metrics pipeline (`node_exporter_metrics` input → OTLP/Prometheus output) to a
    metrics receiver. Pin the guest NIC name in `image/network_setup.sh` first; it currently
    matches on `Driver=virtio_net` and never on a name, so nothing determines whether the
    interface is `eth0` or `ens4`.
7.  **Severity mapping.** The workload VM's `stackdriver` output sets `severity_key severity`,
    but journal records carry `PRIORITY`, not `severity`. Nothing currently maps one to the
    other — including in go-tpm-tools' own config — so all records likely land at default
    severity. A `modify`/`lua` filter would fix it for both repos.
8.  **Task 1 is blocked as written.** Rust cannot write to `/run/systemd/journal/socket`:
    that socket is not mounted into the container (`kps_runner.sh` mounts only
    `/run/container_launcher`). Either add the bind mount, or drop the requirement — logging
    to stderr already reaches journald via the container's inherited stdio, which is how
    every KPS log gets there today.
9.  **Task 8's KCC stress test presupposes the journal socket.** "Filling up
    `/run/systemd/journal/socket`" is not reachable from inside the container as configured.
    Re-scope alongside item 8.
10. **Consider `containerd.service` in the input filter** if boot-time failures of
    `keymanager.service` prove hard to diagnose from the debug image alone.
