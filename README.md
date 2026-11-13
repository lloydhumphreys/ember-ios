# Ember for iOS

An iPhone app for [Ember](https://github.com/NYLLON-SOFTWARE/ember-cloudflare), built on the [Ember Swift SDK](https://github.com/lloydhumphreys/ember-swift-sdk).

<p>
  <picture>
    <source media="(prefers-color-scheme: dark)" srcset="docs/screenshots/rooms-dark.png">
    <img src="docs/screenshots/rooms.png" width="240" alt="Rooms">
  </picture>
  <picture>
    <source media="(prefers-color-scheme: dark)" srcset="docs/screenshots/room-dark.png">
    <img src="docs/screenshots/room.png" width="240" alt="A room">
  </picture>
  <picture>
    <source media="(prefers-color-scheme: dark)" srcset="docs/screenshots/cards-dark.png">
    <img src="docs/screenshots/cards.png" width="240" alt="Bot cards">
  </picture>
</p>

## Status

The app has been tested mostly against the SDK's stand-in server, which mirrors Ember's protocol as of Ember release 0.4.2, with some use against a real Ember deployment. It runs on iPhone only; there is no iPad layout.

There are no push notifications. Ember's server sends Web Push only to a short list of browser push services, so a native app needs a change on the server first. [docs/push-notifications.md](docs/push-notifications.md) sets out the options.

## What it covers

**Connecting and signing in.** You enter a server address, and the app checks that it is an Ember server. It then signs in with email and password, or with just a name when the server allows guests. Forgot Password opens the server's reset page in Safari. The server and the session are remembered between launches. A server that hasn't been set up yet is opened in Safari for first-run setup. If the server can't be reached, the app retries on its own and again as soon as the network comes back.

**Accounts.** You can be signed in to several accounts, on the same server or different ones. Tap your avatar for the account menu: switch accounts, Add Account, choose an appearance (system, light or dark), or Sign Out. Each account is kept apart, with its own cookies, drafts and caches. Only the account on screen is connected.

**Home.** The tab bar has Home, Activity and Search, and an orange + button floats above it for a new message. Home lists rooms, with starred ones first, and direct messages, with suggested people to start one with. Pull to refresh. Swipe a row to star it or mute it. Long-press a row to set its notification level. Unread rooms are bold and muted rooms are dimmed. New Message starts a direct message with one or more people from the directory. The app reopens the tab, room or thread you were last in.

**Activity.** Unread rooms and direct messages, with the count on the tab.

**Rooms.** The timeline is newest at the bottom, pages in older and newer history as you scroll, and has a Jump to Latest button. Messages fall under day headings, and messages one person sends close together are grouped. Messages that mention you are highlighted. Edited and deleted messages are marked. Typing indicators are shown, and the room is marked read as you open and leave it. The back button shows how many other rooms are unread. Tapping the room's title opens its details: notifications, star, the members of a group direct message, and who else has the room open now.

**Messages.** Long-press a message to react with a quick emoji, reply in a thread, choose another reaction or type your own, copy it, select its text, edit it or delete it. Edit and delete are offered only where Ember allows them, and delete asks first. Reactions (Ember's boosts) show as chips under the message. Tap a chip to see who reacted and to remove your own, or tap + to add one. An edit, delete or reaction that fails shows under the message with Retry. Long messages fold behind Show more.

**Composing.** A plain-text composer, with photos, videos and files attached from the photo library or the Files app. Type @ to mention someone: suggestions show each person's avatar, so two people with the same name can be told apart. Staged files show above the field and can be removed before sending. Uploads show progress. A message that fails to send can be retried or discarded. Drafts are kept for each room and thread until you send or clear them, across launches. Editing reuses the composer and changes only the part of the body you touched, so formatting elsewhere in the message is kept.

**Threads.** A thread shows the parent and its replies. The reply composer can also send the reply to the room, or to the direct message. In the room, a thread shows a summary with faces, a reply count and the time of the latest reply.

**Message bodies.** Paragraphs, headings, code blocks, quotes, lists, tables, rules, link previews and mentions are drawn natively. Emoji-only messages are shown large. Images are shown inline at their stored proportions, and animated GIFs play unless Reduce Motion is on. A picture that fails to load can be retried. Videos show a poster and play full screen. Images and other files open in Quick Look. A tapped link to a room, message or thread on the same server opens in the app. Other links open only if they are http, https, `mailto` or `tel`.

**Bot cards.** Ember's card attachments, square-cornered and tinted: colour bar, author, title, fields, sections, buttons, tables, context rows, images, tiles, footers and "Show more" for long text.

**Search.** Search messages, with filters for room, person, mentions of you, links, files and threads, sorted newest or oldest first. Matched words are highlighted and recent searches are kept. Tapping a result opens the room or thread at that message.

**Connection.** When the device is offline, a crossed-out Wi-Fi symbol shows on Home and in the room's title. A spinner shows while the app reconnects.

**Signing out.** Signing out, or a session the server ends, removes what the app kept for that account: drafts, unsent messages, downloaded messages, files and pictures, and the room and people lists.

**Accessibility.** Layouts change at the largest text sizes. VoiceOver reads unread counts and offers a message's actions. Colours are checked for contrast. Reduce Motion is respected.

## Not there yet

Compared with Ember's web client:

- A rich-text composer (bold, lists, code). The composer sends plain text and mentions.
- Quote and Copy link in the message menu.
- Presence in the room lists, and the member list of a shared room.
- Inline video playback.
- Creating rooms, and room settings.
- Profiles and the people list.
- Workspace, admin, bot and assistant settings.
- Invitations, join links and QR sign-in.
- Signing in with Memberful. First-run setup is done in Safari.
- Custom room icons and branding. Rooms show a number sign or a lock.
- Push notifications (see Status).
- iPad.

## Getting it running

The app runs on iOS 18 and later. It uses iOS 26 features where they exist, so you need Xcode 26 to build it. You also need [XcodeGen](https://github.com/yonaskolb/XcodeGen).

```bash
brew install xcodegen
```

The app uses the [Ember Swift SDK](https://github.com/lloydhumphreys/ember-swift-sdk) at version 0.1.0, which Xcode fetches when it opens the project.

```bash
git clone https://github.com/lloydhumphreys/ember-ios
```

```bash
cd ember-ios
```

The Xcode project is generated from `project.yml` and isn't checked in.

```bash
xcodegen generate
```

```bash
open Ember.xcodeproj
```

Choose the `Ember` scheme and an iPhone simulator, then run. A simulator build needs no signing setup. Run `xcodegen generate` again after adding or removing files.

To work on the SDK alongside the app, clone it next to `ember-ios` and change `packages.EmberSDK` in `project.yml` to `path: ../ember-swift-sdk`.

## Trying it without a server

The SDK includes a stand-in server, so you can try the app without deploying Ember. It is a small Node script (Node 18 or later, no dependencies) that speaks Ember's HTTP and socket protocol, with seeded people, rooms, threads, files and bot cards. State is held in memory and resets on each start.

Every seeded account uses one password, which you choose. The server reads it from `EMBER_SEED_PASSWORD`, or else from `.dev/seed-password` at the root of the SDK checkout. It never prints the password. Clone the SDK next to the app, and from that checkout:

```bash
git clone https://github.com/lloydhumphreys/ember-swift-sdk ../ember-swift-sdk
```

```bash
cd ../ember-swift-sdk
```

```bash
export EMBER_SEED_PASSWORD='choose-a-password'
```

```bash
node Tools/mock-server/server.mjs
```

On start-up the server prints the address it is listening on and the administrator account to sign in as. In the app, enter `127.0.0.1:8787` as the server, then sign in with that account and your password. The other seeded accounts are listed in `Tools/mock-server/README.md`, along with the variables for guest sign-in, the scripted replier and search paging.

## Pointing it at a real Ember server

Enter the server's address on the first screen. `https://` is assumed unless the host is local, so `chat.example.com` is enough. To use another server as well, choose Add Account in the account menu. To change the server before signing in, tap Change next to it on the sign-in screen.

To fill a server of your own with test data, `Tools/big-seed` adds a made-up company of 50 people with rooms, threads, files and bot cards, and can remove them again. [Tools/big-seed/README.md](Tools/big-seed/README.md) explains how to run it.

## Running on a device

A device build needs a development team and a bundle ID that belongs to it. `Config/Shared.xcconfig` includes `Config/Local.xcconfig` if it exists, and git ignores that file. Copy the template and fill in both values:

```bash
cp Config/Local.example.xcconfig Config/Local.xcconfig
```

```
DEVELOPMENT_TEAM = YOUR_TEAM_ID
EMBER_BUNDLE_ID = com.yourname.ember
```

Then choose your device in Xcode and run.

## Running the tests

The tests are in `EmberTests`. They use the SDK's `EmberTesting` stand-ins and don't touch the network. Run them from Xcode with Product › Test, or from the command line with any iPhone simulator you have installed:

```bash
xcodebuild test -project Ember.xcodeproj -scheme Ember -destination 'platform=iOS Simulator,name=iPhone 17'
```

## How it is put together

The app is SwiftUI, written in Swift 6 with strict concurrency. The SDK does the networking and keeps the state: `Workspace` for the sidebar, `RoomSession` and `ThreadSession` for what is on screen. The app observes those stores and draws them. `Accounts` holds one slot per account, each with its own `SessionController` and `AccountStores`. `SessionController` tracks whether you are choosing a server, signing in, signed in or unable to reach the server. The sockets close when the app goes to the background and reopen when it comes back.

- `Ember/App`: the entry point, the root view, accounts, the session controller, network status, server links and where you were.
- `Ember/Auth`: choosing a server and signing in.
- `Ember/Rooms`: the Home and Activity tabs, the account menu and new direct messages.
- `Ember/Room`: the timeline, messages, reactions, attachments, pictures, video, cards, rich text, the composer, mentions, drafts, room details and threads.
- `Ember/Search`: search and its filters.
- `Ember/Support`: avatars, appearance and shared pieces.

## Licence and credits

MIT. See [LICENSE](LICENSE).

The app is a client for [Ember](https://github.com/NYLLON-SOFTWARE/ember-cloudflare), which grew out of [Campfire](https://github.com/basecamp/once-campfire) by 37signals. The flame mark is Ember's.
