# fixture-cli

A minimal, dependency-free test fixture used by
[`.github/workflows/selftest.yml`](../../.github/workflows/selftest.yml) to
exercise the `release.yml` reusable workflow end-to-end (build, test,
archive, SBOM, deb/rpm packaging, SHA256SUMS, dry-run summary) without
touching any of the real app repos.

Not a published crate — lives entirely under `testdata/` and is excluded
from the workspace at the repository root (there is no root `Cargo.toml`,
so this is a self-contained workspace of its own).
