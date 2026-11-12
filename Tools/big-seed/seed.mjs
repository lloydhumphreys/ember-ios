#!/usr/bin/env node
// Fills an Ember that's already set up with Fernwood, a made-up company of fifty people, for testing the
// iOS app against: rooms open and closed, DMs, threads of hundreds of replies, rooms of thousands of
// messages, boosts, edits, mentions, files and pictures of awkward shapes, and bot cards. See README.md.
//
//   node Tools/big-seed/seed.mjs <origin> --confirm <origin> [--size small|large] [--dry-run] [--remove]
//
// It joins with the join link in .dev/big-seed-join-link, posts cards with the bot key in
// .dev/big-seed-bot-key if there is one, keeps everyone's made-up password in .dev/big-seed-password
// and where it got to in .dev/big-seed-state.json, and stops for the day before it spends the free
// plan's daily allowance. Run the same command again to carry on.
import { createHash, randomBytes } from "node:crypto";
import { existsSync, mkdirSync, readFileSync, renameSync, writeFileSync } from "node:fs";
import path from "node:path";
import { parseArgs } from "node:util";
import { BY_KEY, PEOPLE } from "./lib/cast.mjs";
import { Ember, EmberError, RoomSocket, sleep, upload } from "./lib/ember.mjs";
import { avatar, drawPicture, PICTURES } from "./lib/media.mjs";
import { directs, MADE_FILES, ROOMS, scriptFor, SIZES } from "./lib/plan.mjs";
import { esc } from "./lib/text.mjs";

const TOOL = import.meta.dirname;
const FILES = path.join(TOOL, "files");

/**
 * What each step is reckoned to write to Durable Objects' SQLite, in rows, the free plan's first limit to
 * run out (100,000 a day): measured against a local Ember (see README.md), rounded up.
 */
export const COST = { join: 140, room: 120, direct: 30, say: 22, reply: 26, edit: 16, boost: 8, share: 40, bot: 26, socket: 3 };

const USAGE = `Usage: node Tools/big-seed/seed.mjs <origin> --confirm <origin> [options]

  --confirm <origin>   the same origin again, to say you mean this server
  --size small|large   small fits in a day; large takes about three (default: small)
  --dry-run            say what it would do, and what it would cost, without asking the server anything
  --budget <rows>      rows a day it may write to Durable Objects (default: 80000 of the free plan's 100000)
  --pace <ms>          wait between writes (default: 100)
  --admin-push few|none|many
                       DMs with and mentions of the administrator, which push to their devices:
                       a few (default), none, or a 250-message DM as well
  --dir <dir>          where the join link, bot key, password and state are (default: .dev/ in the repo)
  --remove             delete the rooms and DMs it made (people and the bot stay; see README.md)
`;

const { values: opts, positionals } = parseArgs({
  allowPositionals: true,
  options: {
    confirm: { type: "string" },
    size: { type: "string", default: "small" },
    "dry-run": { type: "boolean", default: false },
    budget: { type: "string", default: "80000" },
    pace: { type: "string", default: "100" },
    "admin-push": { type: "string", default: "few" },
    dir: { type: "string", default: path.resolve(TOOL, "../../.dev") },
    remove: { type: "boolean", default: false },
    help: { type: "boolean", default: false },
  },
});

function fail(message, code = 1) {
  console.error(message);
  process.exit(code);
}

if (opts.help || positionals.length !== 1) fail(USAGE, opts.help ? 0 : 1);
const origin = originOf(positionals[0]);
if (!origin) fail(`${positionals[0]} isn't an http(s) origin, such as https://ember.example.workers.dev`);
if (!SIZES[opts.size]) fail(`--size is small or large`);
if (!["few", "none", "many"].includes(opts["admin-push"])) fail(`--admin-push is few, none or many`);
const budget = Number(opts.budget);
const pace = Number(opts.pace);
if (!(budget > 0) || !(pace >= 0)) fail("--budget and --pace are numbers");
if (!opts["dry-run"] && originOf(opts.confirm ?? "") !== origin) fail(`Refusing: pass --confirm ${origin} to say you mean to write to ${origin}.`);

function originOf(value) {
  try {
    const url = new URL(value);
    return ["http:", "https:"].includes(url.protocol) ? url.origin : null;
  } catch {
    return null;
  }
}

// --- Secrets and state, in files only the user can read. Nothing here is ever printed. ---

