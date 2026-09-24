#!/bin/sh
# Creates a local, self-signed code signing certificate for Stash.
#
# Why this exists: an ad-hoc signature (`codesign -s -`) gives the app a
# designated requirement of `cdhash H"..."` — the hash of that exact binary.
# macOS ties the Accessibility (TCC) grant to that requirement, so every
# rebuild produces a new identity and the permission silently stops applying.
# System Settings keeps showing "Stash" with the switch on, but it refers to a
# binary that no longer exists.
#
# Signing with a certificate instead gives a designated requirement of
# `identifier "com.brentc22.Stash" and certificate leaf = H"..."`. Both halves
# stay the same across rebuilds, so the grant survives.
#
# The certificate is self-signed and not trusted by the system. That is fine:
# codesign accepts it, and Gatekeeper already rejects this app either way
# (see the --no-quarantine note in the README). It buys a stable identity,
# not trust.
#
# Run once. Safe to re-run: it does nothing if the identity already exists.
# To remove it: Keychain Access > login > "Stash Self-Signed", delete.

set -eu

NAME="Stash Self-Signed"
KEYCHAIN="$HOME/Library/Keychains/login.keychain-db"

if security find-identity -p codesigning 2>/dev/null | grep -q "$NAME"; then
    echo "identity \"$NAME\" already exists — nothing to do"
    exit 0
fi

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

openssl req -x509 -newkey rsa:2048 -nodes -days 3650 \
    -keyout "$TMP/key.pem" -out "$TMP/cert.pem" \
    -subj "/CN=$NAME" \
    -addext "basicConstraints=critical,CA:false" \
    -addext "keyUsage=critical,digitalSignature" \
    -addext "extendedKeyUsage=critical,codeSigning" \
    >/dev/null 2>&1

# macOS `security` cannot read PKCS#12 files written with OpenSSL 3's default
# algorithms, so ask for the older ones explicitly. Without this the import
# fails with "MAC verification failed during PKCS12 import (wrong password?)",
# which is misleading — the password is fine.
openssl pkcs12 -export \
    -inkey "$TMP/key.pem" -in "$TMP/cert.pem" -out "$TMP/cert.p12" \
    -passout pass:stash -name "$NAME" \
    -certpbe PBE-SHA1-3DES -keypbe PBE-SHA1-3DES -macalg sha1 \
    >/dev/null 2>&1

security import "$TMP/cert.p12" -k "$KEYCHAIN" -P stash -T /usr/bin/codesign -A

echo "created code signing identity \"$NAME\""
echo "run 'make install' to sign Stash with it"
