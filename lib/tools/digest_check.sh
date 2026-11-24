#!/bin/bash
# ── digest_check.sh — deterministic char-cap validator & trimmer ──
# Purpose: enforce Discord-size caps on digests/reports BEFORE dispatch.
# Replaces brittle ad-hoc "insert then assert length" checks (incident
# inc_op_bash_exec_1791292874 / fingerprint 80cfc3d933bb) with a
# deterministic, pure-POSIX (bash + awk, UTF-8 aware) helper.
#
# Usage:
#   digest_check.sh validate [file] [cap]   # exit 0 OK / 1 OVER
#   digest_check.sh count    [file] [cap]   # print '<chars> <cap>' only
#   digest_check.sh trim     [file] [cap]   # rewrite in place: drop whole
#                                           # trailing lines until under cap
#
# Defaults: file="-" (stdin), cap=1800 (Discord soft limit).
# Exit codes: 0 OK / 1 over-cap (validate only) / 2 untrimmable / 3 bad usage

set -u

MODE="${1:-validate}"
FILE="${2:--}"
CAP="${3:-1800}"

case "$MODE" in
    validate|count|trim) ;;
    *)
        echo "Usage: $0 {validate|count|trim} [file] [cap]" >&2
        exit 3
        ;;
esac

case "$CAP" in
    ''|*[!0-9]*)
        echo "digest_check: cap must be a positive integer (got: '$CAP')" >&2
        exit 3
        ;;
esac

# Resolve input: read from stdin or file.
if [ "$FILE" = "-" ]; then
    SRC_CONTENT=$(cat)
else
    if [ ! -r "$FILE" ]; then
        echo "digest_check: cannot read file: $FILE" >&2
        exit 3
    fi
    SRC_CONTENT=$(cat "$FILE")
fi

# UTF-8 aware character count. Splits into newline-count + awk char-sum so
# no escape sequences are needed inside the awk program.
char_count() {
    local input="$1" lines chars
    lines=$(printf '%s' "$input" | wc -l)
    chars=$(printf '%s' "$input" | LC_ALL=C.UTF-8 awk '{ total += length($0) } END { print total + 0 }')
    echo $(( lines + chars ))
}

N=$(char_count "$SRC_CONTENT")

# --- Mode: count (machine-readable, always exit 0 on success) ---
if [ "$MODE" = "count" ]; then
    echo "$N $CAP"
    exit 0
fi

# --- Mode: validate (report + exit code) ---
if [ "$MODE" = "validate" ]; then
    if [ "$N" -le "$CAP" ]; then
        echo "OK $N/$CAP"
        exit 0
    else
        echo "OVER $((N-CAP)) $N/$CAP" >&2
        exit 1
    fi
fi

# --- Mode: trim (rewrite in place, dropping whole trailing lines) ---
# Invariant: never split a line — digest items are self-contained lines.
if [ "$FILE" != "-" ] && [ ! -w "$FILE" ]; then
    echo "digest_check: cannot write file: $FILE" >&2
    exit 3
fi

TRIMMED=$(printf '%s' "$SRC_CONTENT" | LC_ALL=C.UTF-8 awk -v cap="$CAP" '
    { lines[++k] = $0 }
    END {
        if (k == 0) exit 0
        total = length(lines[1]) + 1
        if (total > cap) { print "UNTRIMMABLE" > "/dev/stderr"; exit 2 }
        keep = 1
        for (i = 2; i <= k; i++) {
            if (total + length(lines[i]) + 1 <= cap) {
                total += length(lines[i]) + 1
                keep = i
            } else {
                break
            }
        }
        for (i = 1; i <= keep; i++) print lines[i]
    }')
TRIM_RC=$?
if [ "$TRIM_RC" -ne 0 ]; then
    echo "digest_check: first line alone exceeds cap $CAP — refusing to empty digest" >&2
    exit 2
fi

if [ "$FILE" = "-" ]; then
    printf '%s\n' "$TRIMMED"
else
    printf '%s\n' "$TRIMMED" > "$FILE"
fi

NEW_N=$(char_count "$TRIMMED")
echo "TRIMMED $NEW_N/$CAP" >&2
exit 0
