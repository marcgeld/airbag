#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/../.."
# Use the compiler bundled with the selected Xcode SDK, not a PATH override.
export TOOLCHAINS=com.apple.dt.toolchain.XcodeDefault
/usr/bin/xcrun --toolchain XcodeDefault --sdk macosx swift build
bin_dir=$(/usr/bin/xcrun --toolchain XcodeDefault --sdk macosx swift build --show-bin-path)
/usr/bin/xcrun --toolchain XcodeDefault --sdk macosx swift build --scratch-path .build-invalid -Xswiftc -DAIRBAG_INVALID_POLICY
invalid_dir=$(/usr/bin/xcrun --toolchain XcodeDefault --sdk macosx swift build --scratch-path .build-invalid --show-bin-path)
/usr/bin/xcrun --toolchain XcodeDefault --sdk macosx clang Tests/Security/probe.c -o "$bin_dir/airbag-probe"
/usr/bin/xcrun --toolchain XcodeDefault --sdk macosx clang Tests/Security/link_probe.c -o "$bin_dir/airbag-link-probe"
/usr/bin/xcrun --toolchain XcodeDefault --sdk macosx clang -std=c11 -pthread Tests/Security/symlink_race.c -o "$bin_dir/airbag-symlink-race"
/usr/bin/xcrun --toolchain XcodeDefault --sdk macosx clang Tests/Security/network_probe.c -o "$bin_dir/airbag-network-probe"
work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT
# Use isolated defaults so tests never read or modify the user's settings.
export HOME="$work/home"
mkdir -p "$HOME"
bin="$bin_dir/airbag"
probe="$bin_dir/airbag-probe"
expect_status() {
    local expected="$1" actual=0
    shift
    "$@" || actual=$?
    if [ "$actual" -ne "$expected" ]; then
        echo "FAIL: expected status $expected, got $actual" >&2
        exit 1
    fi
}
# Positive controls prevent permission/network failures giving false positives.
"$probe" write "$work/control" allowed
"$probe" read "$work/control" allowed
"$probe" network unused allowed
expect_status 0 "$bin" /bin/echo 'Sandbox active'
expect_status 0 "$bin" /bin/cat "$work/control"
expect_status 0 "$bin" "$probe" write "$work/blocked" denied
[ ! -e "$work/blocked" ]
expect_status 0 "$bin" "$probe" network unused denied
# A per-command network grant must not grant file writes or persist to the next command.
expect_status 0 "$bin" --network=all "$probe" network unused allowed
expect_status 0 "$bin" --network=all "$probe" write "$work/network-write" denied
expect_status 0 "$bin" "$probe" network unused denied
# Bash starts a child that execs the probe; restrictions must be inherited.
expect_status 0 "$bin" /bin/bash --noprofile --norc -c '"$1" write "$2" denied; result=$?; exit "$result"' _ "$probe" "$work/child"
[ ! -e "$work/child" ]
expect_status 0 "$bin" /bin/bash --noprofile --norc -c '"$1" network unused denied; result=$?; exit "$result"' _ "$probe"
expect_status 37 "$bin" /bin/bash --noprofile --norc -c 'exit 37'
expect_status 127 "$bin" /no/such/airbag-command
expect_status 126 "$bin" "$work/control"
expect_status 64 "$bin"
# Even with a command that exits successfully, invalid policy must stop execution.
expect_status 70 "$invalid_dir/airbag" /bin/echo SHOULD_NOT_RUN > "$work/invalid-output"
[ ! -s "$work/invalid-output" ]
# Exercise configurable permissions independently and verify existing files are preserved.
config="$HOME/.config/airbag/config.json"
printf '{"allowFileWrites": true, "allowNetwork": false}\n' > "$config"
expect_status 0 "$bin" "$probe" write "$work/allowed" allowed
# Even globally writable commands cannot change Airbag's trusted configuration.
expect_status 0 "$bin" "$probe" write "$config" denied
expect_status 0 "$bin" "$probe" write "$HOME/.config/airbag/forged-approval" denied
expect_status 0 "$bin" "$probe" network unused denied
printf '{"allowFileWrites": false, "allowNetwork": true}\n' > "$config"
cp "$config" "$work/config-before"
expect_status 0 "$bin" "$probe" write "$work/still-blocked" denied
expect_status 0 "$bin" "$probe" network unused allowed
cmp -s "$work/config-before" "$config"
# Read and write switches are independent, including inside a workspace.
workspace="$work/workspace"
mkdir -p "$workspace" "$work/workspace-sibling"
printf 'inside' > "$workspace/input"
printf 'outside' > "$work/workspace-sibling/input"
ln -s "$work/control" "$workspace/escape"
for reads in true false; do
    for writes in true false; do
        printf '{"allowFileReads": %s, "allowFileWrites": %s, "allowNetwork": false}\n' "$reads" "$writes" > "$config"
        read_result=denied
        write_result=denied
        if [ "$reads" = true ]; then read_result=allowed; fi
        if [ "$writes" = true ]; then write_result=allowed; fi
        expect_status 0 "$bin" --workspace "$workspace" "$probe" read "$workspace/input" "$read_result"
        expect_status 0 "$bin" --workspace "$workspace" "$probe" write "$workspace/output" "$write_result"
        expect_status 0 "$bin" --workspace "$workspace" "$probe" read "$work/control" denied
        expect_status 0 "$bin" --workspace "$workspace" "$probe" write "$work/outside-write" denied
    done
