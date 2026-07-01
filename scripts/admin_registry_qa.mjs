#!/usr/bin/env node
import {mkdir, writeFile} from "node:fs/promises";
import {basename, dirname, extname, join} from "node:path";
import {CdpClient, captureScreenshot, delay, launchBrowser} from "./admin_registry_cdp_helpers.mjs";
import {clickFirstScheduleControl, navigateAndWait, pageProbe, selectSeededProvider, setViewport} from "./admin_registry_scenario_helpers.mjs";

const baseUrl = process.argv[2];
const screenshotPath = process.argv[3];
const chromeBin = process.env.CHROME_BIN || "chromium";
const debugPort = Number.parseInt(process.env.CHROME_ADMIN_REGISTRY_DEBUG_PORT || "9237", 10);
const deadlineMs = Number.parseInt(process.env.ADMIN_REGISTRY_QA_TIMEOUT_MS || "20000", 10);
const inviteToken = process.env.HIRAETH_ADMIN_INVITE_TOKEN || "";
const viewports = [
  {name: "desktop", width: 1280, height: 960, required: true},
  {name: "tablet", width: 768, height: 1024, required: false},
  {name: "mobile", width: 390, height: 844, mobile: true, required: false}
];

if (!baseUrl || !screenshotPath) {
  console.error("usage: admin_registry_qa.mjs <base-url> <screenshot-png>");
  process.exit(2);
}

const parsedBase = new URL(baseUrl);
const localHosts = new Set(["127.0.0.1", "localhost", "::1"]);
if (!localHosts.has(parsedBase.hostname)) {
  console.error("admin registry QA only accepts local targets by default");
  process.exit(2);
}

const receiptPath = `${screenshotPath}.json`;
await mkdir(dirname(screenshotPath), {recursive: true});
let browser;
let client;
let lastRunReceipt;

function viewportScreenshotPath(viewport) {
  if (viewport.required) return screenshotPath;
  const ext = extname(screenshotPath) || ".png";
  return join(dirname(screenshotPath), `${basename(screenshotPath, ext)}-${viewport.name}${ext}`);
}

async function captureViewport(viewport) {
  await setViewport(client, viewport);
  await delay(300);
  const probe = await pageProbe(client);
  const path = viewportScreenshotPath(viewport);
  await captureScreenshot(client, path);
  return {name: viewport.name, required: viewport.required, viewport, screenshotPath: path, probe};
}

async function runQa() {
  browser = await launchBrowser({chromeBin, debugPort});
  const pageWs = await browser.waitForPageWebSocket();
  client = new CdpClient(pageWs);
  await client.connect();
  await client.send("Page.enable");
  await client.send("Runtime.enable");
  await setViewport(client, viewports[0]);

  if (inviteToken) {
    await navigateAndWait(client, parsedBase, `/admin/session/${encodeURIComponent(inviteToken)}`, "body");
  }

  const finalUrl = await navigateAndWait(client, parsedBase, "/admin/ingestion", "body");
  await delay(800);
  const selectedProvider = await selectSeededProvider(client);
  const beforeClickProbe = await pageProbe(client);
  const clickResult = await clickFirstScheduleControl(client);
  const probe = await pageProbe(client);
  const desktopCapture = await captureViewport(viewports[0]);
  const additionalCaptures = [];

  for (const viewport of viewports.slice(1)) {
    additionalCaptures.push(await captureViewport(viewport));
  }

  const passed = Boolean(
    probe.hasShell && probe.hasRegistry && probe.hasTimeline && probe.hasPauseOrResume &&
    probe.pauseOrResumeVisibleInViewport && selectedProvider.selected &&
    probe.hasFunctionalArtifactLink && clickResult.clicked && clickResult.afterId
  );
  lastRunReceipt = {
    passed,
    baseUrl,
    finalUrl,
    screenshotPath,
    receiptPath,
    authenticatedWithInvite: Boolean(inviteToken),
    selectedProvider,
    beforeClickProbe,
    clickResult,
    probe,
    viewportCaptures: [desktopCapture, ...additionalCaptures],
    visualQaScope: {
      acceptanceGate: "desktop functional Chromium QA",
      supplementalCaptures: additionalCaptures.map(capture => capture.name),
      note: "Tablet/mobile screenshots and DOM probes are recorded for DESIGN.md breadth; T19 acceptance remains the desktop operator workflow gate."
    }
  };

  if (!passed) {
    throw new Error(`admin registry UI markers, visibility, artifact link, or schedule click failed; finalUrl=${probe.url}`);
  }
}

let exitCode = 0;
let failure;
try {
  await Promise.race([
    runQa(),
    delay(deadlineMs).then(() => { throw new Error(`admin registry QA timed out after ${deadlineMs}ms`); })
  ]);
} catch (error) {
  exitCode = 1;
  failure = error;
  try {
    if (client) await captureScreenshot(client, screenshotPath);
  } catch (_screenshotError) {
  }
} finally {
  const cleanup = browser ? await browser.cleanup(client) : {userDataDirRemoved: false, chromeTerminated: false};
  const receipt = lastRunReceipt || {
    passed: false,
    baseUrl,
    screenshotPath,
    receiptPath,
    authenticatedWithInvite: Boolean(inviteToken)
  };
  await writeFile(receiptPath, JSON.stringify({
    ...receipt,
    passed: exitCode === 0 && Boolean(receipt.passed),
    cleanup,
    error: failure?.message,
    chromeStderrTail: browser?.stderr.join("").slice(-1200)
  }, null, 2));
}

if (failure) console.error(failure);
if (exitCode !== 0) process.exit(exitCode);
