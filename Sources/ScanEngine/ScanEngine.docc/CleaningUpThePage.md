# Cleaning up the page

What the enhancer does to a photo of paper, and why.

## Overview

The enhancer turns a photo of paper into something that reads as a scan: white paper, dark ink, and colour kept where it is content.

1. **Lighting correction.** The ink is erased with a morphological dilation, which leaves an estimate of the lighting alone. Dividing by it removes shadows and lighting gradients. Dilation, not blur, so letters do not get halos. The gain is capped, so a deep shadow stays dark instead of turning into noise.
2. **Tone mapping.** The paper's white point is the most common paper value, not a percentile. A percentile moves with how much ink is on the page, so the same paper came out a different grey on every page.
3. **Colour protection.** Saturated areas, such as a highlighter or a coloured table cell, get a gentler mapping. They keep their fill while the paper around them still turns white.
4. **Style.** Each style is a set of settings on the same pipeline. `.bitonal` ends with Otsu's threshold, which works because the corrected page has two clear peaks: paper and ink.

## Auto

`.auto` looks at the page and chooses. On the test pages it picks `.color` for the ordinary receipts and `.enhanced` for the shadowed ones. ``ScannedPage/style`` tells you what it chose.

## Does cleanup help the text recogniser?

Usually, not always. On the ordinary test receipts, the cleaned page has about three times fewer character errors than the photo. On the heavy-shadow test pages, the photo as shot currently reads slightly better than the style Auto picks. See <doc:MeasuringAccuracy>.
