#!/usr/bin/env bash
# Decidio - verify deploy approval. The deploy job's FIRST step: proves to Decidio, as THIS job (the job's OIDC token: no secret
# stored), that the run was started by the Decidio app for an approval of this exact commit and environment, and uses that
# approval up (once). On success it outputs the approved commit to check out; on anything else the step fails and nothing after
# it runs - do not deploy. Inputs arrive as environment variables only; the identity token is masked.
set -euo pipefail
# v1.3: this action's version, sent with the verify so Decidio can say when a newer one is available.
ACTION_VERSION="1.4.0"
fail() { echo "::error title=Decidio::$1 - do not deploy" >&2; exit 1; }
api="${DECIDIO_API_URL%/}"
decision="${DECIDIO_DECISION:-}"
# v1.4: THE EMERGENCY ROUTE - a repository admin's own run while Decidio can't be reached (the decision input "emergency: <why>"). Its
# own block, ending in an exit: a run with any other input never enters it, and the approval path below it is v1.3.1's. It opens only
# when Decidio's own address gives no answer but a server error on three tries (no response or a 5xx; any 100-499 is an answer and
# closes it), and only for a run started by hand whose starter is its actor and a repository admin (GitHub says so, read with this job's
# token). It stamps the run - one annotation, "Decidio emergency deploy" - which Decidio reads when it is back.
if [[ "$decision" == emergency:* ]]; then
  export LC_ALL=C
  PROD="https://mcp.decidioai.com"
  one() { printf '%s' "$1" | tr -d '\r\n' | sed 's/::/: :/g' | cut -c1-120; }
  low() { printf '%s' "$1" | tr '[:upper:]' '[:lower:]'; }
  why="${decision#emergency:}"; while [[ "$why" == " "* ]]; do why="${why# }"; done
  [[ "$api" == "$PROD" ]] || fail "the emergency route works only with Decidio's own address ($PROD), not $(one "$api")"
  [[ ${#why} -ge 3 && ${#why} -le 200 && ! "$why" =~ [[:cntrl:]] ]] || fail "the emergency route needs a reason on one line: decidio = emergency: <why>, 3 to 200 characters"
  [[ "${DECIDIO_GH_EVENT:-}" == "workflow_dispatch" ]] || fail "the emergency route is only for a run started by hand (Run workflow), not a $(one "${DECIDIO_GH_EVENT:-unknown}") run"
  actor="${DECIDIO_GH_ACTOR:-}"; trig="${DECIDIO_GH_TRIGGERING_ACTOR:-}"; actor_id="${DECIDIO_GH_ACTOR_ID:-}"
  [[ "$actor" =~ ^[A-Za-z0-9][A-Za-z0-9-]{0,38}$ && "$actor_id" =~ ^[0-9]{1,20}$ ]] || fail "only a person's GitHub account can use the emergency route, not $(one "$actor")"
  [[ "$(low "$actor")" == "$(low "$trig")" ]] || fail "the emergency route needs the person who starts the run: $(one "$trig") re-ran a run $actor started"
  repo="${DECIDIO_GH_REPOSITORY:-}"; gh="${DECIDIO_GH_API_URL%/}"; sha="${DECIDIO_GH_SHA:-}"
  [[ "$repo" =~ ^[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+$ && "$gh" =~ ^https://[A-Za-z0-9.-]+(:[0-9]{1,5})?(/api/v3)?$ && "$sha" =~ ^[0-9a-f]{40}$ ]] || fail "GitHub's context for this run is incomplete"
  command -v jq >/dev/null || fail "this action needs jq on the runner (GitHub-hosted runners have it)"
  [[ -n "${ACTIONS_ID_TOKEN_REQUEST_URL:-}" && -n "${ACTIONS_ID_TOKEN_REQUEST_TOKEN:-}" ]] || fail "this job needs 'permissions: id-token: write' so GitHub can vouch for it"
  oidc() { curl -sS --fail --max-time 30 -H "Authorization: bearer $ACTIONS_ID_TOKEN_REQUEST_TOKEN" "$ACTIONS_ID_TOKEN_REQUEST_URL&audience=decidio" | jq -r '.value // empty'; }
  token="$(oidc)" && [[ -n "$token" ]] || fail "GitHub did not issue this job's identity token"
  echo "::add-mask::$token"
  # The job's environment, as GitHub's token states it (decoded here; Decidio checks it is one of the repository's).
  seg="${token#*.}"; seg="${seg%%.*}"; seg="$(printf '%s' "$seg" | tr '_-' '/+')"; while (( ${#seg} % 4 )); do seg="$seg="; done
  env="$(printf '%s' "$seg" | base64 -d 2>/dev/null | jq -r '.environment // empty | tostring' 2>/dev/null)" || env=""
  [[ -n "$env" && ${#env} -le 255 && ! "$env" =~ [[:cntrl:]] ]] || fail "the emergency route is for a deploy job with an environment (environment: in the job)"
  # A repository admin, checked with GitHub (this job's own token, sent to GitHub only) - before Decidio is tried at all.
  role="$(curl -sS --fail --max-time 30 -H "Authorization: Bearer ${DECIDIO_GITHUB_TOKEN:-}" -H "Accept: application/vnd.github+json" "$gh/repos/$repo/collaborators/$actor/permission" \
    | jq -r '[(.permission // "" | tostring), (.user.login // "" | tostring)] | join(" ")' 2>/dev/null)" || role=""
  perm="${role%% *}"; who="${role#* }"
  [[ "$perm" == "admin" && "$(low "$who")" == "$(low "$actor")" ]] || fail "only a repository admin can use the emergency route, checked with GitHub: $actor is $(one "${perm:-not readable}")"
  # Decidio, tried at its own address as patiently as the approval path (60 s a try), three times over a few minutes. The FIRST answer
  # closes the route: an HTTP status from 100 to 499 is an answer whatever curl's exit says; only no response (000) or a 5xx is not.
  out="$(mktemp)"; tries=(); first="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
  for wait in 0 30 60; do
    if (( wait > 0 )); then sleep "$wait"; fi
    tok="$(oidc)" && [[ -n "$tok" ]] || fail "GitHub did not issue this job's identity token"
    echo "::add-mask::$tok"
    rc=0; st="$(curl -sS --connect-timeout 10 --max-time 60 -o "$out" -w '%{http_code}' -X POST "$PROD/api/github/runs/verify" \
      -H "Authorization: Bearer $tok" -H "Content-Type: application/json" -H "X-Decidio-Client: action-verify/$ACTION_VERSION" \
      --data '{"decision":"emergency"}')" || rc=$?
    [[ "$st" =~ ^[0-9]{3}$ ]] || st="000"
    if [[ "$st" =~ ^[1-4][0-9][0-9]$ ]]; then
      code="$(jq -r '.code // empty | tostring' "$out" 2>/dev/null | tr -cd 'A-Z_' | cut -c1-40)" || code=""
      fail "Decidio answered ($st${code:+ $code}), so it can be reached and the emergency route stays closed. Ask for this deploy in Decidio"
    fi
    tries+=("$rc/$st")
  done
  last="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
  [[ -n "${GITHUB_OUTPUT:-}" ]] && { echo "sha=$sha"; echo "decision=emergency"; } >> "$GITHUB_OUTPUT"
  # THE STAMP: one annotation. The environment percent-encoded, the reason last (it may hold spaces); then the workflow command's own
  # escape (% first), so the run's annotation reads exactly this message.
  msg="decidio-emergency/1 by=$actor id=$actor_id env=$(jq -rn --arg v "$env" '$v|@uri') sha=$sha tries=${#tries[@]} first=$first last=$last errors=$(IFS=,; echo "${tries[*]}") reason=$why"
  echo "::warning title=Decidio emergency deploy::$(printf '%s' "$msg" | sed 's/%/%25/g; s/::/: :/g')"
  if [[ -n "${GITHUB_STEP_SUMMARY:-}" ]]; then
    md() { printf '%s' "$1" | tr -d '\r\n' | tr -d '|<>`@[]()*_\\#!' | sed 's#://#: //#g; s#www\.#www #g' | cut -c1-240; }
    {
      echo "### Emergency deploy, not approved in Decidio"
      echo ""
      echo "| | |"
      echo "|---|---|"
      echo "| Started by | $actor (a repository admin, checked with GitHub) |"
      echo "| Why | $(md "$why") |"
      echo "| Commit | \`${sha:0:12}\` |"
      echo "| Environment | $(md "$env") |"
      echo "| Decidio | couldn't be reached at $PROD (${#tries[@]} tries, ${first:11:5}-${last:11:5} UTC) |"
      echo ""
      echo "_Decidio records this run when it's back: the workspace owner is emailed and the executive role reviews it._"
    } >> "$GITHUB_STEP_SUMMARY" || true
  fi
  exit 0
fi
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
