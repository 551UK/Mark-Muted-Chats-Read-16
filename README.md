# Mark Muted Chats Read 16

Automatically marks muted Messages app as read. Mute chats using **Hide Alerts** which is a stock iOS feature. Once you mark a chat as muted you will never get a notification or badge from that person as all messages will be marked as read.

Settings includes an enable switch and GitHub link. Changes apply without a respring.

You can use to hide monthly network messages that you will never read or similar.

For iOS 16 Dopamine/rootless. Install the `.deb` from Releases and respring once. Enabled read receipts may be sent.

Version 1.2.2 reacts once to each newly unread message event in muted conversations, with no polling or repeat timers. The background imagent hook is experimental and requires on-device testing. Unmuted chats remain untouched.

Background injection uses the explicit `Mode = Any` filter so either the message service or Messages app can load the tweak. No periodic scans or retries.
