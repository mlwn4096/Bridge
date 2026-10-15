# Bridge protocol v1

Optional `directHotspotV1` and `speedProbeV1` extend connection setup and diagnostics
without changing file framing. See [DIRECT_TRANSFER.md](DIRECT_TRANSFER.md) for
setup, measurement definitions and device-validation limits.

Android is the TLS client; Mac hosts an ephemeral TCP port advertised as `_bridge._tcp`. Discovery is a hint, not trust: the QR-pinned SHA-256 certificate fingerprint must match before any pairing token or credential is sent. No cleartext transport exists.

Control frames are UTF-8 JSON objects followed by LF (negotiated binary frames are described below):

```json
{"v":1,"id":"unique-message-id","type":"ping","payload":{}}
```

Limit: 131072 bytes excluding LF. Embedded newlines in text are JSON-escaped. UUID message IDs are generated locally. Post-authentication messages except `ack` are acknowledged using `ack.payload.messageID`; a bounded set of 2048 IDs suppresses duplicates per connection. Control messages are not replayed across connections. Durable queued files may be offered again with the same transfer ID after reconnect. Malformed frames close the connection. Heartbeats run every 15 seconds; stale connections are closed after 50 seconds without inbound traffic. Android uses bounded exponential reconnect delay (1–15 seconds).

## Enrollment and authentication

- QR: `bridge://pair?host=...&port=...&fingerprint=...&token=...&name=...&service=...`; token is 32 random bytes, base64 encoded, valid for five minutes.
- `pairRequest`: `token`, `deviceID` (UUID), `name`, `credential` (32 random bytes, base64). Mac requires valid token, no current paired device, and user approval.
- `pairAccepted`: Mac `name`. Client persists the credential only after approval; enrollment token is discarded.
- `auth`: `deviceID`, `credential`. Mac checks the paired device and its owner-only salted credential verifier. Legacy Keychain credentials are read only for one-time migration.
- `authAccepted`: Mac `name`. Feature traffic is then allowed. Only one authenticated session is active.
- `unpair`: either peer revokes its local credential and disconnects; Mac rejects subsequent attempts using the revoked credential.
- Unsupported versions, failed pinning, invalid authentication, expired tokens, and unauthenticated feature messages fail closed.

## Feature messages

| Type | Payload |
| --- | --- |
| `preferences` | Mac → phone: `notifications` and `previews` booleans |
| `clipboard` | `text`, maximum 32768 UTF-8 bytes |
| `notification` | phone → Mac: `key`, `app`, `package`, `title`, `body`; content omitted when previews are off |
| `notificationRemoved` | `key` |
| `notificationDismiss` | Mac → phone: `key`; only active clearable nonexcluded notifications |
| `notificationDismissResult` | `key`, boolean `accepted` |
| `notificationAction` | Mac → phone: `key`, opaque single-use `actionID`; requires current notification, unlocked phone and enabled previews |
| `notificationActionResult` | `actionID`, boolean `accepted`; reports PendingIntent dispatch, not application outcome |
| `media` | phone → Mac: boolean `available`, ephemeral `sessionID`, `title`, `artist`, boolean `playing`, supported `actions` array |
| `mediaCommand` | Mac → phone: current `sessionID`, `action` (`play`, `pause`, `previous`, `next`, `volumeUp`, `volumeDown`) |
| `mediaCommandResult` | boolean `accepted`; dispatch acceptance is not proof that the player completed the action |
| `link` | `url`; only http/https with a host, maximum 8192 bytes |
| `battery` | phone → Mac: integer `level` 0–100, boolean `charging`, optional boolean `powerSave` (older peers omit it) |
| `ring` | Mac → phone: boolean `start` |
| `ringState` | phone → Mac: boolean `ringing` |
| `ping`, `pong`, `unpair` | empty object |
| `error` | user-facing `message`; never credentials |

## File transfer

1. `fileOffer`: `transferID` UUID, `name` (safe basename), `size` (0–17179869184), `sha256` (lowercase hex). Maximum three pending/active incoming transfers per peer.
2. Receiver explicitly approves with `fileAccept.transferID`, or sends `fileReject.transferID`.
3. Sender streams `fileChunk`: `transferID`, monotonically increasing `sequence` starting at 0, base64 `data`; maximum decoded chunk 32768 bytes.
4. Sender emits `fileComplete.transferID`. Receiver verifies size and SHA-256, commits the temporary file, and emits `fileReceived.transferID`.
5. Peers advertising `fileFailureV1` use `fileFailed.transferID/reason` for receiver write, integrity or publication failures. The sender retains its durable queue entry and applies bounded retries (pause after three attempts). With older peers, receiver failures use `fileReject`, preserving the sender queue in a paused state for explicit retry. Late failures for inactive transfers are ignored.
6. `fileCancel.transferID` aborts either direction; disconnects also discard incoming partials; durable outgoing items remain queued for a later attempt starting at byte zero. Progress is derived from accepted bytes. Sender completion requires `fileReceived`.

