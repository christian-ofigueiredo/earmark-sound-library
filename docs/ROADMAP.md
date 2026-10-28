# Earmark: from alpha to 1.0

Written 2026-10-28, after the first alpha. `docs/PLAN.md` has the original build plan
(phases 1–4, all built); this is what comes next. Decisions marked **Owner decides**
are still open.

## Version numbers

Earmark follows [Semantic Versioning](https://semver.org): `MAJOR.MINOR.PATCH`, plus a
label for test versions.

- **0.x.y**: before 1.0, anything may still change, including the database and the
  analysis files.
- **-alpha.N**: works, but is still missing planned features. **-beta.N**: has every
  feature planned for 1.0, and is being tested before release.
- The minor number goes up when features arrive, and the alpha/beta number goes up for
  fixes. For example, 0.1.0-alpha.1, then 0.1.0-alpha.2 for fixes, then 0.2.0-alpha.1
  when the next features arrive.

| Version | What it is |
|---|---|
| **0.1.0-alpha.1** (2026-10-28) | Everything in PLAN.md phases 1–4, Mac only. Released on GitHub as a pre-release. |
| 0.1.0-alpha.2, .3… | Fixes from the owner's testing |
| **0.2.0-alpha.1** | The second alpha: everything planned but not built yet (below), Mac only |
| **1.0.0-beta.1** | The Windows version joins: both platforms, every feature |
| 1.0.0-beta.2… | Fixes from testing on both platforms |
| **1.0.0** | The first stable release |

## Second alpha (0.2.0): what was planned and not built

1. **Models from inside the app.** Today testers unzip five model files with a
   Terminal command. Instead, Earmark offers to download them from the GitHub release.
   It checks each file's SHA-256, can resume an interrupted download, and lets you
   choose which to get: tempo and key only (0.4 GB), or everything (4.5 GB).
2. **Timeline files for other editors (FCPXML).** Earmark writes a timeline file with
   the chosen sounds at their times. You import it into the free DaVinci Resolve,
   Resolve Studio or Final Cut Pro. Studio keeps the direct ⌘T. **Owner decides**
   whether to build it (see "Free Resolve or Studio only?" below).
3. **Groups in the analysis files.** Exporting a library's analysis includes its
   similarity groups and your group names, and importing restores them. Moving a
   library to another Mac then keeps your naming work.
4. **Pinch to zoom on the sound map**, with a trackpad, as well as the current zoom.
5. **Group names from the shape of the sound.** Today group names come from the AI's
   words ("wooden", "airy"). This adds words from the waveform itself: a sharp hit or a
   slow rise, a long tail or a sudden stop.
6. **Finish testing what couldn't be tested yet:**
   - the right-click menus (on sidebar groups and list rows);
   - drop-frame timecode (29.97 and 59.94 fps) in Resolve;
   - whether a Resolve export slows down while Earmark is analysing.
7. **Release builds made by GitHub.** A workflow builds the release zip from the tagged
   source and attaches a build attestation (free). Anyone can then check, with
   `gh attestation verify`, that the download was built from this repository's code.
   This replaces some of the trust that Apple's signature would give (see "Not
   signing").
8. **Update check.** Once a day at most, Earmark looks at the GitHub releases page and
   says when a newer version is out. It never downloads or installs anything by itself.

### Free Resolve or Studio only?

**Recommendation: build the timeline file.** It's a few days' work, and Earmark works
the same way in both versions of Resolve:

- With **Studio**, a sound goes straight onto the timeline (⌘T or an AI agent).
- With the **free version**, you import a file. It works, but it's slower, so the
  direct way stays a reason to own Studio without leaving anyone out.
- The same file also opens in Final Cut Pro, which brings in more users.
- Earmark isn't Blackmagic's product. Most people trying a free tool won't buy a
  $295 app first to see whether it's useful.

## Beta (1.0.0): Windows

### Should Earmark be rewritten in Rust?

**Faster: no, not noticeably.** Most of Earmark's time goes to:
- the AI models, which run on the GPU through Apple's Core ML;
- decoding audio, using Apple's decoders;
- SQLite.

None of these depends on the language the app is written in. Swift and Rust both
compile to native code, so the parts written in Swift (the map, the groups, the search)
would run at about the same speed in Rust. On Windows, speed will depend mostly on the
PC's graphics card.

**Easier for Windows: yes, partly.** Swift itself runs on Windows, but most of what
Earmark is built on doesn't: its interface (SwiftUI), Core ML, and Apple's audio
decoders. So Windows needs a new interface and a new way to run the models whatever
the language. Rust is a good choice for the part both versions share. It has mature
libraries for everything Earmark needs:
- audio decoding (Symphonia);
- SQLite (rusqlite);
- AI models (ONNX Runtime, which uses DirectML on Windows);
- an official MCP SDK;
- the Tauri app framework.

### Three ways to do it

| | How | Good | Bad |
|---|---|---|---|
| A. All in Rust | One app for both systems, with a web-based interface (Tauri) | One codebase | The Mac app loses its native look (Liquid Glass, native lists and menus). Everything is rewritten at once, the map included. |
| **B. Shared Rust engine** | The engine moves to Rust: scanning, metadata, database, analysis, groups, map layout, duplicates, the Resolve bridge and the MCP server. The Mac keeps its SwiftUI interface, which calls the engine. Windows gets its own interface (Tauri). | The Mac app stays as it is. Both systems share one engine and give the same results. | Two interfaces to maintain |
| C. Separate Windows app | Windows written from scratch and kept in step by hand | The Mac app isn't touched | Everything is written twice, and the two drift apart |

**Recommendation: B, in steps that each leave a working app.**

1. **Rust engine, checked against Swift.** Port the engine piece by piece. Each
   piece must give the same results as the Swift version on the same files: the
   existing parity checks (`earmark-parity`, `models/parity_*.py`) already do this.
2. **The Mac app switches to the Rust engine**, with the interface unchanged. This
   ships as an alpha, so Mac users test the new engine before Windows exists.
3. **Models for Windows.** Convert PE-AV, CLAP, Beat This! and S-KEY to ONNX, the
   same way `models/` converts them to Core ML, with the same parity checks. On the
   Mac, Core ML stays: it's tested and fast on Apple's GPU.
4. **Windows interface (Tauri)**: the two sections, the sound map (drawn with
   WebGL), the player, Preferences and Connect an AI Agent.
5. **Windows-specific parts:**
   - drive letters and network drives;
   - idle detection, so analysis waits while you work;
   - Resolve's scripting on Windows (the same Python API, from a different folder);
   - an installer.

This is the biggest piece of work left, comparable to phases 1–2 of PLAN.md.

### Windows risks

- **Graphics memory.** PE-AV large needs about 4.2 GB, so PCs with small graphics
  cards will have to run it on the processor (about 3× slower, as on the Mac).
- **Same results through DirectML.** Each model must match the Mac's results on the
  same files. On the Mac, half precision lost 5% of neighbours, so full precision is
  expected here too.
- **Not signing on Windows.** SmartScreen warns about unsigned installers ("Windows
  protected your PC" ▸ More info ▸ Run anyway). Windows signing also costs money (for
  example Microsoft's Trusted Signing, about $10 a month). **Owner decides**, as for
  the Mac.

## Not signing (Mac and Windows)

The owner has decided not to pay for Apple's Developer Program ($99 a year), so Earmark
stays unsigned. What that means:

- **For you (the owner):** no legal risk. The MIT licence already says the software
  comes with no warranty. It's also allowed: Apple only requires signing for the App
  Store, and nothing stops sharing unsigned apps on GitHub.
- **For users:**
  - macOS blocks the first opening, so each user has to choose Open Anyway in System
    Settings. Some won't, and some managed (company) Macs won't allow it.
  - A signature proves who made the app. Without one, someone could repackage a
    harmful copy and pass it off as Earmark. The protections are: downloads only from
    the GitHub page, SHA-256 checksums in each release, the source code to build from,
    and, from 0.2.0, GitHub build attestations.
  - macOS may ask again for permission to read your folders and drives after each
    update. It recognises an unsigned app by its exact build, and every update is a
    new build.

## Making a release (today)

1. Tag the commit: `git tag -a v0.1.0-alpha.2 -m "Earmark 0.1.0 alpha 2"`.
2. `scripts/build-app.sh` (it reads the version from the tag).
3. Zip the app:
   `ditto -c -k --norsrc --noextattr --keepParent app/build/Earmark.app Earmark-<version>-macOS-AppleSilicon.zip`
4. The models only need uploading again when they change. Otherwise, the release
   notes link to the release that has them.
5. Make the checksums (`shasum -a 256`), then push the tag and run
   `gh release create <tag> --prerelease --notes-file …`.
