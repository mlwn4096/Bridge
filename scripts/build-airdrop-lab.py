#!/usr/bin/env python3
"""Build the isolated native Android lab using local SDK tools, without Gradle."""
import argparse
import os
from pathlib import Path
import shutil
import subprocess
import zipfile
import xml.etree.ElementTree as ET

ROOT = Path(__file__).resolve().parent.parent


def run(args):
    subprocess.run([str(a) for a in args], check=True)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--sdk", type=Path, default=Path(os.environ.get("ANDROID_HOME", str(Path.home() / "Library/Android/sdk"))))
    parser.add_argument("--jdk", type=Path, default=Path(os.environ.get("JAVA_HOME", "/opt/homebrew/opt/openjdk@17/libexec/openjdk.jdk/Contents/Home")))
    args = parser.parse_args()
    tools = args.sdk / "build-tools/36.0.0"
    platform = args.sdk / "platforms/android-37.0/android.jar"
    source = ROOT / "android/airdrop-lab/src/main"
    build = ROOT / ".build/airdrop/android-lab"
    for name in ("classes", "dex"):
        directory = build / name
        if directory.exists():
            shutil.rmtree(directory)
        directory.mkdir(parents=True)
    environment = os.environ.copy()
    environment["JAVA_HOME"] = str(args.jdk)
    environment["PATH"] = str(args.jdk / "bin") + os.pathsep + environment.get("PATH", "")
    java = args.jdk / "bin"
    run([java / "javac", "-encoding", "UTF-8", "--release", "17", "-classpath", platform,
         "-d", build / "classes", *sorted((source / "java").rglob("*.java"))])
    run([java / "jar", "--create", "--file", build / "classes.jar", "-C", build / "classes", "."])
    subprocess.run([str(tools / "d8"), "--min-api", "31", "--lib", str(platform),
                    "--output", str(build / "dex"), str(build / "classes.jar")], env=environment, check=True)
    ET.register_namespace("android", "http://schemas.android.com/apk/res/android")
    manifest = ET.parse(source / "AndroidManifest.xml")
    manifest.getroot().set("package", "dev.bridge.airdroplab")
    manifest.write(build / "AndroidManifest.xml", encoding="utf-8", xml_declaration=True)
    run([tools / "aapt2", "link", "--manifest", build / "AndroidManifest.xml", "-I", platform,
         "--min-sdk-version", "31", "--target-sdk-version", "37", "--version-code", "1",
         "--version-name", "0.1", "--rename-manifest-package", "dev.bridge.airdroplab", "-o", build / "unsigned.apk"])
    with zipfile.ZipFile(build / "unsigned.apk", "a", compression=zipfile.ZIP_STORED) as apk:
        for dex in sorted((build / "dex").glob("*.dex")):
            apk.write(dex, dex.name)
    run([tools / "zipalign", "-f", "-P", "16", "4", build / "unsigned.apk", build / "aligned.apk"])
    key = build / "lab-debug.keystore"
    if not key.exists():
        run([java / "keytool", "-genkeypair", "-keystore", key, "-alias", "airdrop-lab",
             "-storepass", "android", "-keypass", "android", "-keyalg", "RSA", "-keysize", "2048",
             "-validity", "3650", "-dname", "CN=Bridge AirDrop Lab Debug"])
    output = ROOT / "dist/Bridge-AirDrop-Lab.apk"
    output.parent.mkdir(exist_ok=True)
    subprocess.run([str(tools / "apksigner"), "sign", "--ks", str(key), "--ks-key-alias", "airdrop-lab",
                    "--ks-pass", "pass:android", "--key-pass", "pass:android", "--out", str(output),
                    str(build / "aligned.apk")], env=environment, check=True)
    subprocess.run([str(tools / "apksigner"), "verify", "--verbose", str(output)], env=environment, check=True)
    run([tools / "zipalign", "-c", "-P", "16", "4", output])
    print(f"Built {output} (separate application dev.bridge.airdroplab)")


if __name__ == "__main__":
    main()
