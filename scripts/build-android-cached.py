#!/usr/bin/env python3
"""Rebuild production Kotlin/resources with cached SDK artifacts, without Gradle sockets.

Requires a successful prior release Gradle build with identical dependencies,
Gradle 9.6.0 caches and the local Bridge/debug signing key. Runtime library
DEX and merged library resources are reused; all application Kotlin and resources
are compiled from current sources. This is a constrained-environment build fallback.
"""
import copy
import hashlib
import json
import os
import pathlib
import re
import shutil
import subprocess
import sys
import time
import xml.etree.ElementTree as ET
import zipfile

ROOT = pathlib.Path(__file__).resolve().parents[1]
SDK = pathlib.Path(os.environ.get('ANDROID_HOME', pathlib.Path.home() / 'Library/Android/sdk'))
JAVA = pathlib.Path(os.environ.get('JAVA_HOME', '/opt/homebrew/opt/openjdk@17/libexec/openjdk.jdk/Contents/Home')) / 'bin/java'
os.environ['JAVA_HOME'] = str(JAVA.parent.parent)
CACHE = pathlib.Path.home() / '.gradle/caches'
MODULES = CACHE / 'modules-2/files-2.1'
INTER = ROOT / 'android/app/build/intermediates'
SOURCE = ROOT / 'android/app/src/main'
build_config = (ROOT / 'android/app/build.gradle.kts').read_text()
VERSION = re.search(r'versionName\s*=\s*"([^"]+)"', build_config).group(1)
VERSION_CODE = int(re.search(r'versionCode\s*=\s*(\d+)', build_config).group(1))
OUT = ROOT / '.build/android-direct'
if OUT.exists(): shutil.rmtree(OUT)
OUT.mkdir(parents=True)

def run(args):
    print('Running', pathlib.Path(str(args[0])).name, str(args[1]) if len(args) > 1 else '', flush=True)
    subprocess.run([str(a) for a in args], cwd=ROOT, check=True)

def jar(name):
    found = list(MODULES.rglob(name))
    if not found: raise RuntimeError('Missing cached dependency: ' + name)
    return found[0]

compiler_names = ['kotlin-compiler-embeddable-2.2.10.jar', 'kotlin-stdlib-2.2.10.jar', 'kotlin-script-runtime-2.2.10.jar', 'kotlin-reflect-1.6.10.jar', 'kotlinx-coroutines-core-jvm-1.8.0.jar', 'annotations-13.0.jar']
compiler = os.pathsep.join(str(jar(n)) for n in compiler_names)
compose_plugin = jar('kotlin-compose-compiler-plugin-embeddable-2.2.10.jar')
android_jar = SDK / 'platforms/android-37.0/android.jar'
# Android AAR class files plus the exact Kotlin/coroutines modules used by app.
classpath = []
seen = set()
for path in sorted(CACHE.glob('9.6.0/transforms/*/transformed/**/jars/classes.jar')):
    digest = hashlib.sha256(path.read_bytes()).digest()
    if digest not in seen: seen.add(digest); classpath.append(path)
for name in ['kotlin-stdlib-2.2.10.jar', 'kotlinx-coroutines-core-jvm-1.10.2.jar', 'kotlinx-coroutines-android-1.10.2.jar', 'annotations-13.0.jar', 'lifecycle-common-jvm-2.9.4.jar']:
    classpath.append(jar(name))
for path in CACHE.glob('9.6.0/transforms/*/transformed/*-api.jar'):
    digest = hashlib.sha256(path.read_bytes()).digest()
    if digest not in seen: seen.add(digest); classpath.append(path)
classpath.extend([android_jar, INTER / 'compile_and_runtime_r_class_jar/release/processReleaseResources/R.jar'])

aapt_candidates = list(CACHE.glob('9.6.0/transforms/*/transformed/aapt2-*/aapt2'))
if not aapt_candidates: raise RuntimeError('Cached AAPT2 required')
aapt = aapt_candidates[0]
compiled = OUT / 'app-res.zip'
run([aapt, 'compile', '--dir', SOURCE / 'res', '-o', compiled])
ANDROID = 'http://schemas.android.com/apk/res/android'
ET.register_namespace('android', ANDROID)
attribute = lambda name: '{' + ANDROID + '}' + name
# Retain dependency-added scanner/startup declarations. Replace all app-owned
# declarations with source manifest so the fallback never ships stale app rules.
merged = ET.parse(INTER / 'merged_manifests/release/processReleaseManifest/AndroidManifest.xml').getroot()
current = ET.parse(SOURCE / 'AndroidManifest.xml').getroot()
merged.set(attribute('versionCode'), str(VERSION_CODE)); merged.set(attribute('versionName'), VERSION)
app = merged.find('application'); source_app = current.find('application')
for name, value in source_app.attrib.items(): app.set(name, value)
app.set(attribute('debuggable'), 'false')
for element in current:
    if element.tag == 'application': continue
    name = element.get(attribute('name'))
    for existing in list(merged):
        if existing.tag == element.tag and existing.get(attribute('name')) == name: merged.remove(existing)
    merged.append(copy.deepcopy(element))
