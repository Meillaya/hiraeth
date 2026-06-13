#!/usr/bin/env node
import {mkdtemp, rm, writeFile} from "node:fs/promises";
import {tmpdir} from "node:os";
import {join} from "node:path";
import {spawn} from "node:child_process";

const baseUrl = process.argv[2];
const outputDir = process.argv[3];
const chromeBin = process.env.CHROME_BIN || "chromium";
const debugPort = Number.parseInt(process.env.CHROME_ADMIN_DEBUG_PORT || "9228", 10);
const email = process.env.HIRAETH_BROWSER_ADMIN_EMAIL || "real-catalog-admin@example.test";
const password = process.env.HIRAETH_BROWSER_ADMIN_PASSWORD || "correct horse battery staple";
const bookSlug = "deep-vellum-immigrant";
const expectedCoverAttribution = "Browser QA cached cover";
const expectedCoverSource = "https://covers.example.test/browser-qa-immigrant.png";

if (!baseUrl || !outputDir) {
  console.error("usage: admin_browser_check.mjs <base-url> <output-dir>");
  process.exit(2);
}

const userDataDir = await mkdtemp(join(tmpdir(), "hiraeth-admin-browser-"));
const chrome = spawn(chromeBin, [
  "--headless=new",
  "--disable-gpu",
  "--no-sandbox",
  `--remote-debugging-port=${debugPort}`,
  `--user-data-dir=${userDataDir}`,
  "about:blank"
], {stdio: ["ignore", "ignore", "pipe"]});

const stderr = [];
const chromeExit = new Promise(resolve => chrome.once("exit", resolve));
chrome.stderr.on("data", chunk => stderr.push(chunk.toString()));

async function delay(ms) {
  await new Promise(resolve => setTimeout(resolve, ms));
}

async function cleanup() {
  if (!chrome.killed) chrome.kill("SIGTERM");
  await Promise.race([chromeExit, delay(2000)]);
  await rm(userDataDir, {recursive: true, force: true, maxRetries: 5, retryDelay: 100});
}

async function fetchJson(path) {
  const response = await fetch(`http://127.0.0.1:${debugPort}${path}`);
  if (!response.ok) throw new Error(`CDP ${path} returned ${response.status}`);
  return response.json();
}

async function waitForPageWebSocket() {
  for (let attempt = 0; attempt < 80; attempt += 1) {
    try {
      const pages = await fetchJson("/json/list");
      const page = pages.find(candidate => candidate.type === "page" && candidate.webSocketDebuggerUrl);
      if (page) return page.webSocketDebuggerUrl;
    } catch (_error) {
      // Chrome is still booting.
    }
    await delay(125);
  }
  throw new Error(`Chrome DevTools did not become ready: ${stderr.join("").slice(-800)}`);
}

class CdpClient {
  constructor(url) {
    this.url = url;
    this.nextId = 1;
    this.pending = new Map();
  }

  async connect() {
    this.socket = new WebSocket(this.url);
    this.socket.addEventListener("message", event => this.#onMessage(event));
    await new Promise((resolve, reject) => {
      this.socket.addEventListener("open", resolve, {once: true});
      this.socket.addEventListener("error", reject, {once: true});
    });
  }

  send(method, params = {}) {
    const id = this.nextId;
    this.nextId += 1;
    const result = new Promise((resolve, reject) => this.pending.set(id, {resolve, reject}));
    this.socket.send(JSON.stringify({id, method, params}));
    return result;
  }

  async close() {
    this.socket.close();
  }

  #onMessage(event) {
    const message = JSON.parse(event.data);
    if (!message.id || !this.pending.has(message.id)) return;
    const {resolve, reject} = this.pending.get(message.id);
    this.pending.delete(message.id);
    if (message.error) reject(new Error(`${message.error.message}: ${message.error.data || ""}`));
    else resolve(message.result || {});
  }
}

async function evaluate(client, expression) {
  const result = await client.send("Runtime.evaluate", {
    expression,
    returnByValue: true,
    awaitPromise: true
  });
  return result.result.value;
}

async function navigate(client, url) {
  await client.send("Page.navigate", {url});
  await delay(1200);
}

async function capturePage(client, outputDir, baseUrl, path, name) {
  await navigate(client, `${baseUrl}${path}`);
  const html = await evaluate(client, `document.documentElement.outerHTML`);
  const title = await evaluate(client, `document.title`);
  const screenshot = await client.send("Page.captureScreenshot", {format: "png", captureBeyondViewport: true});
  await writeFile(join(outputDir, `${name}.png`), Buffer.from(screenshot.data, "base64"));
  await writeFile(join(outputDir, `${name}.html`), html);
  return {path, name, title, html};
}

