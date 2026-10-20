#!/usr/bin/env bash
# Decidio - request deploy approval. Asks Decidio, as THIS job (GitHub vouches for it with the job's OIDC token: no secret is
# stored in the repository), for an approval of the commit being pushed to the given environment. A teammate approves in Decidio,
# Slack or on their phone; Decidio then starts the repository's deploy workflow. The job ends as soon as the request is made.
# Fails (non-zero) when Decidio refuses, blocks by policy, or a person refused this commit before (ask again with a justification).
# Inputs arrive as environment variables only - never interpolated into this script - and the identity token is masked.
set -euo pipefail
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
body="$(jq -cn --arg e "$env_name" --arg j "$just" '{environment: $e} + (if $j == "" then {} else {justification: $j} end)')"
out="$(mktemp)"
status="$(curl -sS --max-time 60 -o "$out" -w '%{http_code}' -X POST "$api/api/github/runs/request" \
  -H "Authorization: Bearer $token" -H "Content-Type: application/json" -H "X-Decidio-Client: action-request/1" --data "$body")" \
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
  exit 0
fi
if [[ "$status" == "200" && "$decision" == "duplicate" ]]; then
  fail "$(say "${why:-a teammate refused this commit before}") - to ask again, set the justification input to what changed"
fi
if [[ "$status" == "200" && "$decision" == "block" ]]; then
  fail "the workspace's policy blocks this deploy ($ref)"
fi
fail "Decidio refused the request ($(say "$status${code:+ $code}")): $(say "${why:-no reason given}")"
