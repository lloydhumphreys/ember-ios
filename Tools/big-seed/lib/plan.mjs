// What the seed makes: Fernwood's rooms and DMs, and what's said in each, worked out the same way on
// every run from the size and options alone, so a run that stops can pick up at the step it reached.
//
// A room's script is a list of steps:
//   { k: "say", by, body, label?, thread?, alsoSend?, quote? }   a message, a reply in `thread`, or a quoting reply
//   { k: "edit", by, target, body }                               an edit of the message labelled `target`
//   { k: "boost", by, target, content }                           a boost of it
//   { k: "share", by, file, thread? , label? }                    a file, from files/ or drawn (media.mjs)
//   { k: "bot", marker, payload }                                 the bot's Slack-style post
import * as bot from "./bots.mjs";
import { KEYS } from "./cast.mjs";
import { random } from "./media.mjs";
import { at, BASH, BOOSTS, code, EMOJI_ONLY, esc, JSON_SAMPLE, linkPreview, longSwift, p, pick, placeholder, prose, remark, SQL, standup, changelog, SWIFT, TYPESCRIPT, WORLD } from "./text.mjs";

export const SIZES = {
  small: { scale: 1, firehose: 600, standup: 200, changelog: 100, bigThread: 210, midThread: 60 },
  large: { scale: 2, firehose: 3000, standup: 2500, changelog: 2000, bigThread: 260, midThread: 120 },
};

const hash = (text) => [...text].reduce((h, c) => (Math.imul(h ^ c.codePointAt(0), 16777619) >>> 0), 2166136261);

const EVERYONE = KEYS;
const CORE = ["maya", "sam", "priya", "leo", "jordan", "amara", "tomas"];
const ODD = ["sam2", "alex1", "alex2", "alex3", "maria1", "maria2", "bart", "hubert", "bea", "ravi", "fox", "nour", "yael", "hanako", "jiwoo", "zoe", "siobhan", "ana", "x"];

/**
 * The rooms, in the order the seed fills them: the varied ones first, so that a run stopped by the day's
 * budget leaves a bit of everything, and the rooms of thousands of messages last. `members` lists a
 * closed room's people (the administrator and the bot are added as `admin` and `bot` say).
 */
export const ROOMS = [
  { key: "launch", name: "Launch", icon: "rocket", kind: "open", by: "maya" },
  { key: "engineering", name: "Engineering", icon: "code", kind: "open", by: "sam" },
  { key: "design", name: "Design", icon: "palette", kind: "open", by: "priya" },
  { key: "support", name: "Support", icon: "life-buoy", kind: "open", by: "amara" },
  { key: "watercooler", name: "Watercooler", icon: "coffee", kind: "open", by: "jordan" },
  { key: "whoswho", name: "Who's who", icon: "users", kind: "open", by: "alex1" },
  { key: "photos", name: "Photos", icon: "camera", kind: "open", by: "priya" },
  { key: "files", name: "Files & docs", icon: "file-text", kind: "open", by: "jordan" },
  { key: "codereview", name: "Code review", icon: "git-pull-request", kind: "open", by: "leo" },
  { key: "longreads", name: "Long reads", icon: "scroll-text", kind: "open", by: "maya" },
  { key: "emoji", name: "Emoji only 🎉", icon: "", kind: "open", by: "jordan" },
  { key: "world", name: "International · دولي · 国際", icon: "languages", kind: "open", by: "nour" },
  { key: "releases", name: "Release train", icon: "train-front", kind: "open", by: "sam", needsBot: true },
  { key: "incidents", name: "Incidents", icon: "siren", kind: "open", by: "amara", needsBot: true },
  { key: "announcements", name: "Announcements", icon: "megaphone", kind: "open", by: "maya" },
  { key: "bookclub", name: "Book club", icon: "book-open", kind: "open", by: "yael" },
  { key: "hiking", name: "Hiking", icon: "mountain", kind: "open", by: "tomas" },
  { key: "recipes", name: "Recipes", icon: "utensils", kind: "open", by: "amara" },
  { key: "music", name: "Music", icon: "music", kind: "open", by: "leo" },
  { key: "hundred", name: "A room whose name is exactly one hundred characters long, so the sidebar has to cut it off somewhere", icon: "", kind: "open", by: "bart" },
  { key: "quiet", name: "Quiet corner", icon: "leaf", kind: "open", by: "priya" },
  { key: "leadership", name: "Leadership", icon: "briefcase", kind: "closed", by: "maya", members: ["sam", "priya", "rosa", "isla"] },
  { key: "hiring", name: "Hiring", icon: "lock", kind: "closed", by: "quinn", members: ["maya", "isla", "sam", "tara", "ben"] },
  { key: "offsite", name: "Offsite planning", icon: "plane", kind: "closed", by: "leo", members: [...CORE, ...ODD.slice(0, 8), "isla"] },
  { key: "cake", name: "Secret cake 🎂", icon: "cake", kind: "closed", by: "leo", members: ["maya", "jordan", "priya", "amara"] },
  { key: "oncall", name: "On-call", icon: "shield", kind: "closed", by: "sam", members: ["dev", "yusuf", "elena", "sven", "hugo"], bot: true },
  { key: "threads", name: "Threads", icon: "message-circle", kind: "open", by: "maya" },
  { key: "standup", name: "Standup log", icon: "calendar", kind: "open", by: "tomas" },
  { key: "changelog", name: "Changelog archive", icon: "hash", kind: "open", by: "sam" },
  { key: "firehose", name: "Firehose", icon: "flag", kind: "open", by: "leo" },
];

