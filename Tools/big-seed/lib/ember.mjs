// The seed's client for Ember, after upstream's apps/worker/scripts/seed/client.ts: the Worker's API as
// the app's own pages call it, and room sockets as its tabs open them. It counts what it asks for, so a
// run can say what it cost, and it never puts a join code or a bot key in what it logs.

const ROOM_PROTOCOL = 4;
const ANSWER_TIMEOUT_MS = 30_000;

/** A path with its secrets taken out, for errors and logs. */
export const redact = (path) => path.replace(/^(\/api\/join\/)[^/?]+/, "$1…").replace(/^(\/rooms\/[^/]+\/)[^/]+(?=\/(?:messages|slack))/, "$1…");

export class EmberError extends Error {
  constructor(message, status) {
    super(message);
    this.status = status;
  }
}

const asBlob = ({ bytes, type }) => new Blob([bytes], { type });

/** Someone's fields as the join form sends them: JSON, or with a picture a form with `user`, `avatar` and `variant` parts. */
function userForm(fields, picture) {
  if (!picture) return { body: JSON.stringify(fields), headers: { "Content-Type": "application/json" } };
  const form = new FormData();
  form.set("user", JSON.stringify(fields));
  form.set("avatar", asBlob(picture), picture.name);
  form.set("variant", asBlob(picture), picture.name);
  return { body: form };
}

export class Ember {
  constructor(origin, { onRequest = () => {} } = {}) {
    this.origin = origin;
    this.onRequest = onRequest;
  }

  async request(path, { cookie, expected = [200], retry = true, ...init } = {}) {
    const headers = new Headers(init.headers);
    headers.set("Origin", this.origin);
    headers.set("Sec-Fetch-Site", "same-origin");
    if (cookie) headers.set("Cookie", cookie);
    this.onRequest("http");
    // A POST that may have been stored isn't sent again, so a room or a person isn't made twice; a 429 was refused, so it is.
    const repeatable = retry && (init.method ?? "GET") !== "POST";
    let response;
    for (let attempt = 1; ; attempt++) {
      try {
        response = await fetch(new URL(path, this.origin), { ...init, headers, redirect: "manual" });
      } catch (error) {
        if (attempt >= 4 || !repeatable) throw new EmberError(`${init.method ?? "GET"} ${redact(path)} failed: ${error.message}`);
        await sleep(1000 * attempt);
        continue;
      }
      if ((response.status === 429 || (response.status >= 500 && repeatable)) && attempt < 4 && retry) {
        await response.body?.cancel();
        await sleep(2000 * attempt);
        continue;
      }
      break;
    }
    if (!expected.includes(response.status)) {
      const text = (await response.text()).slice(0, 300);
      throw new EmberError(`${init.method ?? "GET"} ${redact(path)} answered ${response.status}: ${text}`, response.status);
    }
    return response;
  }

  json(path, method, body, ask = {}) {
    return this.request(path, { ...ask, method, body: JSON.stringify(body), headers: { "Content-Type": "application/json" } });
  }

  async get(path, cookie) {
    return (await this.request(path, { cookie })).json();
  }

  /** Joins with the join link's code, as its form does, answering the session. Joining sends no email. */
  async join(code, person, picture) {
    const response = await this.request(`/api/join/${encodeURIComponent(code)}`, { method: "POST", ...userForm(person, picture), expected: [201, 302, 303, 409], retry: false });
    if (response.status !== 201) throw new EmberError(`Joining as ${person.name} was sent to sign in: that email address has an account already`, response.status);
    return sessionOf(response);
  }

  async signIn(emailAddress, password) {
    return sessionOf(await this.json("/api/session", "POST", { emailAddress, password }, { expected: [200, 201], retry: false }));
  }
}

async function sessionOf(response) {
  const { user } = await response.json();
  const cookie = response.headers.getSetCookie()[0]?.split(";")[0];
  if (!cookie) throw new EmberError(`Signing ${user.name} in set no cookie`);
  return { user: { id: user.id, name: user.name }, cookie };
}

export const sleep = (ms) => new Promise((resolve) => setTimeout(resolve, ms));

/** Someone's socket to a room, through which they write, edit and boost, as the app does. */
export class RoomSocket {
  #socket;
  #waiters = new Set();
  #closed = null;

