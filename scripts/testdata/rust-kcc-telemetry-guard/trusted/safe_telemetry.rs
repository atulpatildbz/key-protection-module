fn install() {
    std::panic::set_hook(Box::new(|_| {}));
    tracing::error!("fixed sanitized event");
}
