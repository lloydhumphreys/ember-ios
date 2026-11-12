# Big seed

Fills an Ember that's already set up with Fernwood, a made-up company of 50 people, so the iOS app has
plenty to show. You get 30 rooms (open and closed, some with thousands of messages), DMs with you,
threads of 200+ replies, boosts, edits, mentions, files and pictures of awkward shapes, and bot cards.
Node 20+, nothing to install.

## Run it

1. In Ember's Community settings, copy the Join link into `.dev/big-seed-join-link`.
2. Optional, for bot cards: make a bot on the Chat bots page and paste its key (or its webhook URL) into
   `.dev/big-seed-bot-key`.
3. From the repo:

   ```sh
   node Tools/big-seed/seed.mjs https://ember.example.workers.dev --confirm https://ember.example.workers.dev
   ```

If it stops for the day, or you stop it with Ctrl-C, run the same command again and it carries on.

| Option | |
| --- | --- |
| `--dry-run` | Shows what it would make and what it would cost. Doesn't contact the server. |
| `--size small\|large` | `small` (default) is about 59,000 rows, so one day. `large` is about 227,000, so three days. |
| `--budget <rows>` | How many Durable Object rows it may write per UTC day. Default 80,000 (the free plan allows 100,000). Its reckoning runs about 12% over what Ember really writes, so you have room to spare. |
| `--pace <ms>` | Wait between writes. Default 100. |
| `--admin-push few\|none\|many` | DMs with you and mentions of you, which push to your phone. `few` (default) is 4 DMs and a few mentions. `none` skips them. `many` adds a 250-message DM. |
| `--dir <dir>` | Where the link, key, password and state are kept. Default `.dev/`. |
| `--remove` | Deletes the rooms and DMs it made. |

## What it keeps in `.dev/` (git-ignored)

| File | |
| --- | --- |
| `big-seed-join-link`, `big-seed-bot-key` | You fill these in. The seed never prints them. |
| `big-seed-password` | Made on the first run. Every Fernwood person signs in with it. |
| `big-seed-state.json` | Everyone's ids and sessions, and how far each room has got. Keep it, or `--remove` can't find what to delete. |

The fake people's addresses are `big-seed.<name>@fernwood.example`. `.example` is a reserved domain, so
no email can reach anyone.

## Taking it out

1. `node Tools/big-seed/seed.mjs <origin> --confirm <origin> --remove` deletes every room and DM the seed made, with their messages and files. For a large seed this writes about 30,000 rows.
2. In Community settings, remove the `@fernwood.example` people, and delete the bot. The seed can't do this for you.

## What it can't do

- **Backdating:** every message is stamped with the time it's sent, so everything looks recent.
- **Interactive buttons:** bot buttons are links only.
- **Card pictures:** they have to live on another host, so they come from picsum.photos and need a network connection to show.
- **Your own messages:** it can't post as you. It mentions you and DMs you instead.

## If the state file is lost

The people sign in again (Ember allows 10 sign-ins per address every 3 minutes, so this takes a few
minutes), but the rooms are made again from scratch. Remove the old ones by hand.
