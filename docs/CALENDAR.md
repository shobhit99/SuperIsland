# Calendar

The Calendar module reads events through EventKit after the user grants Calendar access.

## Source selection

Settings -> Modules -> Calendar shows calendars grouped by account/source. The first launch keeps all calendars enabled. Once the user changes any calendar toggle, that explicit selection is used for:

- Today's events
- The selected day
- Upcoming events
- Calendar grid event indicators
- Pre-event island reminders

## Duplicate and clutter filters

The module can hide birthday calendars, hide holiday calendars, and collapse duplicate events. Duplicate collapse compares title, start/end time, all-day state, and location when available.

## Meeting links

Meeting links are detected from event notes and location fields. Zoom, Google Meet, Microsoft Teams, and generic web links can be opened or copied from the expanded calendar view.