Reject path separators, traversal names, control characters, overlong basenames, invalid sizes/hashes, out-of-sequence chunks, and excess bytes. Receive to temporary files. Never open a received file or link automatically. Mac does not overwrite an existing destination. Android uses scoped MediaStore or user-selected document destinations; temporary destinations remain unpublished until verified.

## Incoming Android save policy

Files smaller than 1,000,000,000 bytes are accepted automatically from the authenticated paired Mac into MediaStore Downloads/FromMac. Exactly 1 GB and larger require a user-created SAF document before fileAccept. Both peers cap files at 16 GiB. The existing framing/chunk protocol is unchanged; older app versions can reject files above their previous cap. Pending Downloads rows remain hidden until exact length and SHA-256 verification. Interrupted document destinations are journaled privately for recovery; unavailable providers retain cleanup records for a later startup.

## Negotiated binary file frames

Both endpoints advertise `capabilities: ["binaryFileV1"]` in authentication/pairing request and acceptance messages. File offers select `encoding: "binary-v1"` when both support it; fileAccept confirms this encoding. Without the capability/confirmation, existing newline JSON/Base64 fileChunk remains supported.

On the same authenticated TLS stream, a zero first byte marks a binary frame; JSON control frames continue beginning with `{` and ending in newline. Binary header: 0x00, unsigned 32-bit big-endian body length, 36 ASCII bytes of canonical UUID (case preserved), nonnegative 64-bit big-endian sequence, raw data. Body length is 45 through 262188 bytes, with at most 262144 data bytes. Frames can be fragmented/coalesced with control frames. Invalid declared sizes are rejected before body allocation. Binary frames bypass message-ID ACK/dedup and use per-transfer sequence and the existing end-of-file SHA-256/length validation. Neither empty data frames nor binary frames before authentication/capability negotiation are accepted.

Mac batches at most four data chunks before awaiting Network.framework processing callbacks, keeping application buffering bounded. Receiving on Mac waits for file IO completion before reading more frames. Unknown transfer chunks may be discarded to drain already-in-flight cancelled data. Android bulk reads the explicit-length body, and reserved `_binaryChunk` is internal-only (cannot be supplied as a JSON message type). UI MB/s is an average over the active sending/receiving phase, excluding preparation/acceptance and final provider close/verification time. It is not an end-to-end completion benchmark.

Integrity preparation remains unchanged in this increment: Mac calculates the file hash before offering; Android prepares a cached outgoing file and hash. This preserves stable advertised metadata while optimizing the transfer phase.

## Receiver-confirmed progress

Updated peers also advertise `receiverProgressV1`. For negotiated binary transfers, receiver sends `fileProgress` with transferID and nonnegative integer receivedBytes, at most approximately twice per second and at the last chunk. Sender rejects regressing, out-of-bounds or noninteger reports, and uses a smoothed recent rate plus remaining bytes for estimates. Legacy peers retain local-write estimates.

Local fileComplete transmission does not force receiver-confirmed percentage to 100: sender enters Finishing, continues accepting progress, then Verifying after receiver counts all bytes. Complete still requires fileReceived after exact-length/SHA-256 validation and destination close/publication. Five seconds without progress replaces live estimates with Waiting for data. Estimates exclude preparation/acceptance and cannot predict final provider-close latency.

## USB tunnel
Mac polls authorized physical USB transports via installed ADB, excludes wireless debugging, and maps Android loopback port 38473 to the live Mac listener using reverse TCP forwarding. Only a single authorized physical device is configured to avoid ambiguity. Existing TLS certificate pinning, pairing credentials, framing, file integrity, acceptance and save rules apply unchanged. Auth messages can carry `transport: usb` for the connection label (cosmetic metadata, not authorization). Android tries this pinned loopback endpoint before its persisted LAN address; the USB endpoint never replaces persisted LAN discovery information. Between transfers Android probes pinned TLS on loopback, requests `usbSwitchRequest` over the authenticated control connection, and closes the LAN route only after `usbSwitchReady` and its own idle check. Mac replies only when its file queues are empty. Unplugging during a file interrupts that attempt; its durable outgoing item can retry after reconnect from byte zero, not the interrupted offset. Wireless fallback occurs on the next connection attempt. ADB and USB debugging authorization are required; Android Studio need not run. Actual speeds remain subject to USB negotiation, ADB, TLS and storage.

## Bounded transfer pipeline (hotspot optimization)
Binary framing and capabilities are unchanged. Mac submits ordered batches sequentially, retaining at most four outstanding drain receipts (1 MiB payload per batch). A receipt completes only after all its Network.framework contentProcessed callbacks finish. The next batch can be read and encoded while earlier batches drain. Final `fileComplete` is enqueued only after all receipts finish; receiver-confirmed progress and final `fileReceived` remain authoritative. Network callbacks/decoder use a private serial queue; model access and callback delivery return to main. Receive requests are capped at 1 MiB.

