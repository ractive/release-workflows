//! Minimal test fixture for release-workflows' selftest.yml.
//!
//! Exercises the reusable release pipeline (build, test, package, archive)
//! without pulling in any dependencies, so CI runs stay fast. Two binaries
//! share this code: `fixture-cli` and `fixture-cli-two` (the package of that
//! name in crates/two-cli), so the selftest can run two callers of
//! release.yml in one run, one bin-name the prefix of the other.

/// The reply to `args` for the binary called `name`.
pub fn run(name: &str, args: &[String]) -> String {
    let version = env!("CARGO_PKG_VERSION");
    match args.first().map(String::as_str) {
        Some("--version") | Some("-V") => format!("{name} {version}"),
        Some("--help") | Some("-h") => {
            format!("{name} {version}\nUsage: {name} [--version|--help]")
        }
        _ => format!("Hello from {name} {version}"),
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    const NAME: &str = "fixture-cli";

    #[test]
    fn version_flag_includes_crate_version() {
        let out = run(NAME, &["--version".to_string()]);
        assert!(out.contains(env!("CARGO_PKG_VERSION")));
        assert!(out.contains(NAME));
    }

    #[test]
    fn help_flag_includes_usage() {
        let out = run(NAME, &["--help".to_string()]);
        assert!(out.contains("Usage"));
    }

    #[test]
    fn default_greets() {
        let out = run(NAME, &[]);
        assert!(out.contains("Hello from"));
    }
}
