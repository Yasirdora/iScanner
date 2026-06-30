# Scanner engine

An on-device document scanning pipeline for Apple platforms. No network, no
third-party dependencies, no per-scan cost.

The engine builds for macOS as well as iOS, so the whole pipeline can be run and
measured from the command line without a simulator.

## Build

```bash
swift build
swift test
```

## Measure

Generate a synthetic page with exact ground truth, then score every enhancement
style against it:

```bash
swift run scanlab synth Fixtures/receipt-hard.png --difficulty hard
swift run scanlab compare Fixtures/receipt-hard.png
```

```
style      enhance    recognize   chars    conf     CER      png
color      58ms       897ms       351      0.533    0.000    3548KB
grayscale  46ms       254ms       351      0.540    0.006    1731KB
bitonal    48ms       259ms       349      0.526    0.003    131KB
original   0ms        245ms       349      0.525    0.332    1385KB
```

Unenhanced, a third of the characters are wrong. Corrected, none are. Bitonal is
10.6× smaller at a character error rate of 0.003.

## Use

```bash
swift run scanlab process <image> --style bitonal   # searchable PDF + PNG
swift run scanlab extract <image>                   # typed fields, on-device
```

`process` writes a PDF whose text layer is real: selectable, searchable, and
positioned on the ink.
