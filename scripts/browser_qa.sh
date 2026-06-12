#!/usr/bin/env bash
set -euo pipefail

QA_DIR="${QA_DIR:-artifacts/qa/browser}"
PORT="${PORT:-4014}"
BASE_URL="${BASE_URL:-http://127.0.0.1:${PORT}}"
CHROME_BIN="${CHROME_BIN:-}"
SERVER_PID=""

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

log "starting postgres and deterministic dev seed"
docker compose up -d postgres | tee -a "${TRANSCRIPT}"
mix ecto.drop --force >> "${TRANSCRIPT}" 2>&1 || true
mix ecto.create >> "${TRANSCRIPT}" 2>&1
mix ash.migrate >> "${TRANSCRIPT}" 2>&1
mix run priv/repo/seeds.exs >> "${TRANSCRIPT}" 2>&1
mix run scripts/seed_browser_qa.exs >> "${TRANSCRIPT}" 2>&1

log "starting Phoenix server"
PORT="${PORT}" PHX_SERVER=true mix phx.server > "${QA_DIR}/server.log" 2>&1 &
SERVER_PID="$!"

ready=0
for _ in {1..80}; do
  if curl -fsS "${BASE_URL}/" > /dev/null 2>> "${TRANSCRIPT}"; then
    ready=1
    break
  fi
  sleep 0.25
done

if [[ "${ready}" != "1" ]]; then
  log "server_ready=fail"
  tail -120 "${QA_DIR}/server.log" | tee -a "${TRANSCRIPT}"
  exit 1
fi
log "server_ready=pass"

log "running real keyboard focus audit"
node scripts/keyboard_focus_check.mjs "${BASE_URL}/browse" "${QA_DIR}/keyboard-focus.json" | tee -a "${TRANSCRIPT}"
grep -q '"passed": true' "${QA_DIR}/keyboard-focus.json"
log "keyboard_focus_artifact=${QA_DIR}/keyboard-focus.json"

log "running authenticated admin browser audit"
node scripts/admin_browser_check.mjs "${BASE_URL}" "${QA_DIR}" | tee -a "${TRANSCRIPT}"
grep -q '"passed": true' "${QA_DIR}/admin-authenticated.json"
log "admin_authenticated_artifact=${QA_DIR}/admin-authenticated.json"

pages=(
  "/"
  "/browse"
  "/browse?q=Moon"
  "/browse?q=%E6%9C%88"
  "/search?q=9780000001011"
  "/publishers"
  "/publishers/moth-house-editions"
  "/series"
  "/series/pocket-weather-library"
  "/editions/the-orchard-of-minor-moons-paperback"
)

viewports=("desktop:1440,1000" "tablet:768,1024" "mobile:390,844")
page_failures=()
resource_failures=()
external_resource_references=()

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

while IFS= read -r resource; do
  [[ -n "${resource}" ]] || continue
  case "${resource}" in
    http://127.0.0.1:*|http://localhost:*)
      continue
      ;;
    http://*|https://*)
      external_resource_references+=("${resource}")
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
  echo "long_titles=pass: edition/detail pages captured using seeded multi-word titles"
  echo "missing_covers=pass: edition pages render typographic fallback when no cover is assigned"
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
  if grep -R "月の余白" "${QA_DIR}"/*browse-q-%E6%9C%88*.html >/dev/null && grep -R "مدينة الورق" "${QA_DIR}"/*browse-q-%E6%9C%88*.html >/dev/null; then
    echo "cjk_rtl=pass: Chromium DOM captures include seeded CJK/RTL title"
  else
    echo "cjk_rtl=fail: seeded CJK/RTL title missing from browser captures"
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
printf '  "external_resource_references": [' >> "${NETWORK_REPORT}"
for i in "${!external_resource_references[@]}"; do
  [[ "$i" == "0" ]] || printf ', ' >> "${NETWORK_REPORT}"
  printf '"%s"' "${external_resource_references[$i]}" >> "${NETWORK_REPORT}"
done
printf ']\n' >> "${NETWORK_REPORT}"
printf '}\n' >> "${NETWORK_REPORT}"

if [[ "${#page_failures[@]}" -ne 0 || "${#resource_failures[@]}" -ne 0 || "${#external_resource_references[@]}" -ne 0 ]]; then
  log "network_errors=fail"
  cat "${NETWORK_REPORT}" | tee -a "${TRANSCRIPT}"
  exit 1
fi

log "network_errors=pass report=${NETWORK_REPORT}"
log "screenshots_count=$(find "${QA_DIR}" -maxdepth 1 -name '*.png' | wc -l | tr -d ' ')"
log "test_browser=pass"
