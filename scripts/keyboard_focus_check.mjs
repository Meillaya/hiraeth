#!/usr/bin/env node
import {mkdtemp, rm, writeFile} from "node:fs/promises";
import {tmpdir} from "node:os";
import {join} from "node:path";
import {spawn} from "node:child_process";

const targetUrl = process.argv[2];
const outputPath = process.argv[3];
const chromeBin = process.env.CHROME_BIN || "chromium";
const debugPort = Number.parseInt(process.env.CHROME_DEBUG_PORT || "9227", 10);

if (!targetUrl || !outputPath) {
  console.error("usage: keyboard_focus_check.mjs <url> <output-json>");
  process.exit(2);
}

const userDataDir = await mkdtemp(join(tmpdir(), "hiraeth-keyboard-focus-"));
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

async function cleanup() {
  if (!chrome.killed) chrome.kill("SIGTERM");
  await new Promise(resolve => chrome.once("exit", resolve));
  await rm(userDataDir, {recursive: true, force: true});
}

async function delay(ms) {
  await new Promise(resolve => setTimeout(resolve, ms));
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
    this.events = [];
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
    const payload = {id, method, params};

    const result = new Promise((resolve, reject) => {
      this.pending.set(id, {resolve, reject});
    });

    this.socket.send(JSON.stringify(payload));
    return result;
  }

  async close() {
    this.socket.close();
  }

  #onMessage(event) {
    const message = JSON.parse(event.data);

    if (message.id && this.pending.has(message.id)) {
      const {resolve, reject} = this.pending.get(message.id);
      this.pending.delete(message.id);
      if (message.error) reject(new Error(`${message.error.message}: ${message.error.data || ""}`));
      else resolve(message.result || {});
      return;
    }

    this.events.push(message);
  }
}

function focusProbeExpression() {
  return `(() => {
    const element = document.activeElement;
    const style = window.getComputedStyle(element);
    const label = element.innerText || element.getAttribute('aria-label') || element.getAttribute('name') || element.getAttribute('href') || '';
    return {
      tag: element.tagName,
      id: element.id || '',
      href: element.href || '',
      role: element.getAttribute('role') || '',
      ariaLabel: element.getAttribute('aria-label') || '',
      text: String(label).trim().slice(0, 120),
      className: String(element.className || '').slice(0, 200),
      focusVisible: element.matches(':focus-visible'),
      outlineStyle: style.outlineStyle,
      outlineWidth: style.outlineWidth,
      boxShadow: style.boxShadow
    };
  })()`;
}

async function pressTab(client) {
  await client.send("Input.dispatchKeyEvent", {
    type: "keyDown",
    key: "Tab",
    code: "Tab",
    windowsVirtualKeyCode: 9,
    nativeVirtualKeyCode: 9
  });
  await client.send("Input.dispatchKeyEvent", {
    type: "keyUp",
    key: "Tab",
    code: "Tab",
    windowsVirtualKeyCode: 9,
    nativeVirtualKeyCode: 9
  });
  await delay(150);
}

async function activeElement(client) {
  const result = await client.send("Runtime.evaluate", {
    expression: focusProbeExpression(),
    returnByValue: true,
    awaitPromise: true
  });
  return result.result.value;
}

try {
  const pageWs = await waitForPageWebSocket();
  const client = new CdpClient(pageWs);
  await client.connect();
  await client.send("Page.enable");
  await client.send("Runtime.enable");
  await client.send("Page.navigate", {url: targetUrl});
  await delay(1200);

  const focusOrder = [];
  for (let i = 0; i < 8; i += 1) {
    await pressTab(client);
    focusOrder.push(await activeElement(client));
  }

  const interactiveTags = new Set(["A", "BUTTON", "INPUT", "SELECT", "TEXTAREA"]);
  const uniqueTargets = new Set(focusOrder.map(item => `${item.tag}#${item.id}:${item.href}:${item.text}`));
  const interactiveCount = focusOrder.filter(item => interactiveTags.has(item.tag) || item.role === "button" || item.role === "link").length;
  const hasVisibleFocusEvidence = focusOrder.some(item => item.focusVisible || item.outlineStyle !== "none" || item.outlineWidth !== "0px" || item.boxShadow !== "none");
  const passed = uniqueTargets.size >= 3 && interactiveCount >= 3 && hasVisibleFocusEvidence;

  await writeFile(outputPath, JSON.stringify({
    passed,
    targetUrl,
    focusOrder,
    uniqueTargets: uniqueTargets.size,
    interactiveCount,
    hasVisibleFocusEvidence
  }, null, 2));

  await client.close();
  await cleanup();

  if (!passed) process.exit(1);
} catch (error) {
  await writeFile(outputPath, JSON.stringify({
    passed: false,
    targetUrl,
    error: error.message,
    chromeStderrTail: stderr.join("").slice(-1200)
  }, null, 2));
  await cleanup();
  console.error(error);
  process.exit(1);
}
