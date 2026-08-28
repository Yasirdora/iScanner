# Writing searchable PDFs

How the text layer is built so it can be selected, searched and copied.

## Overview

Each page is drawn as its cleaned image, with the recognised lines on top as invisible text. Two details make that layer useful rather than cosmetic:

- The text uses the PDF's invisible rendering mode (`Tr 3`), not a transparent colour. A transparent fill still emits paint operations, and some viewers and printers draw them anyway.
- Each line's font size is fitted to its own box, so a selection lands on the ink. Fitting by stretching the text instead leaves wide gaps between letters, and PDF readers take those gaps for spaces: "INT. COFFEE SHOP" came back as "I N T . C O F F E E  S H O P".

The text is set in Helvetica, one of the standard PDF fonts every reader has, so nothing is embedded and the text layer costs almost nothing in file size.

Page size follows the image and an assumed capture resolution of 200 dpi: a 1700 × 2200 pixel page becomes US Letter, 612 × 792 points.

``DocumentScanner/exportPDF(_:to:title:author:)`` writes the title and author into the PDF's document information, and refuses an empty page list.