# Remove all old app-owned declarations before adding current ones. Library
# scanner/startup components are retained. Never resurrect removed services.
for existing in list(app):
    component = existing.get(attribute('name'), '')
    if component.startswith('.') or component.startswith('dev.bridge.companion.'):
        app.remove(existing)
for element in source_app:
    name = element.get(attribute('name'), '')
    normalized = 'dev.bridge.companion' + name if name.startswith('.') else name
    for existing in list(app):
        other = existing.get(attribute('name'), '')
        if existing.tag == element.tag and other in [name, normalized]: app.remove(existing)
    fresh = copy.deepcopy(element)
    if name.startswith('.'): fresh.set(attribute('name'), normalized)
    app.append(fresh)
manifest = OUT / 'AndroidManifest.xml'
ET.ElementTree(merged).write(manifest, encoding='utf-8', xml_declaration=True)
base_resources = sorted(p for p in (INTER / 'merged_res/release/mergeReleaseResources').glob('*.flat') if 'pointer_assistance' not in p.name)
if not base_resources: raise RuntimeError('Prior merged dependency resources required')
# Gradle stores AAR non-values resources in transformed dependency directories
# rather than copying them into the app's merged_res output.
dependency_resources = []
resource_hashes = set()
for path in sorted(CACHE.glob('9.6.0/transforms/*/transformed/**/*.flat')):
    if path.name.startswith('values'): continue
    digest = hashlib.sha256(path.read_bytes()).digest()
    if digest not in resource_hashes:
        resource_hashes.add(digest); dependency_resources.append(path)
resource_apk = OUT / 'resources.apk'
generated_r = OUT / 'generated-r'; generated_r.mkdir()
run([aapt, 'link', '-o', resource_apk, '-I', android_jar, '--manifest', manifest,
     '--java', generated_r, '--custom-package', 'dev.bridge.companion',
     '--min-sdk-version', '29', '--target-sdk-version', '37', '--auto-add-overlay',
     '--stable-ids', INTER / 'stable_resource_ids_file/release/processReleaseResources/stableIds.txt',
     *dependency_resources, *base_resources, '-R', compiled])

# Generate current application resource constants before compiling Kotlin. Cached
# R classes alone cannot represent newly added drawables and may embed stale IDs.
resource_classes = OUT / 'resource-classes'; resource_classes.mkdir()
with zipfile.ZipFile(INTER / 'compile_and_runtime_r_class_jar/release/processReleaseResources/R.jar') as cached_r:
    cached_r.extractall(resource_classes)
for old_r in (resource_classes / 'dev/bridge/companion').glob('R*.class'):
    old_r.unlink()
r_sources = sorted(generated_r.rglob('*.java'))
if not r_sources: raise RuntimeError('AAPT2 did not generate current resource classes')
run([JAVA.parent / 'javac', '--release', '17', '-d', resource_classes, *r_sources])
classpath.insert(0, resource_classes)

cp = os.pathsep.join(str(p) for p in classpath)
classes = OUT / 'classes'; classes.mkdir()
kotlin_sources = sorted(SOURCE.rglob('*.kt'))
source_hashes = {str(p.relative_to(ROOT)): hashlib.sha256(p.read_bytes()).hexdigest() for p in kotlin_sources}
run([JAVA, '-Xmx3g', '-cp', compiler, 'org.jetbrains.kotlin.cli.jvm.K2JVMCompiler', '-no-stdlib', '-no-reflect', '-jvm-target', '17', '-Xplugin=' + str(compose_plugin), '-cp', cp, '-d', classes, *kotlin_sources])
# Include freshly generated application R classes and unchanged dependency R classes.
shutil.copytree(resource_classes, classes, dirs_exist_ok=True)
app_jar = OUT / 'app.jar'
with zipfile.ZipFile(app_jar, 'w', zipfile.ZIP_DEFLATED) as archive:
    for path in classes.rglob('*'):
        if path.is_file(): archive.write(path, path.relative_to(classes))

