# Decidio deploy approvals

A deploy waits until a teammate approves it in [Decidio](https://decidioai.com), Slack or on their phone. Then Decidio starts
the deploy, and the deploy proves the approval (once, for this commit and environment) before anything runs.

No secret is stored in your repository: the action uses the job's own GitHub OIDC token (`permissions: id-token: write`).

## Before you start

In Decidio, open **Connect → GitHub approvals** (https://app.decidioai.com/connect/github) and follow the four steps: install the
Decidio GitHub App, link your GitHub account, choose the repository, and add the two workflow files below. The page fills them
in for you.

## The two workflows

`.github/workflows/decidio-request.yml` asks for approval on each push. It can only ask. A push that changes only these two
workflow files asks for nothing, so adding them never creates a deploy request.

```yaml
name: Ask Decidio to deploy
on:
  push:
    branches: [main]
    paths-ignore:
      - .github/workflows/decidio-request.yml
      - .github/workflows/deploy.yml
  workflow_dispatch:
permissions:
  id-token: write
  contents: read
jobs:
  ask:
    runs-on: ubuntu-latest
    steps:
      - uses: OmniTwin/decidio-actions@<full commit sha> # v1.0.0
        with:
          step: request
          environment: production
```

`.github/workflows/deploy.yml` runs only when Decidio starts it, after the approval. Its first step proves the approval.

```yaml
name: Deploy
run-name: Decidio ${{ inputs.decidio }}
on:
  workflow_dispatch:
    inputs:
      decidio:
        description: Set by Decidio
        required: true
permissions:
  id-token: write
  contents: read
jobs:
  deploy:
    runs-on: ubuntu-latest
    environment: production
    steps:
      - id: decidio
        uses: OmniTwin/decidio-actions@<full commit sha> # v1.0.0
        with:
          step: verify
          decision: ${{ inputs.decidio }}
      - uses: actions/checkout@11d5960a326750d5838078e36cf38b85af677262 # v4.4.0
        with:
          ref: ${{ steps.decidio.outputs.sha }}
      - name: Deploy
        run: ./deploy.sh   # your deploy command
```

Then, in the repository's **Settings → Actions**, allow only the Decidio app to run the deploy workflow, so nobody can start a
deploy by hand.

## Check the connection

Once both files are in, click **Check the connection** on Decidio's setup page, or run *Ask Decidio to deploy* from the
repository's **Actions** tab. A run started that way (`workflow_dispatch`) is a connection check: Decidio confirms the
repository, the job's identity and the environment, and the job says **Connected**. It asks for nothing and creates no record.
Your next push asks a teammate to approve its deploy.

## Pin it to a commit

The verify step guards your production deploy, so pin it to a full commit, never a tag. Replace `<full commit sha>` above
with the release's commit from this repository's Releases page; Decidio's setup page and `npx @decidio/sdk github init` write
the current one for you. There is no `v1` tag to follow on purpose. Let Dependabot propose the bumps.

## Inputs

| Input | Step | Meaning |
|---|---|---|
| `step` | both | `request` (ask for approval) or `verify` (prove it, first step of the deploy job) |
| `environment` | request | The environment to ask for, one the repository was set up with in Decidio |
| `justification` | request | One line on what changed: needed to ask again after a teammate refused this commit |
| `decision` | verify | The workflow's `decidio` input, set by Decidio when it starts the run |
| `api-url` | both | Decidio's API address (default `https://mcp.decidioai.com`) |

## Outputs

| Output | Step | Meaning |
|---|---|---|
| `decision` | request | `route` (a teammate approves next), `proceed` (no approval needed; Decidio starts the deploy), or `connected` (a connection check: nothing was asked) |
| `decision-id`, `url` | request | The request in Decidio |
| `sha` | verify | The approved commit: check out and deploy exactly this |

## When it fails

- **request** fails when the workspace's policy blocks the deploy, or when a teammate already refused this commit. To ask again,
  add a `justification` saying what changed, or push a new commit.
- **verify** fails, and writes no `sha`, whenever the approval cannot be proved: not approved, already used, another commit or
  environment. The job stops there, so nothing deploys. Do not add `continue-on-error` to it.

## License

MIT
