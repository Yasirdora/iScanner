# Reading the text

What recognition returns, and how to tune it.

## Overview

Recognition uses Vision's `RecognizeDocumentsRequest`, which returns the page's structure rather than a flat list of lines. ``ScannedPage/recognition`` holds:

- `transcript` — the whole text, in reading order.
- `runs` — each line with its box and Vision's confidence. Boxes are normalised, with the origin at the lower left.
- `tables` — tables as rows of cell strings.
- `detected` — data found in the text: phone numbers, email and postal addresses, dates, amounts of money, tracking numbers and more.
- `barcodes` — the payloads of barcodes on the page.

On the test receipt, the phone number and the address come back as detected data, and the item list comes back as a table.

## Options

``DocumentScanner/Options/recognition`` passes settings through to the recogniser:

```swift
var options = DocumentScanner.Options()
options.recognition.languages = [Locale.Language(identifier: "de-DE")]
options.recognition.customWords = ["NG-4471-B"]
let scanner = DocumentScanner(options: options)
```

By default the language is detected automatically and language correction is on. Custom words help with part numbers and names that correction would otherwise "fix".