dex = OUT / 'dex'; dex.mkdir()
build_tools = SDK / 'build-tools/36.0.0'
d8 = build_tools / 'd8'
env = os.environ.copy(); env['JAVA_HOME'] = str(JAVA.parent.parent)
# Merge fresh project classes with cached, unchanged dependency DEX; D8 validates
# duplicate classes and desugars fresh app bytecode against the full classpath.
external_dex = sorted((INTER / 'external_libs_dex/release/mergeExtDexRelease').glob('*.dex'))
external_dex += sorted((INTER / 'global_synthetics_dex/release/mergeReleaseGlobalSynthetics').glob('*.dex'))
if not external_dex: raise RuntimeError('Prior dependency DEX required')
print('Running D8 production dex merge', flush=True)
subprocess.run([str(d8), '--release', '--min-api', '29', '--lib', str(android_jar),
                *[flag for path in classpath if path != android_jar for flag in ('--classpath', str(path))],
                '--output', str(dex), str(app_jar), *map(str, external_dex)], env=env, check=True, cwd=ROOT)
unsigned = OUT / 'unsigned.apk'
# Preserve library assets/native components/Java service resources, never old
# app bytecode, manifest, resources or signatures.
prior = ROOT / 'android/app/build/outputs/apk/release/app-release.apk'
with zipfile.ZipFile(unsigned, 'w', zipfile.ZIP_DEFLATED) as target:
    with zipfile.ZipFile(resource_apk) as resources:
        for info in resources.infolist():
            # Android 11+ requires an uncompressed/aligned resource table.
            compression = zipfile.ZIP_STORED if info.filename == 'resources.arsc' else zipfile.ZIP_DEFLATED
            target.writestr(info.filename, resources.read(info.filename), compress_type=compression)
    with zipfile.ZipFile(prior) as previous:
        for info in previous.infolist():
            name = info.filename
            if name.startswith(('assets/', 'lib/', 'META-INF/services/')) or name.endswith('.version'):
                # extractNativeLibs=false requires native libraries stored and
                # page aligned in the APK; compression prevents installation.
                compression = zipfile.ZIP_STORED if name.startswith('lib/') and name.endswith('.so') else zipfile.ZIP_DEFLATED
                target.writestr(name, previous.read(name), compress_type=compression)
    for path in sorted(dex.glob('*.dex')): target.write(path, path.name)
aligned = OUT / 'aligned.apk'
run([build_tools / 'zipalign', '-f', '-P', '16', '4', unsigned, aligned])
output = ROOT / 'dist/Bridge-direct-transfer.apk'; output.parent.mkdir(parents=True, exist_ok=True)
original_key = ROOT.parent / 'private-workspace/.tooling/gradle/android-signing.jks'
keystore = original_key if original_key.exists() else pathlib.Path.home() / '.android/debug.keystore'
if not keystore.exists(): raise RuntimeError('Existing update-compatible signing key required')
run([build_tools / 'apksigner', 'sign', '--ks', keystore, '--ks-key-alias', 'androiddebugkey',
     '--ks-pass', 'pass:android', '--key-pass', 'pass:android', '--out', output, aligned])
run([build_tools / 'apksigner', 'verify', '--verbose', '--print-certs', output])
run([build_tools / 'zipalign', '-c', '-P', '16', '4', output])
run([aapt, 'dump', 'badging', output])
for file, digest in source_hashes.items():
    if hashlib.sha256((ROOT / file).read_bytes()).hexdigest() != digest:
        raise RuntimeError('Source changed during build: ' + file + '; rebuild before release')
report = {'version': VERSION, 'versionCode': VERSION_CODE, 'debuggable': False, 'builtAt': time.time(),
          'method': 'fresh Kotlin, Compose and application resources; cached unchanged dependency resources and DEX',
          'sources': source_hashes,
          'sha256': hashlib.sha256(output.read_bytes()).hexdigest()}
pathlib.Path(str(output) + '.build.json').write_text(json.dumps(report, indent=2) + '\n')
pathlib.Path(str(output) + '.sha256').write_text(report['sha256'] + '  ' + output.name + '\n')
# Keep this test APK separate from published release artifacts.
print('Built', output)
