#!/usr/bin/env bash
# Shared validators. Source from other scripts.
# Each helper exits 2 on failure with a message on stderr.

_die() { echo "ERROR: $*" >&2; exit 2; }

require_ipv4() {
    local v="$1" label="${2:-value}"
    [[ "$v" =~ ^([0-9]{1,3}\.){3}[0-9]{1,3}$ ]] || _die "$label: expected IPv4, got '$v'"
    local IFS=.
    local -a o=($v)
    for n in "${o[@]}"; do
        (( n >= 0 && n <= 255 )) || _die "$label: octet out of range in '$v'"
    done
}

require_mac() {
    local v="$1" label="${2:-value}"
    [[ "$v" =~ ^([0-9a-fA-F]{2}:){5}[0-9a-fA-F]{2}$ ]] || _die "$label: expected MAC, got '$v'"
}

require_int() {
    local v="$1" label="${2:-value}" min="${3:-0}" max="${4:-2147483647}"
    [[ "$v" =~ ^[0-9]+$ ]] || _die "$label: expected integer, got '$v'"
    (( v >= min && v <= max )) || _die "$label: '$v' out of range [$min,$max]"
}

require_iface() {
    local v="$1" label="${2:-value}"
    [[ "$v" =~ ^[A-Za-z0-9_.:-]+$ ]] || _die "$label: invalid interface name '$v'"
}

require_since() {
    # e.g. 30, 30m, 2h, 7d, 1w
    local v="$1" label="${2:-value}"
    [[ "$v" =~ ^[0-9]+[smhdw]?$ ]] || _die "$label: expected NUMBER[smhdw], got '$v'"
}

require_filter_basename() {
    # filter-file should be a plain basename (no slashes, no leading dot).
    local v="$1" label="${2:-value}"
    [[ "$v" =~ ^[A-Za-z0-9_.-]+$ && "$v" != .* ]] || _die "$label: invalid filter name '$v'"
}

require_no_squote() {
    # Reject single-quotes in strings that will be embedded inside single-quoted remote args.
    local v="$1" label="${2:-value}"
    [[ "$v" != *\'* ]] || _die "$label: single-quote not allowed in '$v'"
}

require_grep_pattern() {
    # Allow regex metachars but block single-quote and newline (would break remote SSH framing).
    local v="$1" label="${2:-value}"
    [[ "$v" != *\'* ]] || _die "$label: single-quote not allowed"
    [[ "$v" != *$'\n'* ]] || _die "$label: newline not allowed"
}
