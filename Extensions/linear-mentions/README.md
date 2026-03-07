# Linear Mentions

DynamicIsland extension that polls Linear for new issue mentions and issue comment mentions, mirrors them into the shared notification feed, and opens an inline reply composer when you click the island notification.

## Setup

1. Open DynamicIsland Settings -> Extensions -> `Linear Mentions`.
2. Activate the extension and click `Login with Linear`.
3. Complete OAuth in the browser. The callback returns to `superisland://auth/callback?...` and is persisted automatically.
4. Keep the extension active.

## Behavior

- Detects new Linear notifications of type `issueMention` and `issueCommentMention`.
- Uses the current notification list as a baseline on first successful sync, so it does not replay old mentions immediately after setup.
- Clicking the Dynamic Island notification opens a reply composer inside the island.
- Replies are sent with Linear's `commentCreate` GraphQL mutation.

## Notes

- The OAuth callback payload is persisted in the extension-scoped store and reused until it expires or you disconnect.
- Replies to comment mentions are posted into the same thread when Linear provides a parent comment thread ID.
- Mentions in issue descriptions are treated as issue-level mentions and replied to as a normal issue comment.
