# Setup, Run and Use

## Requirements

- macOS 14 or later
- Xcode 15 or later (built and tested with Xcode 26.5)
- [XcodeGen](https://github.com/yonaskolb/XcodeGen) only if you change `project.yml` (`brew install xcodegen`)

## Build and run

Open `Spectrogram Studio.xcodeproj` in Xcode and press ⌘R. Or from the terminal:

```bash
xcodebuild -project "Spectrogram Studio.xcodeproj" -scheme "Spectrogram Studio" -configuration Release -derivedDataPath build build
```

```bash
open "build/Build/Products/Release/Spectrogram Studio.app"
```

After editing `project.yml`, regenerate the project:

```bash
xcodegen generate
```

## Run the tests

```bash
xcodebuild -project "Spectrogram Studio.xcodeproj" -scheme "Spectrogram Studio" -derivedDataPath build test
```

22 tests cover the FFT, perfect reconstruction, painted cuts, partial re-rendering, the mask, undo/redo, analysis, YIN, MFCC, decoding WAV and AAC, feedback storage, mouse painting on the spectrogram view and live playback.

## Try it with the demo sound

`scripts/make_demo.swift` synthesises a 12-second melody (with vibrato, harmonics, a whistle, a 60 Hz hum and hi-hat ticks) as both a WAV and an MP4 video:

```bash
swiftc -O scripts/make_demo.swift -o build/make_demo && build/make_demo build/demo
```

Then drop `build/demo/Demo Melody.mp4` onto the window.

## Using the app

| To | Do this |
|---|---|
| Open a file | Drop any audio or video file on the window, or File ▸ Open… (⌘O). Video files use their audio track. |
| Play / pause | Space, or the ▶ button |
| Seek | Click or drag in the time ruler, or ⌥-click anywhere |
| Zoom | ⌘-scroll or pinch over the spectrogram; ⌘= / ⌘- / ⌘0 (fit) |
| Scroll in time | Two-finger horizontal scroll |
| Paint a cut | Choose **Cut** in the toolbar and drag across the spectrogram |
| Paint a boost | Choose **Boost** (capped at +24 dB) |
| Brush amount, size, hardness | The brush button next to Cut/Boost, or Settings ▸ Brush |
| Undo / redo a stroke | ⌘Z / ⇧⌘Z |
| Clear all filters | The bin icon, or Audio ▸ Clear Filters (⌘⌫). Undoable. |
| Compare with the original | **Hear: Original / Filtered** in the toolbar, or ⌘B |
| See the original's analysis | **Show: Original / Filtered** in the status bar |
| Export | File ▸ Export Filtered Audio… (⇧⌘E) — mono WAV, 24-bit or 32-bit float |
| Settings | ⌘, or the gear: FFT size, window, MFCC and pitch settings, frequency axis, colours, dB floor, brush, volume, loop, export format |
| Feedback | The small **Feedback** button bottom-right, or Help ▸ Send Feedback… (⇧⌘F). Saved locally to `~/Library/Application Support/Spectrogram Studio/Feedback.jsonl`; optionally opens a GitHub issue. |

The inspector on the right follows the playhead, or the pointer while you hover: pitch (note, cents, Hz, confidence), the spectrum at that instant (original and filtered) and that frame's MFCCs.

**A note on file access:** files you open through the Open panel or by dropping them are always readable. If you launch the app from the terminal with `-openFile` pointing into Desktop, Documents or Downloads, macOS asks for folder access first and the app waits for that answer.

## The website

The web version is one HTML page, [`web/index.html`](../web/index.html), published at [amalmehta.github.io/SpectrogramStudio](https://amalmehta.github.io/SpectrogramStudio/). It opens on the demo melody with three example filters, decodes whatever your browser can (WAV, MP3, AAC/M4A, usually MP4), and has the same painting, undo, Hear/Show switches and a Settings dialog. Export saves a `.zip` containing the WAV, because artifact downloads don't allow `.wav` directly.

It's republished to GitHub Pages on every push to `main`.

## Regenerating screenshots and the icon

```bash
scripts/screenshots.sh
```

```bash
swift scripts/make_icon.swift "Spectrogram Studio/Resources/Assets.xcassets/AppIcon.appiconset"
```

`screenshots.sh` needs Screen Recording permission for your terminal. It launches the Release build with launch arguments: `-openFile <path>`, `-demoStrokes YES` (paints three example filters), `-seekTo <seconds>`, `-showFeedback YES`, `-openSettings YES`.