  constructor(label, socket, onFrame) {
    this.label = label;
    this.#socket = socket;
    this.onFrame = onFrame;
    socket.addEventListener("message", (event) => {
      const frame = JSON.parse(String(event.data));
      for (const waiter of this.#waiters) if (waiter(frame)) this.#waiters.delete(waiter);
    });
    socket.addEventListener("close", (event) => {
      this.#closed = event.code;
      for (const waiter of this.#waiters) waiter({ type: "error", message: `socket closed (${event.code})` });
      this.#waiters.clear();
    });
  }

  get closed() {
    return this.#closed !== null;
  }

  /** Opens `session`'s socket to `roomId`, answering it and the room's welcome, its newest page. */
  static async open(ember, session, roomId) {
    const url = new URL(`/api/rooms/${encodeURIComponent(roomId)}/socket?visible=1&protocol=${ROOM_PROTOCOL}`, ember.origin);
    url.protocol = url.protocol === "https:" ? "wss:" : "ws:";
    ember.onRequest("socket");
    const ws = new WebSocket(url.href, { headers: { Cookie: session.cookie, Origin: ember.origin } });
    const socket = new RoomSocket(session.user.name, ws, () => ember.onRequest("frame"));
    const opened = new Promise((resolve, reject) => {
      ws.addEventListener("error", () => reject(new EmberError(`${session.user.name}'s socket to a room didn't open`)), { once: true });
      ws.addEventListener("close", (event) => reject(new EmberError(`${session.user.name}'s socket to a room closed (${event.code})`, event.code)), { once: true });
    });
    const welcome = await Promise.race([socket.next((frame) => (frame.type === "welcome" ? frame : undefined)), opened]);
    return { socket, welcome };
  }

  post(body, inThread) {
    return this.postWithId(crypto.randomUUID(), body, inThread);
  }

  postWithId(clientMessageId, body, inThread) {
    return this.ask({ type: "message.create", clientMessageId, body, ...inThread }, (frame) => (frame.type === "message.created" && frame.message.clientMessageId === clientMessageId ? frame.message : undefined));
  }

  edit(messageId, body) {
    return this.ask({ type: "message.update", messageId, body }, (frame) => (frame.type === "message.updated" && frame.message.id === messageId ? frame.message : undefined));
  }

  boost(messageId, content) {
    return this.ask({ type: "boost.create", messageId, content }, (frame) => (frame.type === "boost.created" && frame.boost.messageId === messageId && frame.boost.content === content ? frame : undefined));
  }

  /** Which of these client message ids the room stored for this person. */
  check(clientMessageIds) {
    return this.ask({ type: "message.check", clientMessageIds }, (frame) => (frame.type === "message.checked" ? frame : undefined));
  }

  before(before, limit = 40) {
    return this.ask({ type: "history.before", before, limit }, (frame) => (frame.type === "history" && frame.before === before ? frame : undefined));
  }

  openThread(parentId) {
    return this.ask({ type: "thread.open", parentId }, (frame) => (frame.type === "thread.opened" && frame.parentId === parentId ? frame : undefined));
  }

  threadBefore(parentId, before, limit = 40) {
    return this.ask({ type: "thread.before", parentId, before, limit }, (frame) => (frame.type === "thread.history" && frame.parentId === parentId && frame.before === before ? frame : undefined));
  }

  /** Reads the room to its end, as staying on it does: the room hears frames in order, so its pong comes after. */
  async read() {
    this.#send({ type: "presence.visible", visible: true });
    await this.ask({ type: "ping", by: "big-seed" }, (frame) => (frame.type === "pong" ? frame : undefined));
  }

  next(pick) {
    return new Promise((resolve, reject) => {
      if (this.closed) return reject(new EmberError(`${this.label}'s socket is closed`));
      const timer = setTimeout(() => {
        this.#waiters.delete(waiter);
        reject(new EmberError(`${this.label}'s socket heard nothing it was waiting for`));
      }, ANSWER_TIMEOUT_MS);
      const waiter = (frame) => {
        const picked = frame.type === "error" ? undefined : pick(frame);
        if (frame.type !== "error" && picked === undefined) return false;
        clearTimeout(timer);
        if (frame.type === "error") reject(new EmberError(`The room refused ${this.label}: ${frame.message}`));
        else resolve(picked);
        return true;
      };
      this.#waiters.add(waiter);
    });
  }

  ask(frame, pick) {
    const answer = this.next(pick);
    this.#send(frame);
    return answer;
  }

  #send(frame) {
    this.onFrame();
    this.#socket.send(JSON.stringify(frame));
  }

  close() {
    if (!this.closed) this.#socket.close(1000);
  }
}

/** Uploads a file to a room as the composer does: start, its parts, the preview, the last part posting the message. */
export async function upload(ember, session, roomId, clientMessageId, file, preview, inThread) {
  const room = encodeURIComponent(roomId);
  const start = { name: file.name, type: file.type, size: file.bytes.length, clientMessageId, ...inThread };
  const { id, partSize, parts } = await (await ember.json(`/api/rooms/${room}/uploads`, "POST", start, { cookie: session.cookie, expected: [201] })).json();
  const part = (n) => file.bytes.subarray((n - 1) * partSize, n === parts ? file.bytes.length : n * partSize);
  for (let n = 1; n < parts; n++) await ember.request(`/api/rooms/${room}/uploads/${id}/parts/${n}`, { method: "PUT", body: part(n), cookie: session.cookie, expected: [204] });
  if (preview) await ember.request(`/api/rooms/${room}/uploads/${id}/preview`, { method: "PUT", body: preview.bytes, cookie: session.cookie, expected: [204] });
  return (await ember.request(`/api/rooms/${room}/uploads/${id}/parts/${parts}`, { method: "PUT", body: part(parts), cookie: session.cookie, expected: [200, 201] })).json();
}
