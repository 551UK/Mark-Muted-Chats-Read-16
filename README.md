# Mark Muted Chats Read 16

Automatically marks muted Messages app as read. Mute chats using **Hide Alerts** which is a stock iOS feature. Once you mark a chat as muted you will never get a notification or badge from that person as all messages will be marked as read.

Settings includes an enable switch and GitHub link. Changes apply without a respring.

You can use to hide monthly network messages that you will never read or similar.

For iOS 16 Dopamine/rootless. Install the `.deb` from Releases and respring once. Enabled read receipts may be sent.

Version 1.2.3 reacts once to each newly unread message event in muted conversations, with no polling or repeat timers. The background imagent hook is experimental and requires on-device testing. Unmuted chats remain untouched.

Background injection uses the explicit `Mode = Any` filter so either the message service or Messages app can load the tweak. No periodic scans or retries.

In 1.2.3, an initial catch-up no longer depends only on an early startup scan: IMChatRegistry chat-loaded events and Messages foreground activation also trigger a catch-up scan. Runtime logs include non-identifying mark attempts under `[MutedRead]`, useful for diagnosing devices where private APIs differ. Requires on-device verification; a successful build does not prove that mute detection or daemon injection runs.

## 1.3.0 correction
Replaces the incorrect assumption that iOS 16 `IMChat` implements `__ck_isMuted` with the documented modern `isMuted` and `muteUntilDate` runtime selectors, preserving legacy fallbacks. This is the likely reason all previous versions failed to mark any conversation. Toggling Hide Alerts gives the model one 200 ms opportunity to settle its state before one read attempt. There is still no periodic timer or polling. Install/respring, test an unread muted conversation. iOS 16 runtime testing remains necessary.
