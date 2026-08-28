# Finding the page

How the scanner decides which part of a photo is the document.

## Overview

A photo of a page usually shows more than the page: a table, a notebook, a keyboard. The page finder collects candidate outlines from several sources and scores how document-like each one is:

- Vision's document segmenter, which is fast and finds a page that fills the frame.
- Rectangles that Vision detects in the photo.
- Clusters of text, because printed matter carries dense text and a table does not.
- An optional learned corner model, set with ``DocumentScanner/Options/cornerModel``.

The segmenter alone picks the largest rectangle, so a voucher lying on a notepad comes back as the notepad. Scoring each candidate by how much of the photo's text it holds, and how much it stands out, finds the voucher instead.

The winning outline is straightened with Core Image's perspective correction, using the same four corners.

## Coordinates

Outlines use Vision's convention: normalised to the photo, with the origin at the lower left. ``ScannedPage/outline`` is in that space, so it can be drawn over the photo or handed back to Vision.

## Known limits

- On an image where the page fills the whole frame, the finder prefers a region inside the page, and text is lost. Set ``DocumentScanner/Options/findsPage`` to `false` for such images.
- Curved pages, such as an open book, are not flattened. Only perspective is corrected.

## Live capture

For a camera viewfinder, `ScanCapture` also provides `DocumentTracker`, which combines the fast segmenter on every frame with the slower scorer, and `CaptureStabilizer`, which fires the shutter once when the page holds still. Both are covered by tests; the app in this repository does not use them yet. ``DocumentScanner`` works on single photos.