const dir = path.resolve(opts.dir);
const file = (name) => path.join(dir, name);

function writePrivate(target, text) {
  mkdirSync(path.dirname(target), { recursive: true, mode: 0o700 });
  const temporary = `${target}.${process.pid}.tmp`;
  writeFileSync(temporary, text, { mode: 0o600 });
  renameSync(temporary, target);
}

function secret(envName, fileName, required) {
  const value = process.env[envName]?.trim() || (existsSync(file(fileName)) ? readFileSync(file(fileName), "utf8").trim() : "");
  if (!value && required) fail(`No ${fileName}: paste it into ${file(fileName)} (or set ${envName}). See README.md.`);
  return value || null;
}

function joinCode() {
  const link = secret("BIG_SEED_JOIN_LINK", "big-seed-join-link", true);
  let url;
  try {
    url = new URL(link);
  } catch {
    fail(`${file("big-seed-join-link")} doesn't hold a link. Copy it from Settings → Join link.`);
  }
  if (url.origin !== origin) fail(`The join link in ${file("big-seed-join-link")} is for another server, not ${origin}.`);
  const match = url.pathname.match(/^\/join\/([^/]+)\/?$/);
  if (!match) fail(`${file("big-seed-join-link")} isn't a join link (…/join/…).`);
  return decodeURIComponent(match[1]);
}

function botKey() {
  const key = secret("BIG_SEED_BOT_KEY", "big-seed-bot-key", false);
  if (key === null) return null;
  // The key may be pasted as the webhook URL the Chat bots page shows, or on its own.
  const fromUrl = key.match(/\/rooms\/[^/]+\/([^/]+)\/(?:slack|messages)/)?.[1];
  const bare = fromUrl ?? key;
  if (!/^[^-\s/]+-[A-Za-z0-9]+$/.test(bare)) fail(`${file("big-seed-bot-key")} doesn't look like a bot key (id-token).`);
  return { id: bare.split("-")[0], key: bare };
}

function password() {
  const target = file("big-seed-password");
  if (existsSync(target)) return readFileSync(target, "utf8").trim();
  const made = randomBytes(18).toString("base64url");
  writePrivate(target, `${made}\n`);
  console.log(`Made up a password for the seed's people; it's in ${target}.`);
  return made;
}

const statePath = file("big-seed-state.json");

function loadState() {
  if (!existsSync(statePath)) return null;
  const state = JSON.parse(readFileSync(statePath, "utf8"));
  if (state.origin !== origin) fail(`${statePath} is for ${state.origin}, not ${origin}. Pass --dir for another server.`);
  return state;
}

let state;
const save = () => writePrivate(statePath, JSON.stringify(state));

// --- What it would do, and what that costs. ---

const adminMode = opts["admin-push"];

function plan(hasBot) {
  const rooms = ROOMS.map((room) => ({ ...room, steps: scriptFor(room.key, opts.size, { adminMode, hasBot }) }));
  const dms = directs(adminMode).map((dm) => ({ ...dm, kind: "direct", by: dm.people[0], steps: scriptFor(dm.key, opts.size, { adminMode, hasBot }) }));
  return [...rooms, ...dms];
}

const stepCost = (step) => (step.k === "say" ? (step.thread ? COST.reply : COST.say) : COST[step.k]);

function estimate(rooms) {
  const counts = { people: PEOPLE.length, rooms: 0, dms: 0, messages: 0, replies: 0, boosts: 0, edits: 0, files: 0, botPosts: 0, rows: PEOPLE.length * COST.join };
  for (const room of rooms) {
    if (room.kind === "direct") counts.dms++;
    else counts.rooms++;
    counts.rows += room.kind === "direct" ? COST.direct : COST.room;
    const speakers = new Set();
    for (const step of room.steps) {
      counts.rows += stepCost(step);
      if (step.by) speakers.add(step.by);
      if (step.k === "say") step.thread ? counts.replies++ : counts.messages++;
      if (step.k === "boost") counts.boosts++;
      if (step.k === "edit") counts.edits++;
      if (step.k === "share") counts.files++;
      if (step.k === "bot") counts.botPosts++;
    }
    counts.rows += speakers.size * COST.socket;
  }
  return counts;
}

