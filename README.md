# Airbag

A lightweight macOS command sandbox. *Airbag doesn't prevent the journey. It softens the impact.*

Requires macOS 15+, Swift 6.4, and Xcode. Use Xcode's bundled compiler to avoid SDK/toolchain mismatches.

```bash
xcrun --toolchain XcodeDefault --sdk macosx swift build
.build/debug/airbag --help
.build/debug/airbag --network=all /bin/bash --noprofile --norc
.build/debug/airbag --workspace ./project /bin/bash --noprofile --norc
.build/debug/airbag --workspace ./project --init-project-config
```

Arguments after the command are passed through unchanged. Add `-c release` to build an optimized binary in `.build/release/airbag`.

`--network=all` allows all network traffic for one command, overriding global and project settings without saving changes. Other network values (domains and CIDR ranges) are not supported. Filesystem and IPC restrictions still apply. Place Airbag options before the command.

## Configuration

Global defaults live in `$HOME/.config/airbag/config.json`, created if missing:

```json
{
  "allowFileReads": true,
  "allowFileWrites": false,
  "allowNetwork": false
}
```

Project overrides live in `.airbag.json` in the selected workspace, or the current directory when no workspace is selected. Omitted keys inherit global defaults. For example:

```json
{
  "allowFileWrites": true,
  "allowNetwork": true
}
```

A project file confines user-file access to its directory. `--workspace` overrides the global workspace; configured workspace paths must be absolute. `--init-project-config` creates a project file using current global defaults and never overwrites an existing file. Configuration uses Swift Codable with Foundation JSONDecoder and JSONEncoder, with no external configuration library. Existing TOML files must be converted before commands can run when the corresponding JSON file is absent.

Project files are trusted user-managed configuration, without signatures or approval prompts yet. Review files from downloaded repositories before running commands. No separate `approvals.json` is used. Invalid configuration stops execution with status 78.

## Sandbox boundaries

Airbag applies `sandbox_init` before `execvp` and aborts if sandbox activation fails. Reads and writes are independent. Workspace restrictions retain read access to system runtimes, system commands, the selected executable, and basic devices; file metadata remains visible outside the workspace. Mach broker lookups are blocked in restricted filesystem modes, which can limit tool compatibility.

Child processes cannot read or modify `.airbag.json`, including case aliases and symlink targets. They cannot write to Airbag's global configuration directory, even when other writes are permitted. New hard links are denied. Before activation, Airbag checks all workspace entries (including hidden files) without following symlinks and refuses regular files with multiple hard links; this also applies to legitimate hard links. Protected global configuration files are checked too.

This is not complete isolation: inherited standard streams remain available, and an unsandboxed process can change the filesystem after preflight. Keep the workspace under trusted control during execution. Seatbelt is deprecated; verify each supported macOS version.

## Logging

Airbag uses OSLog with subsystem `se.redseven.airbag` and categories `configuration`, `sandbox`, and `command`.

```bash
/usr/bin/log stream --style compact --level debug --predicate 'subsystem == "se.redseven.airbag"'
```

Debug events include the full invocation arguments, effective configuration, and configuration source paths in clear text; these may contain credentials. Other levels report startup, sandbox activation, handoff, and failures. Airbag is replaced by `execvp`, so it does not log the launched command's output or final exit status. Debug events are best observed live and may not be retained in log history.

## Tests and releases

```bash
xcrun --toolchain XcodeDefault --sdk macosx swift test
./Tests/Security/test.sh
```

Run sandbox tests from a regular terminal. The suite includes link chains, directory links, path traversal, renames, hard-link rejection, configuration aliases, and concurrent symlink swaps. GitHub Actions tests Airbag with Xcode 27.2. Releases produce a signed arm64 zip and checksum; `v*` tags also notarize and publish. Required secrets: `BUILD_CERTIFICATE_BASE64`, `P12_PASSWORD`, `APPLE_ID`, `APPLE_TEAM_ID`, `APPLE_APP_PASSWORD`. The signing identity must match the certificate. Dependabot proposes weekly updates; patch/minor updates auto-merge after required CI passes.
