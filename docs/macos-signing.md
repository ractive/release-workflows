# macOS signing and notarisation

`release.yml` can sign every macOS binary with a Developer ID certificate
and have Apple notarise it, so Gatekeeper lets people run it without the
"cannot be opened because the developer cannot be verified" warning.

It is off until the secrets below exist. Without `APPLE_CERTIFICATE` the
signing steps skip and a release builds exactly as before.

## 1. In Apple's portals (once)

You need a paid Apple Developer Program membership. Only the Account
Holder can create a Developer ID certificate; on a personal account that
is you.

**Certificate signing request.** On your Mac open Keychain Access, then
*Keychain Access > Certificate Assistant > Request a Certificate From a
Certificate Authority*. Enter your email and name, leave "CA Email" empty,
choose *Saved to disk*. This makes a `.certSigningRequest` file and keeps
the private key in your login keychain.

**Developer ID Application certificate.** At
[developer.apple.com/account/resources/certificates](https://developer.apple.com/account/resources/certificates/list)
click **+**, choose **Developer ID Application** (G2 Sub-CA), upload the
request, download the `.cer` and double-click it. It now sits in Keychain
Access under *My Certificates* as "Developer ID Application: Your Name
(TEAMID)", with the private key below it.

**Export it as .p12.** In *My Certificates* select that certificate,
*File > Export Items*, format *Personal Information Exchange (.p12)*, and
give it a strong password. The workflow needs the certificate and its
private key together, which is what the .p12 holds.

**App Store Connect API key.** At
[appstoreconnect.apple.com/access/integrations/api](https://appstoreconnect.apple.com/access/integrations/api)
(*Users and Access > Integrations > App Store Connect API > Team Keys*;
the first time you may have to request access), generate a key named e.g.
"notarisation" with the **Developer** role. Download `AuthKey_<KEYID>.p8`.
Apple lets you download it only once. Note the **Key ID** (in the table)
and the **Issuer ID** (the UUID above the table).

Keep the .p12, its password and the .p8 in your password manager, not in
a repository.

## 2. Store them as GitHub secrets

```sh
scripts/set-apple-secrets.sh --dry-run   # checks the files, sets nothing
scripts/set-apple-secrets.sh             # hyalo hoppy ff-rdp hptx saturnus
scripts/set-apple-secrets.sh hyalo       # or only some repos
```

It asks for the two file paths, the .p12 password (not echoed), the
identity (read from the .p12 if possible) and the key and issuer IDs (the
key ID is read from the .p8 file name). Nothing secret goes on the command
line, and it prints only secret names. It needs `gh` logged in as
`ractive`.

The secrets, the same in every repo:

| Secret | Contents |
| --- | --- |
| `APPLE_CERTIFICATE` | base64 of the .p12 file |
| `APPLE_CERTIFICATE_PASSWORD` | the .p12 password |
| `APPLE_SIGNING_IDENTITY` | `Developer ID Application: Your Name (TEAMID)` |
| `APPLE_API_KEY_ID` | the key ID |
| `APPLE_API_ISSUER` | the issuer ID |
| `APPLE_API_KEY` | base64 of the .p8 file (the raw PEM text also works) |

The callers already pass `secrets: inherit`, which covers these, so no
caller declares or forwards them.

## 3. Bump the callers

Signing arrives with the first release-workflows tag after v0.2.3. Each
repo's `.github/workflows/release.yml` bumps its `uses:` line to that tag.
Nothing else changes. Repos still on an older tag keep shipping unsigned
binaries even with the secrets set.

## What a release then does

On each macOS target, after the build and the `pre-package-command` and
before archiving:

1. imports the .p12 into a temporary keychain;
2. signs the binary with `codesign --force --options runtime --timestamp`
   (hardened runtime, secure timestamp) and checks it with
   `codesign --verify --strict`;
3. runs it once with `--help` (targets with `run_tests`), so a hardened
   runtime problem fails the build;
4. zips it and submits the zip with `xcrun notarytool submit --wait`; any
   status other than Accepted fails the build and prints Apple's log;
5. deletes the keychain and key files, whatever happened.

The archive, its SBOM and attestation, `SHA256SUMS` and the Homebrew
checksum are all made after this, so they describe the signed binary.

If `APPLE_CERTIFICATE` is set but any of the other five is missing, the
build fails rather than ship a signed but unnotarised binary.

## Limits

- **No stapling.** A bare binary has nowhere to keep the ticket, so
  Gatekeeper looks it up online the first time someone runs a downloaded
  copy. Offline, that first run can still be blocked.
- **Only quarantined files are checked.** A browser download is
  quarantined; `curl`, `tar` and Homebrew formulae are not, so for them
  signing mostly changes nothing visible.
- **Dry runs sign too.** A `dry-run: true` call in a repo with the
  secrets signs and notarises like a release (a useful test of the setup,
  a few minutes slower). The selftest in this repo passes no secrets and
  checks that its macOS binary stays unsigned.
- **`spctl` is informational.** Apple's Gatekeeper tools are meant for
  apps, installers and disk images; the workflow logs `spctl`'s verdict on
  the binary but relies on notarytool's "Accepted".
- **Renewal.** A Developer ID certificate lasts five years. Make a new
  one the same way and rerun the script; the API key does not expire but
  can be revoked in App Store Connect.
