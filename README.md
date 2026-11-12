# Mark Muted Chats Read 16

Automatically marks muted Messages app as read. Mute chats using **Hide Alerts** which is a stock iOS feature. Once you mark a chat as muted you will never get a notification or badge from that person as all messages will be marked as read.

Settings includes an enable switch and GitHub link. Changes apply without a respring.

You can use to hide monthly network messages that you will never read or similar.

For iOS 16 Dopamine/rootless. Install the `.deb` from Releases and respring once. Enabled read receipts may be sent.

Version 1.2.0 also watches the background `imagent` service, so unread muted chats can be caught while Messages is suspended. This is an iOS 16 rootless update; test on-device because private Apple framework behaviour varies. Normal chats are never intentionally marked read. Hide Alerts remains responsible for silencing alerts; the tweak addresses unread state and badges.
