#!/usr/bin/env bash
# Shared by the Linux and macOS entry points; compatible with macOS Bash 3.2.

fail() { printf '%s\n' "$*" >&2; return 1; }

prompt() {
    local answer
    read -r -p "$1${2:+ [$2]}: " answer || return 1
    printf '%s' "${answer:-$2}"
}

validate_address() {
    if [[ $1 == *:* || $1 == *%* ]]; then
        # Hexadecimal groups only, so nothing reaches sshfs that a shell or an
        # ssh option could reinterpret. A %zone names an interface on this
        # computer, and a link-local address is meaningless without one.
        local colons=${1//[^:]/}
        [[ $1 =~ ^[0-9A-Fa-f:]+$ ]] || { fail 'That is not a usable IPv6 address. Copy one of the addresses shown in SSH Switch.'; return 1; }
        [[ $1 == *::* || ${#colons} == 7 ]] || { fail 'That is not a usable IPv6 address. Copy one of the addresses shown in SSH Switch.'; return 1; }
        [[ ! $1 =~ ^[Ff][Ee][89AaBb] ]] || { fail 'A link-local IPv6 address cannot be used from another computer. Use the other address shown in SSH Switch, or a hostname such as steamdeck.local.'; return 1; }
        return 0
    fi
    [[ $1 =~ ^[a-zA-Z0-9][a-zA-Z0-9.-]*$ ]] || { fail 'Enter an IPv4 address or hostname, without a URL or username.'; return 1; }
}

sshfs_target() {
    # sshfs splits host from path on the first colon, so an IPv6 literal needs
    # the bracketed form its manual page documents.
    if [[ $2 == *:* ]]; then printf '%s@[%s]:%s' "$1" "$2" "$3"; else printf '%s@%s:%s' "$1" "$2" "$3"; fi
}

validate_connection() {
    # Use the IPv4 address displayed by SSH Switch, or a DNS hostname.
    validate_address "$1" || return 1
    if [[ ! $2 =~ ^[0-9]{1,5}$ ]] || (( 10#$2 < 1 || 10#$2 > 65535 )); then
        fail 'Port must be between 1 and 65535.'
        return 1
    fi
    [[ $3 =~ ^[a-zA-Z_][a-zA-Z0-9_-]*\$?$ ]] || { fail 'Enter the username shown on the Deck.'; return 1; }
    [[ $4 == /* && $4 != *$'\n'* && $4 != *$'\r'* ]] || { fail 'Remote folder must be an absolute path.'; return 1; }
}

unmount_folder() {
    if [[ $1 == Darwin ]]; then
        umount "$2"
    elif command -v fusermount3 >/dev/null 2>&1; then
        fusermount3 -u "$2"
    else
        fusermount -u "$2"
    fi
}

record_directory() {
    if [[ $1 == Darwin ]]; then
        printf '%s\n' "$HOME/Library/Application Support/SSH Switch/mounts"
    else
        printf '%s\n' "${XDG_STATE_HOME:-$HOME/.local/state}/ssh-switch/mounts"
    fi
}

mount_identity() {
    if [[ $1 == Linux ]]; then
        # Raw output escapes whitespace in paths; the mount ID detects replacements.
        findmnt --noheadings --raw --nocanonicalize --mountpoint "$2" --output ID,SOURCE,FSTYPE
    else
        local line listing
        listing=$(mount) || return 2
        while IFS= read -r line; do
            if [[ ${line% (*} == *" on $2" ]]; then printf '%s\n' "$line"; return; fi
        done <<< "$listing"
        return 1
    fi
}

record_mount() (
    umask 077
    local directory identity temporary
    directory=$(record_directory "$1")
    identity=$(mount_identity "$1" "$2") || return 1
    [[ -n $identity && $identity != *$'\n'* ]] || return 1
    mkdir -p -- "$directory" || return 1
    [[ ! -L $directory && -O $directory && -w $directory ]] || return 1
    temporary=$(mktemp "$directory/.pending.XXXXXXXX") || return 1
    # Publish a separate record per mount, so concurrent runs cannot lose entries.
    if ! { printf '%s\n%s\n' "$2" "$identity" > "$temporary" &&
        mv -- "$temporary" "$directory/mount.${temporary##*.}"; }; then
        rm -f -- "$temporary"
        return 1
    fi
)

unmount_recorded() {
    local platform=$1 directory record folder expected current result failed=0 found=0
    directory=$(record_directory "$platform")
    if [[ $platform == Linux ]]; then
        command -v findmnt >/dev/null 2>&1 || { fail 'Install util-linux (findmnt) first.'; return 1; }
    fi
    for record in "$directory"/mount.*; do
        [[ -f $record && ! -L $record ]] || continue
        found=1
        if ! { IFS= read -r folder && IFS= read -r expected; } < "$record" ||
            [[ $folder != /* || -z $expected ]]; then
            printf 'Cannot read mount record: %s\n' "$record" >&2
            failed=1
            continue
        fi
        result=0
        current=$(mount_identity "$platform" "$folder") || result=$?
        if (( result > 1 )); then
            printf 'Cannot check the mount at %s; its record was kept.\n' "$folder" >&2
            failed=1
            continue
        elif (( result == 1 )); then
            printf 'Already unmounted: %s\n' "$folder"
        elif [[ $current != "$expected" ]]; then
            printf 'Skipping %s: a different filesystem is mounted there.\n' "$folder"
        elif unmount_folder "$platform" "$folder"; then
            printf 'Unmounted: %s\n' "$folder"
        else
            printf 'Could not unmount %s. Close files using it and try again.\n' "$folder" >&2
            failed=1
            continue
        fi
        rm -- "$record" || return 1
    done
    (( found )) || printf '%s\n' 'No recorded folders to unmount.'
    return "$failed"
}

mount_main() {
    local platform=$1
    shift
    [[ $(uname -s) == "$platform" ]] || { fail "This script is for $platform."; return 1; }
    if [[ ${1:-} == --unmount ]]; then
        if [[ $# == 1 ]]; then unmount_recorded "$platform"; return; fi
        if [[ $# == 2 ]]; then
            [[ $2 == /* ]] || { fail 'Use an absolute local mount path.'; return 1; }
            unmount_folder "$platform" "$2"
            return
        fi
    fi
    [[ $# == 0 ]] || { printf 'Usage: bash %q [--unmount [/local/folder]]\n' "$0" >&2; return 1; }
    (( EUID != 0 )) || { fail 'Run this script as your normal user, without sudo.'; return 1; }
    if ! command -v sshfs >/dev/null 2>&1; then
        if [[ $platform == Darwin ]]; then
            fail 'Install Homebrew, then run: brew install macos-fuse-t/homebrew-cask/fuse-t macos-fuse-t/homebrew-cask/sshfs-fuse-t'
        else
            fail 'Install sshfs with your package manager (Ubuntu/Debian: sudo apt install sshfs; Fedora: sudo dnf install fuse-sshfs; Arch: sudo pacman -S sshfs).'
        fi
        return 1
    fi
    command -v ssh >/dev/null 2>&1 || { fail 'Install the OpenSSH client first.'; return 1; }
    if [[ $platform == Linux ]]; then
        command -v findmnt >/dev/null 2>&1 || { fail 'Install util-linux (findmnt) first.'; return 1; }
        command -v fusermount3 >/dev/null 2>&1 || command -v fusermount >/dev/null 2>&1 || { fail 'Install FUSE (fusermount3 or fusermount) first.'; return 1; }
    fi

    local address port username remote folder
    printf '%s\n' 'On your Deck, enable SSH and open SSH Switch > Connect from computer.'
    # Checked here so a bad address fails at its own prompt, not after the rest.
    address=$(prompt 'Address' 'steamdeck.local')
    validate_address "$address" || return 1
    port=$(prompt 'Port' '22')
    username=$(prompt 'Username' 'deck')
    remote=$(prompt 'Remote folder' "/home/$username")
    validate_connection "$address" "$port" "$username" "$remote" || return 1
    folder=$(prompt 'Local mount folder' "$HOME/SteamDeck")
    [[ $folder == /* && $folder != *$'\n'* && $folder != *$'\r'* ]] || { fail 'Use an absolute local mount path.'; return 1; }
    [[ ! -L $folder ]] || { fail 'The local mount folder must not be a symbolic link.'; return 1; }
    mkdir -p -- "$folder"
    # Canonicalize before checking mounts, including symlinks in parent folders.
    folder=$(cd -- "$folder" && pwd -P)
    if mount_identity "$platform" "$folder" >/dev/null; then fail 'This folder is already mounted.'; return 1; fi
    [[ -O $folder && -w $folder && -z $(ls -A -- "$folder") ]] || { fail 'Choose an empty, writable folder owned by your user.'; return 1; }

    printf '%s\n' 'Compare the SSH fingerprint with the one on your Deck before accepting it.'
    # SSH owns the password/key prompt and known_hosts verification. Never use eval
    # or put the password in command arguments. Disable user SSH config rewriting
    # the address/port or supplying an unrelated proxy for this direct connection.
    sshfs "$(sshfs_target "$username" "$address" "$remote")" "$folder" -p "$((10#$port))" \
        -o ssh_command='ssh -F /dev/null' -o StrictHostKeyChecking=ask \
        -o HostKeyAlgorithms=ssh-ed25519 -o ConnectTimeout=10 \
        -o ServerAliveInterval=15 -o ServerAliveCountMax=3
    local script
    script="$(cd -- "$(dirname -- "$0")" && pwd)/$(basename -- "$0")"
    if ! record_mount "$platform" "$folder"; then
        printf 'Mounted at %s, but its location could not be saved.\n' "$folder" >&2
        printf 'To disconnect: bash %q --unmount %q\n' "$script" "$folder" >&2
        return 1
    fi
    printf 'Mounted at %s\n' "$folder"
    local unmount_script=unmount-linux.sh
    [[ $platform != Darwin ]] || unmount_script=unmount-macos.sh
    printf 'To disconnect later: bash %q\n' "$(dirname -- "$script")/$unmount_script"
}
