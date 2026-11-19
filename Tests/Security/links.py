#!/usr/bin/env python3
"""Adversarial link tests using disposable fixtures on the same filesystem."""
import hashlib
import json
import os
from pathlib import Path
import subprocess
import sys
import tempfile

binary_dir = Path(sys.argv[1])
airbag = binary_dir / "airbag"
probe = binary_dir / "airbag-probe"
links = binary_dir / "airbag-link-probe"
race = binary_dir / "airbag-symlink-race"

with tempfile.TemporaryDirectory(prefix="airbag-links-") as temporary:
    root = Path(temporary)
    workspace, outside, home = root / "workspace", root / "outside", root / "home"
    workspace.mkdir()
    outside.mkdir()
    configuration = home / ".config" / "airbag"
    configuration.mkdir(parents=True)
    config = configuration / "config.json"
    config.write_text(json.dumps(dict(allowFileReads=True, allowFileWrites=True, allowNetwork=False)))
    environment = dict(os.environ, HOME=str(home))
    secret = outside / "secret"
    secret.write_text("outside-marker-must-not-change")
    inside = workspace / "inside"
    inside.write_text("inside-marker")
    initial = hashlib.sha256(secret.read_bytes()).hexdigest()
    control = outside / "control-hardlink"
    subprocess.run([str(links), "hardlink", str(secret), str(control), "allowed"], check=True)
    control.unlink()
    subprocess.run([str(links), "symlink", str(secret), str(control), "allowed"], check=True)
    subprocess.run([str(probe), "read", str(control), "allowed"], check=True)
    control.unlink()
    control.write_text("rename control")
    subprocess.run([str(links), "rename", str(control), str(outside / "renamed-control"), "allowed"], check=True)

    def run(*arguments, status=0, scoped=True, stderr_contains=None):
        command = [str(airbag)]
        if scoped:
            command += ["--workspace", str(workspace)]
        result = subprocess.run(command + list(map(str, arguments)), env=environment,
                                capture_output=True, text=True, timeout=30)
        if result.returncode != status or (stderr_contains and stderr_contains not in result.stderr):
            raise AssertionError(f"{command + list(map(str, arguments))}: expected {status}, got {result.returncode}\n{result.stdout}\n{result.stderr}")
        return result

    # Positive controls prove that both the outside file and link syscalls work without Airbag.
    subprocess.run([str(probe), "read", str(secret), "allowed"], check=True)
    os.link(secret, outside / "control-hardlink")
    (outside / "control-hardlink").unlink()
    (workspace / "within").symlink_to(inside)
    run(probe, "read", workspace / "within", "allowed")
    run(links, "symlink", inside, workspace / "created-within", "allowed")
    run(probe, "read", workspace / "created-within", "allowed")

    cases = {
        "absolute": str(secret),
        "relative": "../outside/secret",
        "chain": "absolute",
        "directory": str(outside),
        "dangling": "../outside/new-file",
    }
    for name, target in cases.items():
        (workspace / name).symlink_to(target)
    for name in ["absolute", "relative", "chain", "directory/secret", "../outside/secret"]:
        run(probe, "read", workspace / name, "denied")
        run(probe, "write", workspace / name, "denied")
    run(probe, "write", workspace / "dangling", "denied")
    assert not (outside / "new-file").exists()
    # The command may create an outside-pointing symlink, but cannot follow it for access.
    run(links, "symlink", secret, workspace / "created-escape", "allowed")
    run(probe, "read", workspace / "created-escape", "denied")
    run(probe, "write", workspace / "created-escape", "denied")
    run(links, "rename", inside, outside / "moved", "denied")
    run(links, "rename", secret, workspace / "stolen", "denied")

    # A symlink used as --workspace resolves once to the same approved directory.
    alias = root / "workspace-alias"
    alias.symlink_to(workspace)
    run("--workspace", alias, probe, "read", inside, "allowed", scoped=False)
    run("--workspace", alias, probe, "read", secret, "denied", scoped=False)

    # New hard links are denied, even between two otherwise writable in-scope paths.
    run(links, "hardlink", secret, workspace / "hard-escape", "denied")
    run(links, "hardlink", inside, workspace / "hard-within", "denied")
    run(links, "hardlink", config, workspace / "hard-config", "denied")

    # Existing hard-linked files are rejected before the command starts.
    os.link(secret, workspace / "preexisting-hardlink")
    result = run("/bin/echo", "SHOULD_NOT_RUN", status=78, stderr_contains="multiple hard links")
    assert not result.stdout
    (workspace / "preexisting-hardlink").unlink()
    os.link(config, workspace / "preexisting-config")
    result = run("/bin/echo", "SHOULD_NOT_RUN", status=78, stderr_contains="multiple hard links")
    assert not result.stdout
    (workspace / "preexisting-config").unlink()

    policy = workspace / ".airbag.json"
    policy.write_text("{}")
    os.link(policy, workspace / "preexisting-policy")
    result = run("/bin/echo", "SHOULD_NOT_RUN", status=78, stderr_contains="multiple hard links")
    assert not result.stdout
    (workspace / "preexisting-policy").unlink()

    # Protected global configuration remains protected when the file itself is a symlink.
    target = workspace / "global-source.json"
    target.write_bytes(config.read_bytes())
    config.unlink()
    config.symlink_to(target)
    run(probe, "write", target, "denied")
    run(probe, "write", config, "denied")
    config.unlink()
    config.write_bytes(target.read_bytes())

    # Race accesses against atomic swaps between allowed and forbidden symlink targets.
    (workspace / "racing").symlink_to(inside)
    for operation in ["read", "write"]:
        result = run(race, operation, secret, inside, workspace / "racing")
        print(result.stdout.strip())
    assert hashlib.sha256(secret.read_bytes()).hexdigest() == initial
    print("PASS: symlink chains/directories, traversal, workspace aliases, renames, hard links, configuration aliases, races")
