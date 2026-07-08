# Scanner

[![CI](https://github.com/Yasirdora/scanner/actions/workflows/ci.yml/badge.svg)](https://github.com/Yasirdora/scanner/actions/workflows/ci.yml)

An on-device document scanner for iPhone. A Swift package turns a photo of a
page into a clean, searchable PDF, and a SwiftUI app is built on top of it.

Everything runs on the device. The engine has no network code and no
third-party code dependencies. It also builds for macOS, so the whole pipeline
can be run, measured and tested from the command line, without a simulator.

![A synthetic page with a heavy shadow: as shot, enhanced, and bitonal](Fixtures/out/comparison.png)

*A synthetic test page with a heavy shadow: as shot, enhanced, and bitonal.
`scanlab synth` writes the page together with its exact transcript, so every
result can be scored.*

## What it does

| Step | Module | How |
|---|---|---|
| Find the page | `ScanCapture` | Vision's document segmenter on every frame, a slower candidate scorer that also finds small items, and a Core ML corner model. A tracker decides which answer to trust. |
| Capture | `ScanCapture` | Auto-capture fires once when the page holds still, then waits until the page changes. |
| Flatten | `ScanEnhance` | Perspective correction from the same four corners the viewfinder showed. |
| Clean up | `ScanEnhance` | Flat-field lighting correction, document tone mapping and Otsu binarisation, in Core Image. |
| Read | `ScanRecognize` | Vision's `RecognizeDocumentsRequest`: text with positions, tables, detected values and barcodes. |
| Export | `ScanExport` | A PDF with an invisible, selectable text layer that sits on the ink. |
| Extract | `ScanExtract` | Typed fields and a title from the on-device Foundation Models model, when the device has one. |

## Measured, not guessed

`scanlab compare` runs every enhancement style through the recogniser and
scores it against the ground truth. CER is the character error rate: lower is
better, 0 means every character is right.

<!-- RESULTS: filled in from a fresh `scanlab compare` run -->

## Tests

52 tests (Swift Testing) cover the engine. Some of them, by name:

- *A page held steady is captured exactly once, however long it is held*
- *Lifting the phone away and returning captures the next page*
- *The small printed item wins over the sheet it rests on* (real photographs)
- *The PDF text layer is selectable and correctly ordered* (read back with PDFKit)
- *Colour is reproduced rather than inflated*
- *Sub-pixel refinement beats the raw grid position*

CI runs them on every push, and also builds the app for the iOS Simulator.

## Requirements

- Xcode 27 (built and tested with Xcode 27.0 and Swift 6.4)
- iOS 26 or macOS 26
- The camera needs a real iPhone. In the simulator, import a photo instead.
- Field extraction needs a device with Apple Intelligence. Everything else
  works without it.

## Build and run

The engine and its command-line tool:

```bash
swift build
swift test
swift run scanlab synth /tmp/page.png --difficulty hard   # a page and its transcript
swift run scanlab compare /tmp/page.png                   # score every style
swift run scanlab auto Fixtures/real/7794.png --out /tmp/scan   # photo → searchable PDF
```

`swift run scanlab` with no arguments lists every command.

The app: open `Scanner.xcodeproj` and run the **Scanner** scheme. The project
is generated from `project.yml` with [XcodeGen](https://github.com/yonaskolb/XcodeGen)
(`xcodegen generate`).

## Layout

```
Sources/
  ScanCore        value types, options, accuracy metrics
  ScanCapture     detection, candidate scoring, tracking, auto-capture rules
  ScanEnhance     perspective, lighting correction, tone, binarisation
  ScanRecognize   Vision document recognition → positioned text
  ScanExport      searchable PDF (Core Graphics + Core Text)
  ScanExtract     DocumentExtracting protocol + Foundation Models implementation
  scanlab         command-line harness
App/              SwiftUI iPhone app: camera, corner editor, page viewer
Tests/            Swift Testing suites
Fixtures/         test pages, ground-truth transcripts, sample outputs
Models/           Core ML corner model (see NOTICE)
```

## Design notes

- **Two detectors, one tracker.** Vision's segmenter takes 3–6 ms, fast enough
  for every frame, but it finds nothing when a small card lies on a larger
  sheet. The candidate scorer finds the card, but takes 144–235 ms (measured
  on a Mac), too slow for every frame. `DocumentTracker` holds both answers:
  it trusts the precise one only while it is fresh and the scene still
  matches, and the fast one otherwise. It is pure and synchronous, so every
  rule has a test.
- **White point from the paper, not from a percentile.** A percentile moves
  with how much ink is on the page, so the same paper came out a different
  grey on every page. Taking the most common paper value fixed that, and cut
  the colour output from 3548 KB to 478 KB.
- **Thresholds the tests caught.** The first auto-capture drift limit, 0.012
  per frame, turned out to be a deliberate hand movement, not a tremor. It is
  now 0.0035, and 16 stabiliser tests cover the capture rules.
- **A real text layer.** Text is drawn in `CGTextDrawingMode.invisible`
  (PDF `Tr 3`), not with a transparent fill, which some viewers and printers
  still paint. Each run's font size is fitted to its own box, so a selection
  lands on the ink.

## Known limits

- Curved pages, such as an open book, are not flattened. Only perspective is
  corrected.
- The auto-capture limits come from reasoning about hand tremor, not from
  measurements in the field.
- Most test pages are synthetic. There are three real photographs so far.
- In very deep shadow, where the lighting estimate is near zero, banding can
  appear.

## License

MIT — see [LICENSE](LICENSE).

`Models/DocumentCorners.mlpackage` is converted from
[DocAligner](https://github.com/DocsaidLab/DocAligner) by Ze Yuan (DocsaidLab)
and stays under the Apache License 2.0. See [NOTICE](NOTICE).
