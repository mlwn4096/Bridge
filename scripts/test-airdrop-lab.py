#!/usr/bin/env python3
"""Generate independent fixtures and run the lab's bounded protocol checks."""
import gzip
from pathlib import Path
import plistlib
import subprocess
import tempfile

ROOT = Path(__file__).resolve().parent.parent
JDK = Path("/opt/homebrew/opt/openjdk@17/libexec/openjdk.jdk/Contents/Home/bin")
SDK_JAR = Path.home() / "Library/Android/sdk/platforms/android-37.0/android.jar"


def newc(name, payload=b"", mode=0o100644, links=1):
    name = name.encode() + b"\0"
    fields = [1, mode, 0, 0, links, 0, len(payload), 0, 0, 0, 0, len(name), 0]
    header = b"070701" + "".join(f"{n:08x}" for n in fields).encode()
    block = header + name
    block += b"\0" * (-len(block) % 4)
    return block + payload + b"\0" * (-len(payload) % 4)


def main():
    build = ROOT / ".build/airdrop/tests"
    build.mkdir(parents=True, exist_ok=True)
    source = ROOT / "android/airdrop-lab/src"
    subprocess.run([str(JDK / "javac"), "--release", "17", "-encoding", "UTF-8", "-classpath", str(SDK_JAR),
                    "-d", str(build), *map(str, sorted((source / "main/java").rglob("*.java"))),
                    *map(str, sorted((source / "test/java").rglob("*.java")))], check=True)
    with tempfile.TemporaryDirectory(prefix="fixtures-", dir=build) as directory:
        fixtures = Path(directory)
        expected = {"ReceiverComputerName": "Málaga 📁", "ReceiverMediaCapabilities": bytes(range(4)),
                    "Bool": False, "Integer": 4294967296, "Array": ["sample"] * 20}
        (fixtures / "python.plist").write_bytes(plistlib.dumps(expected, fmt=plistlib.FMT_BINARY))
        (fixtures / "ask.plist").write_bytes(plistlib.dumps({"SenderComputerName": "Fixture sender", "Files": [
            {"FileName": "hello.txt", "FileBomPath": "./hello.txt", "FileIsDirectory": False}]}, fmt=plistlib.FMT_BINARY))
        trailer = bytes(6) + bytes([1, 1]) + (1).to_bytes(8, "big") + bytes(8) + (10).to_bytes(8, "big")
        (fixtures / "cycle.plist").write_bytes(b"bplist00\xa1\x00\x08" + trailer)
        (fixtures / "offset.plist").write_bytes(b"bplist00\xa1\x00\xff" + trailer)
        (fixtures / "hello.txt").write_bytes(b"hello\n")
        for fmt in ("odc", "newc"):
            archive = fixtures / f"{fmt}.cpio"
            subprocess.run(["/usr/bin/bsdtar", "-cf", str(archive), f"--format={fmt}", "hello.txt"], cwd=fixtures, check=True)
            (fixtures / f"{fmt}.gz").write_bytes(gzip.compress(archive.read_bytes()))
        tail = newc("TRAILER!!!", mode=0)
        good = newc("hello.txt", b"hello\n")
        malformed = {
            "traversal": newc("../outside", b"oops") + tail,
            "absolute": newc("/outside", b"oops") + tail,
            "symlink": newc("hello.txt", b"../outside", mode=0o120777) + tail,
            "hardlink": newc("hello.txt", b"hello\n", links=2) + tail,
            "duplicate": good + good + tail,
            "unexpected": newc("other.txt", b"hello\n") + tail,
            "truncated": good[:-3], "missing": tail,
        }
        for name, value in malformed.items():
            (fixtures / f"{name}.gz").write_bytes(gzip.compress(value))
        crc = bytearray(gzip.compress(good + tail)); crc[-8] ^= 255
        (fixtures / "crc.gz").write_bytes(crc)
        subprocess.run([str(JDK / "java"), "-cp", str(build) + ":" + str(SDK_JAR),
                        "dev.bridge.airdroplab.CoreChecks", str(fixtures)], check=True)
        generated = plistlib.loads((fixtures / "java.plist").read_bytes())
        assert generated == dict(expected, Negative=-1), generated
        extracted = subprocess.check_output(["/usr/bin/bsdtar", "-xOf", str(fixtures / "java.cpio.gz"), "./hello.txt"])
        assert extracted == b"hello\n", extracted
        print("Python plistlib and libarchive independently accepted Java output")


if __name__ == "__main__":
    main()
