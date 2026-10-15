#!/usr/bin/env python3
"""Exercise actual whole-bundle replacement and rollback in temporary directories."""
import os
import sys
import pathlib
import subprocess
import tempfile

root = pathlib.Path(__file__).resolve().parent.parent
source = pathlib.Path(sys.argv[1]).resolve() if len(sys.argv) > 1 else root / 'dist/macos/AppleSilicon/Bridge.app'
helper = root / 'scripts/install-mac-bundle.zsh'
with tempfile.TemporaryDirectory(prefix='bridge-install-test-') as directory:
    work = pathlib.Path(directory)
    target = work / 'Bridge.app'
    subprocess.run(['ditto', '--norsrc', '--noextattr', str(source), str(target)], check=True)
    obsolete = target / 'Contents/Resources/obsolete-resource.txt'
    obsolete.write_text('old resource')
    subprocess.run(['zsh', str(helper), str(source), str(target)], check=True)
    assert not obsolete.exists(), 'Old resources survived replacement'
    subprocess.run(['codesign', '--verify', '--deep', '--strict', str(target)], check=True)
    original_binary = (target / 'Contents/MacOS/Bridge').read_bytes()
    sentinel = target / 'Contents/Resources/old-install-marker.txt'
    sentinel.write_text('previous installation')
    # Inject failure only at final destination verification; staging remains real.
    tools = work / 'tools'; tools.mkdir()
    shim = tools / 'codesign'
    shim.write_text('#!/bin/zsh\nif [[ "${@[-1]}" == "$BRIDGE_TEST_FAIL_TARGET" ]]; then exit 1; fi\nexec /usr/bin/codesign "$@"\n')
    shim.chmod(0o755)
    env = dict(os.environ, PATH=str(tools) + ':' + os.environ['PATH'], BRIDGE_TEST_FAIL_TARGET=str(target))
    result = subprocess.run(['zsh', str(helper), str(source), str(target)], env=env)
    assert result.returncode != 0, 'Injected final verification failure ignored'
    assert sentinel.read_text() == 'previous installation', 'Failed update did not restore old bundle'
    assert (target / 'Contents/MacOS/Bridge').read_bytes() == original_binary
    # Failure during staging also leaves the old installation untouched.
    invalid = work / 'invalid.app'; invalid.mkdir()
    result = subprocess.run(['zsh', str(helper), str(invalid), str(target)], capture_output=True)
    assert result.returncode != 0 and sentinel.exists()
    assert not list(work.glob('.BridgeInstall.*')), 'Staging/backup directories leaked'
print('Passed complete replacement, obsolete-resource removal, staging failure and post-replacement rollback checks')
