# Reseal-js parity checklist (zui client)

One pass over Reseal-js `public/js` (main.js, core/, data/, ui/) against `src/client`.
Marks: `[x]` done, `[ ]` missing, `[~]` intentionally different (reason given).
Missing items carry an id (M1…) and are worked through in that order.

## App shell (main.js, shell.js, router.js)
- [x] Nav rail Chats / Calls / Saved / Contacts / Settings, profile avatar (opens profile), badges with 99+ cap
- [x] M3 'AI' section in the rail and tab bar, and the 'Ask AI' quick action on the empty main pane
- [x] Phone tab bar; switching section closes the chat on phones
- [x] Empty main pane: logo, text, 'New chat', 'New group', 'Saved'
- [x] Routes /c/<id>#seq (message links), /join/<code> (invite sheet, request to join), /@username, /dev
- [x] Boot failure 'Cannot reach Reseal' / 'Try again'; session expiry to sign-in
- [x] Connection pill 'Connecting…' after the connection dropped
- [x] 'Waiting for network…' when the device is offline (zui env.online)
- [x] M18 Window title '(N) Reseal' and the installed-app badge on the web
- [x] M23 Web: the 'Turn on notifications to know when messages arrive.' toast (phones register push by themselves)
- [x] M20 Keyboard (zui keyEvent, zig-core d79cf35): Esc (menus, viewer, info panel, pane, chat, reply/edit), Alt+Up/Down (previous/next chat), Up in an empty composer edits the last message, arrows in the viewer; Ctrl/Cmd+Shift+F if letters arrive
- [x] M26 Labels on icon-only buttons (web tooltips, screen readers, long-press label on phones) with zui box labels (zig-core 418c0ee)

## Chat list (chatlist.js)
- [x] Row: avatar + online dot, type icon, title, lock, mute, time, ticks, preview (Locked chat / typing / Draft / You: / sender), mention and unread badges, pin icon
- [x] Archive row 'Archived · N', Archived chats pane and its empty state
- [x] Filter chips All / Unread / People / Groups / Channels / AI / folders / +; 'Mark all as read' on long press or right click
- [x] Empty states, story strip in All only
- [x] Chat menu: Pin, Mute… (1 h, 8 h, 2 days, forever), Archive (toast with Undo), Mark as read/unread, Add to folder…, Lock chat, Edit (saved), delete/leave items by chat type
- [x] Delete chat / group / saved chat, Clear saved, Leave dialogs with Reseal-js wording
- [x] Search: Recent, Chats, Global search, On Wufour, Messages
- [x] Saved pane: search, new saved chat, hint with fewer than 2 saved chats
- [x] M17 Saved editor: the primary chat's name is fixed ('Your default saved chat keeps its name.')

## Chat view (chatview.js)
- [x] Header: avatar, title, lock/sparkles, status line by chat type, Call / Video call / group call, Search in chat, More
- [x] Top bars: group call bar with Join, pinned bar, AI notice
- [x] M8 Pinned bar: cycles to the next pin on each tap, 'Pinned message #n', × Unpin for those allowed
- [x] Composer replacements (Join, Mute in channels, Unblock, deleted account, admins only)
- [x] Day separators, unread separator, runs, infinite scroll both ways
- [x] Intro: assistant greeting and starters, 'Encrypted chat' + 'Verify the security code', saved purpose
- [x] Scroll-to-bottom button with count
- [x] M1 'Next mention' button (jumps to the first unread mention)
- [x] Read marking, jump to message with highlight, 'That message is no longer available.'
- [x] Message menu: reactions bar + More reactions, Reply, Edit, Copy text, Copy message link, Pin/Unpin, Forward, Save to Saved / Save to…, Download, Retract vote, Stop poll, Seen by…, Select, Details, Delete
- [x] Pin dialog with 'Notify all members'
- [x] Delete dialog ('Delete for yourself, or for everyone in the chat.', ticked), channels/saved always for everyone
- [x] Forward picker (several chats, 'Forwarded to {name}' / '{n} chats')
- [x] Selection mode (Select messages / Select notes), Copy / Forward / Delete
- [x] Reactions list, poll voters ('Votes'), Message details
- [x] More menu: info item names, Edit, Mute, lock, Select, Scheduled/Reminders, Auto-delete submenu, Encryption, Export, Talk to a person, Block/Unblock, Clear history, delete items
- [x] Block flow and toasts; Clear history with 'Also clear for {name}' / 'Clear for everyone'
- [x] Scheduled / Reminders sheet with Send now, delete, empty states, 'When {name} comes online'
- [x] In-chat search for plain chats (server)
- [x] M15 In-chat search in encrypted chats over an on-device index ('Search everything', 'Indexing…'); kept on the device encrypted (AES-GCM, key in secure storage), forgotten at log out
- [x] M13 Hashtags open in-chat search; tapping inline code copies it; 'Nobody has that username.' for unknown mentions
- [x] Avatars and sender names open profiles; voice messages play the next one
- [x] M11 Inline bot buttons (URL buttons open, callback buttons call the server and toast)
- [x] M12 AI replies: Markdown rendering (headings, lists, tables, code blocks with Copy → 'Code copied') and Stop / Copy / Regenerate
- [x] Call service messages start a call again
- [x] M19 Web: paste and drag-and-drop files into the chat
- [x] A double tap (or double click) on a message adds a heart; one tap opens the menu once a double tap is ruled out (300 ms)

