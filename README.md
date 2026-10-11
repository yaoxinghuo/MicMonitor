# MicMonitor

English | [中文](README-zh.md)

A lightweight macOS menu bar tool that **passes your microphone through to your headphones in real time**, with adjustable mix volume.
Built for the "wearing noise-isolating headphones and can't hear coworkers calling you" scenario — your music keeps playing through the system as usual; this app only adds the mic signal on top.

<img width="700" height="1144" alt="image" src="https://github.com/user-attachments/assets/27314f65-216c-4550-a05a-6839f5b9f2b5" />

- Lives in the menu bar (optional Dock icon that opens a settings window on click)
- Independently selectable input (mic) and output (headphone) devices; follows system defaults
- Mix volume 0%–200% (soft-clipped above 100%, no clipping distortion), one-click mute
- Optional noise gate with a live level meter to help set the threshold
- Feedback guard: automatically lowers volume when the mic picks up headphone output
- Low-latency mode + adaptive buffering: buffer auto-scales up when a device can't keep a stable clock
- Auto stop/resume on device hot-plug; follows default device changes
- English and Chinese UI (follows system language)
- Zero third-party dependencies; universal binary (Apple Silicon + Intel); macOS 15+

## Download & First Launch

1. Download `MicMonitor.zip` from the latest **Release** (CI builds and publishes it when a `v*` tag is pushed);
   for development builds, grab the artifact from the latest successful **Actions** run.
2. Unzip to get `MicMonitor.app`, drag it to `Applications` or anywhere you like.
3. **The app is ad-hoc signed (no Apple Developer certificate), so Gatekeeper will block the first launch.** Either:
   - Right-click `MicMonitor.app` → **Open** → click "Open" in the dialog; or
   - Remove the quarantine attribute in Terminal (then double-click works):
     ```bash
     xattr -dr com.apple.quarantine /path/to/MicMonitor.app
     ```
4. Toggling "Enable Mic Passthrough" the first time shows the microphone permission prompt — click Allow.
   If you accidentally deny it: menu bar icon → "Open System Settings" goes straight to Privacy & Security → Microphone.
5. **Note: the ad-hoc signature changes on every rebuild, which can invalidate the mic permission.** If that happens:
   ```bash
   tccutil reset Microphone com.example.micmonitor
   ```
   then relaunch the app and re-authorize.

## Usage

| Option | Notes |
|---|---|
| Input device | The built-in mic is recommended. **Avoid a Bluetooth headset mic**: the Bluetooth protocol switches the headset into call mode (HFP), noticeably degrading music quality. A yellow warning appears when input and output are the same Bluetooth device. |
| Output device | Pick the headphones you're wearing, or "System Default" to follow the system. |
| Mix volume | 0%–200%. 100% is unity gain; anything above is soft-clipped — louder, but no hard clipping. |
| Noise gate | Enable when a constant hiss is audible in quiet environments. Watch the level meter and set the threshold "above the noise floor, below speech" (attack ~10 ms, release ~400 ms). |
| Low-latency mode | On by default; requests a smaller I/O buffer to cut end-to-end latency (reduces the "echo" feel). Automatically falls back if the device can't keep up. |
| Show icon in Dock | Off by default (menu-bar only). When on, clicking the Dock icon opens the same settings panel as a window. |
| Buffer | The footer shows the current ring-buffer level (ms) and underrun/drop counts; on unstable devices the adaptive buffer scales up automatically (orange hint). |

## FAQ

- **Bluetooth audio suddenly sounds terrible**: an unavoidable consequence of enabling a Bluetooth mic (HFP profile). Switch the input to the built-in mic.
- **Echo / howling**: headphone leakage is being re-captured by the mic. Lower the mix volume, enable the noise gate, or use better-isolating headphones. The feedback guard auto-attenuates, but the real fix is physical distance between mic and driver (e.g. the built-in mic). Don't enable passthrough over speakers.
- **High latency / stuttering**: check the buffer level and underrun counter in the panel; USB/Bluetooth devices with drifting clocks can cause periodic crackling — the adaptive buffer mitigates this automatically.
- **Troubleshooting**: click "Copy Diagnostics" in the panel (version, device list, permissions, error counters, recent log) and paste it when reporting issues.

## Development / Building (no Xcode required)

```bash
swift test                  # unit tests (RingBuffer / DSP)
bash scripts/build_app.sh   # produces MicMonitor.zip (universal binary, ad-hoc signed)
```

CI: pushes to main / PRs / manual dispatch run the unit tests; the .app/.zip artifact and a GitHub Release are only produced when a `v*` tag is pushed.

## Implementation Notes

- **Architecture**: prefer a private aggregate audio device (input sub-device + output sub-device, output as master clock, drift compensation on) driven by a **single `AVAudioEngine`** — input tap and output rendering share one I/O cycle and clock domain, so there is no drift by construction (same approach as AU Lab passthrough). Falls back to a dual-engine + ring-buffer design if aggregate creation fails.
- **Data path**: capture `installTap` → `AVAudioConverter` into a canonical planar Float32 format → lock-free SPSC ring buffer → `AVAudioSourceNode` → `mainMixerNode` → output.
- **Stability**: low-latency requests read back the device's actual granted buffer size; a 2 s post-start underrun self-check; every 3 s underrun+overflow deltas feed an adaptive buffer that scales up ×1.8 (cap ×6); a 2 s suppression window on configuration-change notifications breaks rebuild loops.
- **DSP**: per-sample linear gain ramps; noise gate with 10 ms attack / 400 ms release; `tanh` soft clip (threshold 0.8); feedback governor lowers gain when output stays near the clip point.
- Real-time callbacks do no allocation, no locking, no logging; levels and counters are atomics read by the UI at ~15 fps.
