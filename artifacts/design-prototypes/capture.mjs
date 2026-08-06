#!/usr/bin/env node
// Prototype capture harness for artifacts/design-prototypes.
//
// Mirrors the existing browser QA harness pattern (scripts/qa/browser/*.mjs):
// spawns the devenv Chromium executable with a pinned remote-debugging port,
// drives it over the Chrome DevTools Protocol via the WebSocket available in
// Node 22+ (no package.json, no npm install - this repo forbids a root
// package.json), overrides the device metrics per viewport, navigates to each
// prototype page (file:// URLs; the prototypes are self-contained with
// relative covers/ and fonts/ dirs), and captures a PNG screenshot.
//
// Usage: node artifacts/design-prototypes/capture.mjs [--viewport-only 1440x900]
// Env:   CHROME_BIN   - chromium executable (default: "chromium")
//        CHROME_CAPTURE_DEBUG_PORT - CDP port (default: 9246)
//
// Output: artifacts/design-prototypes/captures/<direction>/<page>-<viewport>.png
//         plus captures/summary.json listing every captured file.

import {mkdtemp, rm, writeFile, readFile, mkdir} from "node:fs/promises";
import {tmpdir} from "node:os";
import {join, dirname} from "node:path";
import {spawn} from "node:child_process";
import {fileURLToPath} from "node:url";

const rootDir = dirname(fileURLToPath(import.meta.url));
const chromeBin = process.env.CHROME_BIN || "chromium";
const debugPort = Number.parseInt(process.env.CHROME_CAPTURE_DEBUG_PORT || "9246", 10);

const directions = ["gallery", "ledger", "night-reading"];
const pages = ["index", "browse", "book", "publishers"];
const viewports = [
  {name: "1440x900", width: 1440, height: 900},
  {name: "390x844", width: 390, height: 844}
];

const viewportOnlyArg = process.argv.indexOf("--viewport-only");
const viewportOnly =
  viewportOnlyArg !== -1 && process.argv[viewportOnlyArg + 1]
    ? process.argv[viewportOnlyArg + 1]
    : null;

const userDataDir = await mkdtemp(join(tmpdir(), "hiraeth-proto-capture-"));
const chrome = spawn(chromeBin, [
  "--headless=new",
  "--disable-gpu",
  "--no-sandbox",
  "--remote-debugging-address=127.0.0.1",
  `--remote-debugging-port=${debugPort}`,
  `--user-data-dir=${userDataDir}`,
  "about:blank"
], {stdio: ["ignore", "ignore", "pipe"]});

const stderr = [];
chrome.stderr.on("data", chunk => stderr.push(chunk.toString()));
const chromeExited = new Promise(resolve => chrome.once("exit", resolve));
let cleanedUp = false;

async function delay(ms) {
  await new Promise(resolve => setTimeout(resolve, ms));
}

async function waitForReady(client) {
  let ready = false;
  for (let attempt = 0; attempt < 60; attempt += 1) {
    try {
      const result = await client.send("Runtime.evaluate", {
        expression: `document.readyState === "complete"`,
        returnByValue: true
      });
      if (result.result && result.result.value) {
        ready = true;
        break;
      }
    } catch (_error) {
      // navigation in flight; retry
    }
    await delay(250);
  }
  if (!ready) throw new Error("page did not reach document.readyState=complete in time");
  // Let images/fonts settle (progressive font-display swap, cover decode).
  await delay(1200);
}

async function cleanup() {
  if (cleanedUp) return;
  cleanedUp = true;
  if (chrome.exitCode === null && !chrome.killed) chrome.kill("SIGTERM");
  await Promise.race([chromeExited, delay(2000)]);
  await rm(userDataDir, {recursive: true, force: true, maxRetries: 10, retryDelay: 100});
}

async function fetchJson(path) {
  const response = await fetch(`http://127.0.0.1:${debugPort}${path}`);
  if (!response.ok) throw new Error(`CDP ${path} returned ${response.status}`);
  return response.json();
}

async function waitForPageWebSocket() {
  let lastError = null;
  for (let attempt = 0; attempt < 80; attempt += 1) {
    try {
      const pages = await fetchJson("/json/list");
      const page = pages.find(candidate => candidate.type === "page" && candidate.webSocketDebuggerUrl);
      if (page) return page.webSocketDebuggerUrl;
    } catch (error) {
      lastError = error;
    }
    await delay(125);
  }
  const errorDetail = lastError ? ` lastError=${lastError.message}` : "";
  throw new Error(`Chrome DevTools did not become ready:${errorDetail} ${stderr.join("").slice(-800)}`);
}

class CdpClient {
  constructor(url) {
    this.url = url;
    this.nextId = 1;
    this.pending = new Map();
    this.events = [];
  }

