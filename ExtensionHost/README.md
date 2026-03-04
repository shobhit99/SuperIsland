ExtensionHost contains the app-side DynamicIsland extension runtime.

This folder is intentionally separate from:
- `DynamicIsland/`, which contains the main app UI and built-in modules
- `Extensions/`, which contains unpacked local and sample third-party extensions

The files here implement manifest loading, the JavaScriptCore bridge, native rendering,
settings schemas, runtime sandboxing, and extension discovery used by the app.
