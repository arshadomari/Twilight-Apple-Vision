# Twilight for Apple Vision Pro

A native visionOS port of [Twilight 7.1.0](https://github.com/Neguete10/twilight/releases/tag/v7.1.0), a GameStream/Sunshine client that is itself a fork of Moonlight Qt. Moonlight has not endorsed this project. GPL-3.0, like Twilight.

Twilight's Qt/QML shell and macOS-only pieces (IOKit, CoreHID, MoltenVK, Game Mode) don't run on visionOS. This port keeps the parts that matter:

| Twilight 7.1.0 (Mac)                       | This port (Vision Pro)                                      |
|--------------------------------------------|-------------------------------------------------------------|
| moonlight-common-c (Andy Grundman's fork)  | Same commit (`Vendor/moonlight-common-c`), built from source |
| OpenSSL                                    | mbedTLS 3.6 (PSA crypto)                                     |
| NvPairingManager / IdentityManager / NvHTTP | `Pairing.swift`, `ClientIdentity.swift`, `GameStreamHTTP.swift` |
| Metal / VideoToolbox decoder               | VideoToolbox through `AVSampleBufferDisplayLayer`            |
| Core Audio spatial mixer                   | libopus + AVAudioEngine; visionOS spatial audio (anchored, follow head, off) |
| SDL game controllers                       | GameController framework, with rumble via Core Haptics       |
| Hosts sidebar + game library shell         | SwiftUI `NavigationSplitView`, box art grid                 |
| Twilight HUD (FPS, bitrate, latency, End)  | Stream window HUD and ornament controls                     |

Input: game controllers (including DualSense, with rumble), Bluetooth keyboards and mice/trackpads go straight to the host. While the stream is in view, the app takes the controller from visionOS (`GCEventInteraction`), so the thumbsticks reach the host instead of driving system UI.

The default pointer mode is **Trackpad**: pinch and drag moves the cursor, a quick pinch clicks, and pinch-hold-then-move drags. It uses relative mouse motion like Twilight's default mouse mode, which every host honours. **Direct** mode (Settings → Input) moves the cursor to where you look and pinch, using absolute positioning; some hosts ignore it. The ornament under the stream has a right-click toggle and an on-screen keyboard.

The stream window opens in place of the library window (`pushWindow`), so it appears where you're already looking.

The PC can't stream more frames per second than its display refresh rate. For 90 fps (Vision Pro's display rate), set the host display to 90 Hz or use Apollo/Vibepollo's virtual display.

Not ported yet: AV1 (needs `av1C` construction), PyroWave, microphone forwarding, adaptive bitrate, Wake-on-LAN, HDR metadata passthrough.

The stream libraries (mbedTLS, libopus, moonlight-common-c) and TwilightKit are always compiled with optimisation, even in Debug builds, because they run per packet. The shared `Twilight` scheme runs the Release configuration without the debugger attached.

## Layout

- `Package.swift` – **TwilightKit**: the C libraries (`Vendor/` submodules) plus the Swift streaming core in `Sources/`.
- `App/TwilightVision.xcodeproj` – the visionOS app (`App/Twilight/`), which depends on TwilightKit locally.
- `Tests/TwilightKitTests` – crypto, video bitstream, XML and settings tests (`swift test` runs them on the Mac).

## Building

```sh
git submodule update --init --recursive
swift test                       # core tests on macOS
open App/TwilightVision.xcodeproj
```

Pick the **Twilight** scheme and an Apple Vision Pro simulator or device. For a device, set your team under Signing & Capabilities and change the bundle ID `dev.twilight.vision` if needed.

On the host, run Sunshine (or a fork such as Vibepollo) or GeForce Experience. Make sure TCP 47984, 47989 and 48010 and UDP 47998–48000 are reachable.
