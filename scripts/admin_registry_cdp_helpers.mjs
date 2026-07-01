import {mkdtemp, rm, writeFile} from "node:fs/promises";
import {join} from "node:path";
import {tmpdir} from "node:os";
import {spawn} from "node:child_process";

export function delay(ms) {
  return new Promise(resolve => setTimeout(resolve, ms));
}

export class CdpClient {
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
      }, 5000);
      this.pending.set(id, {resolve, reject, timer});
    });
    this.socket.send(JSON.stringify({id, method, params}));
    return result;
  }

  async close() {
    if (this.socket?.readyState === WebSocket.OPEN) this.socket.close();
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

export async function launchBrowser({chromeBin, debugPort}) {
  const userDataDir = await mkdtemp(join(tmpdir(), "hiraeth-admin-registry-"));
  const chrome = spawn(chromeBin, [
    "--headless=new",
    "--disable-gpu",
    "--no-sandbox",
    "--remote-debugging-address=127.0.0.1",
    `--remote-debugging-port=${debugPort}`,
    `--user-data-dir=${userDataDir}`,
    "--window-size=1280,960",
    "about:blank"
  ], {stdio: ["ignore", "ignore", "pipe"]});

  const stderr = [];
  let cleanedUp = false;
  const chromeExited = new Promise(resolve => chrome.once("exit", resolve));
  chrome.stderr.on("data", chunk => stderr.push(chunk.toString()));

  async function cleanup(client) {
    if (cleanedUp) return {userDataDirRemoved: true, chromeTerminated: true, repeated: true};
    cleanedUp = true;
    if (client) await client.close().catch(() => {});
    if (chrome.exitCode === null && !chrome.killed) chrome.kill("SIGTERM");
    await Promise.race([chromeExited, delay(2000)]);
    await rm(userDataDir, {recursive: true, force: true, maxRetries: 10, retryDelay: 100});
    return {userDataDirRemoved: true, chromeTerminated: chrome.exitCode !== null || chrome.killed};
  }

  async function fetchJson(path) {
    const response = await fetch(`http://127.0.0.1:${debugPort}${path}`);
    if (!response.ok) throw new Error(`CDP ${path} returned ${response.status}`);
    return response.json();
  }

  async function waitForPageWebSocket() {
    let lastError;
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
    throw new Error(`Chrome DevTools did not become ready: ${lastError?.message || "no page"} ${stderr.join("").slice(-800)}`);
  }

  return {cleanup, stderr, userDataDir, waitForPageWebSocket};
}

export async function captureScreenshot(client, screenshotPath) {
  const capture = await client.send("Page.captureScreenshot", {format: "png", captureBeyondViewport: true});
  await writeFile(screenshotPath, Buffer.from(capture.data, "base64"));
}
