# ``ScanEngine``

Turn a photo of a page into a straightened, cleaned page, its text, and a searchable PDF — on the device.

## Overview

``DocumentScanner`` runs the whole pipeline in one call: it finds the page in a photo, straightens it, cleans it up and reads the text. ``DocumentScanner/exportPDF(_:to:title:author:)`` then writes the pages as a PDF whose text can be selected, searched and copied.

Everything runs on the device with Apple frameworks — Vision, Core Image, Core ML, Core Graphics and Core Text. Nothing is sent over the network, and the package has no third-party code dependencies.

Each stage is also its own module — `ScanCapture`, `ScanEnhance`, `ScanRecognize`, `ScanExport` and `ScanExtract` — for callers that need to drive one directly.

## Topics

### Essentials

- <doc:GettingStarted>
- ``DocumentScanner``
- ``ScannedPage``

### How the pipeline works

- <doc:FindingThePage>
- <doc:CleaningUpThePage>
- <doc:ReadingTheText>
- <doc:WritingSearchablePDFs>

### Quality

- <doc:MeasuringAccuracy>

### Errors

- ``ScanError``
