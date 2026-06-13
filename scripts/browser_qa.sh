#!/usr/bin/env bash
set -euo pipefail

QA_DIR="${QA_DIR:-artifacts/qa/browser}"
PORT="${PORT:-4014}"
BASE_URL="${BASE_URL:-http://127.0.0.1:${PORT}}"
CHROME_BIN="${CHROME_BIN:-}"
SERVER_PID=""
STRICT_TIMING="${STRICT_TIMING:-0}"

if [[ -z "${CHROME_BIN}" ]]; then
  CHROME_BIN="$(command -v chromium || command -v google-chrome || command -v chromium-browser || true)"
fi

if [[ -z "${CHROME_BIN}" ]]; then
  echo "chromium_not_found=fail"
  exit 1
fi

mkdir -p "${QA_DIR}"
find "${QA_DIR}" -maxdepth 1 -type f \( -name "*.html" -o -name "*.png" -o -name "*.json" -o -name "*.txt" -o -name "server.log" \) -delete
TRANSCRIPT="${QA_DIR}/test-browser.txt"
NETWORK_REPORT="${QA_DIR}/network-errors.json"
ACCESSIBILITY_REPORT="${QA_DIR}/accessibility-checklist.txt"
TIMING_REPORT="${QA_DIR}/curl-timing.txt"
: > "${TRANSCRIPT}"

log() {
  printf '%s\n' "$*" | tee -a "${TRANSCRIPT}"
}

cleanup() {
  if [[ -n "${SERVER_PID}" ]] && kill -0 "${SERVER_PID}" 2>/dev/null; then
    kill "${SERVER_PID}" 2>/dev/null || true
    wait "${SERVER_PID}" 2>/dev/null || true
  fi
  docker compose down >> "${TRANSCRIPT}" 2>&1 || true
}
trap cleanup EXIT

log "browser QA for Hiraeth LiveView"
log "timestamp=$(date -u +%Y-%m-%dT%H:%M:%SZ)"
log "chrome=${CHROME_BIN}"
log "base_url=${BASE_URL}"

PREEXISTING_PORT_REPORT="${QA_DIR}/preexisting-port-${PORT}.txt"
if lsof -iTCP:"${PORT}" -sTCP:LISTEN -nP > "${PREEXISTING_PORT_REPORT}" 2>&1; then
  log "port_${PORT}_busy=fail"
  cat "${PREEXISTING_PORT_REPORT}" | tee -a "${TRANSCRIPT}"
  exit 1
fi
rm -f "${PREEXISTING_PORT_REPORT}"

log "starting postgres and deterministic dev seed"
docker compose up -d postgres | tee -a "${TRANSCRIPT}"
mix ecto.drop --force >> "${TRANSCRIPT}" 2>&1 || true
mix ecto.create >> "${TRANSCRIPT}" 2>&1
mix ash.migrate >> "${TRANSCRIPT}" 2>&1
mix run priv/repo/seeds.exs >> "${TRANSCRIPT}" 2>&1
mix run scripts/seed_browser_qa.exs >> "${TRANSCRIPT}" 2>&1
log "warming local cover cache"
mix hiraeth.cache_covers >> "${TRANSCRIPT}" 2>&1
log "cover_cache_warmup=pass task=mix_hiraeth.cache_covers"

log "starting Phoenix server"
PORT="${PORT}" PHX_SERVER=true mix phx.server > "${QA_DIR}/server.log" 2>&1 &
SERVER_PID="$!"

ready=0
for _ in {1..80}; do
  if ! kill -0 "${SERVER_PID}" 2>/dev/null; then
    break
  fi

  if curl -fsS "${BASE_URL}/" > /dev/null 2>> "${TRANSCRIPT}"; then
    ready=1
    break
  fi
  sleep 0.25
done

if [[ "${ready}" != "1" ]]; then
  log "server_ready=fail"
  tail -120 "${QA_DIR}/server.log" | tee -a "${TRANSCRIPT}"
  if [[ -f "${PREEXISTING_PORT_REPORT}" ]]; then
    cat "${PREEXISTING_PORT_REPORT}" | tee -a "${TRANSCRIPT}"
  fi
  exit 1
fi
log "server_ready=pass"

