// What Fernwood's bot posts to its Slack-compatible webhook: upstream's deploy card and alert, and cards
// that press on the app: tables of many rows, carousels of tiles with pictures and buttons, rows of
// buttons, tall and wide images, Markdown and rich text. Every one carries its own `marker` in its text,
// so a run that stopped mid-post can tell whether it arrived.
import { placeholder } from "./text.mjs";

const REGIONS = ["fra1", "iad1", "syd1", "nrt1", "gru1", "lhr1", "sin1", "ams1", "cdg1", "ord1"];
const SERVICES = ["message-api", "socket-gateway", "search", "uploads", "push", "billing", "auth", "unfurler", "exports", "web"];

const cell = (text) => ({ type: "raw_text", text: String(text) });

export function deployed(n) {
  const service = SERVICES[n % SERVICES.length];
  const version = `4.${Math.floor(n / 10)}.${n % 10}`;
  const title = `Deployed ${service} ${version} to production`;
  return {
    marker: title,
    payload: {
      text: title,
      blocks: [
        { type: "header", text: { type: "plain_text", text: title } },
        {
          type: "section",
          text: { type: "mrkdwn", text: `Smoke tests passed in *2m ${10 + (n % 50)}s*. Nothing to roll back.` },
          accessory: { type: "button", text: { type: "plain_text", text: "Release notes" }, url: `https://fernwood.example/releases/${version}`, style: "primary" },
        },
        { type: "section", fields: [{ type: "mrkdwn", text: `*Commit*\n\`${(0x8a1969f + n * 7919).toString(16).slice(0, 7)}\`` }, { type: "mrkdwn", text: "*Started by*\nSam Rivera" }] },
        { type: "context", elements: [{ type: "mrkdwn", text: `Took 4m 31s · <https://fernwood.example/deploys/${1874 + n}|Deploy #${1874 + n}>` }] },
      ],
    },
  };
}

export function alert(n, firing) {
  const service = SERVICES[n % SERVICES.length];
  const state = firing ? "FIRING" : "RESOLVED";
  const text = `[${state}] HighErrorRate ${service} (#${n})`;
  return {
    marker: text,
    payload: {
      text,
      attachments: [
        {
          color: firing ? "danger" : "good",
          title: `[${state}] HighErrorRate ${service}`,
          title_link: "https://status.fernwood.example/alerts/high-error-rate",
          text: firing ? `5xx rate is *${(2 + (n % 7) * 1.3).toFixed(1)}%* over 5 minutes in \`${REGIONS[n % REGIONS.length]}\`.` : "Back under 0.5% for 10 minutes.",
          mrkdwn_in: ["text"],
          fields: [
            { title: "Severity", value: firing ? "critical" : "resolved", short: true },
            { title: "Region", value: REGIONS[n % REGIONS.length], short: true },
          ],
          actions: firing ? [{ type: "button", text: "Runbook", url: "https://runbooks.fernwood.example/high-error-rate", style: "danger" }] : [],
          footer: "Uptime",
          ts: 1_760_000_000 + n * 600,
        },
      ],
    },
  };
}

/** A table of `rows` rows of five columns, numbers lined up on the right. */
export function table(rows, n = 0) {
  const marker = `Latency by service and region, ${rows} rows (#${n})`;
  const body = [[cell("Service"), cell("Region"), cell("p50 ms"), cell("p99 ms"), cell("Errors")]];
  for (let i = 0; i < rows; i++)
    body.push([cell(SERVICES[i % SERVICES.length]), cell(REGIONS[(i * 3) % REGIONS.length]), { type: "raw_number", text: String(20 + ((i * 37) % 180)) }, { type: "raw_number", text: String(200 + ((i * 101) % 1800)) }, cell(i % 9 === 0 ? "⚠️ 12" : "0")]);
  return {
    marker,
    payload: {
      text: marker,
      blocks: [
        { type: "header", text: { type: "plain_text", text: marker } },
        { type: "table", rows: body, column_settings: [{ align: "left" }, { align: "left" }, { align: "right" }, { align: "right" }, { align: "right" }] },
        { type: "context", elements: [{ type: "mrkdwn", text: "From the last hour · <https://grafana.fernwood.example/d/latency|Dashboard>" }] },
      ],
    },
  };
}

/** A table whose cells hold long, wrapped text. */
export function wideTable(n = 0) {
  const marker = `Open incidents, long descriptions (#${n})`;
  const rows = [[cell("ID"), cell("Summary"), cell("Owner")]];
  for (let i = 0; i < 24; i++) rows.push([cell(`INC-${400 + i}`), cell(`Customers in ${REGIONS[i % REGIONS.length]} see slow uploads when the file is larger than 50 MB and the connection drops part way through, so the retry starts from zero.`), cell(i % 2 ? "Dev Malhotra" : "Yusuf Demir")]);
  return { marker, payload: { text: marker, blocks: [{ type: "table", rows, column_settings: [{ align: "left" }, { align: "left", is_wrapped: true }, { align: "left" }] }] } };
}

