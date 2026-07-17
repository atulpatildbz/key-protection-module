fn install() {
    std::panic::set_hook(Box::new(|_| {}));
    tracing::error!("first event");
    tracing::warn!("unreviewed second event");
}