function printEstimate(rooms, hasBot) {
  const c = estimate(rooms);
  const days = Math.ceil(c.rows / budget);
  console.log(`${opts.size} seed of ${origin}:`);
  console.log(`  ${c.people} people, ${c.rooms} rooms, ${c.dms} DMs with the administrator (--admin-push ${adminMode})`);
  console.log(`  ${c.messages} messages, ${c.replies} thread replies, ${c.boosts} boosts, ${c.edits} edits, ${c.files} files, ${c.botPosts} bot posts${hasBot ? "" : " (no bot key, so none)"}`);
  console.log(`  about ${c.rows.toLocaleString("en")} rows written to Durable Objects: ${days} day${days === 1 ? "" : "s"} at ${budget.toLocaleString("en")} a day`);
}

// --- Running it. ---

const usage = { http: 0, socket: 0, frame: 0 };
const ember = new Ember(origin, { onRequest: (kind) => usage[kind]++ });
let stopping = false;
process.on("SIGINT", () => {
  if (stopping) process.exit(130);
  stopping = true;
  console.log("\nStopping after this step; run the same command to carry on.");
});

const today = () => new Date().toISOString().slice(0, 10);

class OutOfBudget extends Error {}

/** Counts `rows` against today's budget, stopping the run first if they'd go past it. */
function spend(rows) {
  const day = (state.days[today()] ??= { rows: 0 });
  if (day.rows + rows > budget) throw new OutOfBudget();
  day.rows += rows;
}

function untilMidnightUtc() {
  const now = new Date();
  const midnight = Date.UTC(now.getUTCFullYear(), now.getUTCMonth(), now.getUTCDate() + 1);
  const minutes = Math.ceil((midnight - now) / 60000);
  return `${Math.floor(minutes / 60)}h ${minutes % 60}m`;
}

function readFile(name) {
  if (PICTURES[name]) return drawPicture(name);
  const made = MADE_FILES[name];
  if (made) return { file: { name: made.name, type: made.type, bytes: Buffer.from(made.text) } };
  const bytes = readFileSync(path.join(FILES, name));
  const type = { ".png": "image/png", ".jpg": "image/jpeg", ".pdf": "application/pdf", ".csv": "text/csv", ".mp4": "video/mp4" }[path.extname(name)];
  const preview = name === "prototype.mp4" ? { name: "prototype-poster.jpg", type: "image/jpeg", bytes: readFileSync(path.join(FILES, "prototype-poster.jpg")) } : undefined;
  return { file: { name, type, bytes }, preview };
}

function pictureOf(person) {
  if (typeof person.avatar === "number") return avatar(person.avatar, `${person.key}.png`);
  if (typeof person.avatar === "string") {
    const type = person.avatar.endsWith(".jpg") ? "image/jpeg" : "image/png";
    return { name: person.avatar, type, bytes: readFileSync(path.join(FILES, person.avatar)) };
  }
  return undefined;
}

/** Signs `person` in, waiting out Ember's limit of 10 sign-ins from an address in 3 minutes. */
async function signIn(person) {
  for (let attempt = 1; ; attempt++) {
    try {
      return await ember.signIn(person.emailAddress, state.password);
    } catch (error) {
      if (!(error instanceof EmberError) || error.status !== 429 || attempt >= 5 || stopping) throw error;
      console.log("  Waiting a minute: Ember takes 10 sign-ins from one address every 3 minutes.");
      await sleep(60_000);
    }
  }
}

async function signInAgain(key) {
  const session = await signIn(BY_KEY.get(key));
  state.people[key].cookie = session.cookie;
  spend(26);
  save();
  return state.people[key];
}

async function sessionOf(key) {
  const session = state.people[key];
  if (!session) throw new Error(`${key} hasn't joined`);
  return { user: { id: session.id, name: BY_KEY.get(key).name }, cookie: session.cookie };
}

async function join(code) {
  for (const person of PEOPLE) {
    if (stopping) return;
    if (state.people[person.key]) continue;
    spend(COST.join);
    let session;
    try {
      session = await ember.join(code, { name: person.name, emailAddress: person.emailAddress, password: state.password }, pictureOf(person));
    } catch (error) {
      // Already joined, by a run whose state is gone: sign in with the same password.
      if (!(error instanceof EmberError) || ![302, 303, 409].includes(error.status)) throw error;
      session = await signIn(person);
    }
    state.people[person.key] = { id: session.user.id, cookie: session.cookie };
    if (person.bio) await ember.json("/api/users/me/profile", "PATCH", { bio: person.bio }, { cookie: session.cookie });
    await ember.request("/api/sidebar/invitation", { method: "DELETE", cookie: session.cookie, expected: [204, 404] });
    save();
    await sleep(pace);
  }
  console.log(`${PEOPLE.length} people have joined.`);
}

