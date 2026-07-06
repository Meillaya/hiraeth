#!/usr/bin/env node
import {mkdtemp, rm, writeFile, readFile} from "node:fs/promises";
import {tmpdir} from "node:os";
import {join} from "node:path";
import {spawn} from "node:child_process";

const baseUrl = process.argv[2];
const outputPath = process.argv[3];
const routes = process.argv.slice(4);
const chromeBin = process.env.CHROME_BIN || "chromium";
const debugPort = Number.parseInt(process.env.CHROME_RESOURCE_DEBUG_PORT || "9234", 10);

if (!baseUrl || !outputPath || routes.length === 0) {
  console.error("usage: public_resource_dependency_check.mjs <base-url> <output-json> <route> [...route]");
  process.exit(2);
}

const parsedBase = new URL(baseUrl);
const localHosts = new Set(["127.0.0.1", "localhost", "::1"]);
if (!localHosts.has(parsedBase.hostname)) {
  console.error("public resource dependency check only accepts local base URLs");
  process.exit(2);
}

const userDataDir = await mkdtemp(join(tmpdir(), "hiraeth-resource-deps-"));
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
      }, 5000);
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
    for (const {reject, timer} of this.pending.values()) {
      clearTimeout(timer);
      reject(error);
    }
    this.pending.clear();
  }
}

function sameOrigin(url) {
  try {
    const parsed = new URL(url);
    return parsed.origin === parsedBase.origin;
  } catch (_error) {
    return true;
  }
}

function domProbeExpression() {
  return `(() => {
    const remoteImages = [...document.images].map(img => img.currentSrc || img.src).filter(src => /^https?:\/\//.test(src));
    const remoteScripts = [...document.querySelectorAll('script[src]')].map(script => script.src).filter(src => /^https?:\/\//.test(src));
    const remoteResourceLinks = [...document.querySelectorAll('link[href]')]
      .filter(link => /^(stylesheet|preload|modulepreload|preconnect|dns-prefetch|icon)$/i.test(link.rel || ''))
      .map(link => link.href)
      .filter(href => /^https?:\/\//.test(href));
    const remoteCssUrls = [...document.querySelectorAll('style')]
      .flatMap(style => [...style.textContent.matchAll(/url\(["']?(https?:[^"')]+)["']?\)/g)].map(match => match[1]));
    for (const element of document.querySelectorAll('[style]')) {
      const style = element.getAttribute('style') || '';
      for (const match of style.matchAll(/url\(["']?(https?:[^"')]+)["']?\)/g)) remoteCssUrls.push(match[1]);
    }
    return {remoteImages, remoteScripts, remoteResourceLinks, remoteCssUrls};
  })()`;
}

let exitCode = 0;
let client;
const routeReports = [];

try {
  const pageWs = await waitForPageWebSocket();
  client = new CdpClient(pageWs);
  await client.connect();
  await client.send("Page.enable");
  await client.send("Runtime.enable");
  await client.send("Network.enable");

  for (const route of routes) {
    const targetUrl = new URL(route, parsedBase).toString();
    if (new URL(targetUrl).origin !== parsedBase.origin) {
      throw new Error(`public resource dependency route must stay on ${parsedBase.origin}: ${route}`);
    }
    client.events = [];
    await client.send("Page.navigate", {url: targetUrl});
    await delay(1400);

    const dom = await client.send("Runtime.evaluate", {
      expression: domProbeExpression(),
      returnByValue: true,
      awaitPromise: true
    });

    const requestedExternalResources = client.events
      .filter(event => event.method === "Network.requestWillBeSent")
      .map(event => event.params?.request?.url)
      .filter(Boolean)
      .filter(url => /^https?:\/\//.test(url) && !sameOrigin(url));

    const domValue = dom.result.value || {};

    routeReports.push({
      route,
      targetUrl,
      requestedExternalResources: [...new Set(requestedExternalResources)],
      remoteImages: domValue.remoteImages || [],
      remoteScripts: domValue.remoteScripts || [],
      remoteResourceLinks: domValue.remoteResourceLinks || [],
      remoteCssUrls: domValue.remoteCssUrls || []
    });
  }

  const cssFiles = ["assets/css/app.css"];
  const remoteCssSourceUrls = [];
  for (const cssFile of cssFiles) {
    const css = await readFile(cssFile, "utf8");
    for (const match of css.matchAll(/url\(["']?(https?:[^"')]+)["']?\)/g)) {
      remoteCssSourceUrls.push({file: cssFile, url: match[1]});
    }
  }

  const failures = routeReports.flatMap(report => [
    ...report.requestedExternalResources.map(url => ({route: report.route, kind: "network", url})),
    ...report.remoteImages.map(url => ({route: report.route, kind: "image", url})),
    ...report.remoteScripts.map(url => ({route: report.route, kind: "script", url})),
    ...report.remoteResourceLinks.map(url => ({route: report.route, kind: "resource-link", url})),
    ...report.remoteCssUrls.map(url => ({route: report.route, kind: "css-url", url}))
  ]).concat(remoteCssSourceUrls.map(item => ({route: "asset-css", kind: "css-source-url", ...item})));

  const passed = failures.length === 0;
  await writeFile(outputPath, JSON.stringify({passed, baseUrl, routes, routeReports, failures}, null, 2));
  if (!passed) exitCode = 1;
} catch (error) {
  exitCode = 1;
  await writeFile(outputPath, JSON.stringify({
    passed: false,
    baseUrl,
    routes,
    error: error.message,
    chromeStderrTail: stderr.join("").slice(-1200)
  }, null, 2));
  console.error(error);
} finally {
  if (client) await client.close();
  await cleanup();
}

if (exitCode !== 0) process.exit(exitCode);
