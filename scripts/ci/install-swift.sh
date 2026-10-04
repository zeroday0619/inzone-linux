#!/usr/bin/env bash
# The package notices and runtime manifest require this exact Swift release.
set -euo pipefail

usage() {
    printf '%s\n' 'Usage: install-swift.sh DESTINATION' \
        'Install the verified Swift 6.3.3 Ubuntu 24.04 amd64 toolchain in a new directory.' \
        'The script does not install system packages or modify the system toolchain.'
}

if [[ ${1:-} == --help ]]; then
    usage
    exit 0
fi
if [[ $# -ne 1 ]]; then
    usage >&2
    exit 2
fi
if [[ $(uname -s) != Linux || $(uname -m) != x86_64 ]]; then
    printf '%s\n' 'This toolchain requires Linux x86_64.' >&2
    exit 1
fi
for command in curl gpg tar realpath awk; do
    if ! command -v "$command" >/dev/null 2>&1; then
        printf 'Required command is unavailable: %s\n' "$command" >&2
        exit 1
    fi
done

readonly version=6.3.3
readonly archive_name="swift-${version}-RELEASE-ubuntu24.04.tar.gz"
# The URL and fingerprint are published by the Swift project.
# https://www.swift.org/install/linux/ubuntu/24_04/
# https://www.swift.org/keys/active/
readonly archive_url="https://download.swift.org/swift-${version}-release/ubuntu2404/swift-${version}-RELEASE/${archive_name}"
readonly signing_fingerprint=52BB7E3DE28A71BE22EC05FFEF80A866B47A981F
readonly signing_key_url=https://www.swift.org/keys/release-key-swift-6.x.asc
destination=$(realpath -m -- "$1")
readonly destination

if [[ -e $destination || -L $destination ]]; then
    printf 'Destination already exists: %s\n' "$destination" >&2
    exit 1
fi
mkdir -p -- "$(dirname -- "$destination")"
working_directory=$(mktemp -d "${destination}.download.XXXXXX")
trap 'rm -rf -- "$working_directory"' EXIT
mkdir -m 700 "$working_directory/gnupg"

fetch() {
    curl --fail --location --compressed --silent --show-error --retry 3 \
        --proto '=https' --proto-redir '=https' --tlsv1.2 \
        --output "$2" "$1"
}

fetch "$signing_key_url" "$working_directory/signing-key.asc"
gpg --batch --homedir "$working_directory/gnupg" \
    --import "$working_directory/signing-key.asc"
key_fingerprint=$(gpg --batch --homedir "$working_directory/gnupg" \
    --with-colons --fingerprint | awk -F: '$1 == "fpr" {print $10; exit}')
if [[ $key_fingerprint != "$signing_fingerprint" ]]; then
    printf '%s\n' 'The downloaded Swift signing key does not match the pinned fingerprint.' >&2
    exit 1
fi

fetch "$archive_url" "$working_directory/$archive_name"
fetch "$archive_url.sig" "$working_directory/$archive_name.sig"
gpg --batch --homedir "$working_directory/gnupg" --status-fd 1 \
    --verify "$working_directory/$archive_name.sig" "$working_directory/$archive_name" \
    > "$working_directory/signature-status"
if ! awk -v fingerprint="$signing_fingerprint" \
    '$1 == "[GNUPG:]" && $2 == "VALIDSIG" && ($3 == fingerprint || $NF == fingerprint) {valid = 1} END {exit !valid}' \
    "$working_directory/signature-status"; then
    printf '%s\n' 'The Swift archive does not have a valid signature from the pinned release key.' >&2
    exit 1
fi

mkdir "$working_directory/toolchain"
tar --extract --gzip --file "$working_directory/$archive_name" \
    --directory "$working_directory/toolchain" --strip-components=1 --no-same-owner
version_output=$("$working_directory/toolchain/usr/bin/swiftc" --version)
if [[ $version_output != "Swift version $version "* ]]; then
    printf 'Unexpected Swift compiler version: %s\n' "$version_output" >&2
    exit 1
fi
mv -- "$working_directory/toolchain" "$destination"
printf '%s\n' "$version_output"
printf 'Swift toolchain: %s\n' "$destination"

if [[ -n ${GITHUB_PATH:-} ]]; then
    printf '%s\n' "$destination/usr/bin" >> "$GITHUB_PATH"
fi
if [[ -n ${GITHUB_OUTPUT:-} ]]; then
    printf 'toolchain-prefix=%s\ntoolchain-bin=%s/usr/bin\n' \
        "$destination" "$destination" >> "$GITHUB_OUTPUT"
fi
