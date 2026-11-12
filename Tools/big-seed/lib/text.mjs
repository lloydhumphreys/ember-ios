// Message bodies, as the composer writes them (after upstream's seed/markup.ts), and made-up things for
// Fernwood's people to say. A mention is written {{@key}}, for the person the seed knows by that key, or
// {{@admin}}, for the server's administrator; the seed puts in their ids as it posts.

export const esc = (text) => String(text).replace(/&/g, "&amp;").replace(/</g, "&lt;").replace(/>/g, "&gt;").replace(/"/g, "&quot;");

/** What's typed into the composer: a paragraph whose lines are kept. */
export const p = (typed) => `<p>${String(typed).split("\n").map(esc).join("<br>")}</p>`;

/** A code block in `language`, its lines broken with <br>s, as the composer's toolbar writes one. */
export const code = (language, source) => `<pre data-language="${esc(language)}">${source.split("\n").map(esc).join("<br>")}</pre>`;

export const at = (key) => `{{@${key}}}`;

/** A paragraph linking to `url`, with the preview the composer adds below a link it unfurls. */
export function linkPreview(before, { url, title, description, image }) {
  const img = image ? `<div class="og-embed__image"><img src="${esc(image)}" class="image center" alt=""></div>` : "";
  const content =
    `<actiontext-opengraph-embed><div class="og-embed gap"><div class="og-embed__content">` +
    `<div class="og-embed__title"><a href="${esc(url)}" rel="noreferrer" target="_blank">${esc(title)}</a></div>` +
    `<div class="og-embed__description">${esc(description)}</div></div>${img}</div></actiontext-opengraph-embed>`;
  return `<p>${esc(before)} <a href="${esc(url)}">${esc(url)}</a></p><action-text-attachment content-type="application/vnd.actiontext.opengraph-embed" content="${esc(content)}"></action-text-attachment>`;
}

/** A picture on a public placeholder host, for cards and previews, which take only addresses off this server. */
export const placeholder = (seed, width, height) => `https://picsum.photos/seed/fernwood-${seed}/${width}/${height}`;

export const pick = (next, list) => list[Math.floor(next() * list.length)];

const THINGS = ["the onboarding flow", "the billing page", "search", "the iOS beta", "the Android build", "the sidebar", "push notifications", "the export job", "dark mode", "the changelog", "the status page", "the importer", "file uploads", "the new pricing", "threads", "the API docs", "the login screen", "the settings page", "the help centre", "the release checklist"];
const STATES = ["looks good to me", "is flaky again", "is ready for review", "shipped this morning", "needs another pass", "is blocked on legal", "is 80% done", "broke on Safari", "passed QA", "is on staging now", "needs copy", "is faster by about 30%", "has a weird edge case", "is waiting on design", "is behind a flag"];
const OPENERS = ["Quick one:", "FYI", "Heads up,", "Small update:", "Hmm,", "Okay so", "Not urgent, but", "Good news:", "Re yesterday,", "For the record,", "", "", ""];
const CLOSERS = ["", "", "", " 👍", " 🙏", " 🎉", " Thoughts?", " Will update here.", " More tomorrow.", " 🌿", " (again)", " Anyone else seeing this?"];
const QUESTIONS = ["Does anyone know who owns {thing}?", "Can someone look at {thing} before lunch?", "Are we still doing {thing} this week?", "Where did we land on {thing}?", "Is {thing} in the release notes?", "Who has context on {thing}?"];
const ANSWERS = ["I think that's me, actually.", "Yes, after the standup.", "Not yet, adding it now.", "Ask Leo, he knows.", "Let me check and get back to you.", "Done ✅", "On it.", "No idea, sorry!", "That was last sprint, I believe.", "Good catch, thank you."];

/** A made-up remark about work, from `next`'s randomness. */
export function remark(next) {
  const thing = pick(next, THINGS);
  const roll = next();
  if (roll < 0.25) return pick(next, QUESTIONS).replace("{thing}", thing);
  if (roll < 0.45) return pick(next, ANSWERS);
  const opener = pick(next, OPENERS);
  const sentence = `${thing} ${pick(next, STATES)}.`;
  return `${opener ? `${opener} ` : ""}${opener ? sentence : sentence[0].toUpperCase() + sentence.slice(1)}${pick(next, CLOSERS)}`;
}

const YESTERDAY = ["finished the migration", "reviewed three PRs", "paired with Sam on the importer", "wrote tests for the sidebar", "fixed the flaky upload test", "triaged the support queue", "drafted the launch email", "profiled search", "cleaned up feature flags", "updated the docs"];
const TODAY = ["start on threads", "ship the export fix", "write the RFC", "pair on push notifications", "finish the billing copy", "look at crash reports", "release 4.2 to beta", "interview two candidates", "tidy the backlog", "dark mode polish"];
const BLOCKERS = ["none", "none", "none", "waiting on design", "need a staging DB", "CI is slow", "none 🎉", "review from Priya"];

export function standup(next) {
  return `Yesterday: ${pick(next, YESTERDAY)}.\nToday: ${pick(next, TODAY)}.\nBlockers: ${pick(next, BLOCKERS)}.`;
}

const VERBS = ["Fix", "Add", "Remove", "Speed up", "Rename", "Refactor", "Document", "Revert", "Tidy", "Guard"];
const AREAS = ["sidebar unread counts", "thread paging", "upload retries", "avatar caching", "search ranking", "push payloads", "link previews", "bot cards", "room sockets", "session renewal", "email templates", "markdown tables"];

export function changelog(next, n) {
  return `v4.${Math.floor(n / 50)}.${n % 50} · ${pick(next, VERBS)} ${pick(next, AREAS)} (#${1000 + n})`;
}

export const BOOSTS = ["👍", "❤️", "😂", "🎉", "🔥", "👀", "🙏", "✅", "+1", "nice!", "🚀", "💯", "so good", "🥐", "🌿", "exactly 16 chars", "🇳🇿", "👩🏽‍💻"];

export const EMOJI_ONLY = ["🎉", "👍", "😂😂😂", "🫠", "🇳🇿🇯🇵🇧🇷", "👩🏽‍💻", "🧑‍🤝‍🧑", "❤️‍🔥", "🌿🌿", "🥐☕️", "🙃", "💯", "🚀🚀🚀🚀🚀🚀🚀🚀🚀🚀", "👋🏻👋🏼👋🏽👋🏾👋🏿", "🦊", "✨", "🐢", "🏳️‍🌈", "1️⃣2️⃣3️⃣", "🫶"];

export const WORLD = [
  "صباح الخير يا فريق! الإصدار الجديد جاهز للاختبار اليوم.",
  "בוקר טוב לכולם! מישהו ראה את הדוח של אתמול?",
  "The build 4.2.1 passed — الاختبارات نجحت بنسبة 100% ✅",
  "Meeting moved to 15:00 · הפגישה נדחתה ל-15:00 · تم تأجيل الاجتماع",
  "明日のリリース、よろしくお願いします🙏",
  "今天的会议改到下午三点。",
  "점심 같이 드실 분?",
  "सब ठीक है, कल मिलते हैं।",
  "สวัสดีครับ ทุกคน",
  "Добрый день! Кто-нибудь видел новый дизайн?",
  "Γεια σας! Η κυκλοφορία πήγε καλά.",
  "Z̷̢͓a̸͚͝l̴̰͝g̶̳̈o̵̙͝ ̶̤̌t̸̯̾e̴͎͝x̸͈̂t̵̺̐ is still text.",
  "שלום! This line starts in Hebrew and ends in English.",
  "مرحبا 👋 hello 👋 שלום",
  "Ünïcödé çhàrâctérs ëvérywhérë: ñ, ø, å, ß, ł, ő",
];

/** About `length` characters of made-up prose, in paragraphs. */
export function prose(next, length) {
  const paragraphs = [];
  let total = 0;
  while (total < length) {
    let paragraph = "";
    while (paragraph.length < 400) paragraph += `${remark(next)} `;
    paragraphs.push(paragraph.trim());
    total += paragraph.length + 2;
  }
  return paragraphs.join("\n\n").slice(0, length);
}

export const SWIFT = `import SwiftUI

struct RoomRow: View {
    let room: Room
    @Environment(\\.colorScheme) private var colorScheme

    var body: some View {
        HStack(spacing: 12) {
            RoomIcon(room.icon)
            VStack(alignment: .leading) {
                Text(room.name).font(.headline).lineLimit(1)
                if let preview = room.lastMessage?.plainText {
                    Text(preview).font(.subheadline).foregroundStyle(.secondary).lineLimit(2)
                }
            }
            Spacer()
            if room.unread { Circle().frame(width: 8, height: 8) }
        }
    }
}`;

export const TYPESCRIPT = `export async function retry<T>(work: () => Promise<T>, attempts = 3): Promise<T> {
  let last: unknown;
  for (let attempt = 1; attempt <= attempts; attempt++) {
    try {
      return await work();
    } catch (error) {
      last = error;
      await new Promise((resolve) => setTimeout(resolve, 2 ** attempt * 100));
    }
  }
  throw last;
}`;

export const SQL = `SELECT room_id, count(*) AS messages, max(created_at) AS latest
FROM messages
WHERE created_at > datetime('now', '-7 days')
GROUP BY room_id
ORDER BY messages DESC
LIMIT 20;`;

export const JSON_SAMPLE = JSON.stringify({ id: "msg_01", room: { id: "room_42", name: "Launch" }, boosts: [{ content: "🎉", count: 3 }], attachment: null, edited: false }, null, 2);

export const BASH = `#!/usr/bin/env bash
set -euo pipefail
for region in fra1 iad1 syd1; do
  echo "Deploying to $region…"
  ./deploy --region "$region" --version "$(git describe --tags)" || exit 1
done`;

/** A long generated Swift file, for a code block far taller than a screen. */
export function longSwift(lines) {
  const out = ["// Generated: every case Fernwood's sidebar knows.", "enum SidebarItem: String, CaseIterable {"];
  for (let i = 0; i < lines - 3; i++) out.push(`    case item${String(i).padStart(3, "0")} = "item-${i}" // ${i % 7 === 0 ? "a much longer trailing comment that runs on past the edge of any phone screen to test horizontal scrolling in code blocks" : "ok"}`);
  out.push("}");
  return out.join("\n");
}
