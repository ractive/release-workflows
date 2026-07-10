# release-workflows

Shared, reusable GitHub Actions release workflows for ractive's Rust CLI
repositories (currently [hyalo](https://github.com/ractive/hyalo),
[hoppy](https://github.com/ractive/hoppy), and
[ff-rdp](https://github.com/ractive/ff-rdp)).

Each app repo keeps a thin caller workflow that invokes the reusable
workflows here via `workflow_call`. All build, package, security-scan,
publish, and package-manager logic lives in this repo so it's fixed once and
inherited everywhere.

## Why fully self-contained

Reusable workflows run their jobs against the **calling** repository's
checkout, not this one. That means composite actions or scripts checked out
from this repo would resolve against the wrong tree at runtime. So
`release.yml` and `publish-crates.yml` are single files with everything
inlined — including a duplicated crates.io publish retry loop. That
duplication is intentional; see the comment at the top of each file.

## Workflows

| File | Trigger | Purpose |
| --- | --- | --- |
| `.github/workflows/release.yml` | `workflow_call` | Full release pipeline: version check, security audit, cross-platform build, optional SBOM/attestation/deb/rpm, GitHub release upload, crates.io, Homebrew, Scoop, winget. |
| `.github/workflows/publish-crates.yml` | `workflow_call` | Standalone crates.io publish loop — the recovery path for when `release.yml`'s `crates-io` job fails after the GitHub release itself has already succeeded. |
| `.github/workflows/ci.yml` | `push` to `main`, `pull_request` | Lints this repo's own workflow files with `actionlint`. |

## `release.yml` inputs

| Input | Type | Default | Description |
| --- | --- | --- | --- |
| `bin-name` | string | *(required)* | Binary name, e.g. `hyalo`. |
| `version-package` | string | *(required)* | Cargo package whose version must match the release tag, e.g. `hyalo-cli`. |
| `publish-crates` | string | `""` | Comma-separated, dependency-ordered list of crates to publish to crates.io. Empty skips crates.io. |
| `targets` | string (JSON) | 7-target union (see below) | JSON array of `{"target", "os", "cross", "run_tests"}` matrix entries. |
| `enable-sbom` | boolean | `true` | Generate a CycloneDX SBOM via `cargo-cyclonedx` on native (non-cross) targets. |
| `enable-attestation` | boolean | `true` | Attest build provenance via `actions/attest-build-provenance` on native targets. Cross containers lack OIDC, so cross targets are always skipped. Skipped entirely in dry-run. |
| `enable-linux-packages` | boolean | `false` | Build `.deb` and `.rpm` packages from a native `x86_64-unknown-linux-gnu` build via `cargo-deb` + `cargo-generate-rpm`. |
| `linux-package-crate` | string | `""` | Crate to package for deb/rpm. Empty falls back to `version-package`. |
| `pre-package-command` | string | `""` | Bash command run after the native build, before archiving/packaging (e.g. generate shell completions or man pages). Runs on native builds only. `TARGET`, `BIN_NAME`, `VERSION` are exported into its environment. |
| `extra-archive-paths` | string | `""` | Newline- or space-separated extra paths (relative to workspace root) to include in archives alongside the binary, `LICENSE`, and `README.md`. |
| `winget-identifier` | string | `""` | e.g. `ractive.hyalo`. Empty skips winget. |
| `winget-pkgs-fork` | string | `"ractive/winget-pkgs"` | Owner/repo of the winget-pkgs fork to sync and submit from. |
| `homebrew-tap` | string | `"ractive/homebrew-tap"` | Homebrew tap repository to publish the formula to. |
| `homebrew-formula` | string | `""` | Formula file name (without `.rb`). Empty falls back to `bin-name`. |
| `scoop-bucket` | string | `"ractive/scoop-bucket"` | Scoop bucket repository to publish the manifest to. |
| `dry-run` | boolean | `false` | Build, test, package, and upload as workflow artifacts only. Skips tag verification (derives version from `cargo metadata` instead), GitHub release upload, crates.io, Homebrew, Scoop, winget, and attestation. |

Default `targets`:

```json
[
  {"target": "x86_64-unknown-linux-gnu",   "os": "ubuntu-latest",  "cross": false, "run_tests": true},
  {"target": "x86_64-unknown-linux-musl",  "os": "ubuntu-latest",  "cross": true,  "run_tests": true},
  {"target": "aarch64-unknown-linux-gnu",  "os": "ubuntu-latest",  "cross": true,  "run_tests": true},
  {"target": "aarch64-unknown-linux-musl", "os": "ubuntu-latest",  "cross": true,  "run_tests": true},
  {"target": "aarch64-apple-darwin",       "os": "macos-latest",   "cross": false, "run_tests": true},
  {"target": "x86_64-pc-windows-msvc",     "os": "windows-latest", "cross": false, "run_tests": true},
  {"target": "aarch64-pc-windows-msvc",    "os": "windows-latest", "cross": false, "run_tests": false}
]
```

Archive/package artifact names are standardized on the versioned form:
`<bin-name>-v<version>-<target>.tar.gz` (Unix) / `.zip` (Windows), and
`<bin-name>-v<version>-x86_64-linux.deb` / `.rpm` for Linux packages. The
Homebrew and Scoop jobs look for artifacts using exactly this naming, so
`bin-name` must match what callers expect.

## `publish-crates.yml` inputs

| Input | Type | Default | Description |
| --- | --- | --- | --- |
| `publish-crates` | string | *(required)* | Comma-separated, dependency-ordered list of crates to publish. |
| `ref` | string | `""` | Git ref (tag/branch/sha) to check out and publish from. Empty uses the triggering ref. |

## Secrets

Callers should pass `secrets: inherit` — do not declare a `secrets:` block.
The reusable workflows read repository secrets directly, and only require
the secret for a feature that's actually enabled:

| Secret | Required when | Used by |
| --- | --- | --- |
| `CARGO_TOKEN` | `publish-crates` is non-empty | `release.yml` (`crates-io` job), `publish-crates.yml` |
| `HOMEBREW_TAP_TOKEN` | always (Homebrew job always runs unless `dry-run`) | `release.yml` (`homebrew` job) |
| `SCOOP_BUCKET_TOKEN` | always (Scoop job always runs unless `dry-run`) | `release.yml` (`scoop` job) |
| `WINGET_TOKEN` | `winget-identifier` is non-empty | `release.yml` (`winget` job) |

`GH_TOKEN`/`github.token` (the automatic `GITHUB_TOKEN`) is used for release
asset upload/download and needs no configuration beyond the permissions
below.

## Required caller permissions

Callers must grant these permissions to the calling workflow (they flow
through to the reusable workflow's jobs):

```yaml
permissions:
  contents: write       # GitHub release asset upload
  id-token: write        # OIDC token for build provenance attestation
  attestations: write     # write attestations to the repo's attestation store
```

If `enable-attestation` is `false`, `id-token`/`attestations` can be omitted.

## Example callers

### hyalo

```yaml
# .github/workflows/release.yml
name: Release
on:
  release:
    types: [published]
permissions:
  contents: write
  id-token: write
  attestations: write
jobs:
  release:
    uses: ractive/release-workflows/.github/workflows/release.yml@v1.0.0
    secrets: inherit
    with:
      bin-name: hyalo
      version-package: hyalo-cli
      publish-crates: hyalo-core,hyalo-mdlint,hyalo-cli
      winget-identifier: ractive.hyalo
```

### hoppy

hoppy links OpenSSL, so it cannot use the default musl targets, and it needs
Linux packages plus a pre-package step to generate shell completions and man
pages before archiving/packaging:

```yaml
# .github/workflows/release.yml
name: Release
on:
  release:
    types: [published]
permissions:
  contents: write
  id-token: write
  attestations: write
jobs:
  release:
    uses: ractive/release-workflows/.github/workflows/release.yml@v1.0.0
    secrets: inherit
    with:
      bin-name: hoppy
      version-package: hoppy-cli
      publish-crates: bunny-net-api,bunny-syslog-receiver,hoppy-cli
      enable-linux-packages: true
      pre-package-command: |
        mkdir -p completions man
        if [ "$TARGET" = "aarch64-pc-windows-msvc" ] || [ "$TARGET" = "aarch64-unknown-linux-gnu" ]; then
          cargo run --release -- completions bash  > completions/hoppy.bash
          cargo run --release -- completions zsh   > completions/_hoppy
          cargo run --release -- completions fish  > completions/hoppy.fish
        else
          BIN="target/$TARGET/release/hoppy"
          [ -f "${BIN}.exe" ] && BIN="${BIN}.exe"
          "$BIN" completions bash > completions/hoppy.bash
          "$BIN" completions zsh  > completions/_hoppy
          "$BIN" completions fish > completions/hoppy.fish
        fi
        cargo xtask --output-dir man
      extra-archive-paths: completions man
      targets: >-
        [
          {"target": "x86_64-unknown-linux-gnu",  "os": "ubuntu-latest",  "cross": false, "run_tests": true},
          {"target": "aarch64-unknown-linux-gnu", "os": "ubuntu-latest",  "cross": true,  "run_tests": false},
          {"target": "aarch64-apple-darwin",      "os": "macos-latest",  "cross": false, "run_tests": true},
          {"target": "x86_64-pc-windows-msvc",    "os": "windows-latest", "cross": false, "run_tests": true},
          {"target": "aarch64-pc-windows-msvc",   "os": "windows-latest", "cross": false, "run_tests": false}
        ]
```

> Note: hoppy's upstream workflow builds completions/man pages via a separate
> step per OS (bash on Unix, pwsh on Windows) and additionally packages
> `.deb`/`.rpm` from a dedicated native build with its own completions/man
> generation. `pre-package-command` above covers the archive path; the
> `enable-linux-packages` job runs the same generation independently against
> its own native build, matching upstream's structure.

### ff-rdp

```yaml
# .github/workflows/release.yml
name: Release
on:
  release:
    types: [published]
permissions:
  contents: write
  id-token: write
  attestations: write
jobs:
  release:
    uses: ractive/release-workflows/.github/workflows/release.yml@v1.0.0
    secrets: inherit
    with:
      bin-name: ff-rdp
      version-package: ff-rdp-cli
      publish-crates: ff-rdp-core,ff-rdp-cli
      winget-identifier: ractive.ff-rdp
      targets: >-
        [
          {"target": "x86_64-unknown-linux-gnu",   "os": "ubuntu-latest",  "cross": false, "run_tests": true},
          {"target": "x86_64-unknown-linux-musl",  "os": "ubuntu-latest",  "cross": true,  "run_tests": false},
          {"target": "aarch64-unknown-linux-musl", "os": "ubuntu-latest",  "cross": true,  "run_tests": false},
          {"target": "aarch64-apple-darwin",       "os": "macos-latest",  "cross": false, "run_tests": true},
          {"target": "x86_64-pc-windows-msvc",     "os": "windows-latest", "cross": false, "run_tests": false},
          {"target": "aarch64-pc-windows-msvc",    "os": "windows-latest", "cross": false, "run_tests": false}
        ]
```

### Dry-run caller (validate the pipeline without cutting a release)

```yaml
# .github/workflows/release-dry-run.yml
name: Release dry run
on:
  workflow_dispatch: {}
permissions:
  contents: read
jobs:
  dry-run:
    uses: ractive/release-workflows/.github/workflows/release.yml@v1.0.0
    secrets: inherit
    with:
      bin-name: hyalo
      version-package: hyalo-cli
      dry-run: true
```

Trigger it manually from the Actions tab. It builds, tests, packages, and
generates `SHA256SUMS`, then uploads everything as one `dry-run-bundle`
workflow artifact and prints a file/size table to the job summary — nothing
is published anywhere.

### Recovery: standalone crates.io publish

App repos keep a thin recovery workflow so a failed `crates-io` job can be
retried against a fixed-up `main` without re-running the whole release:

```yaml
# .github/workflows/publish-crates.yml
name: Publish crates
on:
  workflow_dispatch:
    inputs:
      ref:
        description: "Git ref (tag/branch/sha) to publish from"
        required: false
        default: "main"
permissions:
  contents: read
jobs:
  publish:
    uses: ractive/release-workflows/.github/workflows/publish-crates.yml@v1.0.0
    secrets: inherit
    with:
      publish-crates: hyalo-core,hyalo-mdlint,hyalo-cli
      ref: ${{ inputs.ref }}
```

## Versioning policy

Releases are cut with `gh release create vX.Y.Z` (never manual tags — the
release event triggers the app repos' own `release.yml`, which is separate
from this repo's release process). Callers pin to a specific tag:

```yaml
uses: ractive/release-workflows/.github/workflows/release.yml@v1.0.0
```

Do not pin to `@main` — an unreviewed change here would immediately affect
every consuming repo's next release.

## What callers must provide

- A `LICENSE` and `README.md` at the workspace root (both are copied into
  every archive when present; missing files are silently skipped, not an
  error).
- For `enable-linux-packages: true`: `[package.metadata.deb]` and
  `[package.metadata.generate-rpm]` sections in the packaged crate's
  `Cargo.toml`, with asset paths resolved relative to that crate's directory
  (see hoppy's `crates/hoppy-cli/Cargo.toml` for a worked example — assets
  must already exist on disk when `cargo deb`/`cargo generate-rpm` run, which
  is why `pre-package-command` also runs before the `linux-packages` job's
  packaging steps).
- A `Cross.toml` at the workspace root with `[build.env] passthrough =
  ["GIT_COMMIT", "GIT_COMMIT_DATE"]` if the crate's `build.rs` uses those
  variables for hermetic build provenance — required for cross-compiled
  targets to get correct output; native targets get them from the workflow's
  own `$GITHUB_ENV` regardless.
- Repository secrets as documented above, scoped per the permissions table.
- Existing Homebrew tap (`ractive/homebrew-tap`), Scoop bucket
  (`ractive/scoop-bucket`), and — for winget — an existing, already-synced
  fork of `microsoft/winget-pkgs` under the `ractive` org. `winget-releaser`
  can only update packages that already exist upstream; the first submission
  of a new package must be done manually via PR to `microsoft/winget-pkgs`.
