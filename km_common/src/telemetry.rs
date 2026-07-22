//! Sanitized telemetry infrastructure for Rust KCC FFI boundaries.

use crate::Status;
use std::io;
use std::sync::atomic::{AtomicU64, Ordering};
use std::sync::mpsc::{Receiver, SyncSender, TrySendError};
use std::sync::{Arc, OnceLock};
use tracing_subscriber::prelude::*;

const FAILURE_QUEUE_CAPACITY: usize = 256;

static PANIC_HOOK: std::sync::Once = std::sync::Once::new();
static FAILURE_REPORTER: OnceLock<Option<FailureReporter>> = OnceLock::new();

pub(crate) fn install_sanitized_panic_hook() {
    PANIC_HOOK.call_once(|| {
        std::panic::set_hook(Box::new(|_| {}));
    });
}

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum KccOperation {
    GenerateKemKeypair,
    DestroyKemKey,
    EnumerateKemKeys,
    DecapAndSeal,
    GetKemKey,
    GenerateBindingKeypair,
    DestroyBindingKey,
    DestroyAllBindingKeys,
    Open,
    EnumerateBindingKeys,
    GetBindingKey,
}

impl KccOperation {
    fn as_str(self) -> &'static str {
        match self {
            Self::GenerateKemKeypair => "generate_kem_keypair",
            Self::DestroyKemKey => "destroy_kem_key",
            Self::EnumerateKemKeys => "enumerate_kem_keys",
            Self::DecapAndSeal => "decap_and_seal",
            Self::GetKemKey => "get_kem_key",
            Self::GenerateBindingKeypair => "generate_binding_keypair",
            Self::DestroyBindingKey => "destroy_binding_key",
            Self::DestroyAllBindingKeys => "destroy_all_binding_keys",
            Self::Open => "open",
            Self::EnumerateBindingKeys => "enumerate_binding_keys",
            Self::GetBindingKey => "get_binding_key",
        }
    }
}

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub(crate) enum FailureKind {
    Error,
    Panic,
}

impl FailureKind {
    fn as_str(self) -> &'static str {
        match self {
            Self::Error => "error",
            Self::Panic => "panic",
        }
    }
}

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub(crate) struct Failure {
    pub(crate) operation: KccOperation,
    pub(crate) status: Status,
    pub(crate) kind: FailureKind,
}

#[derive(Clone, Copy)]
struct JournalEvent {
    failure: Failure,
    dropped_events: u64,
}

#[derive(Clone)]
struct FailureReporter {
    sender: SyncSender<JournalEvent>,
    dropped_events: Arc<AtomicU64>,
}

impl FailureReporter {
    fn spawn<F>(capacity: usize, worker: F) -> io::Result<Self>
    where
        F: FnOnce(Receiver<JournalEvent>) + Send + 'static,
    {
        let (sender, receiver) = std::sync::mpsc::sync_channel(capacity);
        std::thread::Builder::new()
            .name("rust-kcc-telemetry".to_owned())
            .spawn(move || worker(receiver))?;

        Ok(Self {
            sender,
            dropped_events: Arc::new(AtomicU64::new(0)),
        })
    }

    fn journald() -> io::Result<Self> {
        Self::spawn(FAILURE_QUEUE_CAPACITY, run_journald_worker)
    }

    fn report(&self, failure: Failure) {
        let event = JournalEvent {
            failure,
            dropped_events: self.dropped_events.load(Ordering::Relaxed),
        };

        if matches!(
            self.sender.try_send(event),
            Err(TrySendError::Full(_) | TrySendError::Disconnected(_))
        ) {
            self.dropped_events.fetch_add(1, Ordering::Relaxed);
        }
    }

    #[cfg(test)]
    fn dropped_events(&self) -> u64 {
        self.dropped_events.load(Ordering::Relaxed)
    }
}

fn run_journald_worker(receiver: Receiver<JournalEvent>) {
    let Ok(layer) = tracing_journald::layer() else {
        return;
    };
    let subscriber = tracing_subscriber::registry().with(
        layer
            .with_field_prefix(None)
            .with_syslog_identifier("rust-kcc".to_owned()),
    );

    tracing::subscriber::with_default(subscriber, || {
        for event in receiver {
            tracing::error!(
                target: "rust_kcc",
                operation = event.failure.operation.as_str(),
                status = event.failure.status.as_str_name(),
                failure_kind = event.failure.kind.as_str(),
                dropped_events = event.dropped_events,
                "kcc_operation_failed"
            );
        }
    });
}

pub(crate) fn report_failure(failure: Failure) {
    let reporter = FAILURE_REPORTER.get_or_init(|| FailureReporter::journald().ok());
    if let Some(reporter) = reporter {
        reporter.report(failure);
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::sync::mpsc;
    use std::time::Duration;

    fn sample_failure() -> Failure {
        Failure {
            operation: KccOperation::Open,
            status: Status::DecryptionFailure,
            kind: FailureKind::Error,
        }
    }

    #[test]
    fn a_full_failure_queue_does_not_block_the_producer() {
        let (worker_ready_tx, worker_ready_rx) = mpsc::channel();
        let (release_worker_tx, release_worker_rx) = mpsc::channel();
        let reporter = FailureReporter::spawn(1, move |receiver| {
            receiver.recv().expect("first event should arrive");
            worker_ready_tx
                .send(())
                .expect("test should observe the stalled worker");
            release_worker_rx
                .recv()
                .expect("test should release the stalled worker");
        })
        .expect("test worker should start");

        reporter.report(sample_failure());
        worker_ready_rx
            .recv_timeout(Duration::from_secs(1))
            .expect("worker should receive the first event");

        reporter.report(sample_failure());

        let producer = reporter.clone();
        let (producer_done_tx, producer_done_rx) = mpsc::channel();
        std::thread::spawn(move || {
            producer.report(sample_failure());
            producer_done_tx
                .send(())
                .expect("test should observe producer completion");
        });

        producer_done_rx
            .recv_timeout(Duration::from_secs(1))
            .expect("a full telemetry queue must not block the producer");
        assert_eq!(reporter.dropped_events(), 1);

        release_worker_tx
            .send(())
            .expect("stalled worker should still be alive");
    }
}