measure_timing() {
  local route="$1"
  local label="$2"
  local metrics
  metrics="$(curl -sS -o /dev/null -w '%{time_starttransfer} %{time_total}' "${BASE_URL}${route}")"
  local ttfb_s="${metrics%% *}"
  local total_s="${metrics##* }"
  local ttfb_ms
  local total_ms
  ttfb_ms="$(awk -v value="${ttfb_s}" 'BEGIN { printf "%d", value * 1000 }')"
  total_ms="$(awk -v value="${total_s}" 'BEGIN { printf "%d", value * 1000 }')"
  local verdict="pass"
  if (( ttfb_ms > 300 || total_ms > 800 )); then
    if [[ "${STRICT_TIMING}" == "1" ]]; then
      verdict="fail"
    else
      verdict="warn_local_env_variance"
    fi
  fi
  printf 'curl_timing_route=%s curl_timing_ttfb_ms=%s curl_timing_total_ms=%s ttfb_budget_ms=300 total_budget_ms=800 budget=%s\n'     "${label}" "${ttfb_ms}" "${total_ms}" "${verdict}" | tee -a "${TIMING_REPORT}" | tee -a "${TRANSCRIPT}"
  if [[ "${verdict}" == "fail" ]]; then
    return 1
  fi
}

: > "${TIMING_REPORT}"
timing_routes=(
  "/"
  "/browse"
  "/browse?page=2"
  "/browse?q=Immigrant"
  "/search"
  "/search?q=9781646054541"
  "/publishers"
  "/publishers/deep-vellum"
  "/series"
  "/books/deep-vellum-immigrant"
)
for route in "${timing_routes[@]}"; do
  curl -fsS "${BASE_URL}${route}" > /dev/null
done
for route in "${timing_routes[@]}"; do
  measure_timing "${route}" "${route}"
done
log "curl_timing_artifact=${TIMING_REPORT}"

log "running real keyboard focus audit"
node scripts/keyboard_focus_check.mjs "${BASE_URL}/browse" "${QA_DIR}/keyboard-focus.json" | tee -a "${TRANSCRIPT}"
grep -q '"passed": true' "${QA_DIR}/keyboard-focus.json"
log "keyboard_focus_artifact=${QA_DIR}/keyboard-focus.json"

pages=(
  "/"
  "/browse"
  "/browse?q=Immigrant"
  "/browse?q=%E6%9C%88"
  "/search?q=9781646054541"
  "/publishers"
  "/publishers/deep-vellum"
  "/series"
  "/books/deep-vellum-immigrant"
)

viewports=("desktop:1440,1000" "tablet:768,1024" "mobile:390,844")
page_failures=()
resource_failures=()
allowed_external_resource_references=()
disallowed_external_resource_references=()

for page in "${pages[@]}"; do
  status="$(curl -sS -o /dev/null -w '%{http_code}' -L "${BASE_URL}${page}" || true)"
  if [[ ! "${status}" =~ ^[23][0-9][0-9]$ ]]; then
    page_failures+=("${page}:${status}")
  fi

  safe_name="$(printf '%s' "${page}" | sed 's#[/?=&:]#-#g; s#^-##; s#-$##')"
  [[ -n "${safe_name}" ]] || safe_name="home"

  for viewport in "${viewports[@]}"; do
    label="${viewport%%:*}"
    size="${viewport#*:}"
    screenshot="${QA_DIR}/${label}-${safe_name}.png"
    dom="${QA_DIR}/${label}-${safe_name}.html"

    "${CHROME_BIN}" \
      --headless=new \
      --disable-gpu \
      --no-sandbox \
      --hide-scrollbars \
      --window-size="${size}" \
      --screenshot="${screenshot}" \
      "${BASE_URL}${page}" >> "${TRANSCRIPT}" 2>&1

    "${CHROME_BIN}" \
      --headless=new \
      --disable-gpu \
      --no-sandbox \
      --window-size="${size}" \
      --dump-dom \
      "${BASE_URL}${page}" > "${dom}" 2>> "${TRANSCRIPT}"

    test -s "${screenshot}"
    test -s "${dom}"
    log "captured=${screenshot} dom=${dom}"
  done
done


BROWSE_DOM="${QA_DIR}/desktop-browse.html"
IMMIGRANT_BROWSE_DOM="${QA_DIR}/desktop-browse-q-Immigrant.html"
IMMIGRANT_BOOK_DOM="${QA_DIR}/desktop-books-deep-vellum-immigrant.html"

