# WhatsApp Notifier Extension

Shows recent WhatsApp notifications in DynamicIsland and can auto-reveal the island when a new WhatsApp message arrives.
When available, it renders sender avatar, sender name, and message preview from macOS notifications.
This extension is configured as a notification-feed extension, so it opens the shared Notifications bar instead of using its own dedicated module slot.

## Permissions

- `notifications` (read mirrored notification feed from host)
- `storage` (persist last seen message id)

## Settings

- `autoReveal`: automatically bring the island forward when a new WhatsApp message is detected.

## Privacy note

Message preview and avatar are best-effort. If macOS notification previews are disabled, the extension falls back to sender/app-only display.
