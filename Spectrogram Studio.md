PROJECT NAME: Spectrogram Studio

META-INSTRUCTIONS:

<Read it all before acting. Ask about anything unclear, contradictory or
 underspecified — before starting and mid-build. Ask in the question widget
 (AskUserQuestion): related questions batched, concrete options, your
 recommendation first. Plain text only if the widget isn't available.>

<Don't expand scope. Anything not listed here is a proposal, including changes
 to this file — propose it, don't do it.>

<Prefer doing over describing: run the code, write the files, test it.>

<Always in scope, no proposal needed: when it goes on GitHub, a README that is
 easy to read at a glance — a line on what it is, then clear visuals
 (screenshots, a diagram or a chart), then links. Everything else goes in
 linked files: docs/INSTRUCTIONS.md (setup, run, use),
 docs/SYSTEM-DESIGN.md (see below) and docs/FILE-STRUCTURE.md (what's where). If what you're
 building is an application rather than a script, also a small unobtrusive feedback tab, and a settings
 button or tab (⌘, on the Mac) that gathers its preferences in one place.>

<If what you're building is an application, build it as a Mac app first; the
 website comes after, as its own step.>

<Name things the way a person would say them — "Goal Tracker", not
 goal_tracker — for the app, its windows, titles, files people open, repo
 descriptions and README headings. When you create the GitHub repo, name it
 with no "_" or "-": one word or joined words, e.g. GoalTracker.>

<Always in scope: a system design doc in the codebase, docs/SYSTEM-DESIGN.md,
 kept current as the build changes. Cover the architecture (with a Mermaid
 diagram), each component's job, the main flows, where data lives, the key
 design decisions and their trade-offs, how it's tested, and known limits.>

<Finish by listing every deliverable: path, what it is, how to check it works.>

<Git rules (no Claude attribution, never commit .claude/) are in
 ~/.claude/CLAUDE.md and apply on their own — nothing to repeat here.>

<Keep the changelog at the bottom current.>

CONTEXT:

A native Mac app where you drop in any audio or video file and see live STFT, MFCC and pitch-tracking views. You can paint filters directly onto the spectrogram and hear the result straight away.

It turns the theory from signal_processing_primer into a hands-on creative tool, built in the SwiftUI, AppKit and Swift Charts stack they keep returning to.

DELIVERABLES:

<What you want at the end: the app, files, links. One per line.>

OPEN QUESTIONS / ASSUMPTIONS:

Asked and answered (2026-10-06):
- Painted filters are heard by re-rendering on each stroke (only the frames it touches), not by real-time masking during the drag.
- Video files: the app uses their audio track only; no picture is shown.
- GitHub: public repo amalmehta/SpectrogramStudio.
- Extras approved beyond the brief: export filtered audio (WAV), undo/redo + clear filters, and the website version built in the same session.

Decided without asking:
- Mono throughout: stereo is mixed down for analysis, painting, playback and export.
- macOS 14+, XcodeGen project like Signal Processing Primer; bundle id com.amalmehta.SpectrogramStudio.
- STFT hop fixed at FFT size / 4; FFT size, window, MFCC count, mel bands and YIN range/threshold are in Settings.
- Strokes are stored in seconds and Hz so they survive zoom and settings changes; boosts capped at +24 dB, cuts at −64 dB.
- Painted filters aren't saved between launches (no project file format).
- Feedback is saved locally (JSON lines) with an optional pre-filled GitHub issue, as in Signal Processing Primer.
- The website is a single self-contained page (JavaScript port of the same DSP) published as a private claude.ai artifact; its export is a .zip containing the WAV because artifact downloads don't allow .wav.

CHANGELOG:

- 2026-10-06 — created
- 2026-10-06 — built: Mac app, website, docs, tests; filled in assumptions
- 2026-09-15 — added meta-instruction: built-out applications include a small feedback tab
- 2026-09-15 — added meta-instruction: no "Claude" attribution in commits, PRs, or branches
- 2026-09-16 — added meta-instruction: always include a README when adding to GitHub
- 2026-09-16 — changed meta-instruction: ask clarifying questions in the question widget
- 2026-09-17 — added meta-instructions: Claude never a contributor; never commit .claude/
- 2026-09-26 — compressed the meta-instructions and every field prompt; git rules moved to the global instruction file
- 2026-09-27 — added meta-instruction: applications are built as a Mac app first, then a website
- 2026-09-28 — folded inputs, instructions, constraints, deliverables and done criteria into one free-form CONTEXT
- 2026-09-28 — changed meta-instruction: a README on GitHub always includes a visual
- 2026-09-28 — added meta-instruction: name things like a person would, never snake_case
- 2026-09-28 — changed meta-instruction: README leads with visuals; instructions live in a linked guide
- 2026-09-28 — changed meta-instruction: README is visuals and links; details in docs/INSTRUCTIONS.md and docs/FILE-STRUCTURE.md
- 2026-09-29 — changed meta-instruction: GitHub repo names have no "_" or "-"
- 2026-10-02 — added a DELIVERABLES field after CONTEXT
- 2026-10-02 — added meta-instruction: every project has a system design doc at docs/SYSTEM-DESIGN.md
- 2026-10-05 — added meta-instruction: applications include a settings button or tab
