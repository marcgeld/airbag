#!/usr/bin/env python3
"""Verify real TCP/UDP traffic, command-line precedence, inheritance and non-persistence."""
import json
import os
from pathlib import Path
import socket
import subprocess
import sys
import tempfile

binary_dir = Path(sys.argv[1])
airbag = binary_dir / "airbag"
probe = binary_dir / "airbag-network-probe"
with tempfile.TemporaryDirectory(prefix="airbag-network-") as temporary:
    root = Path(temporary)
    workspace = root / "project"
    workspace.mkdir()
    home = root / "home"
    directory = home / ".config" / "airbag"
    directory.mkdir(parents=True)
    config = directory / "config.json"
    project_config = workspace / ".airbag.json"
    config.write_text(json.dumps(dict(allowFileReads=True, allowFileWrites=False, allowNetwork=False)))
    project_config.write_text(json.dumps(dict(allowNetwork=False)))
    original_global, original_project = config.read_bytes(), project_config.read_bytes()
    environment = dict(os.environ, HOME=str(home))
    for protocol, socket_type in [("tcp", socket.SOCK_STREAM), ("udp", socket.SOCK_DGRAM)]:
        with socket.socket(socket.AF_INET, socket_type) as server:
            server.bind(("127.0.0.1", 0))
            server.settimeout(0.2)
            if protocol == "tcp":
                server.listen(8)
            port = server.getsockname()[1]
            def verify(options, expected, child=False, control=False):
                message = f"airbag-{protocol}-{expected}"
                arguments = [str(probe), protocol, str(port), message, expected]
                if child:
                    arguments = ["/bin/bash", "--noprofile", "--norc", "-c", '"$@"; result=$?; exit "$result"', "_", *arguments]
                command = arguments if control else [str(airbag), "--workspace", str(workspace), *options, *arguments]
                result = subprocess.run(command, env=environment, capture_output=True, text=True, timeout=10)
                assert result.returncode == 0, f"{command}: {result.returncode}\n{result.stderr}"
                try:
                    if protocol == "tcp":
                        connection, _ = server.accept()
                        with connection:
                            connection.settimeout(1)
                            received = connection.recv(256)
                    else:
                        received, _ = server.recvfrom(256)
                except socket.timeout:
                    assert expected == "denied", "Allowed packet never reached the listener"
                else:
                    assert expected == "allowed", "Denied traffic reached the listener"
                    assert received.decode() == message
            verify([], "allowed", control=True)
            verify([], "denied")
            verify(["--network=all"], "allowed")
            verify(["--network", "all"], "allowed", child=True)
            verify([], "denied")
    assert config.read_bytes() == original_global
    assert project_config.read_bytes() == original_project
    print("PASS: --network=all TCP/UDP, project/global override, child inheritance, no persistence")