if (ROOMS.find(({ key }) => key === "hundred").name.length !== 100) throw new Error("The hundred-character room name isn't 100 characters");

/** DMs, each started by its first person. `admin` ones include the server's administrator, whose devices each message in them pushes to. */
export function directs(adminMode) {
  if (adminMode === "none") return [];
  const list = [
    { key: "dm-maya", people: ["maya"], admin: true },
    { key: "dm-sam2", people: ["sam2"], admin: true },
    { key: "dm-trio", people: ["leo", "jordan"], admin: true },
    { key: "dm-weekend", people: ["tomas", "amara", "priya", "bea", "nour", "hanako", "alex1", "alex2"], admin: true },
  ];
  if (adminMode === "many") list.push({ key: "dm-long", people: ["zoe"], admin: true });
  return list;
}

class Script {
  steps = [];
  #n = 0;
  #referenced = new Set();
  constructor(seed) {
    this.next = random(hash(seed));
  }
  say(by, body, extra = {}) {
    const label = `m${this.#n++}`;
    this.steps.push({ k: "say", by, body: body.startsWith("<") ? body : p(body), label, ...extra });
    return label;
  }
  reply(by, parent, body, alsoSend = false) {
    this.#referenced.add(parent);
    return this.say(by, body, { thread: parent, ...(alsoSend && { alsoSend }) });
  }
  quote(by, target, body) {
    this.#referenced.add(target);
    return this.say(by, body, { quote: target });
  }
  edit(by, target, body) {
    this.#referenced.add(target);
    this.steps.push({ k: "edit", by, target, body: body.startsWith("<") ? body : p(body) });
  }
  boost(by, target, content) {
    this.#referenced.add(target);
    this.steps.push({ k: "boost", by, target, content });
  }
  share(by, file, extra = {}) {
    const label = `m${this.#n++}`;
    if (extra.thread) this.#referenced.add(extra.thread);
    this.steps.push({ k: "share", by, file, label, ...extra });
    return label;
  }
  bot({ marker, payload }) {
    this.steps.push({ k: "bot", marker, payload });
  }
  /** A few people boost `target`. */
  boosts(target, people, most = 3) {
    const n = Math.floor(this.next() * (most + 1));
    const used = new Set();
    for (let i = 0; i < n; i++) {
      const by = pick(this.next, people);
      const content = pick(this.next, BOOSTS);
      if (used.has(by + content)) continue;
      used.add(by + content);
      this.boost(by, target, content);
    }
  }
  /** `count` messages of chatter among `people`, some of them boosted. */
  chatter(people, count, write = (next) => remark(next), boostChance = 0.2) {
    for (let i = 0; i < count; i++) {
      const by = pick(this.next, people);
      const text = write(this.next, i);
      const label = this.say(by, text);
      if (this.next() < boostChance) this.boosts(label, people);
      // Now and then its author edits it, as people fix typos.
      if (this.next() < 0.03) this.edit(by, label, text.startsWith("<") ? `${text}<p>(edited)</p>` : `${text} ✏️`);
    }
  }
  /** The steps, with labels only on the messages something refers to. */
  done() {
    return this.steps.map((step) => (step.label && !this.#referenced.has(step.label) ? (({ label, ...rest }) => rest)(step) : step));
  }
}

/** The steps of room or DM `key`, at `size`, with or without the administrator and the bot. */
export function scriptFor(key, size, { adminMode, hasBot }) {
  const s = new Script(key);
  const z = SIZES[size];
  const adminOk = adminMode !== "none";
  const mentionAdmin = (fallback) => (adminOk ? at("admin") : at(fallback));
  switch (key) {
    case "launch": {
      s.say("maya", "Launch week! 🚀 This room is for anything that has to happen before Thursday.");
      const plan = s.say("maya", `<p><strong>Plan for Thursday</strong></p><ul><li>09:00 freeze</li><li>11:00 ${at("sam")} deploys</li><li>12:00 ${at("jordan")} sends the announcement</li><li>14:00 retro 🥐</li></ul>`);
      s.boosts(plan, CORE, 5);
      const typo = s.say("jordan", "The anouncement draft is ready for review.");
      s.edit("jordan", typo, "The announcement draft is ready for review. (Fixed the typo, thanks Priya.)");
      s.say("leo", `${at("maya")} can we move the freeze to 10:00? One more fix for the sidebar.`);
      s.quote("maya", "m3", "Fine by me, but no later than 10.");
      s.say("maya", `<p>${mentionAdmin("sam")} could you check the new server is ready for launch traffic? 🙏</p>`);
      s.chatter(CORE, 40 * z.scale);
      s.say("priya", "🚀🚀🚀");
      break;
    }
    case "engineering": {
      s.say("sam", "Engineering chat. Code, deploys, and the occasional rant about CI.");
      const pr = s.say("leo", "<p>Can someone review <a href=\"https://fernwood.example/pr/1234\">#1234</a>? It's the retry fix.</p>");
      s.reply("sam", pr, "Looking now.");
      s.reply("sam", pr, code("typescript", TYPESCRIPT));
      s.reply("leo", pr, "Good call on the backoff. Merging. 🙏", true);
      s.say("dev", code("sql", SQL));
      s.say("hugo", `<p>Weird one: the socket closes after exactly 100 seconds idle. ${at("sam")} ${at("dev")} seen this?</p>`);
      s.say("sam", `<p>${mentionAdmin("dev")} is the Cloudflare plan still the free one? We may be near the daily limit.</p>`);
      s.chatter([...CORE, "dev", "hugo", "kenji", "sven", "yusuf", "ben", "tara", "jamal"], 60 * z.scale, (next, i) => (i % 9 === 4 ? code(pick(next, ["swift", "bash", "json"]), pick(next, [SWIFT, BASH, JSON_SAMPLE])) : remark(next)));
      break;
    }
    case "design": {
      s.say("priya", "Design reviews and pictures of things that aren't finished.");
      const mock = s.share("priya", "onboarding-v3.png");
      s.boosts(mock, CORE, 4);
      s.reply("leo", mock, "The empty state is lovely.");
      s.reply("maya", mock, "Can we try the button lower?");
      s.share("priya", "sunrise.jpg");
      s.say("priya", linkPreview("Type scale reference:", { url: "https://fernwood.example/design/type", title: "Fernwood type scale", description: "Eight sizes, two weights, one rule: never smaller than 13pt.", image: placeholder("type", 1200, 630) }));
      s.chatter([...CORE, "grace", "yael", "zoe"], 40 * z.scale);
      break;
    }
    case "support": {
      s.say("amara", "Customer questions and the answers we found.");
      const q = s.say("chloe", "A customer can't upload a 300 MB video. Is that expected?");
      s.reply("amara", q, "Yes, 250 MB is the limit.");
      s.reply("paula", q, "I'll add it to the help centre.");
      s.say("amara", `<p>Escalating: the Acme export is stuck. ${mentionAdmin("sam")} ${at("dev")} any ideas?</p>`);
      s.chatter(["amara", "chloe", "paula", "finn", "mateo", "zara", "nina"], 40 * z.scale);
      break;
    }
    case "watercooler": {
      s.say("jordan", "Anything not about work. 🌿");
      s.chatter(EVERYONE, 60 * z.scale, (next) => (next() < 0.25 ? pick(next, EMOJI_ONLY) : remark(next)), 0.5);
      break;
    }
    case "whoswho": {
      // The people who share a name talk to and about one another, so the app has to tell them apart.
      s.say("alex1", "Hi, I'm Alex Kim (iOS). There are three of us now. 😅");
      s.say("alex2", "Alex Kim from finance here. Hello other Alexes!");
      s.say("alex3", "And I'm the Alex Kim with no picture.");
      s.say("alex1", `<p>${at("alex2")} ${at("alex3")} let's agree on nicknames.</p>`);
      s.say("sam", `<p>Hi ${at("sam2")}! Welcome, other Sam Rivera. 👋</p>`);
      s.say("sam2", `<p>Thanks ${at("sam")}! People keep sending me your deploy alerts.</p>`);
      s.say("maria1", `<p>${at("maria2")} we keep getting each other's mail too.</p>`);
      s.say("maria2", "Two Maria Rossis, one picture between us.");
      s.say("bart", "Hello! Sorry about the name. Bart is fine.");
      s.say("hubert", "And you can call me Hubert.");
      s.say("fox", "🦊");
      s.say("x", "x");
      s.say("ana", "Hi!");
      s.say("bea", "Bea here 🌻");
      s.say("ravi", "Ravi 🚀 reporting in.");
      s.chatter(ODD, 30 * z.scale);
      break;
    }
    case "photos": {
      s.say("priya", "Pictures, in every awkward shape.");
      for (const file of ["very-tall-6000.png", "very-wide-panorama.png", "tiny-8x8.png", "one-pixel.png", "large-4000x3000.png", "heavy-noise-1200x900.png", "transparent-circle.png", "sunrise.jpg", "send-latency.png"]) {
        const label = s.share(pick(s.next, ["priya", "grace", "leo", "tomas", "hanako"]), file);
        s.boosts(label, CORE, 2);
      }
      const tall = "m1";
      s.reply("leo", tall, "That's a long scroll.");
      s.reply("priya", tall, "It's a stress test 😄");
      s.share("tomas", "tomas.jpg", { thread: tall });
      s.chatter(CORE, 10 * z.scale);
      break;
    }
    case "files": {
      s.say("jordan", "Docs, decks, data. 📎");
      s.share("jordan", "brand-guide.pdf");
      s.share("maria1", "send-latency.csv");
      s.say("maria1", "The numbers behind the latency chart, above.");
      const video = s.share("priya", "prototype.mp4");
      s.reply("maya", video, "Love the transition at 0:03.");
      s.share("nina", "long-name");
      s.share("omar", "data.json");
      s.share("rosa", "notes.txt");
      s.chatter(["jordan", "maria1", "omar", "rosa", "nina", "priya"], 10 * z.scale);
      break;
    }
    case "codereview": {
      s.say("leo", "Paste code here, get opinions.");
      s.say("leo", code("swift", SWIFT));
      s.say("jamal", code("typescript", TYPESCRIPT));
      s.say("tara", code("swift", longSwift(170)));
      s.say("kenji", code("text", "x".repeat(400)));
      s.say("ben", `<p>Inline <code>code</code>, then a block:</p>${code("bash", BASH)}`);
      s.say("hugo", code("json", JSON_SAMPLE));
      s.chatter(["leo", "jamal", "tara", "kenji", "ben", "hugo", "sam"], 20 * z.scale, (next, i) => (i % 3 === 0 ? code(pick(next, ["swift", "typescript", "sql", "bash"]), pick(next, [SWIFT, TYPESCRIPT, SQL, BASH])) : remark(next)));
      break;
    }
    case "longreads": {
      s.say("maya", "For messages that need scrolling.");
      s.say("maya", prose(s.next, 9_800));
      s.say("nina", prose(s.next, 3_000));
      s.say("bart", `<p>${"Supercalifragilisticexpialidocious".repeat(60)}</p>`);
      s.say("sven", `<p>https://fernwood.example/${"very/long/path/".repeat(80)}end</p>`);
      s.say("isla", Array.from({ length: 60 }, (_, i) => `Line ${i + 1}`).join("\n"));
      s.say("maya", `<p><strong>Bold</strong>, <em>italic</em>, <del>struck</del>, <a href="https://fernwood.example">a link</a>.</p><blockquote>A quote, on its own.</blockquote><ul><li>One</li><li>Two<ul><li>Two and a half</li></ul></li></ul><ol><li>First</li><li>Second</li></ol><h1>A heading</h1>`);
      s.chatter(CORE, 5 * z.scale, (next) => prose(next, 1_200));
      break;
    }
    case "emoji": {
      for (let i = 0; i < 40 * z.scale; i++) {
        const label = s.say(pick(s.next, EVERYONE), EMOJI_ONLY[i % EMOJI_ONLY.length]);
        if (i % 3 === 0) s.boosts(label, EVERYONE, 4);
      }
      break;
    }
    case "world": {
      for (const line of WORLD) s.say(pick(s.next, ["nour", "yael", "hanako", "jiwoo", "zoe", "chloe", "elena"]), line);
      s.say("nour", `<p>${at("yael")} ${at("hanako")} مرحبا!</p>`);
      s.chatter(["nour", "yael", "hanako", "jiwoo", "zoe"], 20 * z.scale, (next) => pick(next, WORLD));
      break;
    }
    case "releases": {
      s.say("sam", "Every deploy, as the bot posts it.");
      if (hasBot) {
        for (let i = 0; i < 6 * z.scale; i++) s.bot(bot.deployed(i));
        s.bot(bot.table(25, 1));
        s.bot(bot.table(60, 2));
        s.bot(bot.carousel(6, 1));
        s.bot(bot.buttons(1));
        s.bot(bot.images(1));
        s.bot(bot.markdown(1));
        s.bot(bot.attachments(1));
        s.bot(bot.textOnly(1));
        s.bot(bot.wideTable(1));
      }
      s.chatter(["sam", "tomas", "dev", "lena"], 10 * z.scale);
      break;
    }
    case "incidents": {
      s.say("amara", "Alerts from Uptime, and what we did about them.");
      if (hasBot) {
        for (let i = 0; i < 8 * z.scale; i++) {
          s.bot(bot.alert(i, true));
          s.say(pick(s.next, ["dev", "yusuf", "sam"]), pick(s.next, ["Looking.", "Ack 👀", "Rolling back.", "Seems to be the CDN."]));
          s.bot(bot.alert(i, false));
        }
      }
      break;
    }
    case "announcements": {
      s.say("maya", linkPreview("We're hiring! Share widely:", { url: "https://fernwood.example/jobs", title: "Jobs at Fernwood", description: "Calm software, made together. Six open roles, remote-friendly.", image: placeholder("jobs", 1200, 630) }));
      s.say("jordan", linkPreview("The launch post is live:", { url: "https://fernwood.example/blog/launch-week", title: "Launch week at Fernwood", description: "Five new features, one calmer inbox. Here's everything shipping on Thursday." }));
      s.say("isla", linkPreview("Holiday calendar:", { url: "https://fernwood.example/holidays", title: "Fernwood holidays 2027", description: "A very long description that goes on and on, ".repeat(6), image: placeholder("cal", 400, 1200) }));
      if (hasBot) s.bot(bot.markdown(2));
      break;
    }
    case "bookclub":
    case "hiking":
    case "recipes":
    case "music":
      s.chatter(pickPeople(s.next, 12), 30 * z.scale, (next) => remark(next), 0.3);
      break;
    case "hundred":
      s.say("bart", "A long room name for a long name. Fitting.");
      s.chatter(["bart", "hubert", "bea"], 5);
      break;
    case "quiet":
      break; // A room with nothing in it.
    case "leadership":
      s.say("maya", "Board deck draft is in the drive.");
      s.chatter(["maya", "sam", "priya", "rosa", "isla"], 20 * z.scale);
      break;
    case "hiring":
      s.say("quinn", "Pipeline: 4 onsites this week.");
      s.chatter(["quinn", "maya", "isla", "sam", "tara", "ben"], 20 * z.scale);
      break;
    case "offsite":
      s.say("leo", "Lisbon or Kyoto? Vote with a boost. 🇵🇹 🇯🇵");
      s.boosts("m0", [...CORE, ...ODD.slice(0, 8)], 6);
      s.chatter([...CORE, ...ODD.slice(0, 8)], 20 * z.scale);
      break;
    case "cake":
      s.say("leo", "Cake for Tomás on Friday 🎂 Don't tell him!");
      s.say("jordan", "Chocolate or lemon?");
      s.say("maya", "Chocolate, always.");
      s.say("jordan", "🍫");
      break;
    case "oncall":
      s.say("sam", "On-call handover notes.");
      if (hasBot) for (let i = 20; i < 24; i++) s.bot(bot.alert(i, i % 2 === 0));
      s.chatter(["sam", "dev", "yusuf", "elena", "sven", "hugo"], 15 * z.scale);
      break;
    case "threads": {
      s.say("maya", "Threads, long and short. 🧵");
      const big = s.say("maya", "Name the new release! Reply in the thread. 🧵");
      s.boosts(big, CORE, 5);
      for (let i = 0; i < z.bigThread; i++) s.reply(pick(s.next, EVERYONE), big, i % 37 === 0 ? pick(s.next, EMOJI_ONLY) : `${remark(s.next)} · ${i + 1}`, i % 50 === 25);
      s.say("sam", "Meanwhile, outside the thread: lunch?");
      const mid = s.say("priya", "Feedback on the new icons, please.");
      for (let i = 0; i < z.midThread; i++) s.reply(pick(s.next, [...CORE, "grace", "yael"]), mid, `${remark(s.next)} · ${i + 1}`);
      s.reply("priya", mid, `<p>Thanks all! ${mentionAdmin("maya")} the final set is in Figma.</p>`, true);
      for (let t = 0; t < 10; t++) {
        const short = s.say(pick(s.next, CORE), remark(s.next));
        for (let i = 0; i < 1 + (t % 4); i++) s.reply(pick(s.next, CORE), short, remark(s.next));
      }
      break;
    }
    case "standup":
      s.chatter(EVERYONE, z.standup, (next) => standup(next), 0.05);
      break;
    case "changelog":
      for (let i = 0; i < z.changelog; i++) s.say(pick(s.next, ["sam", "hugo", "sven", "kenji"]), changelog(s.next, i));
      break;
    case "firehose":
      for (let i = 0; i < z.firehose; i++) {
        const roll = s.next();
        const body = roll < 0.05 ? pick(s.next, EMOJI_ONLY) : roll < 0.08 ? pick(s.next, WORLD) : `${remark(s.next)} · ${i + 1}`;
        const by = pick(s.next, EVERYONE);
        const label = s.say(by, body);
        if (s.next() < 0.05) s.boosts(label, EVERYONE, 2);
        if (i % 500 === 250) s.edit(by, label, `${remark(s.next)} · ${i + 1} (edited)`);
      }
      break;
    // DMs with the administrator: everything in them pushes to their devices.
    case "dm-maya":
      s.say("maya", "Hey! Thanks for setting the new server up 🙏");
      s.say("maya", "Is it OK if I invite the support team next week?");
      s.share("maya", "brand-guide.pdf");
      break;
    case "dm-sam2":
      s.say("sam2", "Hi, I'm the other Sam Rivera. Sorry in advance for the confusion 😅");
      s.say("sam2", "Quick question about expense reports, when you have a minute.");
      break;
    case "dm-trio":
      s.say("leo", "Group DM test 👋");
      s.say("jordan", "Hello from Jordan!");
      s.say("leo", code("swift", "print(\"hello\")"));
      break;
    case "dm-weekend":
      s.say("tomas", "Weekend hike? Saturday 8am, the ridge trail 🥾");
      s.say("nour", "أنا موجودة! I'm in.");
      s.say("hanako", "行きます！");
      s.say("alex1", "Alex Kim (iOS) is in.");
      s.say("alex2", "Alex Kim (finance) too.");
      break;
    case "dm-long":
      s.chatter(["zoe"], 250, (next, i) => `${remark(next)} · ${i + 1}`, 0);
      break;
    default:
      throw new Error(`No script for ${key}`);
  }
  return s.done();
}

function pickPeople(next, n) {
  const out = new Set();
  while (out.size < n) out.add(pick(next, EVERYONE));
  return [...out];
}

/** Files the seed shares that aren't in files/ or drawn by media.mjs: made here, from text. */
export const MADE_FILES = {
  "long-name": {
    name: `${"Fernwood quarterly planning document final final v2 ".repeat(4).trim().replace(/ /g, "-")}.txt`,
    type: "text/plain",
    text: "A file whose name is far too long for one line.\n",
  },
  "data.json": { name: "export-sample.json", type: "application/json", text: `${JSON_SAMPLE}\n` },
  "notes.txt": { name: "meeting notes (draft) — ünïcödé.txt", type: "text/plain", text: `${esc("Notes\n=====\n")}\n- Budget approved\n- Offsite: Lisbon\n` },
};
