#!/usr/bin/env node
import {mkdtemp, rm, writeFile} from "node:fs/promises";
import {tmpdir} from "node:os";
import {join} from "node:path";
import {spawn} from "node:child_process";

const targetUrl = process.argv[2];
const selector = process.argv[3];
const expectedSrc = process.argv[4];
const outputPath = process.argv[5];
const chromeBin = process.env.CHROME_BIN || "chromium";
const debugPort = Number.parseInt(process.env.CHROME_IMAGE_DEBUG_PORT || "9229", 10);

if (!targetUrl || !selector || !expectedSrc || !outputPath) {
  console.error("usage: image_decode_check.mjs <url> <selector> <expected-src-substring> <output-json>");
  process.exit(2);
}

const userDataDir = await mkdtemp(join(tmpdir(), "hiraeth-image-decode-"));
const chrome = spawn(chromeBin, [
  "--headless=new",
  "--disable-gpu",
  "--no-sandbox",
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

function probeExpression(selectorValue, expectedSrcValue) {
  return `(() => {
    const selector = ${JSON.stringify(selectorValue)};
    const expectedSrc = ${JSON.stringify(expectedSrcValue)};
    const image = document.querySelector(selector);
    if (!image) return {passed: false, reason: 'missing_image', selector};
    return {
      passed: image.complete && image.naturalWidth > 0 && image.naturalHeight > 0 && image.currentSrc.includes(expectedSrc),
      selector,
      currentSrc: image.currentSrc,
      complete: image.complete,
      naturalWidth: image.naturalWidth,
      naturalHeight: image.naturalHeight,
      expectedSrcPresent: image.currentSrc.includes(expectedSrc)
    };
  })()`;
}

let exitCode = 0;
let client;
let probe = {passed: false};

try {
  const pageWs = await waitForPageWebSocket();
  client = new CdpClient(pageWs);
  await client.connect();
  await client.send("Page.enable");
  await client.send("Runtime.enable");
  await client.send("Page.navigate", {url: targetUrl});

  for (let attempt = 0; attempt < 20; attempt += 1) {
    await delay(250);
    const result = await client.send("Runtime.evaluate", {
      expression: probeExpression(selector, expectedSrc),
      returnByValue: true,
      awaitPromise: true
    });
    probe = result.result.value;
    if (probe.passed) break;
  }

  await writeFile(outputPath, JSON.stringify({passed: Boolean(probe.passed), targetUrl, ...probe}, null, 2));
  if (!probe.passed) exitCode = 1;
} catch (error) {
  exitCode = 1;
  await writeFile(outputPath, JSON.stringify({
    passed: false,
    targetUrl,
    selector,
    expectedSrc,
    error: error.message,
    chromeStderrTail: stderr.join("").slice(-1200)
  }, null, 2));
  console.error(error);
} finally {
  if (client) await client.close();
  await cleanup();
}

if (exitCode !== 0) process.exit(exitCode);
