import {delay} from "./admin_registry_cdp_helpers.mjs";

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


async function waitFor(client, expression, attempts = 80) {
  let last;
  for (let attempt = 0; attempt < attempts; attempt += 1) {
    last = await evaluateValue(client, expression);
    if (last?.ok) return last;
    await delay(125);
  }
  return last || {ok: false, reason: "condition never evaluated"};
}

export async function quarantineProbe(client) {
  return evaluateValue(client, `(() => {
    const controlIds = ['button[id^="admin-retry-run-"]', 'button[id^="admin-replay-run-"]', 'button[id^="admin-cancel-run-"]', 'a[id^="admin-export-run-"]'];
    const firstControl = document.querySelector(controlIds.join(','));
    const rect = firstControl?.getBoundingClientRect();
    const text = document.body.innerText;
    const externalImages = Array.from(document.images).filter(img => !new URL(img.currentSrc || img.src, location.href).pathname.startsWith('/covers/cache/'));
    return {
      title: document.title,
      url: location.href,
      viewport: {width: innerWidth, height: innerHeight},
      hasShell: Boolean(document.querySelector('#admin-quarantine-shell')),
      hasRunControls: Boolean(document.querySelector('#admin-run-control-panel')),
      hasCandidateReview: Boolean(document.querySelector('#admin-candidate-review-panel')),
      hasReasonInput: Boolean(document.querySelector('[id^="admin-review-reason-"]')),
      hasDecisionButtons: Boolean(document.querySelector('[id^="admin-approve-candidate-"]')),
      hasEnabledRetry: Boolean(document.querySelector('button[id^="admin-retry-run-"]:not([disabled])')),
      hasEnabledReplay: Boolean(document.querySelector('button[id^="admin-replay-run-"]:not([disabled])')),
      hasExportLink: Boolean(document.querySelector('a[id^="admin-export-run-"][href^="/admin/ingestion/audit/"]')),
      hasExplicitDestructiveApproval: Boolean(document.querySelector('[id^="admin-approve-destructive-"]')),
      noRawScriptText: !document.body.innerHTML.includes('<script>Archive</script>'),
      externalImageCount: externalImages.length,
      firstControlVisible: Boolean(firstControl && rect && rect.width > 0 && rect.height > 0 && rect.left >= 0 && rect.top >= 0 && rect.right <= innerWidth),
      textSample: text.slice(0, 600)
    };
  })()`);
}

export async function approveFirstCandidate(client) {
  const started = await evaluateValue(client, `(() => {
    const form = document.querySelector('[id^="admin-review-form-"]');
    if (!form) return {attempted: false, reason: 'missing review form'};
    const candidateId = form.id.replace('admin-review-form-', '');
    const reason = form.querySelector('[id^="admin-review-reason-"]');
    const approve = form.querySelector('[id^="admin-approve-candidate-"]');
    if (!reason || !approve) return {attempted: false, candidateId, reason: 'missing reason or approve control'};
    return {attempted: true, candidateId, destructiveApprovalPresent: Boolean(form.querySelector('[id^="admin-approve-destructive-"]'))};
  })()`);

  if (!started.attempted) return {...started, approved: false};

  const reasonClick = await trustedClick(client, `#admin-review-reason-${started.candidateId}`);
  if (!reasonClick.ok) return {...started, approved: false, reasonClick};
  await client.send("Input.insertText", {text: "browser qa approved seeded quarantine candidate"});

  let destructiveClick = {ok: true, skipped: true};
  if (started.destructiveApprovalPresent) {
    destructiveClick = await trustedClick(client, `#admin-approve-destructive-${started.candidateId}`);
    if (!destructiveClick.ok) return {...started, approved: false, reasonClick, destructiveClick};
  }

  const approveClick = await trustedClick(client, `#admin-approve-candidate-${started.candidateId}`);
  if (!approveClick.ok) return {...started, approved: false, reasonClick, destructiveClick, approveClick};

  const settled = await waitFor(client, `(() => {
    const article = document.querySelector('#admin-candidates-${started.candidateId}') || document.querySelector('#admin-quarantine-candidates');
    const text = article?.innerText || document.body.innerText;
    const body = document.body.innerText;
    return {ok: text.includes('approved') || body.includes('Candidate approve recorded.'), textSample: text.slice(0, 300), bodySample: body.slice(0, 500)};
  })()`);

  return {...started, destructiveApprovalChecked: started.destructiveApprovalPresent && destructiveClick.ok, approved: Boolean(settled.ok), reasonClick, destructiveClick, approveClick, settled};
}

export async function clickRunControl(client, controlPrefix, expectedText) {
  const clicked = await evaluateValue(client, `(() => {
    const control = document.querySelector('button[id^="${controlPrefix}"]:not([disabled])');
    if (!control) return {clicked: false, reason: 'missing enabled ${controlPrefix}'};
    control.click();
    return {clicked: true, controlId: control.id, beforeText: document.body.innerText.slice(0, 300)};
  })()`);

  if (!clicked.clicked) return clicked;

  const settled = await waitFor(client, `(() => {
    const text = document.body.innerText;
    return {ok: text.includes(${JSON.stringify(expectedText)}), textSample: text.slice(0, 300)};
  })()`);

  return {...clicked, feedbackObserved: Boolean(settled.ok), settled};
}

export async function fetchAuditExport(client) {
  return evaluateValue(client, `(async () => {
    const link = document.querySelector('a[id^="admin-export-run-"][href^="/admin/ingestion/audit/"]');
    if (!link) return {requested: false, reason: 'missing export link'};
    const href = link.getAttribute('href');
    if (href.includes('..') || href.startsWith('#')) return {requested: false, href, reason: 'unsafe export href'};
    const response = await fetch(href);
    const contentType = response.headers.get('content-type') || '';
    const payload = contentType.includes('application/json') ? await response.json() : null;
    return {
      requested: true,
      href,
      status: response.status,
      ok: response.ok,
      contentType,
      hasMetadata: Boolean(payload?.metadata),
      complete: payload?.metadata?.['complete?'] === true,
      truncated: payload?.metadata?.['truncated?'] === true,
      candidateCount: payload?.candidates?.length || 0,
      eventCount: payload?.events?.length || 0,
      artifactCount: payload?.artifacts?.length || 0,
      rowCounts: payload?.metadata?.row_counts || null
    };
  })()`);
}
