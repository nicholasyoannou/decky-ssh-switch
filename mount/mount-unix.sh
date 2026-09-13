#!/usr/bin/env bash
# Shared by the Linux and macOS entry points; compatible with macOS Bash 3.2.

fail() { printf '%s\n' "$*" >&2; return 1; }

prompt() {
    local answer
    read -r -p "$1${2:+ [$2]}: " answer || return 1
    printf '%s' "${answer:-$2}"
}

validate_connection() {
    # Use the IPv4 address displayed by SSH Switch, or a DNS hostname.
    [[ $1 =~ ^[a-zA-Z0-9][a-zA-Z0-9.-]*$ ]] || { fail 'Enter an IPv4 address or hostname, without a URL or username.'; return 1; }
    [[ $2 =~ ^[0-9]{1,5}$ ]] && (( 10#$2 >= 1 && 10#$2 <= 65535 )) || { fail 'Port must be between 1 and 65535.'; return 1; }
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

mount_main() {
    local platform=$1
    shift
    [[ $(uname -s) == "$platform" ]] || { fail "This script is for $platform."; return 1; }
    if [[ ${1:-} == --unmount && $# == 2 ]]; then
        [[ $2 == /* ]] || { fail 'Use an absolute local mount path.'; return 1; }
        unmount_folder "$platform" "$2"
        return
    fi
    [[ $# == 0 ]] || { printf 'Usage: bash %q [--unmount /local/folder]\n' "$0" >&2; return 1; }
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
        command -v mountpoint >/dev/null 2>&1 || { fail 'Install util-linux (mountpoint) first.'; return 1; }
        command -v fusermount3 >/dev/null 2>&1 || command -v fusermount >/dev/null 2>&1 || { fail 'Install FUSE (fusermount3 or fusermount) first.'; return 1; }
    fi

    local address port username remote folder
    printf '%s\n' 'On your Deck, enable SSH and open SSH Switch > Connect from computer.'
    address=$(prompt 'Address' '')
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
    if [[ $platform == Linux ]]; then
        if mountpoint -q -- "$folder"; then fail 'This folder is already mounted.'; return 1; fi
    else
        if mount | grep -F " on $folder (" >/dev/null; then fail 'This folder is already mounted.'; return 1; fi
    fi
    [[ -O $folder && -w $folder && -z $(ls -A -- "$folder") ]] || { fail 'Choose an empty, writable folder owned by your user.'; return 1; }

    printf '%s\n' 'Compare the SSH fingerprint with the one on your Deck before accepting it.'
    # SSH owns the password/key prompt and known_hosts verification. Never use eval
    # or put the password in command arguments. Disable user SSH config rewriting
    # the address/port or supplying an unrelated proxy for this direct connection.
    sshfs "$username@$address:$remote" "$folder" -p "$((10#$port))" \
        -o ssh_command='ssh -F /dev/null' -o StrictHostKeyChecking=ask \
        -o HostKeyAlgorithms=ssh-ed25519 -o ConnectTimeout=10 \
        -o ServerAliveInterval=15 -o ServerAliveCountMax=3
    printf 'Mounted at %s\n' "$folder"
    local script
    script="$(cd -- "$(dirname -- "$0")" && pwd)/$(basename -- "$0")"
    printf 'To disconnect later: bash %q --unmount %q\n' "$script" "$folder"
}
