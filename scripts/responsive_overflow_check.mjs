#!/usr/bin/env node
import {mkdtemp, rm, writeFile} from "node:fs/promises";
import {tmpdir} from "node:os";
import {join} from "node:path";
import {spawn} from "node:child_process";

const targetUrl = process.argv[2];
const outputPath = process.argv[3];
const width = Number.parseInt(process.argv[4] || "390", 10);
const height = Number.parseInt(process.argv[5] || "844", 10);
const expectedSelector = process.argv[6] || "#search-shell";
const screenshotPath = process.argv[7];
const domPath = process.argv[8];
const chromeBin = process.env.CHROME_BIN || "chromium";
const colorScheme = process.env.OVERFLOW_CHECK_COLOR_SCHEME || "light";
const debugPort = Number.parseInt(process.env.CHROME_OVERFLOW_DEBUG_PORT || "9231", 10);
const globalDeadlineMs = Number.parseInt(process.env.OVERFLOW_CHECK_DEADLINE_MS || "15000", 10);
const cdpCommandTimeoutMs = Number.parseInt(process.env.OVERFLOW_CHECK_CDP_TIMEOUT_MS || "5000", 10);

if (!targetUrl || !outputPath) {
  console.error("usage: responsive_overflow_check.mjs <url> <output-json> [width] [height] [expected-css-selector] [screenshot-png] [dom-html]");
  process.exit(2);
}

const parsedTarget = new URL(targetUrl);
const localHosts = new Set(["127.0.0.1", "localhost", "::1"]);
if (!process.env.HIRAETH_ALLOW_REMOTE_OVERFLOW_TARGET && !localHosts.has(parsedTarget.hostname)) {
  console.error("responsive overflow check only accepts local targets by default");
  process.exit(2);
}

const userDataDir = await mkdtemp(join(tmpdir(), "hiraeth-overflow-"));
const chrome = spawn(chromeBin, [
  "--headless=new",
  "--disable-gpu",
  "--no-sandbox",
  "--remote-debugging-address=127.0.0.1",
  `--remote-debugging-port=${debugPort}`,
  `--user-data-dir=${userDataDir}`,
  `--force-prefers-color-scheme=${colorScheme}`,
  `--window-size=${width},${height}`,
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
      }, cdpCommandTimeoutMs);
      this.pending.set(id, {resolve, reject, timer});
    });
    this.socket.send(JSON.stringify({id, method, params}));
    return result;
  }

  async close() {
    this.socket.close();
  }

  #onMessage(event) {
    const message = JSON.parse(event.data);
    if (!message.id || !this.pending.has(message.id)) return;
    const {resolve, reject, timer} = this.pending.get(message.id);
    clearTimeout(timer);
    this.pending.delete(message.id);
    if (message.error) reject(new Error(`${message.error.message}: ${message.error.data || ""}`));
    else resolve(message.result || {});
  }

  #rejectPending(error) {
    for (const {reject, timer} of this.pending.values()) {
      clearTimeout(timer);
      reject(error);
    }
    this.pending.clear();
  }
}

async function waitForLoadAndMarker(client) {
  const selectorJson = JSON.stringify(expectedSelector);

  for (let attempt = 0; attempt < 80; attempt += 1) {
    const result = await client.send("Runtime.evaluate", {
      expression: `(() => ({
        readyState: document.readyState,
        url: location.href,
        hasMarker: Boolean(document.querySelector(${selectorJson}))
      }))()`,
      returnByValue: true
    });

    const value = result.result.value;
    if (value.readyState === "complete" && value.hasMarker) return value.url;
    await delay(125);
  }

  throw new Error(`target page did not load the expected ${expectedSelector} marker before overflow probe`);
}

function overflowProbeExpression() {
  return `(() => {
    const viewportWidth = document.documentElement.clientWidth;
    const documentScrollWidth = Math.max(document.documentElement.scrollWidth, document.body.scrollWidth);
    const overflowing = [];
    for (const element of document.querySelectorAll('body *')) {
      const rect = element.getBoundingClientRect();
      const style = window.getComputedStyle(element);
      if (rect.width > 0 && rect.right > viewportWidth + 1 && style.position !== 'fixed') {
        overflowing.push({
          tag: element.tagName,
          id: element.id || '',
          className: String(element.className || '').slice(0, 160),
          right: Math.round(rect.right),
          width: Math.round(rect.width),
          text: String(element.innerText || '').trim().slice(0, 80)
        });
      }
    }
    return {
      passed: documentScrollWidth <= viewportWidth + 1 && overflowing.length === 0,
      viewportWidth,
      documentScrollWidth,
      overflowCount: overflowing.length,
      overflowing: overflowing.slice(0, 10)
    };
  })()`;
}

let exitCode = 0;
let client;
let probe = {passed: false};

try {
  await Promise.race([
    (async () => {
      const pageWs = await waitForPageWebSocket();
      client = new CdpClient(pageWs);
      await client.connect();
      await client.send("Page.enable");
      await client.send("Runtime.enable");
      await client.send("Emulation.setEmulatedMedia", {
        features: [{name: "prefers-color-scheme", value: colorScheme}]
      });
      await client.send("Page.addScriptToEvaluateOnNewDocument", {
        source: `try { localStorage.setItem("phx:theme", ${JSON.stringify(colorScheme)}); } catch (_error) {}`
      });
      await client.send("Emulation.setDeviceMetricsOverride", {
        width,
        height,
        deviceScaleFactor: 1,
        mobile: width <= 480
      });
      await client.send("Page.navigate", {url: targetUrl});
      const finalUrl = await waitForLoadAndMarker(client);

      const result = await client.send("Runtime.evaluate", {
        expression: overflowProbeExpression(),
        returnByValue: true,
        awaitPromise: true
      });
      probe = result.result.value;
      if (screenshotPath) {
        const screenshot = await client.send("Page.captureScreenshot", {
          format: "png",
          captureBeyondViewport: false
        });
        await writeFile(screenshotPath, Buffer.from(screenshot.data, "base64"));
      }
      if (domPath) {
        const dom = await client.send("Runtime.evaluate", {
          expression: "document.documentElement.outerHTML",
          returnByValue: true
        });
        await writeFile(domPath, dom.result.value);
      }
      await writeFile(outputPath, JSON.stringify({
        passed: Boolean(probe.passed),
        targetUrl,
        finalUrl,
        width,
        height,
        expectedSelector,
        colorScheme,
        screenshotPath,
        domPath,
        ...probe
      }, null, 2));
      if (!probe.passed) exitCode = 1;
    })(),
    new Promise((_, reject) => setTimeout(() => reject(new Error("responsive overflow check exceeded global deadline")), globalDeadlineMs))
  ]);
} catch (error) {
  exitCode = 1;
  await writeFile(outputPath, JSON.stringify({
    passed: false,
    targetUrl,
    width,
    height,
    expectedSelector,
    error: error.message,
    chromeStderrTail: stderr.join("").slice(-1200)
  }, null, 2));
  console.error(error);
} finally {
  if (client) await client.close();
  await cleanup();
}

if (exitCode !== 0) process.exit(exitCode);