/** The server's administrator, whom the seed mentions, DMs and adds to closed rooms, as the directory lists them. */
async function findAdmin() {
  if (state.admin !== undefined) return;
  const { users } = await ember.get("/api/users", state.people.maya.cookie);
  const seeded = new Set(Object.values(state.people).map(({ id }) => id));
  const admin = users.find((user) => user.role === "administrator" && user.status === "active" && !seeded.has(user.id));
  state.admin = admin ? { id: admin.id, name: admin.name } : null;
  save();
  console.log(admin ? "Found the administrator, to mention and DM." : "Found no administrator to mention or DM.");
}

async function createRooms(rooms, bot) {
  for (const room of rooms) {
    if (stopping) return;
    if (state.rooms[room.key]) continue;
    const session = await sessionOf(room.by);
    const others = (keys) => keys.map((key) => state.people[key].id);
    if (room.kind === "direct") {
      if (!state.admin) continue;
      spend(COST.direct);
      const userIds = [...others(room.people.slice(1)), state.admin.id];
      const { room: dm } = await (await ember.json("/api/directs", "POST", { userIds }, { cookie: session.cookie, expected: [200, 201] })).json();
      state.rooms[room.key] = { id: dm.id, by: room.by };
    } else {
      spend(COST.room);
      const body = { name: room.name, icon: room.icon, kind: room.kind };
      // A closed room has just the people it names, its creator among them only if named.
      if (room.kind === "closed") body.memberIds = [...others([room.by, ...room.members]), ...(state.admin ? [state.admin.id] : []), ...(bot && room.bot ? [bot.id] : [])];
      const response = await ember.json("/api/rooms", "POST", body, { cookie: session.cookie, expected: [201, 403] });
      if (response.status === 403) fail(`${origin} lets only administrators make rooms (“Must be admin to create new rooms” in settings). Turn that off while the seed runs, then run it again.`);
      const { room: made } = await response.json();
      state.rooms[room.key] = { id: made.id, by: room.by };
    }
    save();
    await sleep(pace);
  }
  console.log(`${Object.keys(state.rooms).length} rooms and DMs are made.`);
}

/** A deterministic client message id for step `index` of `roomKey`, so a run that stopped can ask the room whether it got it. */
function clientMessageId(roomKey, index) {
  const hex = createHash("sha256").update(`${state.runId}:${roomKey}:${index}`).digest("hex");
  return `${hex.slice(0, 8)}-${hex.slice(8, 12)}-4${hex.slice(13, 16)}-a${hex.slice(17, 20)}-${hex.slice(20, 32)}`;
}

const mentionTag = (id) => `<action-text-attachment sgid="${esc(id)}" content-type="application/vnd.campfire.mention"></action-text-attachment>`;

function resolveMentions(body, asText = false) {
  return body.replace(/\{\{@([a-z0-9]+)\}\}/g, (_, key) => {
    if (key === "admin") return state.admin ? (asText ? esc(state.admin.name) : mentionTag(state.admin.id)) : "the administrator";
    return asText ? esc(BY_KEY.get(key).name) : mentionTag(state.people[key].id);
  });
}

function bodyOf(room, step, steps) {
  const body = resolveMentions(step.body);
  if (!step.quote) return body;
  const target = steps.find((s) => s.label === step.quote);
  const permalink = `${origin}/rooms/${encodeURIComponent(room.id)}/@${encodeURIComponent(state.labels[room.key][step.quote])}`;
  return `<blockquote>${resolveMentions(target.body, true)}</blockquote><cite>${esc(BY_KEY.get(target.by).name)} <a href="${esc(permalink)}">#</a></cite>${body}`;
}

