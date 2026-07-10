//! Minimal test fixture binary for release-workflows' selftest.yml.
//!
//! Exercises the reusable release pipeline (build, test, package, archive)
//! without pulling in any dependencies, so CI runs stay fast.

const NAME: &str = "fixture-cli";
const VERSION: &str = env!("CARGO_PKG_VERSION");

fn run(args: &[String]) -> String {
    match args.first().map(String::as_str) {
        Some("--version") | Some("-V") => format!("{NAME} {VERSION}"),
        Some("--help") | Some("-h") => {
            format!("{NAME} {VERSION}\nUsage: {NAME} [--version|--help]")
        }
        _ => format!("Hello from {NAME} {VERSION}"),
    }
}

fn main() {
    let args: Vec<String> = std::env::args().skip(1).collect();
    println!("{}", run(&args));
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn version_flag_includes_crate_version() {
        let out = run(&["--version".to_string()]);
        assert!(out.contains(VERSION));
        assert!(out.contains(NAME));
    }

    #[test]
    fn help_flag_includes_usage() {
        let out = run(&["--help".to_string()]);
        assert!(out.contains("Usage"));
    }

    #[test]
    fn default_greets() {
        let out = run(&[]);
        assert!(out.contains("Hello from"));
    }
}
