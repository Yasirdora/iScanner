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

Vision's data detection reports amounts, dates and addresses, but not IBANs. The recogniser finds them itself and adds each one whose ISO 13616 check digits hold to `detected`, as a `paymentIdentifier` grouped in fours: `DE89 3704 0044 0532 0130 00`. The check catches every digit misread as another digit and every swap of two neighbouring digits. It does not catch every mistake: about 1 in 110 digits misread as a letter ("5" as "S") still pass, and so do about 1 in 110 pairs of misread digits. So show a found IBAN to the user before money is sent. `IBAN.isValid(_:)` checks one on its own.

## Dates

Dates come back as `calendarEvent` values, in ISO 8601 and in UTC: `2026-10-28T11:00:00Z`. A date printed without a time is noon in the device's time zone.

Only dates printed on the page are reported. Data detection fills in what a text leaves out from the day it runs on: "Zahlbar bis 28.10.2026" ("payable until") comes back as a span from that day to 28 October, and "14:35" on its own as that day at 14:35. So the recogniser reads the text twice, as if on two days more than a year apart, and keeps a date only when both readings agree. "bis 28.10.2026" gives 28 October, and "vom 10.10.2026 bis 14.10.2026" gives both days. A time, a weekday, "heute" or a date without a year gives no date.

Data detection takes the order of day and month from the device's region, not from the page. With the region set to the United States, "01.10.2026" comes back as 10 January; with Germany or the United Kingdom, as 1 October. Dates whose day is 13 or more come back right either way.

## Amounts

Detected amounts always have two decimals, with the currency code first: `EUR 563.94`. On a German bill, data detection can read a quantity printed right before an amount as part of it ("4  340,00 €" as 4340 €), so check amounts against the totals on the page before acting on them.
