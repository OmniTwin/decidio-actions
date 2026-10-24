#!/usr/bin/env bash
# Decidio - verify deploy approval. The deploy job's FIRST step: proves to Decidio, as THIS job (the job's OIDC token: no secret
# stored), that the run was started by the Decidio app for an approval of this exact commit and environment, and uses that
# approval up (once). On success it outputs the approved commit to check out; on anything else the step fails and nothing after
# it runs - do not deploy. Inputs arrive as environment variables only; the identity token is masked.
set -euo pipefail
# v1.3: this action's version, sent with the verify so Decidio can say when a newer one is available.
ACTION_VERSION="1.3.1"
fail() { echo "::error title=Decidio::$1 - do not deploy" >&2; exit 1; }
api="${DECIDIO_API_URL%/}"
decision="${DECIDIO_DECISION:-}"
[[ "$api" =~ ^https://[A-Za-z0-9.-]+(:[0-9]{1,5})?$ || "$api" =~ ^http://127\.0\.0\.1(:[0-9]{1,5})?$ ]] || fail "api-url must be Decidio's https address, e.g. https://mcp.decidioai.com"
[[ "$decision" =~ ^[A-Za-z0-9_-]{1,64}$ ]] || fail "no approval to verify: set the decision input to \${{ inputs.decidio }} (Decidio passes it when it starts this run)"
command -v jq >/dev/null || fail "this action needs jq on the runner (GitHub-hosted runners have it)"
[[ -n "${ACTIONS_ID_TOKEN_REQUEST_URL:-}" && -n "${ACTIONS_ID_TOKEN_REQUEST_TOKEN:-}" ]] \
  || fail "this job needs 'permissions: id-token: write' so GitHub can vouch for it"
token="$(curl -sS --fail --max-time 30 -H "Authorization: bearer $ACTIONS_ID_TOKEN_REQUEST_TOKEN" "$ACTIONS_ID_TOKEN_REQUEST_URL&audience=decidio" | jq -r '.value // empty')" \
  || fail "GitHub did not issue this job's identity token"
[[ -n "$token" ]] || fail "GitHub did not issue this job's identity token"
echo "::add-mask::$token"
out="$(mktemp)"
status="$(curl -sS --max-time 60 -o "$out" -w '%{http_code}' -X POST "$api/api/github/runs/verify" \
  -H "Authorization: Bearer $token" -H "Content-Type: application/json" -H "X-Decidio-Client: action-verify/$ACTION_VERSION" \
  --data "$(jq -cn --arg d "$decision" '{decision: $d}')")" || fail "could not reach Decidio at $api"
field() { jq -r --arg k "$1" '.[$k] // empty | tostring' "$out" 2>/dev/null || true; }
# A server string printed in a log line: one line, no "::" (it could start another workflow command), at most 300 characters.
say() { printf '%s' "$1" | tr -d '\r\n' | sed 's/::/: :/g' | cut -c1-300; }
sha="$(field sha)"
if [[ "$status" == "200" && "$(field ok)" == "true" && "$sha" =~ ^[0-9a-f]{40}$ ]]; then
  [[ -n "${GITHUB_OUTPUT:-}" ]] && { echo "sha=$sha"; echo "decision=$decision"; } >> "$GITHUB_OUTPUT"
  number="$(field displayNumber)"
  echo "::notice title=Decidio::Approved - deploying ${sha:0:12} to $(say "$(field environment)") ($(say "${number:-$decision}")). This approval is now used."
  # The run's summary (v1.1): the record, who approved it and when, the commit, the environment and the risk - Decidio's words, kept to
  # one line each and stripped of anything Markdown would read as a link, a table cell, markup or a mention.
  if [[ -n "${GITHUB_STEP_SUMMARY:-}" ]]; then
    md() { printf '%s' "$1" | tr -d '\r\n' | tr -d '|<>`@[]()*_\\#!' | sed 's#://#: //#g; s#www\.#www #g' | cut -c1-240; }
    url="$(field url)"; at="$(field approvedAt)"; by="$(field approvedBy)"; risk="$(field risk)"
    record="$(md "${number:-$decision}")" || record="$decision"   # never fail the step: the approval is already used
    [[ "$url" =~ ^https://[A-Za-z0-9.-]+(:[0-9]{1,5})?/d/[A-Za-z0-9_-]{1,64}$ ]] && record="[$record]($url)"
    if [[ "$at" =~ ^([0-9]{4}-[0-9]{2}-[0-9]{2})T([0-9]{2}:[0-9]{2}) ]]; then at="${BASH_REMATCH[1]} ${BASH_REMATCH[2]} UTC"; else at=""; fi
    {
      echo "### Approved in Decidio"
      echo ""
      echo "| | |"
      echo "|---|---|"
      echo "| Record | $record |"
      [[ -n "$by" ]] && echo "| Approved by | $(md "$by")${at:+ at $at} |"
      echo "| Commit | \`${sha:0:12}\` |"
      echo "| Environment | $(md "$(field environment)") |"
      [[ -n "$risk" ]] && echo "| Risk | $(md "$risk") |"
      echo ""
      echo "_Deploy approved with [Decidio](https://decidioai.com)_"
    } >> "$GITHUB_STEP_SUMMARY" || true
  fi
  exit 0
fi
code="$(field code)"; why="$(field error)"
fail "not approved ($(say "$status${code:+ $code}")): $(say "${why:-no reason given}")"
