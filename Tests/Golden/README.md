# MVP visual references

`Default.png` and `Transparent.png` were rendered from the deterministic fixtures in ProcessingChecks and visually checked on 2026-11-07 (macOS 26.6.2, arm64). They include a directional shadow cast down and right by upper-left lighting, with the previously approved 140 px transparent margins. The opaque example was inspected composited over white to judge its shadow; the committed files retain transparency.

Normal checks compare decoded pixels exactly. `--record-golden` is an explicit maintenance flag: inspect changed images and the geometric/alpha checks before accepting a new reference. These baselines cover the default style and transparent input, not every platform or color space.
