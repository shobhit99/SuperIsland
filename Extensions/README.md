# Extensions

This directory contains pluggable SuperIsland extensions.

Each extension is self-contained and can be distributed independently (for example as a zip or from a Git repository) with this shape:

```text
<extension>/
  manifest.json
  index.js
  settings.json (optional)
  assets/ (optional)
```

SuperIsland discovers extension folders from this `Extensions/` path during development.