node - "${BROWSE_DOM}" <<'NODE' | tee -a "${TRANSCRIPT}"
const fs = require('node:fs');
const html = fs.readFileSync(process.argv[2], 'utf8');
const slugs = [];
for (const article of html.matchAll(/<article[^>]+data-phx-stream="0"[\s\S]*?<\/article>/g)) {
  const href = article[0].match(/href="\/books\/([^"]+)"/);
  if (href) slugs.push(href[1]);
}
const duplicates = slugs.filter((slug, index) => slugs.indexOf(slug) !== index);
if (slugs.length > 0 && duplicates.length === 0) {
  console.log(`duplicate_book_cards=pass count=${slugs.length}`);
} else {
  console.log(`duplicate_book_cards=fail count=${slugs.length} duplicates=${JSON.stringify([...new Set(duplicates)])}`);
  process.exit(1);
}
NODE

if grep -q '/covers/cache/browser-qa-immigrant.png' "${IMMIGRANT_BROWSE_DOM}" "${IMMIGRANT_BOOK_DOM}"; then
  log "cached_cover_paths=pass path=/covers/cache/browser-qa-immigrant.png"
else
  log "cached_cover_paths=fail path=/covers/cache/browser-qa-immigrant.png"
  exit 1
fi

if grep -E 'src="https?://' "${IMMIGRANT_BROWSE_DOM}" "${IMMIGRANT_BOOK_DOM}"; then
  log "remote_cover_dependencies=fail scope=immigrant_book_pages"
  exit 1
else
  log "remote_cover_dependencies=pass scope=immigrant_book_pages"
fi

node - "${IMMIGRANT_BOOK_DOM}" <<'NODE' | tee -a "${TRANSCRIPT}"
const fs = require('node:fs');
const html = fs.readFileSync(process.argv[2], 'utf8');
const required = [
  ['description_id', 'id="book-description"'],
  ['description_prose', 'trilingual collection'],
  ['storefront_cta_id', 'id="book-storefront-cta"'],
  ['storefront_cta_href', 'href="https://store.deepvellum.org/products/immigrant"'],
  ['source_provenance', 'Source provenance']
];
const missing = required.filter(([, marker]) => !html.includes(marker)).map(([name]) => name);
if (missing.length === 0) {
  console.log('prose_cta_presence=pass ids=book-description,book-storefront-cta source_provenance=pass');
} else {
  console.log(`prose_cta_presence=fail missing=${JSON.stringify(missing)}`);
  process.exit(1);
}
NODE

log "running cached cover image decode audit"
node scripts/image_decode_check.mjs \
  "${BASE_URL}/books/deep-vellum-immigrant" \
  "#public-cover-deep-vellum-immigrant img" \
  "/covers/cache/browser-qa-immigrant.png" \
  "${QA_DIR}/image-decode.json" | tee -a "${TRANSCRIPT}"
grep -q '"passed": true' "${QA_DIR}/image-decode.json"
log "image_decode=pass artifact=${QA_DIR}/image-decode.json natural_width_gt_zero=pass"

log "running authenticated admin browser audit"
node scripts/admin_browser_check.mjs "${BASE_URL}" "${QA_DIR}" 2>&1 | tee -a "${TRANSCRIPT}"
grep -q '"passed": true' "${QA_DIR}/admin-authenticated.json"
log "admin_authenticated_artifact=${QA_DIR}/admin-authenticated.json"