done
# Global read denial still allows writes when explicitly enabled.
printf '{"allowFileReads": false, "allowFileWrites": true, "allowNetwork": false}\n' > "$config"
expect_status 0 "$bin" "$probe" read "$work/control" denied
expect_status 0 "$bin" "$probe" write "$work/write-only" allowed
# Configure the directory in JSON; commands run there, and children stay restricted.
printf '{"allowFileReads": true, "allowFileWrites": true, "allowNetwork": false, "workspace": "%s"}\n' "$workspace" > "$config"
[ "$("$bin" /bin/pwd -P)" = "$(cd "$workspace" && pwd -P)" ]
expect_status 0 "$bin" "$probe" read "$workspace/input" allowed
expect_status 0 "$bin" "$probe" read "$work/workspace-sibling/input" denied
expect_status 0 "$bin" "$probe" read "$workspace/escape" denied
expect_status 0 "$bin" "$probe" write "$workspace/escape" denied
expect_status 1 "$bin" /bin/bash --noprofile --norc -c '/bin/cat "$1"' _ "$work/control"
# The command-line directory overrides the configured directory, including SBPL metacharacters.
other="$work/other \"quoted\" \\ directory"
mkdir -p "$other"
printf 'other' > "$other/input"
expect_status 0 "$bin" --workspace "$other" "$probe" read "$other/input" allowed
expect_status 0 "$bin" --workspace "$other" "$probe" read "$workspace/input" denied
expect_status 78 "$bin" --workspace "$work/nonexistent" /bin/echo SHOULD_NOT_RUN > "$work/workspace-output"
[ ! -s "$work/workspace-output" ]
# Project overrides are read by the launcher, then hidden from the command.
printf '{"allowFileReads": true, "allowFileWrites": false, "allowNetwork": false}\n' > "$config"
printf '{"allowFileWrites": true, "allowNetwork": true}\n' > "$workspace/.airbag.json"
"$probe" read "$workspace/.airbag.json" allowed
expect_status 0 "$bin" --workspace "$workspace" "$probe" read "$workspace/input" allowed
expect_status 0 "$bin" --workspace "$workspace" "$probe" write "$workspace/project-write" allowed
expect_status 0 "$bin" --workspace "$workspace" "$probe" network unused allowed
expect_status 0 "$bin" --workspace "$workspace" "$probe" read "$workspace/.airbag.json" denied
expect_status 0 "$bin" --workspace "$workspace" "$probe" write "$workspace/.airbag.json" denied
if [ -e "$workspace/.AIRBAG.JSON" ]; then
    expect_status 0 "$bin" --workspace "$workspace" "$probe" read "$workspace/.AIRBAG.JSON" denied
fi
ln -s .airbag.json "$workspace/policy-alias"
expect_status 0 "$bin" --workspace "$workspace" "$probe" read "$workspace/policy-alias" denied
expect_status 0 "$bin" --workspace "$workspace" "$probe" write "$workspace/policy-alias" denied
# A policy file pointing to a differently named target must not reveal its contents.
mv "$workspace/.airbag.json" "$workspace/policy-source"
ln -s policy-source "$workspace/.airbag.json"
expect_status 0 "$bin" --workspace "$workspace" "$probe" read "$workspace/policy-source" denied
expect_status 0 "$bin" --workspace "$workspace" "$probe" write "$workspace/policy-source" denied
# A typo in a permission must fail closed, even if the JSON source is valid.
printf '{"allowFileWrites": false, "allowNetwrok": true}\n' > "$config"
expect_status 78 "$bin" /bin/echo SHOULD_NOT_RUN > "$work/config-output"
[ ! -s "$work/config-output" ]
python3 Tests/Security/links.py "$bin_dir"
python3 Tests/Security/network.py "$bin_dir"
echo 'PASS: independent read/write permissions, workspace boundaries, symlinks, protected configuration, inheritance, fail-closed'
