#!/usr/bin/env bash
set -euo pipefail

if [[ "$(uname -s)" != Darwin ]]; then
    printf '%s\n' 'This check requires an Apple macOS build host. It does not install or extract Apple SDKs on Windows/WSL.' >&2
    exit 2
fi

task_script_dir="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
task_sdk_path="$(xcrun --sdk iphoneos --show-sdk-path)"
test -d "$task_sdk_path"
task_scratch="$(mktemp -d "${TMPDIR:-/tmp}/ios-sdk-preflight.XXXXXX")"

xcodebuild -version
xcrun swiftc --version
printf 'iPhoneOS SDK version: '
xcrun --sdk iphoneos --show-sdk-version

xcrun --sdk iphoneos swiftc \
    -sdk "$task_sdk_path" \
    -target arm64-apple-ios17.0 \
    -c "$task_script_dir/SDKProbe.swift" \
    -o "$task_scratch/SDKProbe.o"
file "$task_scratch/SDKProbe.o"
printf '%s\n' 'iOS SDK compilation succeeded. This object is unsigned; no app was installed or published.'
