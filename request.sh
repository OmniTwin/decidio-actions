#!/usr/bin/env bash
# Decidio - request deploy approval. Asks Decidio, as THIS job (GitHub vouches for it with the job's OIDC token: no secret is
# stored in the repository), for an approval of the commit being pushed to the given environment. A teammate approves in Decidio,
# Slack or on their phone; Decidio then starts the repository's deploy workflow. The job ends as soon as the request is made.
# Fails (non-zero) when Decidio refuses, blocks by policy, or a person refused this commit before (ask again with a justification).
# Inputs arrive as environment variables only - never interpolated into this script - and the identity token is masked.
set -euo pipefail
# v1.3: this action's version, sent with every request so Decidio can say when a newer one is available.
ACTION_VERSION="1.3.1"
fail() { echo "::error title=Decidio::$1" >&2; exit 1; }
api="${DECIDIO_API_URL%/}"
env_name="${DECIDIO_ENVIRONMENT:-}"
just="${DECIDIO_JUSTIFICATION:-}"
[[ "$api" =~ ^https://[A-Za-z0-9.-]+(:[0-9]{1,5})?$ || "$api" =~ ^http://127\.0\.0\.1(:[0-9]{1,5})?$ ]] || fail "api-url must be Decidio's https address, e.g. https://mcp.decidioai.com"
[[ "$env_name" =~ ^[A-Za-z0-9._-]{1,64}$ ]] || fail "environment must be one of the repository's deployment environments (letters, digits, . _ -)"
if [[ -n "$just" ]]; then
  [[ ${#just} -le 280 && "$just" != *$'\n'* ]] || fail "justification is one line of up to 280 characters"
fi
command -v jq >/dev/null || fail "this action needs jq on the runner (GitHub-hosted runners have it)"
[[ -n "${ACTIONS_ID_TOKEN_REQUEST_URL:-}" && -n "${ACTIONS_ID_TOKEN_REQUEST_TOKEN:-}" ]] \
  || fail "this job needs 'permissions: id-token: write' so GitHub can vouch for it - no secret is stored"
token="$(curl -sS --fail --max-time 30 -H "Authorization: bearer $ACTIONS_ID_TOKEN_REQUEST_TOKEN" "$ACTIONS_ID_TOKEN_REQUEST_URL&audience=decidio" | jq -r '.value // empty')" \
  || fail "GitHub did not issue this job's identity token"
[[ -n "$token" ]] || fail "GitHub did not issue this job's identity token"
echo "::add-mask::$token"
# v1.2: a push's changed files - names and added/removed line counts, never the code. Decidio holds no permission to read code, so
# GitHub lists the files of a push that came from no pull request only to the repository's own workflow: read here with THIS job's
# token (the ask file grants contents: read; it is sent to GitHub only, never to Decidio) and sent with the request. Decidio shows
# them as the workflow reported them and never sets the risk tier from them. Best effort: anything missing or refused, and the
# request goes on without them.
files='null'
gh_api="${GITHUB_API_URL:-https://api.github.com}"
if [[ "${GITHUB_EVENT_NAME:-}" == "push" && -n "${DECIDIO_GITHUB_TOKEN:-}" && -n "${GITHUB_EVENT_PATH:-}" && -r "${GITHUB_EVENT_PATH:-}" ]]; then
  before="$(jq -r '.before // empty' "$GITHUB_EVENT_PATH" 2>/dev/null || true)"
  if [[ "$before" =~ ^[0-9a-f]{40}$ && ! "$before" =~ ^0+$ && "${GITHUB_SHA:-}" =~ ^[0-9a-f]{40}$ && "${GITHUB_REPOSITORY:-}" =~ ^[A-Za-z0-9._-]+/[A-Za-z0-9._-]+$ ]] \
    && [[ "$gh_api" =~ ^https://[A-Za-z0-9.-]+(:[0-9]{1,5})?(/[A-Za-z0-9._/-]*)?$ || "$gh_api" =~ ^http://127\.0\.0\.1(:[0-9]{1,5})?$ ]]; then
    cmp="$(mktemp)"
    if curl -sS --fail --max-time 20 -o "$cmp" -H "Authorization: Bearer $DECIDIO_GITHUB_TOKEN" -H "Accept: application/vnd.github+json" \
      "${gh_api%/}/repos/$GITHUB_REPOSITORY/compare/$before...$GITHUB_SHA" 2>/dev/null; then
      # GitHub lists at most 300 files of a compare: 100 are sent, the rest counted; 300 listed means there may be more.
      files="$(jq -c '(.files // []) as $f | {files: [$f[:100][] | {path: .filename, add: .additions, del: .deletions}], more: ([($f | length) - 100, 0] | max), lowerBound: (($f | length) >= 300)}' "$cmp" 2>/dev/null || echo null)"
      [[ -n "$files" ]] || files='null'
    else
      echo "Files changed aren't sent: this job's token couldn't read the push from GitHub (the ask workflow needs 'permissions: contents: read')."
    fi
    rm -f "$cmp"
  fi
fi
body="$(jq -cn --arg e "$env_name" --arg j "$just" --argjson f "$files" '{environment: $e} + (if $j == "" then {} else {justification: $j} end)
  + (if $f == null then {} else {files: $f.files, filesMore: $f.more, filesLowerBound: $f.lowerBound} end)')"
out="$(mktemp)"
status="$(curl -sS --max-time 60 -o "$out" -w '%{http_code}' -X POST "$api/api/github/runs/request" \
  -H "Authorization: Bearer $token" -H "Content-Type: application/json" -H "X-Decidio-Client: action-request/$ACTION_VERSION" --data "$body")" \
  || fail "could not reach Decidio at $api"
field() { jq -r --arg k "$1" '.[$k] // empty | tostring' "$out" 2>/dev/null || true; }
# A server string printed in a log line: one line, no "::" (it could start another workflow command), at most 300 characters.
say() { printf '%s' "$1" | tr -d '\r\n' | sed 's/::/: :/g' | cut -c1-300; }
decision="$(field decision)"; id="$(field decisionId)"; number="$(field displayNumber)"; url="$(field url)"; why="$(field error)"; code="$(field code)"
ref="$(say "${number:-$id}")"; [[ -n "$url" ]] && ref="$ref $(say "$url")"
if [[ "$status" == "200" && ( "$decision" == "route" || "$decision" == "proceed" ) ]]; then
  if [[ -n "${GITHUB_OUTPUT:-}" ]]; then
    echo "decision=$decision" >> "$GITHUB_OUTPUT"
    [[ "$id" =~ ^[A-Za-z0-9_-]{1,64}$ ]] && echo "decision-id=$id" >> "$GITHUB_OUTPUT"
    [[ "$url" =~ ^https?://[^[:space:]]{1,300}$ ]] && echo "url=$url" >> "$GITHUB_OUTPUT"
  fi
  if [[ "$decision" == "proceed" ]]; then
    echo "::notice title=Decidio::$env_name needs no approval - Decidio starts the deploy ($ref)"
  else
    echo "::notice title=Decidio::Asked - a teammate approves $env_name in Decidio, then Decidio starts the deploy ($ref)"
  fi
  [[ "$(field existing)" == "true" ]] && echo "An approval request for this commit was already open - that one stands."
  # v1.3: the run's summary says where the approval is waiting, linked to its record (Decidio's own page only) - and by whom it's asked.
  if [[ -n "${GITHUB_STEP_SUMMARY:-}" ]]; then
    md() { printf '%s' "$1" | tr -d '\r\n' | tr -d '|<>`@[]()*_\\#!' | sed 's#://#: //#g; s#www\.#www #g' | cut -c1-240; }
    record="$(md "${number:-$id}")" || record=""
    [[ -n "$record" && "$url" =~ ^https://[A-Za-z0-9.-]+(:[0-9]{1,5})?/d/[A-Za-z0-9_-]{1,64}$ ]] && record="[$record]($url)"
    {
      if [[ "$decision" == "proceed" ]]; then echo "### No approval needed in Decidio"; else echo "### Waiting for approval in Decidio"; fi
      echo ""
      if [[ -n "$record" ]]; then
        if [[ "$decision" == "proceed" ]]; then echo "Record: $record - Decidio starts the deploy to $env_name."; else echo "Record: $record - Decidio starts the deploy to $env_name once it's approved."; fi
        echo ""
      fi
      echo "_Deploy approvals by [Decidio](https://decidioai.com)_"
    } >> "$GITHUB_STEP_SUMMARY" || true
  fi
  exit 0
fi
# A run started by hand or by Decidio's "Check the connection" (workflow_dispatch) is a CONNECTION CHECK: Decidio confirms this
# repository, this job's identity and the environment, and asks for nothing - no deploy request, no record.
if [[ "$status" == "200" && "$decision" == "connected" ]]; then
  [[ -n "${GITHUB_OUTPUT:-}" ]] && echo "decision=connected" >> "$GITHUB_OUTPUT"
  echo "::notice title=Decidio::Connected - Decidio heard this repository ask for $env_name. This check asked for nothing; the next push asks a teammate to approve its deploy."
  exit 0
fi
if [[ "$status" == "200" && "$decision" == "duplicate" ]]; then
  fail "$(say "${why:-a teammate refused this commit before}") - to ask again, set the justification input to what changed"
fi
if [[ "$status" == "200" && "$decision" == "block" ]]; then
  fail "the workspace's policy blocks this deploy ($ref)"
fi
fail "Decidio refused the request ($(say "$status${code:+ $code}")): $(say "${why:-no reason given}")"
