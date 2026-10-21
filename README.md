# Spectrogram Studio

A Mac app (and a website) where you drop in any audio or video file, see its STFT spectrogram, MFCCs and pitch track, and paint filters straight onto the spectrogram to hear the result immediately.

**Website:** [amalmehta.github.io/SpectrogramStudio](https://amalmehta.github.io/SpectrogramStudio/)

![Spectrogram Studio with painted filters: a blue cut across the 3 kHz harmonics, a rising cut and an amber boost](docs/images/main.jpg)

| Before painting | The website | Empty window |
|---|---|---|
| ![Unfiltered demo melody](docs/images/unpainted.jpg) | ![The web version](docs/images/web.jpg) | ![Drop zone](docs/images/empty.jpg) |

```mermaid
flowchart LR
    F["Audio or video file"] --> D["Decode to mono"]
    D --> A["STFT · MFCC · YIN pitch"]
    A --> V["Spectrogram, MFCC and pitch views"]
    V -- "paint" --> M["Gain mask (seconds × Hz)"]
    M --> R["Inverse STFT (overlap-add)"]
    R --> P["Playback · Export WAV"]
    R --> A
```

**Links:** [Website](https://amalmehta.github.io/SpectrogramStudio/) · [Setup and use](docs/INSTRUCTIONS.md) · [System design](docs/SYSTEM-DESIGN.md) · [File structure](docs/FILE-STRUCTURE.md) · [Original brief](Spectrogram%20Studio.md)
