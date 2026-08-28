# Measuring accuracy

How the engine's quality is measured and guarded.

## Overview

Quality here is measured, not judged by eye. `scanlab synth` writes a synthetic page together with its exact transcript, and `scanlab compare` reads the page in every style and reports the character error rate (CER): the share of characters that are wrong, where 0 means every character is right.

```bash
swift run scanlab synth /tmp/page.png --difficulty hard
swift run scanlab compare /tmp/page.png
```

## Guarded by tests

The test suite turns these measurements into limits. `AccuracyTests` reads four test pages in every style and fails if an error rate rises above what was measured plus a margin of about four characters. Other tests check that the default style beats the photo on ordinary pages, and that Ink is always the smallest file.

A test is only useful if it can fail. With the ink-erasure radius deliberately broken, the 4K Ink case rose from 0.023 to 0.31 and failed.

## Current results

Measured with Xcode 27.0 on an Apple silicon Mac, with page finding off:

| Test page | Auto | Photo as shot |
| --- | --- | --- |
| Ordinary receipt | 0.006 | 0.017 |
| Clean receipt | 0.006 | 0.017 |
| Heavy shadow | 0.023 | 0.011 |
| Heavy shadow, 4K | 0.020 | 0.017 |

On the heavy-shadow pages, the photo as shot reads better than the style Auto picks. Closing that gap is open work.