  async connect() {
    this.socket = new WebSocket(this.url);
    this.socket.addEventListener("message", event => this.#onMessage(event));
    this.socket.addEventListener("error", () => this.#rejectPending(new Error("CDP socket error")));
    this.socket.addEventListener("close", () => this.#rejectPending(new Error("CDP socket closed")));
    await new Promise((resolve, reject) => {
      this.socket.addEventListener("open", resolve, {once: true});
      this.socket.addEventListener("error", reject, {once: true});
    });
  }

  send(method, params = {}) {
    const id = this.nextId;
    this.nextId += 1;
    const result = new Promise((resolve, reject) => {
      const timer = setTimeout(() => {
        this.pending.delete(id);
        reject(new Error(`CDP command timed out: ${method}`));
      }, 10000);
      this.pending.set(id, {resolve, reject, timer});
    });
    this.socket.send(JSON.stringify({id, method, params}));
    return result;
  }

  waitForEvent(_method, _timeoutMs = 15000) {
    return Promise.reject(new Error("unused"));
  }

  async close() {
    this.socket.close();
  }

  #onMessage(event) {
    const message = JSON.parse(event.data);
    if (message.id && this.pending.has(message.id)) {
      const {resolve, reject, timer} = this.pending.get(message.id);
      clearTimeout(timer);
      this.pending.delete(message.id);
      if (message.error) reject(new Error(`${message.error.message}: ${message.error.data || ""}`));
      else resolve(message.result || {});
      return;
    }
    this.events.push(message);
  }

  #rejectPending(error) {
    for (const {reject} of this.pending.values()) reject(error);
    this.pending.clear();
  }
}

let exitCode = 0;
let client;
const summary = [];
const errors = [];

try {
  const pageWs = await waitForPageWebSocket();
  client = new CdpClient(pageWs);
  await client.connect();
  await client.send("Page.enable");
  await client.send("Runtime.enable");
  await client.send("Network.enable");

  for (const direction of directions) {
    for (const page of pages) {
      const pageFile = join(rootDir, direction, `${page}.html`);
      // Loud failure on a bogus page name: assert the page file exists first.
      const pageHtml = await readFile(pageFile, "utf8");
      if (!/^<!doctype html>/i.test(pageHtml.trim())) {
        throw new Error(`capture aborted: ${pageFile} is not an HTML document`);
      }

      for (const viewport of viewports) {
        if (viewportOnly && viewport.name !== viewportOnly) continue;

        const targetUrl = `file://${pageFile}`;
        await client.send("Emulation.setDeviceMetricsOverride", {
          width: viewport.width,
          height: viewport.height,
          deviceScaleFactor: 1,
          mobile: viewport.width <= 480
        });

        client.events = [];
        await client.send("Page.navigate", {url: targetUrl});
        // Poll for a fully loaded DOM (mirrors the browser QA harness's
        // post-navigate settle delay, but waits for readyState instead of
        // racing Page.loadEventFired).
        await waitForReady(client);

        const shot = await client.send("Page.captureScreenshot", {format: "png"});
        const outDir = join(rootDir, "captures", direction);
        await mkdir(outDir, {recursive: true});
        const outFile = join(outDir, `${page}-${viewport.name}.png`);
        await writeFile(outFile, Buffer.from(shot.data, "base64"));
        const stat = (await import("node:fs/promises")).stat;

        const statResult = await stat(outFile);
        summary.push({
          direction,
          page,
          viewport: viewport.name,
          file: `captures/${direction}/${page}-${viewport.name}.png`,
          bytes: statResult.size
        });
        console.log(`captured ${direction}/${page}-${viewport.name}.png (${statResult.size} bytes)`);
      }
    }
  }

  const summaryPath = join(rootDir, "captures", "summary.json");
  await mkdir(dirname(summaryPath), {recursive: true});
  await writeFile(summaryPath, JSON.stringify({count: summary.length, captures: summary}, null, 2));
} catch (error) {
  exitCode = 1;
  errors.push({error: error.message, chromeStderrTail: stderr.join("").slice(-1200)});
  console.error(error);
} finally {
  if (client) await client.close();
  await cleanup();
}

if (errors.length > 0) {
  const errPath = join(rootDir, "captures", "capture-errors.json");
  await mkdir(dirname(errPath), {recursive: true});
  await writeFile(errPath, JSON.stringify({passed: false, errors}, null, 2));
  process.exit(1);
}

const expected = viewportOnly ? viewports.filter(v => v.name === viewportOnly).length * directions.length * pages.length : 24;
if (summary.length !== expected) {
  console.error(`expected ${expected} captures, got ${summary.length}`);
  process.exit(1);
}
console.log(`OK: ${summary.length} captures written`);
