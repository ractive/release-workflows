//! The `fixture-cli-two` binary, the selftest's second caller (see lib.rs).

fn main() {
    let args: Vec<String> = std::env::args().skip(1).collect();
    println!("{}", fixture_cli::run(env!("CARGO_BIN_NAME"), &args));
}
