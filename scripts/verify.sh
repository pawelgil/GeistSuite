#!/usr/bin/env bash
# Pre-tag verification: run before `git tag vX.Y.Z` to confirm the
# commit is buildable. Equivalent to what the release workflow does at
# the build stage (skips signing/notarization).
#
# Exits non-zero on the first failure with a clear marker.

set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$REPO_ROOT"

step() {
    printf '\n\033[1;34m==>\033[0m %s\n' "$1"
}

fail() {
    printf '\n\033[1;31m✘ verify.sh failed at: %s\033[0m\n' "$1"
    exit 1
}

step "swift build (package)"
swift build || fail "swift build"

step "swift test --no-parallel (148 tests, ~4s)"
swift test --no-parallel || fail "swift test"

step "xcodegen generate (GeistCast)"
( cd GeistCast/App && xcodegen generate ) || fail "xcodegen GeistCast"

step "xcodegen generate (GeistLens)"
( cd GeistLens/App && xcodegen generate ) || fail "xcodegen GeistLens"

step "xcodebuild build (GeistCast, Release)"
xcodebuild build \
    -project GeistCast/App/GeistCast.xcodeproj \
    -scheme GeistCast \
    -configuration Release \
    -destination 'generic/platform=macOS' \
    CODE_SIGN_IDENTITY="-" \
    CODE_SIGNING_REQUIRED=NO \
    CODE_SIGNING_ALLOWED=NO \
    | tail -3 || fail "GeistCast build"

step "xcodebuild build (GeistLens, Release)"
xcodebuild build \
    -project GeistLens/App/GeistLens.xcodeproj \
    -scheme GeistLens \
    -configuration Release \
    -destination 'generic/platform=macOS' \
    CODE_SIGN_IDENTITY="-" \
    CODE_SIGNING_REQUIRED=NO \
    CODE_SIGNING_ALLOWED=NO \
    | tail -3 || fail "GeistLens build"

printf '\n\033[1;32m✓ all checks passed — safe to tag\033[0m\n'
