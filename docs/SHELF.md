# File Shelf

The Shelf module is a local staging area for items users want to keep close to the island temporarily.

## Supported Items

- Files and folders are stored as metadata with security-scoped bookmarks where available.
- URLs and text snippets are stored as local metadata.
- Dropped image data is saved locally for shelf use; large file drops are not copied into app storage.

## Actions

Shelf items can be opened, pinned, removed, dragged back out, revealed in Finder, previewed with Quick Look, copied, shared with the system sharing picker, or sent with AirDrop when the sharing service is available.

Pinned items stay ahead of unpinned items and are not removed by retention cleanup.

## Retention

Settings -> Modules -> Shelf retention controls automatic cleanup for unpinned shelf items. The default is Never, which preserves the previous behavior. Missing local files remain visible with a missing state so users can remove the stale entry or copy the stored path.
