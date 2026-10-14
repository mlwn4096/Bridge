# AirDrop interoperability investigation

Investigated on 2026-10-14. Target: **direct Android ↔ native Apple AirDrop, no Mac
relay**, with a non-rooted Pixel 8 on Android 17 as the development phone and broad
Android 12+ compatibility as the intended product scope.

**Status: an experimental Android sender/receiver application layer is implemented
and packaged. Native Apple interoperability remains unverified.** See the
[AirDrop Lab instructions](../android/airdrop-lab/README.md). The separate diagnostic
APK can be installed alongside Bridge; production companion behavior is unchanged.

The lab implements binary plists, TLS, discovery, acceptance and streaming upload
over OS-visible networks. It supplies neither firmware-level AWDL nor BLE wake-up.
It is meant to obtain actual failure-stage evidence on the Pixel rather than assume
the available network interfaces can reach native AirDrop.

## Feasibility finding

The application protocol has published reverse engineering. The unresolved requirement
is an Android-accessible wireless link to native AirDrop receivers. No general route
through the public Android APIs was established for the requested device coverage.
This is not proof that a device-specific undocumented route cannot be discovered.

Android's published [Wi-Fi Direct API](https://developer.android.com/develop/connectivity/wifi/wifi-direct)
provides Wi-Fi P2P and explicitly says Android does not support Wi-Fi ad-hoc mode.
[Wi-Fi Aware](https://developer.android.com/reference/android/net/wifi/aware/package-summary)
provides service discovery and data paths where supported. Neither document establishes
native AirDrop interoperability. P2P/Aware feature presence, Android version and a
successful LAN socket are insufficient evidence of an AWDL-capable app transport.

Google's [May announcement](https://blog.google/products-and-platforms/platforms/android/new-android-updates/)
lists Pixel 10/9 series and Pixel 8a, and its
[June Pixel Drop announcement](https://support.google.com/pixelphone/thread/434934448/june-2026-pixel-drop?hl=en-gb)
explicitly excludes Pixel 8 and Pixel 8 Pro. Installing Android 17 alone therefore
does not establish AirDrop support on the development phone. Current support should
be confirmed on the phone rather than inferred from unofficial rollout reports.

Google documents direct, peer-to-peer interoperability in its
[security explanation](https://security.googleblog.com/2025/11/?hl=en), using Everyone
mode. This establishes that direct interoperability is possible on supported platforms;
it does not expose a general third-party AWDL API for Bridge.

## Recovered protocol outline

Apple describes BLE proximity discovery, peer-to-peer Wi-Fi, contact identity matching
and TLS with iCloud identity certificates in
[AirDrop security](https://support.apple.com/guide/security/airdrop-security-sec2261183f4/web).

The research implementation [OpenDrop](https://github.com/seemoo-lab/opendrop)
uses AWDL, IPv6 and `_airdrop._tcp.local.` DNS-SD. Its documented gaps include BLE
wake-up, peer authentication and automatic acceptance of incoming files. Compatibility
with current OS releases needs new device measurements.

The reference [client](https://github.com/seemoo-lab/opendrop/blob/master/opendrop/client.py)
and [server](https://github.com/seemoo-lab/opendrop/blob/master/opendrop/server.py)
show this application exchange:

| Phase | Reference behavior |
| --- | --- |
| `/Discover` | POST binary plist, optionally `SenderRecordData`; response includes receiver computer/model names and capabilities. |
| `/Ask` | POST binary plist with sender name/model/ID, bundle ID and `Files`. Entries describe filename, UTI, BOM path and directory status. User acceptance precedes upload in Apple's flow. |
| `/Upload` | POST `application/x-cpio`, using HTTP chunked transfer; the reference client constructs gzip-filtered CPIO. |

These are observations of research code, not a verified macOS 27 wire specification.
No upstream source was copied into Bridge.

## Why direct Android needs a separate investigation

[OWL](https://github.com/seemoo-lab/owl) implements the AWDL link and requires a Wi-Fi
adapter with active monitor mode and frame injection. Porting the HTTPS messages to
Kotlin does not supply that link. For an independent backend, identify the phone's
chipset, firmware/driver interfaces and permitted frame/channel operations first.
Root alone does not establish those capabilities.

Google documents direct AirDrop interoperability on selected phones in
[Quick Share help](https://support.google.com/pixelphone/answer/9286773?hl=en).
The page's sending and receiving model lists differ, so verify both directions on
the specific phone. A system share-sheet handoff could serve supported phones,
subject to verifying URI permissions, visibility and acceptance behavior; it does
not meet the requested general independent backend or enable unsupported phones.

## Local probe

From the repository root:

```sh
zsh scripts/probe-airdrop.sh --inventory-only
zsh scripts/probe-airdrop.sh --seconds 10
```

The probe enables peer-to-peer Bonjour discovery and prints interface names, TXT
keys and flags, omitting receiver names, addresses and identity records. It sends
no file offers or HTTPS requests. Open the receiving Apple device's AirDrop screen
and enable suitable visibility. Zero results can mean the receiver was asleep or
not discoverable; a browser error is reported separately.

Local observations: macOS 27.0.1 has an active IPv6 `awdl0` interface. The installed
`sharingd` contains `SDAirDropBonjourDiscoverConnection`, `SDAirDropAskRunnerProtocol`
and `SDAirDropServerConnection` symbols, consistent with the research decomposition.
Those symbols do not verify a current wire format. ADB inventory was blocked by
the execution sandbox, so no Android hardware capability was established.

The probe compiled and its inventory mode confirmed AWDL IPv6 on the Mac. Its
five-second discovery attempt returned `-65563: ServiceNotRunning` and exit status 1
inside this execution environment. This is a failed browse, not a negative result
about nearby Apple devices or the Pixel's capabilities.

## Remaining interoperability validation

1. Obtain a reachable Pixel 8 test session and inspect its Wi-Fi driver/firmware and
   available app-accessible interfaces. Check both transfer directions through any
   system-provided interoperability first, with internet disabled to distinguish
   direct transfers from a cloud QR fallback.
2. Establish an app-accessible wireless data path to a native Apple receiver before
   promoting the experimental endpoints into production. Test the hypothesis of infrastructure-LAN
   reachability separately; it must not be assumed from Bonjour visibility.
3. Capture fresh discovery/TLS/application exchanges on owned devices, recording OS
   versions. Encrypted captures alone do not reveal plist bodies. Do not treat the
   older reference implementation as a current wire specification.
4. Exercise the lab's bounded plist/HTTP parsing, acceptance bound to the original
   connection, streaming CPIO, path/link validation, size limits and cleanup against
   real Apple peers. Adapt current private messages only after measuring failures.
5. Repeat on representative Android 12+ devices. Keep an explicit capability matrix;
   a single successful Pixel experiment does not prove general support.

Broad rootless coverage may require changing the product constraint: supported
system Quick Share interoperability, OEM/firmware cooperation, or a Bridge receiver
on the Apple side. No alternative was added to the apps without selecting that scope.
