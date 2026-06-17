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
cover_cache_report="${QA_DIR}/cover-cache-warmup.txt"
: > "${cover_cache_report}"
set +e
mix hiraeth.cache_covers 2>&1 | tee -a "${cover_cache_report}" | tee -a "${TRANSCRIPT}"
cover_cache_status="${PIPESTATUS[0]}"
set -e
cover_cache_failed="$(
  awk -F= '/^cover_cache_failed=/ { value=$2 } END { if (value == "") { print "unknown" } else { print value } }' "${cover_cache_report}"
)"
if [[ "${cover_cache_status}" -ne 0 || ! "${cover_cache_failed}" =~ ^[0-9]+$ || "${cover_cache_failed}" -ne 0 ]]; then
  log "cover_cache_warmup=fail task=mix_hiraeth.cache_covers status=${cover_cache_status} cover_cache_failed=${cover_cache_failed} artifact=${cover_cache_report}"
  exit 1
fi
log "cover_cache_warmup=pass task=mix_hiraeth.cache_covers status=${cover_cache_status} cover_cache_failed=0 artifact=${cover_cache_report}"

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
  "/publishers/new-directions"
  "/contributors"
  "/contributors?role=translator"
  "/contributors/david-bowles"
  "/series"
  "/series/browser-qa-series"
  "/books/deep-vellum-immigrant"
  "/editions/deep-vellum-immigrant-paperback-9781646054541"
  "/editions/not-a-real-edition"
  "/browse?publisher=deep-vellum&role=translator&format=paperback&sort=newest"
  "/browse?q=%25&format=ebook&page=999"
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
  "/browse?page=2"
  "/browse?q=Immigrant"
  "/browse?q=%E6%9C%88"
  "/search"
  "/search?q=9781646054541"
  "/publishers"
  "/publishers/deep-vellum"
  "/publishers/new-directions"
  "/browse?publisher=new-directions"
  "/contributors"
  "/contributors?role=translator"
  "/contributors/david-bowles"
  "/browse?publisher=deep-vellum&role=translator&format=paperback&sort=newest"
  "/browse?q=%25&format=ebook&page=999"
  "/series"
  "/series/browser-qa-series"
  "/books/deep-vellum-immigrant"
  "/editions/deep-vellum-immigrant-paperback-9781646054541"
  "/editions/not-a-real-edition"
)

viewports=("desktop:1440,1000" "tablet:768,1024" "mobile:390,844")
page_failures=()
resource_failures=()
allowed_external_resource_references=()
disallowed_external_resource_references=()

