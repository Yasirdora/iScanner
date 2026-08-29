# Getting started

Add the package, scan a photo, and export a searchable PDF.

## Add the package

In Xcode, choose File > Add Package Dependencies and add this repository. Link the `ScanEngine` product to your app target. The package needs iOS 26 or macOS 26.

## Scan a photo

```swift
import ScanEngine

let scanner = DocumentScanner()
let page = try await scanner.scan(photo)   // photo is a CGImage

print(page.text)          // the recognised text, in reading order
print(page.style)         // the style Auto chose, such as .color
print(page.wasPageFound)  // whether a page was found and straightened
```

The result is a ``ScannedPage``: the cleaned image, everything recognition found in ``ScannedPage/recognition``, and the outline of the page in the original photo.

## Export a PDF

```swift
try scanner.exportPDF([page], to: url, title: "Receipt")
```

Each scanned page becomes one PDF page, in order. The text layer is invisible but can be selected and searched. An empty list throws ``ScanError/noPages``.

## Flat pages and screenshots

An image that is already a flat page, such as a screenshot or a file from a flatbed scanner, comes back whole: when the image shows nothing but the page, the page finder takes the whole image. To skip page finding for such images, turn it off:

```swift
let scanner = DocumentScanner(options: .init(findsPage: false))
```

## Choose a style

``DocumentScanner/Options/style`` defaults to `.auto`, which looks at the page and chooses. To ask for a style:

```swift
let scanner = DocumentScanner(options: .init(style: .bitonal))
```

| Style | For |
| --- | --- |
| `.auto` | Looks at the page and chooses. The default. |
| `.enhanced` | Faint marks: handwriting, pencil, weak print. |
| `.color` | Printed pages with photographs or colour. |
| `.light` | Clean or delicate originals. |
| `.grayscale` | Neutral grey, tone kept. |
| `.bitonal` | Two tones and the smallest files. |
| `.original` | Untouched. |

## Use a corner model

The page finder can also use a learned corner detector. The package does not bundle a model; load one with Core ML and pass it in:

```swift
let detector = CoreMLCornerDetector(model: try MLModel(contentsOf: compiledModelURL))
let scanner = DocumentScanner(options: .init(cornerModel: detector))
```

The example app in `Examples/QuickStart` shows the whole flow in about 100 lines.
