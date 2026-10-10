#!/usr/bin/env bash
# Stores the Apple signing and notarisation credentials as GitHub
# repository secrets, for release.yml's macOS signing steps and saturnus'
# desktop.yml (docs/macos-signing.md).
#
# Usage: scripts/set-apple-secrets.sh [--dry-run] [repo ...]
#
#   repo       "name" (owner ractive) or "owner/name". Default: every repo
#              that releases through release.yml.
#   --dry-run  ask for and check everything, then list what would be set,
#              without calling `gh secret set`.
#
# Nothing secret is ever taken from the command line. The script asks for
# the two file paths, the identity, the key ID and the issuer ID (each can
# also come from the environment variable named in the prompt), and asks
# for the .p12 password without echoing it. It prints secret names only,
# never values, and hands each value to `gh secret set` on stdin.

set -euo pipefail

DEFAULT_OWNER="ractive"
DEFAULT_REPOS=(hyalo hoppy ff-rdp hptx saturnus)

DRY_RUN=false
REPOS=()
for arg in "$@"; do
  case "$arg" in
    --dry-run) DRY_RUN=true ;;
    -h|--help)
      sed -n '2,17p' "$0" | sed 's/^# \{0,1\}//'
      exit 0
      ;;
    -*) echo "unknown option: $arg" >&2; exit 2 ;;
    */*) REPOS+=("$arg") ;;
    *) REPOS+=("${DEFAULT_OWNER}/${arg}") ;;
  esac
done
if [ "${#REPOS[@]}" -eq 0 ]; then
  for r in "${DEFAULT_REPOS[@]}"; do
    REPOS+=("${DEFAULT_OWNER}/${r}")
  done
fi

die() { echo "error: $*" >&2; exit 1; }

# ask VAR "prompt" [default]: the value of $VAR if set, else a prompt.
ask() {
  local var="$1" prompt="$2" default="${3:-}" value
  value="${!var:-}"
  if [ -z "$value" ]; then
    if [ -n "$default" ]; then
      read -r -e -p "${prompt} [${default}]: " value
      value="${value:-$default}"
    else
      read -r -e -p "${prompt}: " value
    fi
  fi
  [ -n "$value" ] || die "${var} is empty"
  printf -v "$var" '%s' "$value"
}

expand_path() {
  case "$1" in
    \~/*) printf '%s\n' "${HOME}/${1#\~/}" ;;
    *) printf '%s\n' "$1" ;;
  esac
}

b64() { base64 < "$1" | tr -d '\n'; }

command -v openssl > /dev/null || die "openssl not found"
if [ "$DRY_RUN" = false ]; then
  command -v gh > /dev/null || die "gh not found"
fi

echo "Developer ID Application certificate (.p12 exported from Keychain Access)"
ask APPLE_P12_PATH "Path to the .p12 file (APPLE_P12_PATH)"
APPLE_P12_PATH=$(expand_path "$APPLE_P12_PATH")
[ -f "$APPLE_P12_PATH" ] || die "no file at ${APPLE_P12_PATH}"
read -r -s -p "Password of the .p12 file: " P12_PASSWORD
echo
[ -n "$P12_PASSWORD" ] || die "the .p12 password is empty (export it with a password)"

# The certificate's subject name doubles as the signing identity. Keychain
# Access exports with older ciphers, which OpenSSL 3 only reads with
# -legacy; LibreSSL (macOS) has no such flag and needs none.
p12_subject() {
  local out
  for legacy in "" "-legacy"; do
    # shellcheck disable=SC2086 # $legacy is empty or one flag
    if out=$(printf '%s\n' "$P12_PASSWORD" \
        | openssl pkcs12 $legacy -in "$APPLE_P12_PATH" -nokeys -clcerts -passin stdin 2> /dev/null \
        | openssl x509 -noout -subject -nameopt multiline 2> /dev/null); then
      printf '%s\n' "$out" | sed -n 's/^ *commonName *= *//p' | head -n 1
      return 0
    fi
  done
  return 1
}
DERIVED_IDENTITY=""
if DERIVED_IDENTITY=$(p12_subject) && [ -n "$DERIVED_IDENTITY" ]; then
  echo "The .p12 opens with that password."
else
  echo "warning: openssl could not open the .p12 with that password." >&2
  read -r -p "Continue anyway? [y/N] " yn
  [ "$yn" = "y" ] || [ "$yn" = "Y" ] || exit 1
fi
case "$DERIVED_IDENTITY" in
  "Developer ID Application:"*) ;;
  "") ;;
  *) echo "warning: the certificate is not a \"Developer ID Application\" one." >&2 ;;
esac
ask APPLE_SIGNING_IDENTITY "Signing identity (APPLE_SIGNING_IDENTITY)" "$DERIVED_IDENTITY"

echo
echo "App Store Connect API key (Team key, Developer role)"
ask APPLE_P8_PATH "Path to the AuthKey_<id>.p8 file (APPLE_P8_PATH)"
APPLE_P8_PATH=$(expand_path "$APPLE_P8_PATH")
[ -f "$APPLE_P8_PATH" ] || die "no file at ${APPLE_P8_PATH}"
grep -q -- '-----BEGIN PRIVATE KEY-----' "$APPLE_P8_PATH" || die "${APPLE_P8_PATH} is not a .p8 private key"
DERIVED_KEY_ID=$(basename "$APPLE_P8_PATH" | sed -n 's/^AuthKey_\([A-Za-z0-9]*\)\.p8$/\1/p')
ask APPLE_API_KEY_ID "Key ID (APPLE_API_KEY_ID)" "$DERIVED_KEY_ID"
ask APPLE_API_ISSUER "Issuer ID, a UUID above the keys table (APPLE_API_ISSUER)"

# name value pairs; each value goes to gh on stdin, never into argv.
NAMES=(APPLE_CERTIFICATE APPLE_CERTIFICATE_PASSWORD APPLE_SIGNING_IDENTITY
       APPLE_API_KEY_ID APPLE_API_ISSUER APPLE_API_KEY)
value_of() {
  case "$1" in
    APPLE_CERTIFICATE) b64 "$APPLE_P12_PATH" ;;
    APPLE_CERTIFICATE_PASSWORD) printf '%s' "$P12_PASSWORD" ;;
    APPLE_SIGNING_IDENTITY) printf '%s' "$APPLE_SIGNING_IDENTITY" ;;
    APPLE_API_KEY_ID) printf '%s' "$APPLE_API_KEY_ID" ;;
    APPLE_API_ISSUER) printf '%s' "$APPLE_API_ISSUER" ;;
    APPLE_API_KEY) b64 "$APPLE_P8_PATH" ;;
  esac
}

echo
if [ "$DRY_RUN" = true ]; then
  echo "Dry run: would set these secrets"
else
  login=$(gh api user --jq .login) || die "gh is not logged in (gh auth login)"
  echo "Setting secrets as GitHub user ${login}"
fi
for repo in "${REPOS[@]}"; do
  for name in "${NAMES[@]}"; do
    if [ "$DRY_RUN" = true ]; then
      echo "  ${repo}: ${name}"
    else
      value_of "$name" | gh secret set "$name" --repo "$repo" > /dev/null
      echo "  ${repo}: ${name} set"
    fi
  done
done
unset P12_PASSWORD
if [ "$DRY_RUN" = true ]; then
  echo "Dry run: nothing was set."
else
  echo "Done."
fi