/** A carousel of `count` tiles, each with a picture, a title, a body and link buttons. */
export function carousel(count, n = 0) {
  const marker = `This week's builds, ${count} tiles (#${n})`;
  const elements = Array.from({ length: count }, (_, i) => ({
    type: "card",
    hero_image: { type: "image", image_url: placeholder(`tile-${n}-${i}`, 600, 340), alt_text: `Build ${i + 1} screenshot` },
    title: { type: "plain_text", text: `Build ${100 + i}` },
    subtitle: { type: "plain_text", text: i % 2 ? "iOS · TestFlight" : "Android · Internal" },
    body: { type: "mrkdwn", text: i % 3 ? "All checks passed." : "*2 flaky tests* retried and passed." },
    actions: [
      { type: "button", text: { type: "plain_text", text: "Install" }, url: `https://builds.fernwood.example/${100 + i}` },
      { type: "button", text: { type: "plain_text", text: "Changes" }, url: `https://builds.fernwood.example/${100 + i}/changes` },
    ],
  }));
  return { marker, payload: { text: marker, blocks: [{ type: "header", text: { type: "plain_text", text: marker } }, { type: "carousel", elements }] } };
}

/** A row of link buttons, more than fit across a phone. */
export function buttons(n = 0) {
  const marker = `Quick links (#${n})`;
  const elements = ["Dashboard", "Runbook", "Logs", "Traces", "Status page", "On-call schedule", "Postmortem template"].map((text, i) => ({ type: "button", text: { type: "plain_text", text }, url: `https://fernwood.example/links/${i}`, ...(i === 0 && { style: "primary" }), ...(i === 1 && { style: "danger" }) }));
  return { marker, payload: { text: marker, blocks: [{ type: "section", text: { type: "mrkdwn", text: `*${marker}*` } }, { type: "actions", elements }] } };
}

/** Image blocks of awkward shapes: very tall, very wide, tiny. */
export function images(n = 0) {
  const marker = `Screenshots from the visual tests (#${n})`;
  return {
    marker,
    payload: {
      text: marker,
      blocks: [
        { type: "image", title: { type: "plain_text", text: "Very tall: 300 × 2400" }, image_url: placeholder(`tall-${n}`, 300, 2400), alt_text: "A very tall screenshot" },
        { type: "image", title: { type: "plain_text", text: "Very wide: 2400 × 200" }, image_url: placeholder(`wide-${n}`, 2400, 200), alt_text: "A very wide screenshot" },
        { type: "image", title: { type: "plain_text", text: "Tiny: 16 × 16" }, image_url: placeholder(`tiny-${n}`, 16, 16), alt_text: "A tiny icon" },
        { type: "context", elements: [{ type: "image", image_url: placeholder(`ctx-${n}`, 32, 32), alt_text: "CI" }, { type: "mrkdwn", text: "Rendered by CI in *41s*" }] },
      ],
    },
  };
}

export function markdown(n = 0) {
  const marker = `Weekly report (#${n})`;
  return {
    marker,
    payload: {
      text: marker,
      blocks: [
        {
          type: "markdown",
          text: `# ${marker}\n\n## Shipped\n\n- Threads paging\n- **Faster** search\n- ~~Old importer~~ removed\n\n## Numbers\n\n| Metric | This week | Last week |\n| --- | ---: | ---: |\n| Messages | 48,210 | 45,002 |\n| Rooms | 312 | 298 |\n\n> Quote of the week: \"It's not a bug, it's a fern.\"\n\n\`\`\`\nnpm run release -- --tag beta\n\`\`\``,
        },
        { type: "divider" },
        { type: "rich_text", elements: [{ type: "rich_text_list", style: "ordered", elements: [{ type: "rich_text_section", elements: [{ type: "text", text: "Read the " }, { type: "link", url: "https://fernwood.example/report", text: "full report" }] }, { type: "rich_text_section", elements: [{ type: "text", text: "Reply in thread", style: { bold: true } }] }] }] },
      ],
    },
  };
}

/** Legacy attachments in three colours, one with an image. */
export function attachments(n = 0) {
  const marker = `Nightly jobs (#${n})`;
  return {
    marker,
    payload: {
      text: marker,
      attachments: [
        { color: "good", title: "Backups", text: "All 12 databases backed up.", footer: "cron" },
        { color: "warning", title: "Exports", text: "3 of 40 exports took over 10 minutes.", fields: [{ title: "Slowest", value: "acme-corp (14m)", short: true }, { title: "Median", value: "2m", short: true }] },
        { color: "#7c3aed", author_name: "Uptime", title: "Status page snapshot", image_url: placeholder(`status-${n}`, 1200, 500), text: "Everything green 🌿" },
      ],
    },
  };
}

export function textOnly(n = 0) {
  return { marker: `(#t${n})`, payload: { text: `Deploy *finished* :tada: (#t${n})\n> All regions healthy\n\`curl https://fernwood.example/up\` → \`ok\`` } };
}
