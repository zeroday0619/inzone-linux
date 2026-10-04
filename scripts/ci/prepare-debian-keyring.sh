#!/usr/bin/env bash
# Ubuntu runner keyrings can predate the Debian suites used for packaging.
set -euo pipefail

if [[ $# -ne 1 || ${1:-} == --help ]]; then
    printf '%s\n' 'Usage: prepare-debian-keyring.sh OUTPUT.gpg'
    if [[ ${1:-} == --help ]]; then exit 0; else exit 2; fi
fi
destination=$(realpath -m -- "$1")
if [[ -e $destination || -L $destination ]]; then
    printf 'Destination already exists: %s\n' "$destination" >&2
    exit 1
fi
working_directory=$(mktemp -d)
trap 'rm -rf -- "$working_directory"' EXIT
mkdir -m 700 "$working_directory/gnupg"

# These primary fingerprints are published by the Debian FTP team.
# https://ftp-master.debian.org/keys.html
keys=(archive-key-13 archive-key-13-security release-13)
fingerprints=(
    04B54C3CDCA79751B16BC6B5225629DF75B188BD
    5E04A1E3223A19A20706E20F9904613D4CCE68C6
    41587F7DB8C774BCCF131416762F67A0B2C39DE4
)
for index in "${!keys[@]}"; do
    curl --fail --location --silent --show-error --compressed --retry 3 \
        --proto '=https' --proto-redir '=https' --tlsv1.2 \
        "https://ftp-master.debian.org/keys/${keys[index]}.asc" \
        --output "$working_directory/key.asc"
    fingerprint=$(gpg --batch --homedir "$working_directory/gnupg" \
        --with-colons --import-options show-only --import "$working_directory/key.asc" \
        | awk -F: '$1 == "fpr" {print $10; exit}')
    if [[ $fingerprint != "${fingerprints[index]}" ]]; then
        printf 'Debian signing key fingerprint mismatch: %s\n' "${keys[index]}" >&2
        exit 1
    fi
    gpg --batch --homedir "$working_directory/gnupg" --import "$working_directory/key.asc"
done
mkdir -p -- "$(dirname -- "$destination")"
gpg --batch --homedir "$working_directory/gnupg" --export "${fingerprints[@]}" \
    > "$working_directory/debian.gpg"
install -m 644 "$working_directory/debian.gpg" "$destination"
printf 'Verified Debian keyring: %s\n' "$destination"