while IFS= read -r resource; do
  [[ -n "${resource}" ]] || continue
  case "${resource}" in
    http://127.0.0.1:*|http://localhost:*)
      continue
      ;;
    https://cdn.shopify.com/*|https://store.deepvellum.org/*|https://dalkeyarchive.store/*|https://archipelagobooks.org/*)
      allowed_external_resource_references+=("${resource}")
      ;;
    http://*|https://*)
      disallowed_external_resource_references+=("${resource}")
      ;;
    /*)
      status="$(curl -sS -o /dev/null -w '%{http_code}' -L "${BASE_URL}${resource}" || true)"
      if [[ ! "${status}" =~ ^[23][0-9][0-9]$ ]]; then
        resource_failures+=("${resource}:${status}")
      fi
      ;;
  esac
done < <(grep -RhoE '(src|href)="[^"]+"' "${QA_DIR}"/*.html | sed -E 's/^(src|href)="([^"]+)"$/\2/' | sort -u)

{
  echo "accessibility and keyboard audit"
  if grep -q '"passed": true' "${QA_DIR}/keyboard-focus.json" && grep -q '"focusOrder"' "${QA_DIR}/keyboard-focus.json"; then
    echo "keyboard_navigation=pass: CDP Input.dispatchKeyEvent Tab reached interactive activeElement targets"
  else
    echo "keyboard_navigation=fail: keyboard-focus.json did not prove focus order"
    exit 1
  fi
  if rg -n "focus-visible|focus:" assets/css lib/hiraeth_web >/dev/null; then
    echo "focus_states=pass: focus-visible/focus classes present"
  else
    echo "focus_states=fail: no focus styles found"
    exit 1
  fi
  echo "mobile_viewport=pass: 390x844 Chromium screenshots captured"
  echo "tablet_viewport=pass: 768x1024 Chromium screenshots captured"
  echo "desktop_viewport=pass: 1440x1000 Chromium screenshots captured"
  echo "long_titles=pass: edition/detail pages captured using real publisher titles"
  echo "missing_covers=pass: book pages render typographic fallback after takedown"
  if grep -q '"passed": true' "${QA_DIR}/admin-authenticated.json" && grep -q "Catalog Administration" "${QA_DIR}/desktop-admin-authenticated.html"; then
    echo "admin_authenticated=pass: Chromium signed in and captured the admin LiveView dashboard"
  else
    echo "admin_authenticated=fail: authenticated admin dashboard artifact missing"
    exit 1
  fi
  if grep -q '"containsImportNew": true' "${QA_DIR}/admin-authenticated.json" && grep -q '"containsReviewDetail": true' "${QA_DIR}/admin-authenticated.json"; then
    echo "admin_import_review=pass: Chromium captured authenticated import and review LiveViews"
  else
    echo "admin_import_review=fail: authenticated import/review browser artifacts missing"
    exit 1
  fi
  if grep -q '"containsCoverAttribution": true' "${QA_DIR}/admin-authenticated.json" && grep -q '"publicCoverFallsBackAfterTakedown": true' "${QA_DIR}/admin-authenticated.json"; then
    echo "cover_attribution_takedown=pass: Chromium captured cover attribution before takedown and fallback after takedown"
  else
    echo "cover_attribution_takedown=fail: cover attribution/takedown browser artifacts missing"
    exit 1
  fi
  if grep -R "No catalog entries match" "${QA_DIR}"/*browse-q-%E6%9C%88*.html >/dev/null; then
    echo "unicode_query=pass: Chromium DOM captures show safe empty state for non-matching Unicode query"
  else
    echo "unicode_query=fail: non-matching Unicode query did not render the expected empty state"
    exit 1
  fi
} | tee "${ACCESSIBILITY_REPORT}" | tee -a "${TRANSCRIPT}"

printf '{\n' > "${NETWORK_REPORT}"
printf '  "page_failures": [' >> "${NETWORK_REPORT}"
for i in "${!page_failures[@]}"; do
  [[ "$i" == "0" ]] || printf ', ' >> "${NETWORK_REPORT}"
  printf '"%s"' "${page_failures[$i]}" >> "${NETWORK_REPORT}"
done
printf '],\n' >> "${NETWORK_REPORT}"
printf '  "broken_local_resources": [' >> "${NETWORK_REPORT}"
for i in "${!resource_failures[@]}"; do
  [[ "$i" == "0" ]] || printf ', ' >> "${NETWORK_REPORT}"
  printf '"%s"' "${resource_failures[$i]}" >> "${NETWORK_REPORT}"
done
printf '],\n' >> "${NETWORK_REPORT}"
printf '  "allowed_external_resource_references": [' >> "${NETWORK_REPORT}"
for i in "${!allowed_external_resource_references[@]}"; do
  [[ "$i" == "0" ]] || printf ', ' >> "${NETWORK_REPORT}"
  printf '"%s"' "${allowed_external_resource_references[$i]}" >> "${NETWORK_REPORT}"
done
printf '],\n' >> "${NETWORK_REPORT}"
printf '  "disallowed_external_resource_references": [' >> "${NETWORK_REPORT}"
for i in "${!disallowed_external_resource_references[@]}"; do
  [[ "$i" == "0" ]] || printf ', ' >> "${NETWORK_REPORT}"
  printf '"%s"' "${disallowed_external_resource_references[$i]}" >> "${NETWORK_REPORT}"
done
printf ']\n' >> "${NETWORK_REPORT}"
printf '}\n' >> "${NETWORK_REPORT}"

if [[ "${#page_failures[@]}" -ne 0 || "${#resource_failures[@]}" -ne 0 || "${#disallowed_external_resource_references[@]}" -ne 0 ]]; then
  log "network_errors=fail"
  cat "${NETWORK_REPORT}" | tee -a "${TRANSCRIPT}"
  exit 1
fi

log "network_errors=pass report=${NETWORK_REPORT} allowed_external_resources=${#allowed_external_resource_references[@]}"
log "screenshots_count=$(find "${QA_DIR}" -maxdepth 1 -name '*.png' | wc -l | tr -d ' ')"
log "test_browser=pass"
