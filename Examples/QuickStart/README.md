# QuickStart

The smallest app that uses ScanEngine: pick a photo of a page, get the
cleaned page, its text and the data found in it, and share it as a
searchable PDF.

**Try the sample bill** scans a bundled photo of a fictional German invoice,
with German set as the language. It lists the amounts, dates, addresses and
the IBAN found in its text.

Open `QuickStart.xcodeproj` and run the **QuickStart** scheme. It uses the
package from this repository by local path, so changes to the engine show up
on the next build.

All of the scanning is in `Sources/ContentView.swift`, in
`scan(_:findsPage:languages:)`: one call to `DocumentScanner.scan(_:)` and one
to `exportPDF(_:to:title:author:)`.

Turn on "The image is already a flat page" for screenshots and scans to
skip page finding. With it off, the page finder takes such an image whole
when it shows nothing but the page.

The project is generated from `project.yml` with
[XcodeGen](https://github.com/yonaskolb/XcodeGen) (`xcodegen generate`).
