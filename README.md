# Mark Muted Chats Read 16

Automatically mark unread conversations using **Hide Alerts** as read, without changing unmuted chats. For iOS 16 Dopamine rootless.

**Install:** Download the newest DEB from Releases. In Dopamine, use **Reboot Userspace** after installing, not just respring, to reload the `imagent` message service.

**Behaviour:** Each incoming message event can trigger one read check for a muted chat; no continuous scans or repeated timers. On opening Messages, a separate foreground catch-up scan checks older unread muted chats.

**v1.3.1:** Adds `IMChatRegistry` unread-change event hooks used by the background messaging stack, and removes unnecessary SpringBoard injection. Retains the working `IMChat isMuted` detection. Runtime selectors are checked before hooking. The background path has not yet been confirmed on-device.

**Troubleshooting:** Look for `[MutedRead]` entries from the `imagent` process in the system log after rebooting userspace. If there are no such entries, investigate daemon injection; if the hooks are installed but no mark attempt occurs, investigate IMCore event and chat loading. No chat content or identifiers are logged.

**Note:** Marking iMessages read may send read receipts if enabled.
