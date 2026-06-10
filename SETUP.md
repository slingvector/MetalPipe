# MetalPipe v2 — Xcode Setup Guide

Follow these steps exactly. Almost every "it silently doesn't work" failure in this
kind of project is a missing Info.plist key or entitlement, not code.

## 1. Create the project

1. Xcode → New Project → **macOS → App** (SwiftUI). Name: `MetalPipeReceiver`.
   This becomes the workspace root.
2. File → New → Target → **iOS → App** (SwiftUI). Name: `MetalPipeHost`.
3. File → New → Target → **iOS → Broadcast Upload Extension**.
   Name: `BroadcastExtension`. Embed in `MetalPipeHost`.
   *Uncheck* "Include UI Extension" — we don't need the setup UI.

## 2. Add the source files

| Folder in this scaffold | Add to target(s) |
|---|---|
| `MetalPipeKit/*.swift` | **All three targets** (check all three boxes in the file inspector) |
| `BroadcastExtension/*.swift` | `BroadcastExtension` only (replace the template `SampleHandler.swift`) |
| `HostApp/MetalPipeHostApp.swift` | `MetalPipeHost` only (replace the template app/ContentView files) |
| `MacReceiver/*.swift` + `Shaders.metal` | `MetalPipeReceiver` only (replace templates) |

> Sharing MetalPipeKit by target membership is the simplest reliable approach for a
> small kit like this. (A Swift Package works too, but cross-platform iOS+macOS
> packages inside one Xcode project add friction you don't need yet.)

## 3. Info.plist — iOS host app AND broadcast extension (both!)

Add to **both** iOS targets:

```xml
<key>NSLocalNetworkUsageDescription</key>
<string>MetalPipe streams your screen to the receiver app on your Mac over the local network.</string>
<key>NSBonjourServices</key>
<array>
    <string>_metalpipe._tcp</string>
</array>
```

⚠️ **This is the #1 silent killer.** Without `NSBonjourServices` listing the exact
service type, the Bonjour browse returns nothing — no error, no prompt, nothing.
And the permission *prompt* can only appear from the host app, never from the
extension — which is why `MetalPipeHostApp` runs a browse on launch.

## 4. Entitlements — Mac receiver

Target `MetalPipeReceiver` → Signing & Capabilities → App Sandbox:

- ✅ **Incoming Connections (Server)** ← required for NWListener
- ✅ **Outgoing Connections (Client)**

Without "Incoming Connections (Server)" the listener fails to start and the iPad
never finds anything.

## 5. Set the extension bundle ID in the picker

In `HostApp/MetalPipeHostApp.swift`, replace:

```swift
picker.preferredExtension = "com.YOURTEAM.MetalPipe.BroadcastExtension"
```

with your real extension bundle identifier (visible in the extension target's
General tab).

## 6. Extension memory ceiling sanity check

The extension target's deployment settings need nothing special, but remember:
**~50MB hard memory limit, enforced silently.** The code already guards this
(`MemoryGuard`), degrades at 35MB, and ends the broadcast cleanly with a visible
error at 45MB instead of being silently killed.

## 7. Build & run order

1. Run `MetalPipeReceiver` on the Mac. Status shows "Waiting for iPad…".
2. Run `MetalPipeHost` on the iPad (this installs the extension).
   - First launch triggers the **Local Network permission prompt — tap Allow.**
   - Wait for "Receiver found on network" ✅.
3. Tap the broadcast button → choose **MetalPipe** → Start Broadcast.
4. Video appears in the Mac window within ~2s (first keyframe).
5. In OBS: add a **macOS Screen Capture / Window Capture** source → pick the
   MetalPipe Receiver window.

## 8. Verifying the failure modes are actually fixed

Run these before calling it done — this is the regression suite for "got stuck":

- [ ] Start → stop → start broadcast **5+ times in a row**. Picture returns every time.
- [ ] Quit and relaunch the **Mac app mid-broadcast**. iPad reconnects automatically (browser restarts on connection failure).
- [ ] Toggle iPad **Wi-Fi off/on mid-broadcast**. Watchdog resets within 5s; reconnect works.
- [ ] Lock the iPad mid-broadcast, unlock, broadcast again. Clean.
- [ ] Leave it streaming for 30+ minutes. In Xcode, attach to the extension process
      (Debug → Attach to Process) and confirm memory is flat, well under 35MB.

## Debugging the extension

Extensions don't log to the app's console. Use:

```bash
# Live extension logs on a connected iPad:
log stream --predicate 'process == "BroadcastExtension"' --level debug
```

Or in Console.app, filter by the extension process name. If the extension dies,
search for `jetsam` or `EXC_RESOURCE` in the device's crash logs
(Xcode → Window → Devices and Simulators → View Device Logs).