try {
  const pageWs = await waitForPageWebSocket();
  const client = new CdpClient(pageWs);
  await client.connect();
  await client.send("Page.enable");
  await client.send("Runtime.enable");

  await navigate(client, `${baseUrl}/sign-in`);
  const formReady = await evaluate(client, `Boolean(document.querySelector('form[action="/auth/user/password/sign_in"]'))`);
  if (!formReady) throw new Error("sign-in form not found");

  await evaluate(client, `(() => {
    const email = document.querySelector('input[name="user[email]"]');
    const password = document.querySelector('input[name="user[password]"]');
    email.value = ${JSON.stringify(email)};
    password.value = ${JSON.stringify(password)};
    for (const element of [email, password]) {
      element.dispatchEvent(new Event('input', {bubbles: true}));
      element.dispatchEvent(new Event('change', {bubbles: true}));
    }
    document.querySelector('form[action="/auth/user/password/sign_in"]').requestSubmit();
    return true;
  })()`);
  await delay(1800);

  const admin = await capturePage(client, outputDir, baseUrl, "/admin", "desktop-admin-authenticated");
  const importsIndex = await capturePage(client, outputDir, baseUrl, "/admin/imports", "desktop-admin-imports");
  const importsNew = await capturePage(client, outputDir, baseUrl, "/admin/imports/new", "desktop-admin-import-new");
  const reviewIndex = await capturePage(client, outputDir, baseUrl, "/admin/review", "desktop-admin-review");
  const reviewDetailHref = await evaluate(client, `(() => {
    const link = document.querySelector('a[id^="open-review-"]');
    return link ? link.getAttribute('href') : null;
  })()`);
  const reviewDetail = reviewDetailHref
    ? await capturePage(client, outputDir, baseUrl, reviewDetailHref, "desktop-admin-review-detail")
    : {html: "", path: null, name: "desktop-admin-review-detail", title: ""};
  const coversBefore = await capturePage(client, outputDir, baseUrl, "/admin/covers", "desktop-admin-covers-before-takedown");
  const coverPublicBefore = await capturePage(
    client,
    outputDir,
    baseUrl,
    `/books/${bookSlug}`,
    "desktop-cover-attribution-before-takedown"
  );
  await navigate(client, `${baseUrl}/admin/covers`);
  const hideClicked = await evaluate(client, `(() => {
    const article = [...document.querySelectorAll('#cover-assignment-list article')]
      .find(candidate => candidate.textContent.includes(${JSON.stringify(expectedCoverSource)}));
    const button = article ? article.querySelector('button[id^="hide-cover-"]') : null;
    if (!button) return false;
    button.click();
    return true;
  })()`);
  await delay(1400);
  const coversAfterHtml = await evaluate(client, `document.documentElement.outerHTML`);
  const coversAfterShot = await client.send("Page.captureScreenshot", {format: "png", captureBeyondViewport: true});
  await writeFile(join(outputDir, "desktop-admin-covers-after-takedown.png"), Buffer.from(coversAfterShot.data, "base64"));
  await writeFile(join(outputDir, "desktop-admin-covers-after-takedown.html"), coversAfterHtml);
  const coverPublicAfter = await capturePage(
    client,
    outputDir,
    baseUrl,
    `/books/${bookSlug}`,
    "desktop-cover-fallback-after-takedown"
  );

  const adminVisible = admin.html.includes("Catalog Administration") && admin.html.includes("Admin dashboard") && admin.html.includes(email);
  const importVisible = importsIndex.html.includes("CSV imports") && importsNew.html.includes("New CSV import");
  const reviewVisible = reviewIndex.html.includes("Review queue") && reviewIndex.html.includes("Browser QA missing ISBN review item") && reviewDetail.html.includes("Review detail");
  const coverVisible = coversBefore.html.includes("Cover governance") && coversBefore.html.includes(expectedCoverAttribution);
  const coverAttributionVisible = coverPublicBefore.html.includes(`id="cover-attribution-${bookSlug}"`) && coverPublicBefore.html.includes(expectedCoverAttribution) && coverPublicBefore.html.includes('/covers/cache/browser-qa-immigrant.png');
  const takedownVisible = hideClicked && coversAfterHtml.includes("hidden · hidden") && coverPublicAfter.html.includes(`missing-cover-${bookSlug}`) && !coverPublicAfter.html.includes(expectedCoverAttribution);
  const passed = adminVisible && importVisible && reviewVisible && coverVisible && coverAttributionVisible && takedownVisible;

  await writeFile(join(outputDir, "admin-authenticated.json"), JSON.stringify({
    passed,
    email,
    reviewDetailPath: reviewDetail.path,
    containsCatalogAdministration: admin.html.includes("Catalog Administration"),
    containsAdminDashboard: admin.html.includes("Admin dashboard"),
    containsAdminEmail: admin.html.includes(email),
    containsImportIndex: importsIndex.html.includes("CSV imports"),
    containsImportNew: importsNew.html.includes("New CSV import"),
    containsReviewQueue: reviewIndex.html.includes("Review queue"),
    containsSeededReviewItem: reviewIndex.html.includes("Browser QA missing ISBN review item"),
    containsReviewDetail: reviewDetail.html.includes("Review detail"),
    containsCoverGovernance: coversBefore.html.includes("Cover governance"),
    containsCoverAttribution: coverAttributionVisible,
    usesBookRouteForPublicCoverChecks: true,
    containsCachedCoverPath: coverPublicBefore.html.includes('/covers/cache/browser-qa-immigrant.png'),
    clickedHideForTakedown: hideClicked,
    containsHiddenTakedown: coversAfterHtml.includes("hidden · hidden"),
    publicCoverFallsBackAfterTakedown: coverPublicAfter.html.includes(`missing-cover-${bookSlug}`) && !coverPublicAfter.html.includes(expectedCoverAttribution)
  }, null, 2));

  await client.close();
  await cleanup();
  if (!passed) process.exit(1);
} catch (error) {
  await writeFile(join(outputDir, "admin-authenticated.json"), JSON.stringify({
    passed: false,
    error: error.message,
    chromeStderrTail: stderr.join("").slice(-1200)
  }, null, 2));
  await cleanup();
  console.error(error);
  process.exit(1);
}