async function fillRoom(room, bot) {
  const made = state.rooms[room.key];
  if (!made) return;
  const steps = room.steps;
  const roomRef = { key: room.key, id: made.id };
  const labels = (state.labels[room.key] ??= {});
  const sockets = new Map();
  let start = state.progress[room.key] ?? 0;
  if (start >= steps.length) return;

  async function socketOf(key) {
    const open = sockets.get(key);
    if (open && !open.socket.closed) return open;
    spend(COST.socket);
    let opened;
    try {
      opened = await RoomSocket.open(ember, await sessionOf(key), made.id);
    } catch (error) {
      // A session that has ended: sign in again with the seed's password and try once more.
      const check = await ember.request("/api/sidebar", { cookie: state.people[key].cookie, expected: [200, 401, 403] });
      if (check.status === 200) throw error;
      await signInAgain(key);
      opened = await RoomSocket.open(ember, await sessionOf(key), made.id);
    }
    sockets.set(key, opened);
    return opened;
  }

  const anyone = () => (room.kind === "closed" ? room.by : (room.steps.find((s) => s.by)?.by ?? room.by));

  /** Whether step `index`, sent before the last run stopped, arrived, saving its message's id if something refers to it. */
  async function settle(index) {
    const step = steps[index];
    if (step.k === "say" || step.k === "share") {
      const cmid = clientMessageId(room.key, index);
      const { socket, welcome } = await socketOf(step.by);
      const { stored } = await socket.check([cmid]);
      if (!stored.includes(cmid)) return false;
      if (step.label) {
        const page = step.thread ? (await socket.openThread(labels[step.thread])).messages : welcome.messages;
        const found = page.find((m) => m.clientMessageId === cmid);
        if (!found) throw new Error(`${room.name}: step ${index} arrived but isn't on the newest page`);
        labels[step.label] = found.id;
      }
      return true;
    }
    if (step.k === "boost") {
      const { socket } = await socketOf(step.by);
      const { message } = await socket.openThread(labels[step.target]);
      return Boolean(message?.boosts.some((b) => b.booster.id === state.people[step.by].id && b.content === step.content));
    }
    if (step.k === "bot") {
      const { welcome } = await socketOf(anyone());
      return welcome.messages.some((m) => m.creator?.id === bot.id && m.plainText.includes(step.marker));
    }
    return false; // An edit is the same done twice.
  }

  if (state.pending?.room === room.key && state.pending.index === start) {
    if (await settle(start)) {
      start++;
      state.progress[room.key] = start;
    }
    state.pending = null;
    save();
  }

  let lastLog = Date.now();
  try {
    for (let index = start; index < steps.length; index++) {
      if (stopping) return;
      const step = steps[index];
      if (step.k === "bot" && !bot) {
        state.progress[room.key] = index + 1;
        continue;
      }
      spend(stepCost(step));
      if (step.k !== "edit") {
        state.pending = { room: room.key, index };
        save();
      }
      await runStep(roomRef, step, index, steps, socketOf, labels, bot);
      state.progress[room.key] = index + 1;
      state.pending = null;
      save();
      if (Date.now() - lastLog > 15_000) {
        console.log(`  ${room.name ?? room.key}: ${index + 1} of ${steps.length}`);
        lastLog = Date.now();
      }
      if (pace) await sleep(pace);
    }
    console.log(`${room.name ?? room.key}: done (${steps.length} steps).`);
  } finally {
    for (const { socket } of sockets.values()) socket.close();
  }
}

async function runStep(room, step, index, steps, socketOf, labels, bot) {
  switch (step.k) {
    case "say": {
      const { socket } = await socketOf(step.by);
      const inThread = step.thread ? { parentId: labels[step.thread], alsoSend: Boolean(step.alsoSend) } : undefined;
      const message = await socket.postWithId(clientMessageId(room.key, index), bodyOf(room, step, steps), inThread);
      if (step.label) labels[step.label] = message.id;
      return;
    }
    case "edit": {
      const { socket } = await socketOf(step.by);
      await socket.edit(labels[step.target], resolveMentions(step.body));
      return;
    }
    case "boost": {
      const { socket } = await socketOf(step.by);
      await socket.boost(labels[step.target], step.content);
      return;
    }
    case "share": {
      await socketOf(step.by);
      const { file, preview } = readFile(step.file);
      const inThread = step.thread ? { parentId: labels[step.thread] } : undefined;
      const message = await upload(ember, await sessionOf(step.by), room.id, clientMessageId(room.key, index), file, preview, inThread);
      if (step.label) labels[step.label] = message.id;
      return;
    }
    case "bot": {
      const path = `/rooms/${encodeURIComponent(room.id)}/${bot.key}/slack`;
      const answer = await (await ember.json(path, "POST", step.payload, { expected: [200] })).text();
      if (answer.trim() !== "ok") throw new Error(`The bot's post was refused: ${answer.slice(0, 100)}`);
      return;
    }
  }
}