## Composer (composer.js)
- [x] Attach, text, emoji, send / mic / round / edit button; Send with Enter
- [x] M2 Placeholders 'Broadcast' (channels) and 'Write a note…' (Saved)
- [x] Formatting: the bar over a selection (Bold, Italic, Underline, Strikethrough, Monospace, Spoiler, Link), Ctrl/Command+B, I, U, +Shift X, M, P, the link prompt (Ctrl+K, 'Add link'), Ctrl+Shift+F to search chats (zui selection and shortcut letters, zig-core 454ca90; iOS: the bar needs a multi-line composer, shortcuts on hardware keyboards)
- [x] @mention suggestions, typing indicator, drafts, link preview with dismiss, edit/reply bars, length limit
- [x] Send menu: without sound, Schedule / Set a reminder, Send when online, Send as disappearing…
- [x] Voice/round mode switch, recording bar, limits, recording typing actions
- [x] M14 Typing actions 'sending a photo/video/file' while uploading (Reseal-js never sends 'choosing a sticker'; it only names it)
- [x] Attach menu: Photo or video, File, Poll, Location
- [x] Attach sheet: Send photo/video/file/{n} items, Compress images, Hide with spoiler, caption, size limit
- [x] Poll sheet (question, options, anonymous, multiple, quiz with correct answer and explanation)
- [x] Location, emoji panel with search and stickers
- [x] M24 Emoji panel section title 'Recently used'
- [x] Sent and incoming sounds (sounds.js tones, when Sounds is on)

## Bubbles (message.js, text.js, format.js, markdown.js)
- [x] Meta line: timer, lock on encrypted media, views, edited, channel signature, time, status icons
- [x] Forwarded from, reply quote (tap jumps), glimpse reply quote
- [x] M9 Album grid for 2–10 photos/videos in one message (they stack now)
- [x] Spoiler cover on media, upload progress, file card with size and download
- [x] Voice bubble play/pause, waveform, time
- [x] M10 Seek by tapping the waveform
- [x] Voice speed 1× / 1.5× / 2× while playing, remembered (zui fx.playbackRate, zig-core 793051d)
- [x] Round video bubble
- [x] Polls (tap to vote, several answers + Vote, results, quiz marks, View votes, explanation)
- [x] Location card (opens Wufour Maps), link preview card, sticker, big emoji
- [x] M25 Contact card: tap opens the profile
- [x] Decrypt states, Deleted message, Unverified sender, Not sent + Retry/Delete
- [x] Reactions row (tap toggles), service messages, selection mark
- [x] Reaction chips: up to three reactors' faces (not in channels) or the count, their names as the label (web tooltip), a tap toggles mine, a long press or right click lists them
- [x] Summaries, service texts, typing texts, presence texts, rich text entities and links

