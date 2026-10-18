# Finding the page

How the scanner decides which part of a photo is the document.

## Overview

A photo of a page usually shows more than the page: a table, a notebook, a keyboard. The page finder collects candidate outlines from several sources and scores how document-like each one is:

- Vision's document segmenter, which is fast and finds a page that fills the frame.
- Rectangles that Vision detects in the photo.
- Clusters of text, because printed matter carries dense text and a table does not.
- The whole photo, when the page fills the frame.

The segmenter alone picks the largest rectangle, so a voucher lying on a notepad comes back as the notepad. Scoring each candidate by how much of the photo's text it holds, and how much it stands out, finds the voucher instead.

## A page that fills the frame

A screenshot, a flat scan or a photo taken close shows no table, so there is no outline to find: the page's edges are the photo's edges. The finder takes the whole photo when two things hold: no outline seen in the photo holds the text, and the photo around the text shows no sharp edge, such as the border of a page, the lines of a notepad or the pattern of a rug. Shadow does not count as an edge. ``ScannedPage/outline`` is then the whole photo.

## A page lying on a table

The finder also estimates the page from its text: the block of text with a margin around it. This finds a card whose border cannot be seen, such as a white card on white paper. But most pages have wider margins than that. On a page photographed on a table, the estimate ran onto the table on one side and cut blank paper on the other.

So an outline seen in the photo wins over the estimate when two things hold: it holds all the text, and the estimate covers at least half of it. A seen outline is a rectangle that Vision detects, or the segmenter's outline when its confidence is 0.7 or more. The sheet under a card holds the card's text too, but the estimate covers less than a third of it, so the card still wins.

## Which way is up

An outline's corners are named by where they sit in the photo, and that says nothing about where the page's top is. A page lying upside down on a table, or a photo taken with the phone held sideways, came out of the straightening upside down or on its side. So every outline gets its corners named by the text inside it: the top is the edge the lines of text have above them. An outline with no text inside it keeps its corners.

The winning outline is straightened with Core Image's perspective correction, using the same four corners.

## Coordinates

Outlines use Vision's convention: normalised to the photo, with the origin at the lower left. ``ScannedPage/outline`` is in that space, so it can be drawn over the photo or handed back to Vision.

## Known limits

- On a flat page with a picture or a logo away from its text, the logo's edges look like a surface around the page, and the finder can keep only the part of the page around the text. Set ``DocumentScanner/Options/findsPage`` to `false` for such images.
- On a page lying on a table with little text, where the text and its margin cover less than half the page, the finder keeps only the part around the text. A card whose border cannot be seen looks the same in a photo, and there the card is the right answer.
- Curved pages, such as an open book, are not flattened. Only perspective is corrected.

## Live capture

For a camera viewfinder, `ScanCapture` also provides `DocumentTracker`, which combines the fast segmenter on every frame with the slower scorer, and `CaptureStabilizer`, which fires the shutter once when the page holds still. Both are covered by tests; the app in this repository does not use them yet. ``DocumentScanner`` works on single photos.
