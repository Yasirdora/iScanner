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

## Set the language when you know it

Automatic language detection is the default, and it reads most pages well. Telling Vision the language still helps: on the photographed German test bill, it reads 91.4% of the words with automatic detection and 97.1% with German set. When your users scan documents in a known language, set it:

```swift
var options = DocumentScanner.Options()
options.recognition.languages = [Locale.Language(identifier: "de-DE")]
```

## IBANs

Vision's data detection reports amounts, dates and addresses, but not IBANs. The recogniser finds them itself and adds each one whose ISO 13616 check digits hold to `detected`, as a `paymentIdentifier` grouped in fours: `DE89 3704 0044 0532 0130 00`. The check catches every single misread character and every swap of two neighbouring ones, so a reported IBAN is very unlikely to be wrong; `IBAN.isValid(_:)` checks one on its own.

## Amounts

Detected amounts always have two decimals, with the currency code first: `EUR 563.94`. On a German bill, data detection can read a quantity printed right before an amount as part of it ("4  340,00 €" as 4340 €), so check amounts against the totals on the page before acting on them.
