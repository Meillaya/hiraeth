import {delay} from "./admin_registry_cdp_helpers.mjs";

const SEEDED_PROVIDER_NAME = "T19 Browser QA Press";
const selectedControlSelector = "[id^=\"admin-selected-pause-provider-\"], [id^=\"admin-selected-resume-provider-\"]";
const rowControlSelector = "[id^=\"admin-pause-provider-\"], [id^=\"admin-resume-provider-\"]";

async function evaluateValue(client, expression) {
  const result = await client.send("Runtime.evaluate", {expression, returnByValue: true, awaitPromise: true});
  return result.result.value;
}

async function trustedClick(client, selector) {
  const target = await evaluateValue(client, `(() => {
    const element = document.querySelector(${JSON.stringify(selector)});
    if (!element) return {ok: false, reason: 'missing click target'};
    element.scrollIntoView({block: 'center', inline: 'center'});
    const rect = element.getBoundingClientRect();
    return {ok: true, x: rect.left + rect.width / 2, y: rect.top + rect.height / 2};
  })()`);
  if (!target.ok) return target;
  await client.send("Input.dispatchMouseEvent", {type: "mousePressed", x: target.x, y: target.y, button: "left", clickCount: 1});
  await client.send("Input.dispatchMouseEvent", {type: "mouseReleased", x: target.x, y: target.y, button: "left", clickCount: 1});
  return target;
}

export async function setViewport(client, viewport) {
  await client.send("Emulation.setDeviceMetricsOverride", {
    width: viewport.width,
    height: viewport.height,
    deviceScaleFactor: viewport.deviceScaleFactor || 1,
    mobile: Boolean(viewport.mobile)
  });
}

export async function navigateAndWait(client, parsedBase, path, selector) {
  const url = new URL(path, parsedBase).toString();
  await client.send("Page.navigate", {url});

  for (let attempt = 0; attempt < 80; attempt += 1) {
    const value = await evaluateValue(client, `(() => ({readyState: document.readyState, href: location.href, hasSelector: Boolean(document.querySelector(${JSON.stringify(selector)}))}))()`);
    if (value.readyState === "complete" && value.hasSelector) return value.href;
    await delay(125);
  }

  throw new Error(`Timed out waiting for ${selector} at ${url}`);
}

export async function pageProbe(client) {
  return evaluateValue(client, `(() => {
    const text = document.body.innerText;
    const providerRow = Array.from(document.querySelectorAll('[id^="providers-"]'))
      .reverse()
      .find(candidate => candidate.textContent.includes(${JSON.stringify(SEEDED_PROVIDER_NAME)}));
    const control = document.querySelector('${selectedControlSelector}') || (providerRow || document).querySelector('${rowControlSelector}');
    const rect = control?.getBoundingClientRect();
    const style = control ? getComputedStyle(control) : null;
    const artifact = document.querySelector('[id^="admin-artifact-link-"]');
    const artifactHref = artifact?.getAttribute('href') || '';
    const controlVisible = Boolean(control && rect && rect.width > 0 && rect.height > 0 && rect.left >= 0 && rect.top >= 0 && rect.right <= window.innerWidth && rect.bottom <= window.innerHeight && style.visibility !== 'hidden' && style.display !== 'none');

    return {
      title: document.title,
      url: location.href,
      viewport: {width: window.innerWidth, height: window.innerHeight},
      hasShell: Boolean(document.querySelector('#admin-ingestion-shell')),
      hasRegistry: Boolean(document.querySelector('#admin-provider-registry')),
      hasTimeline: Boolean(document.querySelector('#admin-run-timeline')),
      hasPauseOrResume: Boolean(control),
      pauseOrResumeVisibleInViewport: controlVisible,
      pauseOrResumeId: control?.id || null,
      pauseOrResumeText: control?.textContent?.trim() || null,
      pauseOrResumeRect: rect ? {left: rect.left, top: rect.top, right: rect.right, bottom: rect.bottom, width: rect.width, height: rect.height} : null,
      hasFunctionalArtifactLink: artifactHref.startsWith('/admin/ingestion/artifacts/') && !artifactHref.startsWith('#'),
      artifactHref,
      providerRows: document.querySelectorAll('[id^="providers-"]').length,
      runRows: document.querySelectorAll('[id^="runs-"]').length,
      textSample: text.slice(0, 500)
    };
  })()`);
}

export async function clickFirstScheduleControl(client) {
  const before = await evaluateValue(client, `(() => {
    const providerRow = Array.from(document.querySelectorAll('[id^="providers-"]'))
      .reverse()
      .find(candidate => candidate.textContent.includes(${JSON.stringify(SEEDED_PROVIDER_NAME)}));
    const control = document.querySelector('${selectedControlSelector}') || (providerRow || document).querySelector('${rowControlSelector}');
    if (!control) return {clicked: false, reason: 'missing'};
    const beforeId = control.id;
    const beforeText = control.textContent.trim();
    return {clicked: true, beforeId, beforeText, selector: '#' + CSS.escape(beforeId)};
  })()`);

  if (!before.clicked) return before;
  const trustedClickResult = await trustedClick(client, before.selector);
  if (!trustedClickResult.ok) return {...before, clicked: false, trustedClickResult};

  for (let attempt = 0; attempt < 80; attempt += 1) {
    const after = await pageProbe(client);
    if (after.pauseOrResumeId && after.pauseOrResumeId !== before.beforeId) {
      return {...before, trustedClickResult, afterId: after.pauseOrResumeId, afterText: after.pauseOrResumeText};
    }
    await delay(125);
  }

  return {...before, trustedClickResult, afterId: null, afterText: null};
}

export async function selectSeededProvider(client) {
  for (let attempt = 0; attempt < 80; attempt += 1) {
    const value = await evaluateValue(client, `(() => {
      const link = Array.from(document.querySelectorAll('[id^="admin-provider-link-"]'))
        .reverse()
        .find(candidate => candidate.textContent.includes(${JSON.stringify(SEEDED_PROVIDER_NAME)}));
      if (!link) return {selected: false, reason: 'missing seeded provider'};
      link.click();
      return {selected: true, href: link.getAttribute('href'), text: link.textContent.trim()};
    })()`);

    if (value.selected) {
      for (let waitAttempt = 0; waitAttempt < 80; waitAttempt += 1) {
        const probe = await pageProbe(client);
        if (probe.hasFunctionalArtifactLink && probe.url.endsWith(value.href)) return value;
        await delay(125);
      }
      return {...value, selected: false, reason: 'selected provider route did not settle'};
    }

    await delay(125);
  }

  return {selected: false, reason: 'timed out waiting for seeded provider'};
}