async function remove() {
  if (!state) fail(`Nothing to remove: ${statePath} doesn't exist.`);
  let removed = 0;
  for (const [key, room] of Object.entries(state.rooms)) {
    if (stopping) break;
    const cookie = state.people[room.by]?.cookie;
    const response = await ember.request(`/api/rooms/${encodeURIComponent(room.id)}`, { method: "DELETE", cookie, expected: [200, 204, 401, 404] });
    if (response.status === 401) {
      await signInAgain(room.by);
      await ember.request(`/api/rooms/${encodeURIComponent(room.id)}`, { method: "DELETE", cookie: state.people[room.by].cookie, expected: [200, 204, 404] });
    }
    delete state.rooms[key];
    delete state.progress[key];
    delete state.labels[key];
    removed++;
    save();
  }
  state.pending = null;
  save();
  console.log(`Deleted ${removed} rooms and DMs, with their messages and files.`);
  console.log(`The ${Object.keys(state.people).length} people (all at @fernwood.example) and the bot stay: remove them in Ember's settings (see README.md).`);
}

async function main() {
  const bot = botKey();
  const rooms = plan(Boolean(bot));
  if (opts["dry-run"]) {
    printEstimate(rooms, Boolean(bot));
    console.log(`  join link: ${secret("BIG_SEED_JOIN_LINK", "big-seed-join-link", false) ? "found" : "missing"}; bot key: ${bot ? "found" : "none (no bot cards)"}; state: ${existsSync(statePath) ? "a run to carry on" : "none yet"}`);
    return;
  }
  state = loadState();
  if (opts.remove) return remove();
  const code = joinCode();
  state ??= { origin, runId: randomBytes(8).toString("hex"), size: opts.size, adminMode, people: {}, rooms: {}, progress: {}, labels: {}, pending: null, days: {} };
  if (state.size !== opts.size || state.adminMode !== adminMode) {
    console.log(`Carrying on the ${state.size} seed begun earlier (--admin-push ${state.adminMode}); delete ${statePath} to start another.`);
    opts.size = state.size;
  }
  state.password = undefined;
  Object.defineProperty(state, "password", { value: password(), enumerable: false, writable: true });
  save();
  const planned = plan(Boolean(bot)).filter((room) => room.kind !== "direct" || directs(state.adminMode).some((dm) => dm.key === room.key));
  printEstimate(planned, Boolean(bot));

  const bootstrap = await ember.get("/api/bootstrap");
  if (bootstrap.setup !== "complete") fail(`${origin} isn't set up yet: set it up in a browser first.`);
  if (bootstrap.account?.restrictRoomCreation && Object.keys(state.rooms).length < planned.length)
    fail(`${origin} lets only administrators make rooms (“Must be admin to create new rooms” in settings). Turn that off while the seed runs, then run it again.`);

  const began = Date.now();
  try {
    await join(code);
    if (!stopping) await findAdmin();
    if (!stopping) await createRooms(planned, bot);
    for (const room of planned) {
      if (stopping) break;
      await fillRoom(room, bot);
    }
  } catch (error) {
    if (!(error instanceof OutOfBudget)) {
      save();
      throw error;
    }
    save();
    console.log(`Today's budget of ${budget.toLocaleString("en")} rows is spent. Run the same command again after 00:00 UTC (in ${untilMidnightUtc()}).`);
    report(began);
    process.exit(3);
  }
  save();
  report(began);
  if (stopping) process.exit(130);
  const left = planned.filter((room) => state.rooms[room.key] && (state.progress[room.key] ?? 0) < room.steps.length);
  console.log(left.length === 0 ? "All done." : `${left.length} rooms still to fill.`);
}

function report(began) {
  const seconds = Math.round((Date.now() - began) / 1000);
  const day = state.days[today()]?.rows ?? 0;
  console.log(`This run: ${seconds}s, ${usage.http} HTTP requests, ${usage.socket} sockets, ${usage.frame} socket frames. Today: about ${day.toLocaleString("en")} of ${budget.toLocaleString("en")} rows.`);
}

main().catch((error) => {
  console.error(`Stopped: ${error.message}`);
  console.error("Run the same command again to carry on from here.");
  process.exit(1);
});
