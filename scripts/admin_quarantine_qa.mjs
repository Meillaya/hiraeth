#!/usr/bin/env node
import {mkdir, writeFile} from "node:fs/promises";
import {basename, dirname, extname, join} from "node:path";
import {CdpClient, captureScreenshot, delay, launchBrowser} from "./admin_registry_cdp_helpers.mjs";
import {navigateAndWait, setViewport} from "./admin_registry_scenario_helpers.mjs";
import {approveFirstCandidate, clickRunControl, fetchAuditExport, quarantineProbe} from "./admin_quarantine_scenario_helpers.mjs";

const baseUrl = process.argv[2];
const screenshotPath = process.argv[3];
const chromeBin = process.env.CHROME_BIN || "chromium";
const debugPort = Number.parseInt(process.env.CHROME_ADMIN_QUARANTINE_DEBUG_PORT || "9238", 10);
const deadlineMs = Number.parseInt(process.env.ADMIN_QUARANTINE_QA_TIMEOUT_MS || "20000", 10);
const inviteToken = process.env.HIRAETH_ADMIN_INVITE_TOKEN || "";
const viewports = [
  {name: "desktop", width: 1280, height: 960, required: true},
  {name: "tablet", width: 768, height: 1024, required: false},
  {name: "mobile", width: 390, height: 844, mobile: true, required: false}
];

if (!baseUrl || !screenshotPath) {
  console.error("usage: admin_quarantine_qa.mjs <base-url> <screenshot-png>");
  process.exit(2);
}

const parsedBase = new URL(baseUrl);
if (!new Set(["127.0.0.1", "localhost", "::1"]).has(parsedBase.hostname)) {
  console.error("admin quarantine QA only accepts local targets by default");
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
  const probe = await quarantineProbe(client);
  const path = viewportScreenshotPath(viewport);
  await captureScreenshot(client, path);
  return {name: viewport.name, required: viewport.required, viewport, screenshotPath: path, probe};
}

async function runQa() {
  browser = await launchBrowser({chromeBin, debugPort});
  client = new CdpClient(await browser.waitForPageWebSocket());
  await client.connect();
  await client.send("Page.enable");
  await client.send("Runtime.enable");
  await setViewport(client, viewports[0]);

  if (inviteToken) {
    await navigateAndWait(client, parsedBase, `/admin/session/${encodeURIComponent(inviteToken)}`, "body");
  }

  const finalUrl = await navigateAndWait(client, parsedBase, "/admin/ingestion/quarantine", "body");
  await delay(800);
  const beforeProbe = await quarantineProbe(client);
  const approveResult = await approveFirstCandidate(client);
  const retryResult = await clickRunControl(client, "admin-retry-run-", "Retry job enqueued.");
  const replayResult = await clickRunControl(client, "admin-replay-run-", "Replay job enqueued.");
  const exportResult = await fetchAuditExport(client);
  const desktopCapture = await captureViewport(viewports[0]);
  const additionalCaptures = [];

  for (const viewport of viewports.slice(1)) additionalCaptures.push(await captureViewport(viewport));

  const probe = desktopCapture.probe;
  const passed = Boolean(
    probe.hasShell && probe.hasRunControls && probe.hasCandidateReview &&
    probe.hasReasonInput && probe.hasDecisionButtons && probe.hasExportLink &&
    beforeProbe.hasEnabledRetry && beforeProbe.hasEnabledReplay &&
    probe.firstControlVisible && probe.noRawScriptText && probe.externalImageCount === 0 &&
    approveResult.approved && retryResult.clicked && retryResult.feedbackObserved &&
    replayResult.clicked && replayResult.feedbackObserved && exportResult.ok &&
    exportResult.hasMetadata && exportResult.complete && !exportResult.truncated
  );
  lastRunReceipt = {
    passed,
    baseUrl,
    finalUrl,
    screenshotPath,
    receiptPath,
    authenticatedWithInvite: Boolean(inviteToken),
    requiredControls: {
      approve: probe.hasDecisionButtons,
      reason: probe.hasReasonInput,
      retry: beforeProbe.hasEnabledRetry,
      replay: beforeProbe.hasEnabledReplay,
      export: probe.hasExportLink,
      destructiveApprovalPresent: beforeProbe.hasExplicitDestructiveApproval
    },
    approveResult,
    retryResult,
    replayResult,
    exportResult,
    beforeProbe,
    probe,
    viewportCaptures: [desktopCapture, ...additionalCaptures]
  };
  if (!passed) throw new Error(`admin quarantine QA approve/retry/replay/export flow failed; finalUrl=${probe.url}`);
}

let exitCode = 0;
let failure;
try {
  await Promise.race([runQa(), delay(deadlineMs).then(() => { throw new Error(`admin quarantine QA timed out after ${deadlineMs}ms`); })]);
} catch (error) {
  exitCode = 1;
  failure = error;
  try { if (client) await captureScreenshot(client, screenshotPath); } catch (_error) {}
} finally {
  const cleanup = browser ? await browser.cleanup(client) : {userDataDirRemoved: false, chromeTerminated: false};
  const receipt = lastRunReceipt || {passed: false, baseUrl, screenshotPath, receiptPath, authenticatedWithInvite: Boolean(inviteToken)};
  await writeFile(receiptPath, JSON.stringify({...receipt, passed: exitCode === 0 && Boolean(receipt.passed), cleanup, error: failure?.message, chromeStderrTail: browser?.stderr.join("").slice(-1200)}, null, 2));
}

if (failure) console.error(failure);
if (exitCode !== 0) process.exit(exitCode);
