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

Vision's data detection reports amounts, dates and addresses, but not IBANs. The recogniser finds them itself. It adds each one to `detected` that fits its country's format in SWIFT's IBAN registry and whose ISO 13616 check digits hold, as a `paymentIdentifier` grouped in fours: `DE89 3704 0044 0532 0130 00`.

The format catches what the check digits miss. A letter counts as two digits in the check (S is 28), so on their own the check digits let about 1 in 110 digits misread as a letter through. A German IBAN is "DE", two check digits and 18 digits, so a letter after "DE", or a lost or doubled character, fails. In a German IBAN, every single misread character fails the check.

Not every mistake does. About 1 in 105 IBANs with two misread digits still pass. In 38 of the registry's 89 countries, part of the account number may hold letters as well as digits, so there the format cannot see a digit misread as a letter. Four of these countries add a check of their own, and the recogniser tests it too: the RIB key (two digits) in France and Monaco, the CIN (a letter) in Italy and San Marino. Measured on 6,000 random IBANs per country, a digit misread as a letter then passes about 1 in 1,000 times in France and Monaco and about 1 in 2,400 in Italy and San Marino, instead of about 1 in 97. What still passes is a letter the national check counts as the same digit, such as 1 read as J in France and Monaco, or 6 read as G, a common OCR slip, in Italy and San Marino; these pass as often as before. In the other 34 countries, Switzerland among them, about 1 in 100 digits misread as a letter still pass. So show a found IBAN to the user before money is sent.

The French and Italian banking associations publish no text of the RIB key or the CIN online. The recogniser uses the rules that bank calculators use, and SWIFT's example IBANs for all four countries fit them; the French one holds a letter, M, which counts as 4. A national check can only reject an IBAN, so if a rule were wrong, a real IBAN would be missing, never a wrong one reported.

A country code the registry does not list is never reported. "RF" starts a creditor reference, which bills print for the payer to quote; its check digits hold, but it is not an account. A country added to the registry after 17 September 2026 is not found until the list in `IBAN` is updated. `IBAN.isValid(_:)` checks one IBAN on its own.

## Dates

Dates come back as `calendarEvent` values, in ISO 8601 and in UTC: `2026-10-28T11:00:00Z`. A date printed without a time is noon in the device's time zone.

Only dates printed on the page are reported. Data detection fills in what a text leaves out from the day it runs on: "Zahlbar bis 28.10.2026" ("payable until") comes back as a span from that day to 28 October, and "14:35" on its own as that day at 14:35. So the recogniser reads the text twice, as if on two days more than a year apart, and keeps a date only when both readings agree. "bis 28.10.2026" gives 28 October, and "vom 10.10.2026 bis 14.10.2026" gives both days. A time, a weekday, "heute" or a date without a year gives no date.

A date written with dots, such as "01.10.2026" or "1.10.26", is read day first on every device, as Germany and most of Europe write it. Data detection alone takes the order of day and month from the device's region, not from the page: with the region set to the United States, "01.10.2026" came back as 10 January. So the recogniser takes the day and month of a date written with dots from the text itself. A date written with slashes, such as "10/01/2026", is still read in the order of the device's region: the United States writes it month first, so there it is 1 October; with the region set to Germany it is 10 January.

## Amounts

Detected amounts always have two decimals, with the currency code first: `EUR 563.94`. On a German bill, data detection can read a quantity printed right before an amount as part of it ("4  340,00 €" as 4340 €), so check amounts against the totals on the page before acting on them.
