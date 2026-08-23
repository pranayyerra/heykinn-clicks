#!/bin/bash
set -euo pipefail

usage() {
    echo "Usage: $0 [--allow-placeholders] [--build N] NOTES_FILE [RECORDING_FILE]" >&2
}

allow_placeholders=false
if [[ "${1:-}" == "--allow-placeholders" ]]; then
    allow_placeholders=true
    shift
fi

build=""
if [[ "${1:-}" == "--build" ]]; then
    build=${2:?--build needs a number}
    shift 2
fi

if [[ $# -lt 1 || $# -gt 2 ]]; then
    usage
    exit 64
fi

notes_file=$1
recording_file=${2:-}

if [[ ! -f "$notes_file" ]]; then
    echo "App Review notes not found: $notes_file" >&2
    exit 1
fi

notes_bytes=$(wc -c < "$notes_file" | tr -d ' ')
if (( notes_bytes > 4000 )); then
    echo "App Review notes are $notes_bytes bytes; App Store Connect permits at most 4000." >&2
    exit 1
fi

if [[ "$allow_placeholders" != true ]] && LC_ALL=C grep -nE '\[\[[^]]+\]\]' "$notes_file"; then
    echo "Replace every [[PLACEHOLDER]] before submission." >&2
    exit 1
fi

# Read from the plist rather than pinned. This said "Heykinn Clicks 1.0 (153)"
# and would have refused every packet after that one — a preflight that fails a
# correct submission is worse than none, and it fails at the moment somebody is
# trying to ship.
version=$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' \
    "$(dirname "$0")/Info.plist" 2>/dev/null || true)
expected="Heykinn Clicks ${version}${build:+ ($build)}"
if ! grep -Fq "$expected" "$notes_file"; then
    echo "Notes do not identify the prepared version: expected \"$expected\"." >&2
    exit 1
fi

for heading in \
    '1. SCREEN RECORDING' \
    '2. TEST DEVICES' \
    '3. FUNCTIONS AND AUDIENCE' \
    '4. SETUP AND ACCESS' \
    '5. EXTERNAL SERVICES, TOOLS, AND PLATFORMS' \
    '6. REGIONAL DIFFERENCES' \
    '7. REGULATION OR PROTECTED MATERIAL'; do
    if ! grep -Fq "$heading" "$notes_file"; then
        echo "Missing required section: $heading" >&2
        exit 1
    fi
done

if [[ -n "$recording_file" ]]; then
    if [[ ! -f "$recording_file" || ! -s "$recording_file" ]]; then
        echo "Screen recording is missing or empty: $recording_file" >&2
        exit 1
    fi
fi

echo "App Review packet preflight passed: $notes_bytes/4000 note bytes."