## Info panel (info.js)
- [x] User/bot info: Message, Call, Video, Mute; username (copied), bio, AI model, View safety number, glimpses, groups in common, shared media, contacts, export, block, delete
- [x] Encryption pane with emoji, numbers and 'Mark as verified'
- [x] M5 Team info for customers ('About {team}', encryption row, 'Order' row, shared media, export, delete)
- [x] M4 Saved info ('About Saved' / 'Saved chat info': 'Only you can see this…', Purpose, items / photos & videos / files counts, shared media, export, delete)
- [x] Group/channel info: counts, Mute, Add, Leave, Description, Public link, Invite links, Encryption, Auto-delete, members, Edit
- [x] M6 Group info 'Voice chat' button
- [x] M7 'Search members' when there are more than 15
- [x] Member menu (admin rights, transfer, remove, ban), admin rights sheet, add members, join requests, invite links and new link sheet, edit pane, public link, permissions, settings section, administrators, banned users
- [x] Shared media tabs Media / Files / Links / Voice / Music

## Calls (calls.js)
- [x] Start from header, profile, call history and call messages; group calls in groups/channels
- [x] Ringing / Connecting / Reconnecting / timer / end reasons; incoming banner with Decline, Answer with video, Answer
- [x] Minimize (mini bar), full screen, encryption emoji badge, unverified warning
- [x] 1:1 and group views, 'Waiting for others to join…', hands on tiles
- [x] Mute, Camera, Screen (desktop web), Flip (phones), Raise hand, End/Leave
- [~] M21 Devices menu (Microphone / Camera / Speaker): zui media has no device list or choice (only front/back camera, which the Flip button uses); 'Open chat' is the call screen's top-bar button
- [x] M22 Floating emoji reactions in group calls; 'Reconnected. If someone cannot hear you…' after a group call reconnects
- [x] Ringtone, dial tone, connect and hang-up sounds, and the message chime and sent sound: Reseal-js's tones made as WAV here and played with fx.play (looped, on the ringtone or call stream; the phones also ring through their call screens)
- [x] 'Voice call' / 'Video call' on Android's ringing screen in the app's language (zui Call.label, zig-core 70d5fe9); CallKit names the kind itself in the phone's language

## Viewer (viewer.js)
- [x] Sender, date, 'i / n', Show in chat, Reply, Forward, Download, Close, Previous/Next, caption, protected content, 'Could not load this file.'
- [x] Viewer: pinch, wheel and the Zoom button zoom 1-5x, a double tap toggles 2.5x, a drag moves a zoomed picture, a sideways swipe goes on (right to left aware), a vertical one closes, arrow keys (zui.gesture over pointer events, zig-core afa236e)

## Pickers (pickers.js)
- [x] Chat picker with search, several chats, chips, Send, 'No chats found'
- [x] M16 Chat picker row subtitles ('Your notes', presence, channel / bot / group); user picker title 'Add people' and empty state 'Nobody found' / 'Search by name or @username.'

## Settings (settings.js, gates.js, theme.js, emoji.js, drafts.js)
- [x] Compose menu (New message, group, channel, glimpse, Chat with AI), new group/channel sheet
- [x] Settings root, profile editing with live username check, delete account, Reseal features tour, log out
- [x] Notifications and sounds (Desktop notifications / Notifications, Message preview, Sounds)
- [x] Privacy rules, read receipts, link previews, blocked users
- [x] Encryption (automatic / advanced protection, passcode change, new recovery key, fingerprint), Security (chat lock, devices, log out)
- [x] Appearance: theme, accent colour, text size, message corners, send with Enter
- [x] 'Animations' switch: turns transitions off and on everywhere (zui fx.reduceMotion, zig-core a95cee7); chat rows and poll bars animate
- [x] Language: 'Language changed. Reloading…' and the web reloads in the new language (settings.js); the phones switch at once
- [x] Chat folders pane, suggested folders, folder editor
- [x] Contacts pane, calls history with Call back
- [x] Sign-in gate, unlock gate, recovery key sheet
- [x] Drafts per chat synced, encrypted in E2EE chats

## Realtime and notifications (sync.js, chats.js, messages.js)
- [x] Live messages, edits, streaming, deletions, reactions, polls, scheduled changes, chat updates, read receipts, pins, members, cleared history, typing, presence, profiles, blocks, folders, keys
- [x] Unread and mention counting, archive pop-out, notifications (muted, silent, locked, previews off), embed forwarding
- [x] Reaction notifications, due reminders (toast with Open), support handoff, new-device security toast
- [x] Optimistic sends in order, retry, forwarding re-encryption, optimistic reactions, poll actions, read receipts

## Not in the inventory above (checked separately)
- [x] Glimpses (stories.js), AI assistants (bots.js), developer console (dev.js), export (export.js), chat lock (chatlock.js)
