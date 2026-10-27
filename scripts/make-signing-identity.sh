#!/bin/bash
# Creates a self-signed code-signing identity in the login keychain, once.
# scripts/build.sh signs with it when it's there. An ad hoc signature changes
# with every build, so macOS treats each build as a new app and forgets its
# privacy permissions; a stable identity keeps them across rebuilds.
set -euo pipefail

NAME="${DYNOTCH_SIGNING_IDENTITY:-Dynotch Local Signing}"
KEYCHAIN="$HOME/Library/Keychains/login.keychain-db"

if security find-identity -p codesigning | grep -Fq "\"$NAME\""; then
    echo "\"$NAME\" is already in your login keychain."
    exit 0
fi

WORK=$(mktemp -d)
trap 'rm -rf "${WORK:?}"' EXIT

cat > "$WORK/cert.cnf" <<EOF
[ req ]
distinguished_name = dn
prompt = no
x509_extensions = ext
[ dn ]
CN = $NAME
[ ext ]
basicConstraints = critical, CA:false
keyUsage = critical, digitalSignature
extendedKeyUsage = critical, codeSigning
subjectKeyIdentifier = hash
EOF

openssl req -x509 -newkey rsa:2048 -nodes -days 3650 -config "$WORK/cert.cnf" \
    -keyout "$WORK/key.pem" -out "$WORK/cert.pem"
# The .p12 only carries the key into the keychain; its password dies with $WORK.
PASS=$(openssl rand -hex 16)
openssl pkcs12 -export -name "$NAME" -inkey "$WORK/key.pem" -in "$WORK/cert.pem" \
    -out "$WORK/identity.p12" -passout "pass:$PASS"
security import "$WORK/identity.p12" -k "$KEYCHAIN" -P "$PASS" -T /usr/bin/codesign
echo "Created \"$NAME\" in your login keychain."

# Sign a throwaway binary now, so the one-time keychain prompt shows up here
# rather than in the middle of a build. Choose Always Allow.
printf 'int main(void) { return 0; }\n' > "$WORK/probe.c"
clang -o "$WORK/probe" "$WORK/probe.c"
codesign --force --sign "$NAME" --timestamp=none "$WORK/probe"
codesign --display --verbose=2 "$WORK/probe" 2>&1 | grep '^Authority'
echo "codesign can sign with \"$NAME\"."
