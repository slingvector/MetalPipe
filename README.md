# MetalPipe v2

**Low-latency, restart-proof iPad → Mac screen streaming over LAN.**

Streams the iPad's screen to a window on the Mac using hardware H.264 end-to-end,
designed for OBS capture (YouTube content creation, demos, live canvas work).
Rebuilt from scratch after v1's classic ReplayKit failure: *"works two or three
times, then silently gets stuck."*

```
┌─────────────────── iPad ───────────────────┐      ┌──────────────── Mac ────────────────┐
│  ReplayKit broadcast extension             │      │  MetalPipeReceiver.app              │
│                                            │ TCP  │                                     │
│  CMSampleBuffer → VTCompressionSession ────┼─────▶│ NWListener → Depacketizer →         │
│  (HW H.264, realtime, no B-frames)         │ LAN  │ VTDecompressionSession →            │
│  → Packetizer → NWConnection (Bonjour)     │      │ CVMetalTextureCache → MTKView       │
│                                            │      │ (window captured by OBS)            │
│  Memory guard: shed @35MB, exit @45MB      │      │ Watchdog: reset after 5s silence    │
└────────────────────────────────────────────┘      └─────────────────────────────────────┘
```

## Why v1 died — and what v2 does about it

ReplayKit broadcast upload extensions are **silently killed by jetsam at ~50MB**
with no crash dialog and no log. Combine that with stale sockets and a receiver
that never resets its decoder, and you get the v1 symptom: a stream that works a
few times, then "just stops."

| v1 failure mode | v2 defence |
|---|---|
| Extension jetsam-killed at ~50MB (silent) | No Metal in the extension, zero raw-frame buffering, `MemoryGuard` sheds frames at 35MB and ends the broadcast *with a visible error* at 45MB |
| Unbounded send queue during Wi-Fi hiccups | Backpressure: >3MB in flight ⇒ drop delta frames, never queue |
| Stale sockets between sessions | Network.framework lifecycle + single-connection policy: a new connection always evicts the old |
| Decoder kept old state → frozen second run | `sessionStart` packet forces a full decoder reset; SPS/PPS re-sent on **every** keyframe; format change ⇒ rebuild session |
| Sender vanished, receiver waited forever | 5-second watchdog drops the connection and resets the decoder |

**Core invariant: no state survives a session.** Every broadcast is
self-describing, every teardown is total. Restartability is designed in, not
patched on.

## Modules

| Module | Platform | Role |
|---|---|---|
| `MetalPipeKit` | shared | Wire protocol, packetizer/depacketizer, config. Pure Swift, compiled into all three targets. |
| `BroadcastExtension` | iOS | `SampleHandler` → hardware encoder → network sender. Encode and ship, nothing else. |
| `HostApp` | iOS | Broadcast picker + Local Network permission primer + receiver-found indicator. |
| `MacReceiver` | macOS | Bonjour-advertised listener → decoder → Metal NV12 renderer. The window OBS captures. |

## Quick start

1. Open `MetalPipeReceiver.xcodeproj` in Xcode.
2. Set your team on all three targets (Signing & Capabilities).
3. Follow **[SETUP.md](SETUP.md)** for the mandatory Info.plist keys and
   entitlements — they are the difference between working and silently failing:
   - Both iOS targets: `NSBonjourServices` (`_metalpipe._tcp`) + `NSLocalNetworkUsageDescription`
   - Mac target: App Sandbox → Incoming Connections (Server) + Outgoing Connections (Client)
4. Run `MetalPipeReceiver` on the Mac → window shows *"Waiting for iPad…"*
5. Run `MetalPipeHost` on the iPad → allow Local Network → wait for
   *"Receiver found on network"* ✅
6. Tap the broadcast button → **MetalPipe** → Start Broadcast.
7. In OBS: add a Window Capture source → pick the MetalPipe Receiver window.

## Receiver status pill

| Pill | Meaning |
|---|---|
| 🟠 Waiting for iPad… | Listening, no connection |
| 🟢 Connected — waiting for video… | Extension connected, no frames yet |
| *(hidden)* | Streaming — clean frame for OBS |
| 🟠 Sender silent — resetting… | Watchdog fired, self-healing |

## Tuning

All knobs live in one file: [`MetalPipeKit/MetalPipeConfig.swift`](MetalPipeKit/MetalPipeConfig.swift)
— bitrate (default 12 Mbps), FPS, keyframe interval, backpressure threshold,
memory limits, watchdog timeout.

## Troubleshooting

- **iPad stuck on "Searching for receiver…"** → Local Network permission denied
  or `NSBonjourServices` missing/typo'd in an Info.plist. Both devices must be on
  the same network.
- **MetalPipe missing from the broadcast picker** → extension failed to install:
  check signing on the `BroadcastExtension` target, or reboot the iPad.
- **Broadcast ends with a memory error** → working as designed; the extension hit
  45MB and chose a clean exit over a silent jetsam kill. Lower the bitrate.
- **Extension logs**: `log stream --predicate 'process == "BroadcastExtension"'`
  on a connected device, or Console.app filtered by process name.

## Out of scope (for now)

Audio (OBS captures it separately), HEVC (one-constant change later), and the
standalone camera-sender app from v1.

## Regression checklist

Before trusting any change, the stream must survive:

- [ ] Start → stop → start broadcast **5+ times in a row**
- [ ] Mac app quit & relaunched mid-broadcast (iPad auto-reconnects)
- [ ] iPad Wi-Fi toggled off/on mid-broadcast (watchdog resets within 5s)
- [ ] iPad locked and unlocked, then broadcast again
- [ ] 30-minute soak with flat extension memory (well under 35MB)
