# Signing a release

A release is signed with an identity this project owns: a self-signed certificate, not an Apple
Developer ID. It makes the artifact verifiable — `codesign -v` passes, and the signature says who
built it — and it does **not** make Gatekeeper trust it. Notarization needs an Apple Developer ID, and
that is a separate decision.

## What is where

| | |
| --- | --- |
| Certificate | `CN=Hermes macOS`, `O=Evsyukov`, `C=RU`, valid 10 years, `codeSigning` only |
| SHA-256 | `E4:30:9B:89:8B:61:23:CB:E4:3A:88:8B:C1:52:10:9F:7B:59:E8:55:BE:74:B1:4B:87:EA:D5:C8:74:8B:D1:80` |
| Private key | in the `.p12`, base64 in the repository's secret `HERMES_MACOS_CERTIFICATE_P12` |
| Password | `HERMES_MACOS_CERTIFICATE_PASSWORD` |
| Identity name | `HERMES_MACOS_IDENTITY` (`Hermes macOS`) |
| A second copy | Bitwarden, folder `macOS signing`, entry `macOS signing: Hermes macOS release` |

The `.github/workflows/release.yml` job imports the certificate into a keychain of its own, signs the
app and the disk image, and prints what it signed with. Without the secrets the job still builds, and
the image is signed ad-hoc.

## Making a new identity, if this one is lost

```sh
work=$(mktemp -d) && cd "$work"
password=$(openssl rand -base64 24 | tr -d '/+=' | cut -c1-24)
openssl req -x509 -newkey rsa:2048 -sha256 -days 3650 -nodes \
  -keyout key.pem -out cert.pem -subj "/CN=Hermes macOS/O=Evsyukov/C=RU" \
  -addext "basicConstraints=critical,CA:false" \
  -addext "keyUsage=critical,digitalSignature" \
  -addext "extendedKeyUsage=critical,codeSigning"
# -legacy matters: macOS refuses the modern PKCS12 encryption with
# "MAC verification failed during PKCS12 import".
openssl pkcs12 -export -legacy -out identity.p12 -inkey key.pem -in cert.pem \
  -passout "pass:$password" -name "Hermes macOS"
base64 -i identity.p12 -o identity.p12.b64
openssl x509 -in cert.pem -noout -fingerprint -sha256
```

Then, in the repository:

```sh
gh secret set HERMES_MACOS_CERTIFICATE_P12 < identity.p12.b64
gh secret set HERMES_MACOS_CERTIFICATE_PASSWORD --body "$password"
gh secret set HERMES_MACOS_IDENTITY --body "Hermes macOS"
```

and put the same three things in Bitwarden. A new identity means a new signature: releases signed
before it keep the old one, and a Mac that had allowed the old one asks again.

## Signing a local build

`scripts/dev-signing.sh create` makes a *separate* self-signed identity for this Mac (`Hermes Dev`),
which is what stops the Keychain asking for a password after every rebuild: an ad-hoc signed binary is
a new app to the Keychain each time, and a signed one is not. `scripts/build.sh` signs with it when it
exists. It is not the release identity and is not meant to be.
