#!/bin/bash
# Sets up the self-signed code-signing identity that scripts/build.sh signs with, once.
# An ad hoc signature changes with every build, so macOS treats each build as a new app
# and forgets its privacy permissions; a stable identity keeps them across rebuilds.
#
# The identity goes in a keychain of its own, ~/Library/Keychains/dynotch-signing.keychain-db,
# with a password you choose here. That keychain stays out of the search list and locks when
# the Mac sleeps and an hour after it was last used, so another process on this Mac can't
# quietly sign a changed Dynotch with the identity and inherit the permissions you gave the
# app. build.sh asks for the password when the keychain is locked.
#
# An identity an earlier version of this script put in the login keychain is moved across,
# so the permissions macOS tied to its certificate stay.
set -euo pipefail

NAME="${DYNOTCH_SIGNING_IDENTITY:-Dynotch Local Signing}"
KEYCHAIN="${DYNOTCH_SIGNING_KEYCHAIN:-$HOME/Library/Keychains/dynotch-signing.keychain-db}"
LOGIN="$HOME/Library/Keychains/login.keychain-db"

has_identity() { security find-identity -p codesigning "$1" 2>/dev/null | grep -Fq "\"$NAME\""; }

if [ -f "$KEYCHAIN" ] && has_identity "$KEYCHAIN"; then
    echo "\"$NAME\" is already in $KEYCHAIN."
    exit 0
fi

WORK=$(mktemp -d)
trap 'rm -rf "${WORK:?}"' EXIT

# The keychain's password, typed here. (read takes it from a pipe too, for tests.)
if [ -f "$KEYCHAIN" ]; then
    read -rs -p "Password of the Dynotch signing keychain: " PASS; echo
    security unlock-keychain -p "$PASS" "$KEYCHAIN"
else
    echo "Choose a password for the Dynotch signing keychain. build.sh asks for it when the keychain is locked."
    read -rs -p "Password: " PASS; echo
    read -rs -p "Again: " AGAIN; echo
    [ "$PASS" = "$AGAIN" ] || { echo "The passwords differ." >&2; exit 1; }
    [ -n "$PASS" ] || { echo "The password can't be empty." >&2; exit 1; }
    mkdir -p "$(dirname "$KEYCHAIN")"
    security create-keychain -p "$PASS" "$KEYCHAIN"
    # Locks when the Mac sleeps and an hour after its last use. Never added to the search list.
    security set-keychain-settings -l -u -t 3600 "$KEYCHAIN"
    echo "Created $KEYCHAIN."
fi

# A one-time passphrase for the .p12 that carries the key into the keychain; it dies with $WORK.
P12PASS=$(openssl rand -hex 16)

if [ -f "$LOGIN" ] && has_identity "$LOGIN"; then
    # The security tool exports a keychain's identities all together, so only a login keychain
    # with just this one can be handled here.
    count=$(security find-identity -p codesigning "$LOGIN" | grep -c '^ *[0-9][0-9]*) ' || true)
    if [ "$count" -ne 1 ]; then
        cat >&2 <<MSG
The login keychain holds "$NAME" along with other identities, and the security tool can only
export them all at once. Move it by hand instead: in Keychain Access, add $KEYCHAIN
with File > Add Keychain, find "$NAME" under login > My Certificates, drag the certificate
and its private key into the new keychain, delete them from login, then run this script again.
MSG
        exit 1
    fi
    echo "Moving \"$NAME\" out of the login keychain. macOS asks whether security may export its key: choose Allow."
    security export -k "$LOGIN" -t identities -f pkcs12 -P "$P12PASS" -o "$WORK/identity.p12"
    security import "$WORK/identity.p12" -k "$KEYCHAIN" -P "$P12PASS" -T /usr/bin/codesign > /dev/null
    has_identity "$KEYCHAIN" || { echo "The identity didn't arrive in $KEYCHAIN; the login keychain is unchanged." >&2; exit 1; }
    hash=$(security find-identity -p codesigning "$LOGIN" | grep -F "\"$NAME\"" | awk '{ print $2 }' | head -1)
    security delete-identity -Z "$hash" "$LOGIN"
    echo "Moved \"$NAME\" into $KEYCHAIN. The permissions you've given Dynotch stay."
else
    cat > "$WORK/cert.cnf" <<CNF
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
CNF
    openssl req -x509 -newkey rsa:2048 -nodes -days 3650 -config "$WORK/cert.cnf" \
        -keyout "$WORK/key.pem" -out "$WORK/cert.pem" 2> /dev/null
    openssl pkcs12 -export -name "$NAME" -inkey "$WORK/key.pem" -in "$WORK/cert.pem" \
        -out "$WORK/identity.p12" -passout "pass:$P12PASS"
    security import "$WORK/identity.p12" -k "$KEYCHAIN" -P "$P12PASS" -T /usr/bin/codesign > /dev/null
    echo "Created \"$NAME\" in $KEYCHAIN."
fi

# codesign may use the key without a dialog while the keychain is open. Its password is the gate.
security set-key-partition-list -S apple-tool:,apple: -s -k "$PASS" "$KEYCHAIN" > /dev/null

# Sign a throwaway binary, so any problem shows up here rather than in the middle of a build.
printf 'int main(void) { return 0; }\n' > "$WORK/probe.c"
clang -o "$WORK/probe" "$WORK/probe.c"
codesign --force --sign "$NAME" --keychain "$KEYCHAIN" --timestamp=none "$WORK/probe"
codesign --display --verbose=2 "$WORK/probe" 2>&1 | grep '^Authority'
echo "build.sh signs with it. The keychain is open now; it locks when the Mac sleeps or after an hour,"
echo "and \"security lock-keychain '$KEYCHAIN'\" locks it sooner."
