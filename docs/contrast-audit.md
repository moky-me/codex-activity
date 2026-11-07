# Contrast audit

Palette from [OpenAI Apps SDK UI primitives](https://github.com/openai/apps-sdk-ui/blob/0f00143c7a639906f1621fe58e1b6be7b5bea46d/src/styles/variables-primitive.css). Official apca-w3 0.1.9 (0.0.98G-4g) and WCAG 2.2 contrast ratios for opaque sRGB colors. Covers the panel, normal cards, and hover. Native menus and alerts retain macOS styling and are outside this numeric audit. Decorative separators and outlines are outside the text and icon measurements.

| Role | Light color | Min light Lc | Dark color | Min dark Lc | Target Lc | Min WCAG light | Min WCAG dark |
|---|---|---:|---|---:|---:|---:|---:|
| Primary text | #0d0d0d | 96.8 | #ffffff | 99.7 | 90 | 17.05:1 | 11.20:1 |
| Secondary / paused / unknown text | #414141 | 84.8 | #dcdcdc | 77.2 | 75 | 8.96:1 | 8.17:1 |
| Project name | #4f4f4f | 79.4 | #cdcdcd | 68.1 | — | 7.19:1 | 7.05:1 |
| Running text | #004f99 | 78.6 | #cce6ff | 81.4 | 75 | 7.15:1 | 8.71:1 |
| Ready text | #004f1f | 83.3 | #b8ebcc | 79.3 | 75 | 8.62:1 | 8.42:1 |
| Attention text | #6d2e0f | 84.3 | #ffe7d9 | 86.9 | 75 | 9.00:1 | 9.43:1 |
| Error text | #6e1615 | 86.8 | #ffd9d9 | 80.8 | 75 | 10.30:1 | 8.63:1 |
| Tokens at rest | #5d5d5d | 73.7 | #b9b9b9 | 56.4 | — | 5.78:1 | 5.71:1 |
| Tokens on hover | #4f4f4f | 56.6 | #cdcdcd | 58.8 | — | 4.90:1 | 4.62:1 |
| Observation while period menu is open | #0d0d0d | 65.7 | #ffffff | 84.0 | — | 9.91:1 | 5.74:1 |

Values are absolute Lc magnitudes (dark mode is reverse polarity). Primary text target >=90; secondary/status text >=75. Project names and token controls use the WCAG AA text threshold of 4.5:1. General text rows cover panel, card and cardHover. Token rows use their actual resting or hover surfaces. Observation is measured on the pressed period surface. Decorative status stripes are excluded. These are palette targets, not blanket accessibility certification. Existing compact typography is retained. Retina backing pixels are not CSS font-size pixels; no automatic point-to-CSS conversion or SF font equivalence is assumed.

Reference font lookup, minimum CSS px (not a certification of the native SF rendering):

| Lc | Weight 300 | Weight 400 | Weight 700 |
|---|---:|---:|---:|
| 75 | 24 | 18 | 14 |
| 90 | 21 | 16 | 14 |

[Official implementation and font lookup](https://github.com/Myndex/apca-w3#readme). [Readability guidance](https://git.apcacontrast.com/documentation/APCA_in_a_Nutshell).

Both themes use neutral card surfaces. Status is expressed through text and a short stripe at the right edge. Native menus, VoiceOver require separate checks.

All measured pairs meet their stated targets.
