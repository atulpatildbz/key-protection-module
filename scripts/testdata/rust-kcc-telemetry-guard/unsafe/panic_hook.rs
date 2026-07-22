fn install_hook() {
    std::panic::set_hook(Box::new(|_| {}));
}