Android authenticates in the socket-reader coroutine, then submits parsed messages into one per-connection 16-slot channel. A single consumer handles chunks and controls in exact wire order, so final verification cannot overtake queued chunks. This permits at most 4 MiB queued binary payload plus the current reader/consumer frames, output buffering and protocol overhead. Backpressure stops the reader when the channel fills. Shutdown cancels the queue and joins the consumer before partial-file cleanup. Existing incomingLock also protects writes against user cancellation/service shutdown. No parallel TCP or protocol switch is introduced in this increment.

## Browser link handoff
Existing `link` messages can include optional `title` alongside `url`; old peers may ignore it. Android share-sheet inputs whose complete trimmed text is a valid HTTP(S) URL now send this message instead of `clipboard`. Sharing-app EXTRA_SUBJECT or EXTRA_TITLE supplies optional title, not scraped browser state. Mac displays a single latest handoff for ten minutes from local receipt, preserving the exact URL/fragment for user-initiated opening. No page fetch, credentials transfer, scroll position or automatic browser launch. Titles are control-stripped, capped at 160 characters and heuristically filtered for secrets. URL user information, unsafe schemes, whitespace/controls, absent hosts and URLs exceeding 8192 bytes are rejected by Mac. Existing Android consent also applies to sensitive URL payloads. Titles never enter clipboard history.

### Link/file notification opening
Mac drag destination now accepts validated HTTP(S) URLs via URL pasteboard entries or exact URL text, alongside file URLs. `link` messages also trigger Pixel native handoff notifications with user-initiated ACTION_VIEW opening. Mac native received-link notifications use an opaque local handoffID matched against the current, unexpired in-memory card; stale/replaced notifications cannot open a different card. Received-file notification metadata contains only transferID, resolved to a completed incoming transfer destination still present on disk. No opening occurs just from network receipt. Existing mirrored-phone notification dismissal routing is retained.

## Durable queues and receipt deduplication (0.3.0)

Outgoing queues persist locally, with a maximum of 100 items and three concurrent active transfers. Mac references regular selected files and validates their size/modification metadata before sending. folder ZIPs on both platforms and imported files use durable owned copies; Android snapshots outgoing content into private storage before enqueueing. No credential or clipboard payload is placed in a queue journal. Pausing cancels the active attempt and retains the item. Retry restarts the sequence at zero; after three failed attempts the item pauses for explicit retry/removal. This is restart recovery, not byte-offset resume.

Local pairing epochs bind preparation and queued work to current trust. Unpair cancels workers, clears pending work and revokes receipts; re-pairing cannot authorize an old worker to repopulate the queue. Startup recovery removes orphan preparation files. Original Mac sources that changed or disappeared require user attention.

Receivers retain at most 500 completion records for seven days: peer, transfer ID, name, size, hash and completion time. If a new authenticated fileOffer matches an already completed record, the receiver can answer fileReceived with alreadyReceived=true, sha256 and size without saving another copy. The sender accepts this offer-phase receipt only when the complete metadata matches its current advertised file; ordinary receipts still require sender completion state. The ledger contains metadata, not file contents or clipboard text. Full integrity/destination publication precedes recording a receipt.

## Local-only tools

Clipboard history, retained-activity search, finite command parsing, event rules, AppIntents and CLI request/reply files do not add remote protocol privileges. Clipboard history remains opt-in and memory-only on both platforms, with sensitive-text exclusion. Search does not index phone storage or fetch network content. Local event rules run only after explicit configuration; configured Shortcuts retain their own behavior and permissions.

Optional ADB developer operations are separate authorized-USB tooling, not unauthenticated Bridge messages. They do not enable wireless debugging or install dependencies. Shared-storage paths are constrained; arbitrary shell text is unavailable. The normal USB reverse tunnel continues to carry pinned authenticated TLS.

## Notification replies (`notificationReplyV1`)

Both peers advertise this capability during pairing/authentication. Android advertises `actions[].kind=reply` and a bounded `placeholder` only for one free-form text RemoteInput backed by a supported mutable broadcast/service PendingIntent. Ordinary notification action descriptors retain `kind=action`. Mac sends `notificationReply` with notification `key`, single-use `actionID`, and unmodified `text` (nonblank, no NUL, at most 4096 UTF-8 bytes).

Android rechecks sharing/previews, phone unlock, exclusions, active notification post time, PendingIntent identity, RemoteInput result key and a five-minute monotonic action lease. It consumes the token before using `RemoteInput.addResultsToIntent` and `PendingIntent.send`. The response `notificationReplyResult` echoes actionID plus accepted/message. Accepted means the phone app was invoked, not that a server delivered the message. Transport failure or a 15-second result timeout is unknown; replies are never stored or retried automatically. `refreshNotifications` republishes active notification actions with fresh tokens.

Implementation follows the platform [RemoteInput contract](https://developer.android.com/reference/android/app/RemoteInput). Choices-only, data-only, immutable and authentication-required reply actions are not exposed. The first Mac UI uses an explicit composer in Bridge’s notification list.
