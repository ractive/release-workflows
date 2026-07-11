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
| `.github/workflows/cloudsmith-republish.yml` | `workflow_call` | Standalone Cloudsmith publish — (re)pushes an existing release's `.deb`/`.rpm` assets. For failed cloudsmith jobs or repositories created/renamed after the release ran (release runs pin inputs at tag time). Inputs: `tag`, `cloudsmith-repo`. |
| `.github/workflows/ci.yml` | `push` to `main`, `pull_request` | Lints this repo's own workflow files with `actionlint` and `zizmor`. |
| `.github/workflows/selftest.yml` | `push` to `main`, `pull_request` | Calls `release.yml` (from this same repo, at the triggering commit) against the `testdata/fixture-cli` fixture crate in `dry-run` mode — end-to-end validation of the pipeline itself. See [Testing](#testing). |

## `release.yml` inputs

| Input | Type | Default | Description |
| --- | --- | --- | --- |
| `bin-name` | string | *(required)* | Binary name, e.g. `hyalo`. |
| `version-package` | string | *(required)* | Cargo package whose version must match the release tag, e.g. `hyalo-cli`. |
| `workspace-dir` | string | `"."` | Path, relative to the caller repo root, to the Cargo workspace to build. Every `cargo`/`cross`/`cargo-deb`/`cargo-generate-rpm` invocation runs with this as its working directory. Used by `selftest.yml` to point at `testdata/fixture-cli`; app repos normally leave this at the default. |
| `publish-crates` | string | `""` | Comma-separated, dependency-ordered list of crates to publish to crates.io. Empty skips crates.io. |
| `targets` | string (JSON) | 7-target union (see below) | JSON array of `{"target", "os", "cross", "run_tests"}` matrix entries. |
| `enable-sbom` | boolean | `true` | Generate a CycloneDX SBOM via `cargo-cyclonedx` on native (non-cross) targets. |
| `sbom-packages` | string | `""` | Comma-separated packages to attach SBOMs for. Empty falls back to `version-package` only. The `version-package` SBOM is named `<archive>.cdx.json`; extras are `<archive>-<package>.cdx.json`. |
| `enable-attestation` | boolean | `true` | Attest build provenance via `actions/attest-build-provenance` on native targets. Cross containers lack OIDC, so cross targets are always skipped. Skipped entirely in dry-run. |
| `enable-linux-packages` | boolean | `false` | Build `.deb` and `.rpm` packages from a native `x86_64-unknown-linux-gnu` build via `cargo-deb` + `cargo-generate-rpm`. |
| `linux-package-crate` | string | `""` | Crate to package for deb/rpm. Empty falls back to `version-package`. |
| `pre-package-command` | string | `""` | Bash command run after the build, before archiving/packaging (e.g. generate shell completions or man pages). Runs on every matrix target and in the linux-packages job. `TARGET`, `CROSS`, `BIN_NAME`, `VERSION`, `BIN_PATH` are exported; `BIN_PATH` is the built binary (relative to workspace-dir, `.exe` resolved on Windows). When `CROSS=true` that binary is not host-runnable, so produce files with a host build (e.g. `cargo run --bin <bin> --`) instead. |
| `extra-archive-paths` | string | `""` | Newline- or space-separated extra paths (relative to workspace root) to include in archives alongside the binary, `LICENSE`, and `README.md`. |
| `winget-identifier` | string | `""` | e.g. `ractive.hyalo`. Empty skips winget. |
| `winget-pkgs-fork` | string | `"ractive/winget-pkgs"` | Owner/repo of the winget-pkgs fork to sync and submit from. |
| `homebrew-tap` | string | `"ractive/homebrew-tap"` | Homebrew tap repository to publish the formula to. |
| `homebrew-formula` | string | `""` | Formula file name (without `.rb`). Empty falls back to `bin-name`. |
| `homebrew-description` | string | `""` | Description for the Homebrew formula `desc` and the Scoop manifest. Empty falls back to the `version-package` crate's `description` in Cargo.toml, then to `"<bin-name> CLI"` — so most callers never set this. |
| `homebrew-caveats` | string | `""` | Formula caveats text, rendered inside a `def caveats` / `<<~EOS` block. Empty omits the caveats block entirely. |
| `scoop-bucket` | string | `"ractive/scoop-bucket"` | Scoop bucket repository to publish the manifest to. |
| `aur-package` | string | `""` | AUR package name, e.g. `hyalo-bin`. Empty skips AUR. |
| `aur-maintainer` | string | `"Jean-Pierre Bergamin <james@ractive.ch>"` | Rendered as the `# Maintainer:` PKGBUILD comment. |
| `cloudsmith-repo` | string | `""` | Cloudsmith org/repo slug, one Cloudsmith repo per project, e.g. `ractive/hoppy`. Empty skips Cloudsmith. |
| `dry-run` | boolean | `false` | Build, test, package, and upload as workflow artifacts only. Skips tag verification (derives version from `cargo metadata` instead), GitHub release upload, crates.io, Homebrew, Scoop, winget, AUR, and Cloudsmith. |

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
| `AUR_SSH_PRIVATE_KEY` | `aur-package` is non-empty | `release.yml` (`aur` job) |
| `CLOUDSMITH_API_KEY` | `cloudsmith-repo` is non-empty | `release.yml` (`cloudsmith` job) |

`GH_TOKEN`/`github.token` (the automatic `GITHUB_TOKEN`) is used for release
asset upload/download and needs no configuration beyond the permissions
below.

## Required caller permissions

Callers must grant these permissions to the calling job:

```yaml
permissions:
  contents: write       # GitHub release asset upload
  id-token: write        # OIDC token for build provenance attestation
  attestations: write     # write attestations to the repo's attestation store
```

`release.yml` deliberately declares no workflow-level `permissions:` block.
Jobs that need a specific permission (e.g. `release`'s `contents: write`)
declare it themselves for least privilege, but `build` and `linux-packages`
declare none at all and instead **inherit whatever the caller granted**. This
is required, not incidental: a called workflow's job that explicitly
requests a permission the caller didn't grant hard-fails immediately, even
if the step that would need it is skipped at runtime. `build`'s attestation
step only needs `id-token`/`attestations` conditionally (`enable-attestation`
and not `dry-run`), so it cannot declare that requirement explicitly without
breaking every caller that doesn't grant it — including `selftest.yml`, whose
caller job only grants `contents: read`. Inheritance is the only shape that
serves both a full production release and a read-only dry-run from the same
job definition.

If `enable-attestation` is `false`, `id-token`/`attestations` can be omitted
from the caller's grant.

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
    uses: ractive/release-workflows/.github/workflows/release.yml@v0.1.0
    secrets: inherit
    with:
      bin-name: hyalo
      version-package: hyalo-cli
      publish-crates: hyalo-core,hyalo-mdlint,hyalo-cli
      winget-identifier: ractive.hyalo
      # AUR and Cloudsmith both require account/repo setup first — see
      # "Linux distro publishing" above. Uncomment once that's done:
      # aur-package: hyalo-bin
      # cloudsmith-repo: ractive/hyalo
```

The Homebrew/Scoop description is derived automatically from `hyalo-cli`'s
`description` field in Cargo.toml.

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
    uses: ractive/release-workflows/.github/workflows/release.yml@v0.1.0
    secrets: inherit
    with:
      bin-name: hoppy
      version-package: hoppy-cli
      publish-crates: bunny-net-api,bunny-syslog-receiver,hoppy-cli
      enable-linux-packages: true
      pre-package-command: |
        mkdir -p completions man
        if [ "$CROSS" = "true" ] || [ "$TARGET" = "aarch64-pc-windows-msvc" ]; then
          # Target binary is not host-runnable: generate with a host build.
          # --bin disambiguates: hoppy-cli ships more than one binary.
          cargo run --release --bin hoppy -- completions bash  > completions/hoppy.bash
          cargo run --release --bin hoppy -- completions zsh   > completions/_hoppy
          cargo run --release --bin hoppy -- completions fish  > completions/hoppy.fish
        else
          "$BIN_PATH" completions bash > completions/hoppy.bash
          "$BIN_PATH" completions zsh  > completions/_hoppy
          "$BIN_PATH" completions fish > completions/hoppy.fish
        fi
        case "$TARGET" in
          # Man pages are not used on Windows, and hoppy's debug xtask
          # overflows the 1 MB MSVC stack; the empty man/ dir keeps
          # extra-archive-paths satisfied.
          *windows*) ;;
          *) cargo xtask --output-dir man ;;
        esac
        # cargo-deb / cargo-generate-rpm resolve [package.metadata.*] asset
        # paths relative to the crate directory:
        mkdir -p crates/hoppy-cli/completions crates/hoppy-cli/man
        cp completions/* crates/hoppy-cli/completions/
        if [ "$(ls -A man)" ]; then cp man/* crates/hoppy-cli/man/; fi
      extra-archive-paths: completions man
      homebrew-caveats: |
        hoppy container logs requires bore for automatic tunnel setup:
          cargo install bore-cli
          brew install bore-cli
        This is optional — see `hoppy container logs --help` for tunnel alternatives.
      # Publishes deb/rpm to the hosted apt/yum repos (CLOUDSMITH_API_KEY
      # secret required); see "Linux distro publishing" above:
      cloudsmith-repo: ractive/hoppy
      # AUR requires account/SSH-key setup first — uncomment once done:
      # aur-package: hoppy-bin
      # run_tests is false everywhere: hoppy's release pipeline has never run
      # tests (PR CI covers them, on ubuntu). Its Windows CLI tests overflow
      # the default 1 MB MSVC stack, so enabling them here would break.
      targets: >-
        [
          {"target": "x86_64-unknown-linux-gnu",  "os": "ubuntu-latest",  "cross": false, "run_tests": false},
          {"target": "aarch64-unknown-linux-gnu", "os": "ubuntu-latest",  "cross": true,  "run_tests": false},
          {"target": "aarch64-apple-darwin",      "os": "macos-latest",  "cross": false, "run_tests": false},
          {"target": "x86_64-pc-windows-msvc",    "os": "windows-latest", "cross": false, "run_tests": false},
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
    uses: ractive/release-workflows/.github/workflows/release.yml@v0.1.0
    secrets: inherit
    with:
      bin-name: ff-rdp
      version-package: ff-rdp-cli
      publish-crates: ff-rdp-core,ff-rdp-cli
      winget-identifier: ractive.ff-rdp
      # ff-rdp ships SBOMs for both published crates, not just the CLI:
      sbom-packages: ff-rdp-cli,ff-rdp-core
      # AUR requires account setup first — see "Linux distro publishing"
      # above. Uncomment once that's done. (No Cloudsmith example here:
      # ff-rdp doesn't set enable-linux-packages, so there's nothing to push.)
      # aur-package: ff-rdp-bin
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
    uses: ractive/release-workflows/.github/workflows/release.yml@v0.1.0
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
    uses: ractive/release-workflows/.github/workflows/publish-crates.yml@v0.1.0
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
uses: ractive/release-workflows/.github/workflows/release.yml@v0.1.0
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

## Linux distro publishing

Two optional, non-blocking jobs (`continue-on-error: true`, same stance as
`winget`) publish Linux packages beyond the GitHub release assets.

**Both ship disabled by default.** `aur-package` and `cloudsmith-repo` both
default to `""`, and each job's `if:` condition requires its input to be
non-empty (`aur`: `inputs.aur-package != ''`; `cloudsmith`: additionally
`inputs.enable-linux-packages && inputs.cloudsmith-repo != ''`) — so no
existing caller (hyalo, hoppy, ff-rdp) is affected by this feature landing.
They also skip in `dry-run` regardless. A repo enables one or both by setting
the corresponding input once the one-time account/secret setup below is
done; until then, this section describes capability, not current behavior.

### AUR (`aur-package`)

Generates a `PKGBUILD` and pushes it to the [Arch User
Repository](https://aur.archlinux.org) via
[`KSXGitHub/github-actions-deploy-aur`](https://github.com/KSXGitHub/github-actions-deploy-aur).
One `PKGBUILD` covers all three app repos: `pkgdesc` uses the same
`homebrew-description` → Cargo.toml `description` → `"<bin-name> CLI"`
precedence as Homebrew/Scoop, `arch=()`/`source_<arch>=()` entries are
emitted only for architectures with an artifact in `SHA256SUMS` (same
musl-preferred-over-gnu selection as the Homebrew job), and `package()`
conditionally installs `LICENSE`, `README.md`, shell completions
(`completions/<bin>.bash`, `completions/_<bin>`, `completions/<bin>.fish`),
and man pages (`man/*.1`) only when those paths exist in the archive —
so hoppy's completions/man pages install correctly while hyalo/ff-rdp (which
don't ship them) get a `PKGBUILD` that just skips those `install` calls.

**One-time setup:**
1. Create an account at [aur.archlinux.org](https://aur.archlinux.org).
2. Generate an SSH key pair dedicated to this purpose; add the **public**
   key to the account at <https://aur.archlinux.org/account/> (SSH Public
   Key field).
3. Store the **private** key as the repository secret `AUR_SSH_PRIVATE_KEY`.
4. The first workflow push auto-creates the AUR package — no separate manual
   submission step, unlike winget.

**User-facing install** (once published):
```bash
yay -S hyalo-bin
# or any other AUR helper, e.g. paru -S hyalo-bin
```

### Cloudsmith (`cloudsmith-repo`)

Pushes the `.deb`/`.rpm` artifacts already built by `enable-linux-packages`
to a [Cloudsmith](https://cloudsmith.com) repository, using
[`cloudsmith-cli`](https://github.com/cloudsmith-io/cloudsmith-cli)
(installed pinned via `uvx --from cloudsmith-cli==<version>`, same pattern as
`zizmor` in `ci.yml`). Requires `enable-linux-packages: true` — there's
nothing to push otherwise. Both formats push to Cloudsmith's documented
`any-distro/any-version` wildcard distribution
([deb docs](https://docs.cloudsmith.com/formats/debian-repository),
[rpm docs](https://docs.cloudsmith.com/formats/redhat-repository)), which
accepts the package for any Debian/RedHat-family distribution rather than
pinning to one distro codename — the right default for a package built
generically by `cargo-deb`/`cargo-generate-rpm` rather than targeting a
specific distro's toolchain.

**One-time setup:**
1. Create a Cloudsmith organization and a repository within it.
2. Apply for Cloudsmith's [open-source
   plan](https://cloudsmith.com/pricing/) (free hosting for qualifying OSS
   projects).
3. Create an API key under the organization/repository settings.
4. Store it as the repository secret `CLOUDSMITH_API_KEY`.

**User-facing install** (once published; replace `<org>`/`<repo>` — this is
Cloudsmith's own documented "Set Me Up" one-liner form, see
[deb](https://docs.cloudsmith.com/formats/debian-repository)/[rpm](https://docs.cloudsmith.com/formats/redhat-repository)
docs for the always-current version):
```bash
# Debian/Ubuntu
curl -sLf 'https://dl.cloudsmith.io/public/ractive/<project>/cfg/setup/bash.deb.sh' | sudo bash
sudo apt install <bin-name>

# Fedora/RHEL/openSUSE (yum/dnf/zypper)
curl -sLf 'https://dl.cloudsmith.io/public/ractive/<project>/cfg/setup/bash.rpm.sh' | sudo bash
sudo dnf install <bin-name>   # or yum / zypper
```

## Testing

This repo tests itself at three layers, each catching a different class of
problem before it reaches an app repo's actual release:

### 1. actionlint — syntax and shell correctness

`ci.yml`'s `actionlint` job runs [actionlint](https://github.com/rhysd/actionlint)
over every workflow file: YAML/expression syntax errors, invalid `uses:`
references, type mismatches against `workflow_call` inputs, and — via its
bundled shellcheck integration — common shell scripting bugs in `run:` steps
(unquoted variables, unsafe globs, etc). This catches "the workflow won't
even parse" and "this shell one-liner breaks on a filename with a space"
class bugs, but it has no idea what the workflow's steps actually *do* at
runtime.

### 2. zizmor — GitHub Actions security static analysis

`ci.yml`'s `zizmor` job runs [zizmor](https://docs.zizmor.sh) (pinned via
`uvx --from zizmor==<version>`) over every workflow file: template-injection
risks (untrusted `${{ }}` expansion spliced directly into a shell command
rather than passed through `env:`), credential-persistence issues
(`actions/checkout` leaking a token into an uploaded artifact), overbroad
permissions, and similar. Findings must be fixed, not silenced — the only
suppressions in this repo live in the committed [`zizmor.yml`](zizmor.yml),
each with a comment explaining why it's a deliberate, reviewed exception
(currently: two `use-trusted-publishing` findings recommending crates.io's
OIDC-based trusted publishing over a long-lived `CARGO_TOKEN`, which would
require reconfiguring publish rights for eight crates across three repos —
tracked as a real follow-up, not dismissed as a false positive).

### 3. selftest.yml — end-to-end dry-run against a fixture crate

`selftest.yml` calls `release.yml` **from this same repo**
(`uses: ./.github/workflows/release.yml`, which is valid for `workflow_call`
and resolves at the triggering commit's SHA) against
[`testdata/fixture-cli`](testdata/fixture-cli), a minimal, dependency-free
Cargo workspace built specifically to exercise this pipeline. It runs with
`dry-run: true`, `enable-sbom: true`, and `enable-linux-packages: true`
across a 4-target matrix chosen to cover each distinct code path once:

| Target | OS | Path exercised |
| --- | --- | --- |
| `x86_64-unknown-linux-gnu` | `ubuntu-latest` | Native build + test + SBOM + attestation-eligible path |
| `x86_64-unknown-linux-musl` | `ubuntu-latest` | `cross`-containerized build (the `Cross.toml`/glibc-cache-poisoning path) |
| `aarch64-apple-darwin` | `macos-latest` | Native macOS build |
| `x86_64-pc-windows-msvc` | `windows-latest` | Windows `.zip` archive path (`7z`) |

This means every PR to this repo gets real end-to-end validation of build,
test, archive naming, SBOM generation, deb/rpm packaging, `SHA256SUMS`
generation, and the dry-run summary — without touching crates.io, any
Homebrew tap, Scoop bucket, winget fork, or any of the three app repos.

### What's NOT covered by any of the above

The publish-side jobs — `crates-io`, `homebrew`, `scoop`, `winget` — are
skipped entirely in `dry-run` mode (see the `dry-run` input above), so
`selftest.yml` never exercises the real crates.io upload, the Homebrew tap
git push, the Scoop bucket git push, or the winget-releaser submission. Those
paths are only exercised by a real release (`release` event) in an app repo.
The [dry-run caller example](#dry-run-caller-validate-the-pipeline-without-cutting-a-release)
above gives app repos an additional pre-release check — run it manually
before cutting a tag to catch build/packaging problems without touching any
publish destination — but it still can't validate the publish steps
themselves. There is currently no automated test of the publish jobs; they
rely on the retry/idempotency logic (documented inline in `release.yml` and
`publish-crates.yml`) and on the "already uploaded/exists" and
"unchanged, skipping commit" guards behaving correctly in production.
