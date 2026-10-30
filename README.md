# MicClean

**A free, system-wide echo and noise reducer for your Mac microphone.**

MicClean sits between your USB microphone and every app on your Mac (Meet, Zoom, Slack, WhatsApp, QuickTime…). It cleans up room echo and background noise in real time and exposes the result as a virtual microphone, so every app gets the processed voice without any per-app setup.

It was built as a free alternative to paid tools like Krisp, for the common case of a condenser USB mic in an untreated room.

> 🇧🇷 [Resumo em português](#português) no final.

## How it works

```
USB mic ──► Apple voice processing ──► dereverb ──► noise gate ──► gain + limiter ──► EQ ──► BlackHole 2ch ──► your apps
           (enables Voice Isolation)  (spectral)                                                (virtual mic)
```

1. **Apple voice processing** (`VoiceProcessingIO`): the same engine FaceTime uses. Because MicClean runs as a real app, macOS lets you turn on **Voice Isolation** for it in Control Center, an ML model that separates your voice from the room. This does most of the heavy lifting.
2. **Dereverberation**: spectral subtraction of late reverberation (Lebart et al., 2001), with gain smoothing across time and frequency to avoid "musical noise".
3. **Noise gate**: closes in pauses so the room tail doesn't linger between sentences.
4. **Gain + limiter**: brings the voice to a comfortable level without clipping.
5. **EQ**: high-pass at 90 Hz, cut at 250 Hz (less boxiness), presence boost at 3.5 kHz (clarity).
6. **BlackHole 2ch** carries the result to other apps as a regular input device.

An optional [Hammerspoon](https://www.hammerspoon.org/) script switches the system default input automatically: **BlackHole** when your mic is plugged in, the **built-in mic** when it's not.

### Results

Measured on a condenser USB mic in an untreated home office (~1.5 s reverb):

| | Raw mic | MicClean |
|---|---|---|
| Echo tail after speech | ~1 s | ~0.1–0.15 s |
| Speech-to-pause level difference | ~34 dB | ~61 dB |
| Noise floor in pauses | −65 dBFS | −80 dBFS |
| Loudness | −33 LUFS | −21 LUFS |

## Requirements

- macOS 13 or later (Apple Silicon or Intel)
- Xcode Command Line Tools (`xcode-select --install`)
- [Homebrew](https://brew.sh) (used to install BlackHole and Hammerspoon)

## Install

```bash
git clone https://github.com/vgoliveira/micclean.git
cd micclean
SOURCE_MIC="Your Mic Name" bash install.sh
```

Use your microphone's name exactly as it appears in **System Settings › Sound › Input**. To list devices:

```bash
swiftc -O -target "$(uname -m)-apple-macos13" micclean.swift -o micclean && ./micclean --list
```

During install:

1. If BlackHole isn't installed, the script installs it (it may ask for your password).
2. macOS asks for **microphone permission for MicClean**: click **Allow**, then press Enter.
3. MicClean is registered as a login service (`launchd`) that starts with your Mac and restarts automatically if it stops (for example, when you unplug the mic).
4. Hammerspoon is installed and configured (skip with `NO_HAMMERSPOON=1`).

Then:

- Turn on **Voice Isolation**: Control Center › Mic Mode › **Voice Isolation** (shown while MicClean is running).
- In your apps, set the microphone to **System Default** (or pick **BlackHole 2ch**).

## Tuning

Pass options through `MICCLEAN_ARGS` and run the installer again:

```bash
SOURCE_MIC="ME6S" MICCLEAN_ARGS="--gain 3 --strength 1.5" bash install.sh
```

To experiment, stop the service and run it in the foreground:

```bash
launchctl bootout gui/$(id -u)/io.github.vgoliveira.micclean
./micclean --source "ME6S" --meter --strength 1.5
```

| Option | Default | What it does |
|---|---|---|
| `--source NAME` | `ME6S` | Input microphone |
| `--sink NAME` | `BlackHole 2ch` | Virtual output device |
| `--no-vp` | | Disable Apple voice processing |
| `--strength X` | `2.0` | Dereverb strength (0.5–3.0) |
| `--floor DB` | `-25` | Max dereverb attenuation per frequency |
| `--rt60 S` | `1.5` | Estimated room reverb time |
| `--no-dereverb` | | Disable dereverberation |
| `--gate DB` | `-45` | Gate threshold (dBFS) |
| `--gate-range DB` | `-45` | Attenuation when the gate is closed |
| `--gate-hold MS` | `150` | Time the gate stays open after speech |
| `--gate-release MS` | `60` | Gate closing speed |
| `--no-gate` | | Disable the gate |
| `--gain DB` | `6` | Output gain (a limiter prevents clipping) |
| `--presence DB` | `6` | Clarity boost at 3.5 kHz |
| `--no-eq` | | Disable EQ |
| `--meter` | | Print input level every second |
| `--list` | | List audio devices |

Signs you've gone too far: a **metallic/underwater** voice means too much dereverb (lower `--strength` or `--floor`); **clipped word endings** mean the gate is too aggressive (raise `--gate-hold`).

## Troubleshooting

- **Is it running?** `tail -n 20 ~/Library/Logs/micclean.log`
- **No audio / restart the service:** `launchctl kickstart -k gui/$(id -u)/io.github.vgoliveira.micclean`
- **An app is stuck at 0:00 when recording:** quit the app completely (⌘Q) and reopen it; some apps keep a stale handle to the previous input device.
- **"Apple voice processing unavailable" in the log:** MicClean falls back to direct capture with its own processing, which still works, just with less echo reduction.
- **After a major macOS update:** run `bash install.sh` again (the app is ad-hoc signed, so macOS may ask for microphone permission again).

## Uninstall

```bash
bash uninstall.sh
```

This removes the service, the app and the Hammerspoon integration. BlackHole and Hammerspoon stay installed; the script prints how to remove them.

## Limitations

- Software can't fully remove room echo. Placing the mic **5–10 cm from your mouth** (on the correct side, since many USB condensers are side-address) and adding soft materials to the room help more than any setting. A dynamic microphone picks up much less room sound.
- Adds roughly 20–40 ms of latency.
- Ad-hoc signed (no Apple Developer ID); built and installed locally from source.
- Program messages are in Portuguese.

## Credits

- [BlackHole](https://github.com/ExistentialAudio/BlackHole) by Existential Audio (virtual audio driver, installed separately)
- [Hammerspoon](https://www.hammerspoon.org/) (automatic input switching)
- Dereverberation based on K. Lebart, J. M. Boucher, P. N. Denbigh, *"A New Method Based on Spectral Subtraction for Speech Dereverberation"*, Acta Acustica, 2001.

## License

[MIT](LICENSE)

---

## Português

O **MicClean** é um redutor gratuito de eco e ruído para o microfone do Mac, que vale para todos os apps ao mesmo tempo. Ele combina o processamento de voz da Apple (com **Isolamento de Voz**), redução de reverberação, noise gate, ganho e EQ, e entrega o resultado como um microfone virtual (**BlackHole 2ch**).

**Instalação:**

```bash
git clone https://github.com/vgoliveira/micclean.git
cd micclean
SOURCE_MIC="Nome do seu microfone" bash install.sh
```

Depois, ative o **Isolamento de Voz** na Central de Controle (Modo de Microfone) e deixe os apps com o microfone em **"Padrão do sistema"**. As opções de ajuste e a solução de problemas estão nas seções acima.
