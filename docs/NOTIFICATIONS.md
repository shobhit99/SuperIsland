# Notifications

SuperIsland can show notification-like events from supported sources. macOS does not provide a public API for arbitrary apps to read every item from Notification Center, so the module should not be described as full system-wide notification mirroring.

## Supported sources

- Extension notifications from installed SuperIsland extensions.
- WhatsApp notifications from the bundled WhatsApp integration.
- Compatible app broadcasts from apps that publish public distributed notifications.

Settings -> Modules -> Notifications lets users enable or disable each supported source, hide previews, and choose how many feed items are retained.

## macOS notification permission

SuperIsland requests notification permission when the Notifications module or an extension needs to send macOS notifications. This permission allows SuperIsland to deliver its own notifications. It does not grant private access to other apps' Notification Center contents.

If permission is denied, use Settings -> Modules -> Notifications -> Permission to open System Settings.

## Unsupported behavior

Installed-app selection is only safe when those apps expose a supported public source. Until a provider exists for a specific app, SuperIsland should show source-level controls instead of claiming it can mirror every app installed on the Mac.