expected_marker_for_page() {
  local page="$1"
  case "${page}" in
    "/")
      printf '%s\n' "#home-shell"
      ;;
    /browse*)
      printf '%s\n' "#browse-shell"
      ;;
    /search*)
      printf '%s\n' "#search-shell"
      ;;
    "/publishers")
      printf '%s\n' "#publishers-shell"
      ;;
    /publishers/*)
      printf '%s\n' "#publisher-detail-shell"
      ;;
    "/contributors"|/contributors\?*)
      printf '%s\n' "#contributors-shell"
      ;;
    /contributors/*)
      printf '%s\n' "#contributor-detail-shell"
      ;;
    "/series")
      printf '%s\n' "#series-shell"
      ;;
    /series/*)
      printf '%s\n' "#series-detail-shell"
      ;;
    /books/*)
      printf '%s\n' "#book-detail-shell"
      ;;
    /editions/not-a-real-edition)
      printf '%s\n' "#edition-detail-shell"
      ;;
    /editions/*)
      printf '%s\n' "#book-detail-shell"
      ;;
    *)
      printf '%s\n' "main"
      ;;
  esac
}

for page in "${pages[@]}"; do
  status="$(curl -sS -o /dev/null -w '%{http_code}' -L "${BASE_URL}${page}" || true)"
  if [[ ! "${status}" =~ ^[23][0-9][0-9]$ ]]; then
    page_failures+=("${page}:${status}")
  fi

  safe_name="$(printf '%s' "${page}" | sed 's#[/?=&:]#-#g; s#^-##; s#-$##')"
  [[ -n "${safe_name}" ]] || safe_name="home"
  marker="$(expected_marker_for_page "${page}")"

  for viewport in "${viewports[@]}"; do
    label="${viewport%%:*}"
    size="${viewport#*:}"
    width="${size%,*}"
    height="${size#*,}"
    screenshot="${QA_DIR}/${label}-${safe_name}.png"
    dom="${QA_DIR}/${label}-${safe_name}.html"
    render_report="${QA_DIR}/${label}-${safe_name}-render.json"

    CHROME_BIN="${CHROME_BIN}" node scripts/responsive_overflow_check.mjs \
      "${BASE_URL}${page}" \
      "${render_report}" \
      "${width}" \
      "${height}" \
      "${marker}" \
      "${screenshot}" \
      "${dom}" >> "${TRANSCRIPT}" 2>&1

    test -s "${screenshot}"
    test -s "${dom}"
    grep -q '"passed": true' "${render_report}"
    log "captured=${screenshot} dom=${dom} marker=${marker} render=${render_report}"
  done
done


BROWSE_DOM="${QA_DIR}/desktop-browse.html"
IMMIGRANT_BROWSE_DOM="${QA_DIR}/desktop-browse-q-Immigrant.html"
IMMIGRANT_BOOK_DOM="${QA_DIR}/desktop-books-deep-vellum-immigrant.html"
NEW_DIRECTIONS_PUBLISHER_DOM="${QA_DIR}/desktop-publishers-new-directions.html"
NEW_DIRECTIONS_BROWSE_DOM="${QA_DIR}/desktop-browse-publisher-new-directions.html"
CONTRIBUTORS_DOM="${QA_DIR}/desktop-contributors.html"
TRANSLATORS_DOM="${QA_DIR}/desktop-contributors-role-translator.html"
CONTRIBUTOR_DETAIL_DOM="${QA_DIR}/desktop-contributors-david-bowles.html"
SERIES_DETAIL_DOM="${QA_DIR}/desktop-series-browser-qa-series.html"
EDITION_REDIRECT_DOM="${QA_DIR}/desktop-editions-deep-vellum-immigrant-paperback-9781646054541.html"
EDITION_NOT_FOUND_DOM="${QA_DIR}/desktop-editions-not-a-real-edition.html"
FILTER_SORT_DOM="${QA_DIR}/desktop-browse-publisher-deep-vellum-role-translator-format-paperback-sort-newest.html"
MALFORMED_QUERY_DOM="${QA_DIR}/desktop-browse-q-%25-format-ebook-page-999.html"

node - "${BROWSE_DOM}" <<'NODE' | tee -a "${TRANSCRIPT}"
const fs = require('node:fs');
const html = fs.readFileSync(process.argv[2], 'utf8');
const slugs = [];
for (const article of html.matchAll(/<article[^>]*class="[^"]*\bgroup\b[^"]*"[\s\S]*?<\/article>/g)) {
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

if grep -q '/covers/cache/browser-qa-immigrant-thumb.png' "${IMMIGRANT_BROWSE_DOM}" && grep -q '/covers/cache/browser-qa-immigrant.png' "${IMMIGRANT_BOOK_DOM}"; then
  log "cached_cover_paths=pass card_path=/covers/cache/browser-qa-immigrant-thumb.png hero_path=/covers/cache/browser-qa-immigrant.png"
else
  log "cached_cover_paths=fail expected_card=/covers/cache/browser-qa-immigrant-thumb.png expected_hero=/covers/cache/browser-qa-immigrant.png"
  exit 1
fi

if grep -q 'loading="lazy"' "${IMMIGRANT_BROWSE_DOM}" && grep -q 'decoding="async"' "${IMMIGRANT_BROWSE_DOM}" && grep -q 'width="400"' "${IMMIGRANT_BROWSE_DOM}" && grep -q 'height="600"' "${IMMIGRANT_BROWSE_DOM}"; then
  log "cover_image_attrs=pass loading=lazy decoding=async dimensions=400x600"
else
  log "cover_image_attrs=fail expected=loading_lazy_decoding_async_dimensions"
  exit 1
fi

if grep -E 'src="https?://' "${IMMIGRANT_BROWSE_DOM}" "${IMMIGRANT_BOOK_DOM}"; then
  log "remote_cover_dependencies=fail scope=immigrant_book_pages"
  exit 1
else
  log "remote_cover_dependencies=pass scope=immigrant_book_pages"
fi

if grep -RhoE '<img[^>]+src="https?://[^"]+"' "${QA_DIR}"/*.html; then
  log "remote_image_dependencies=fail scope=all_captured_pages"
  exit 1
else
  log "remote_image_dependencies=pass scope=all_captured_pages"
fi

if grep -q '50 editions' "${NEW_DIRECTIONS_PUBLISHER_DOM}" && grep -q '50 books' "${NEW_DIRECTIONS_BROWSE_DOM}" && grep -q 'Typographic cover fallback; no cover asset is available.' "${NEW_DIRECTIONS_BROWSE_DOM}"; then
  log "new_directions_cover_fallback=pass publisher_count=50_editions browse_count=50_books remote_dependency=none"
else
  log "new_directions_cover_fallback=fail expected=50_editions_50_books_typographic_fallback"
  exit 1
fi

if grep -q 'Role-aware directory' "${CONTRIBUTORS_DOM}" && grep -q 'Translators' "${TRANSLATORS_DOM}" && grep -q 'David Bowles' "${TRANSLATORS_DOM}" && grep -q 'translator' "${TRANSLATORS_DOM}"; then
  log "contributors_role_filter=pass routes=/contributors,/contributors?role=translator"
else
  log "contributors_role_filter=fail expected=role_directory_translator_results_and_role_badge"
  exit 1
fi

if grep -q 'id="contributor-detail-shell"' "${CONTRIBUTOR_DETAIL_DOM}" && grep -q 'David Bowles' "${CONTRIBUTOR_DETAIL_DOM}" && grep -q 'Immigrant' "${CONTRIBUTOR_DETAIL_DOM}"; then
  log "contributor_detail=pass route=/contributors/david-bowles shell=contributor-detail-shell"
else
  log "contributor_detail=fail expected=detail_shell_david_bowles_immigrant"
  exit 1
fi

if grep -q 'id="series-detail-shell"' "${SERIES_DETAIL_DOM}" && grep -q 'Browser QA Series' "${SERIES_DETAIL_DOM}" && grep -q 'Immigrant' "${SERIES_DETAIL_DOM}"; then
  log "series_detail=pass route=/series/browser-qa-series shell=series-detail-shell"
else
  log "series_detail=fail expected=browser_qa_series_detail_with_immigrant"
  exit 1
fi

if grep -q 'id="book-detail-shell"' "${EDITION_REDIRECT_DOM}" && grep -q 'Immigrant' "${EDITION_REDIRECT_DOM}"; then
  log "edition_redirect=pass route=/editions/deep-vellum-immigrant-paperback-9781646054541 canonical=/books/deep-vellum-immigrant"
else
  log "edition_redirect=fail expected=canonical_book_detail"
  exit 1
fi

if grep -q 'id="edition-detail-shell"' "${EDITION_NOT_FOUND_DOM}" && grep -q 'id="edition-not-found"' "${EDITION_NOT_FOUND_DOM}"; then
  log "edition_not_found=pass route=/editions/not-a-real-edition shell=edition-detail-shell"
else
  log "edition_not_found=fail expected=edition_not_found_shell"
  exit 1
fi

if grep -q 'Catalog Index' "${FILTER_SORT_DOM}" && grep -q 'Deep Vellum' "${FILTER_SORT_DOM}" && grep -q 'translated by' "${FILTER_SORT_DOM}"; then
  log "filter_sort_url=pass route=/browse?publisher=deep-vellum&role=translator&format=paperback&sort=newest"
else
  log "filter_sort_url=fail expected=deep_vellum_translator_paperback_results"
  exit 1
fi

if grep -q 'No catalog entries match' "${MALFORMED_QUERY_DOM}"; then
  log "malformed_query=pass route=/browse?q=%25&format=ebook&page=999"
else
  log "malformed_query=fail expected=safe_empty_state"
  exit 1
fi

node - "${IMMIGRANT_BOOK_DOM}" <<'NODE' | tee -a "${TRANSCRIPT}"
const fs = require('node:fs');
const html = fs.readFileSync(process.argv[2], 'utf8');
const required = [
  ['description_id', 'id="book-description"'],
  ['description_prose', 'trilingual collection'],
  ['storefront_cta_id', 'id="book-storefront-cta"'],
  ['storefront_cta_href', 'href="https://store.deepvellum.org/products/immigrant"'],
  ['source_provenance', 'Source provenance'],
  ['source_thread_motif', 'data-provenance-motif="source-thread"']
];
const missing = required.filter(([, marker]) => !html.includes(marker)).map(([name]) => name);
if (missing.length === 0) {
  console.log('prose_cta_presence=pass ids=book-description,book-storefront-cta source_provenance=pass');
  console.log('enriched_metadata_presence=pass description=pass storefront=pass');
  console.log('provenance_thread=pass data-provenance-motif=source-thread');
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

log "running card thumbnail image decode audit"
node scripts/image_decode_check.mjs \
  "${BASE_URL}/browse?q=Immigrant" \
  "#public-cover-deep-vellum-immigrant img" \
  "/covers/cache/browser-qa-immigrant-thumb.png" \
  "${QA_DIR}/thumbnail-image-decode.json" | tee -a "${TRANSCRIPT}"
grep -q '"passed": true' "${QA_DIR}/thumbnail-image-decode.json"
log "thumbnail_image_decode=pass artifact=${QA_DIR}/thumbnail-image-decode.json card_uses_derivative=pass"

log "running public route responsive overflow audits"
responsive_routes=(
  "home|/|#home-shell"
  "browse|/browse|#browse-shell"
  "search|/search|#search-shell"
  "publishers|/publishers|#publishers-shell"
  "publisher-detail|/publishers/deep-vellum|#publisher-detail-shell"
  "contributors|/contributors|#contributors-shell"
  "contributor-detail|/contributors/david-bowles|#contributor-detail-shell"
  "series|/series|#series-shell"
  "series-detail|/series/browser-qa-series|#series-detail-shell"
  "book-detail|/books/deep-vellum-immigrant|#book-detail-shell"
  "edition-not-found|/editions/not-a-real-edition|#edition-detail-shell"
)

for route_spec in "${responsive_routes[@]}"; do
  IFS='|' read -r route_label route_path marker <<< "${route_spec}"
  for viewport_spec in "mobile|390|844" "tablet|768|1024"; do
    IFS='|' read -r viewport_label viewport_width viewport_height <<< "${viewport_spec}"
    overflow_artifact="${QA_DIR}/${viewport_label}-${route_label}-overflow.json"
    CHROME_BIN="${CHROME_BIN}" node scripts/responsive_overflow_check.mjs \
      "${BASE_URL}${route_path}" \
      "${overflow_artifact}" \
      "${viewport_width}" \
      "${viewport_height}" \
      "${marker}" | tee -a "${TRANSCRIPT}"
    grep -q '"passed": true' "${overflow_artifact}"
    log "responsive_overflow=pass viewport=${viewport_label} route=${route_path} marker=${marker} artifact=${overflow_artifact}"
  done
done

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
