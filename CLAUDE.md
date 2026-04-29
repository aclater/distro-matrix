## Standing instructions

### Always verify current versions before using them

Before referencing any version number for a container image, package,
model, GitHub Action, or tool — look it up. Do not use version numbers
from training knowledge. They are outdated.

- GitHub Actions: verify via API before writing any workflow file:
    gh api repos/<owner>/<action>/releases/latest | jq .tag_name
  Use the exact tag returned. This has caused broken CI multiple times.
- Container images: check the registry (quay.io, ghcr.io,
  registry.access.redhat.com, docker.io) for the current stable tag.
  Never use :latest in production quadlets — pin to tag or digest.
- Python packages: check PyPI for current stable release before pinning.
- LLM models: check Hugging Face directly for current releases.
- System packages (dnf/pip): do not pin versions unless explicitly asked.
- If you cannot verify a version, say so explicitly. Do not guess.

### Fedora 44 / ROCm / gfx1151 context

This system runs Fedora 44 with an AMD Ryzen AI Max+ 395 (gfx1151).
HSA_OVERRIDE_GFX_VERSION=11.5.1 is required for all ROCm workloads.
ROCm support for gfx1151 is in active development — always check for
current known issues before recommending ROCm-dependent solutions.

Memory architecture:
- VRAM: 512MB (GPU housekeeping only — effectively none)
- GTT: ~113GB (all model weights, KV cache, and inference use GTT)
- GPU executes compute against GTT — this is full GPU inference, not CPU
- rocm-smi --showmeminfo gtt confirms current GTT allocation
- Do not treat GTT allocation as a problem — it is correct for this APU

MXR cache (ragpipe):
- ORT_MIGRAPHX_MODEL_CACHE_PATH env var enables MXR caching
- Cold start (no cache): ~3m53s
- Warm start (cache hit): ~6 seconds (39x improvement)
- Cache file: 149MB .mxr on ragpipe-model-cache persistent volume
- Do not treat 6-second startup as slow — the cache is working
- ROCMExecutionProvider is deprecated and removed since ORT 1.23 — do not use it
- MIGraphXExecutionProvider is the only working AMD GPU path on ROCm 7.x
- MIGRAPHX_BATCH_SIZE=64 — MIGraphX uses static shapes, pad all batches to this

### Container hygiene

All services run as rootless Podman quadlets managed by systemd.
SELinux is enforcing. SecurityLabelDisable=true is required on any
container that accesses /dev/kfd.

### Prefer Red Hat supported software and containers

Always prefer Red Hat supported container images and software where
available and appropriate:

- Base images: prefer UBI — ubi10 is current.
  Use ubi10-minimal for small footprint, ubi10 for full base.
  Registry: registry.access.redhat.com/ubi10
  Note: ubi10-minimal does NOT include curl — use Python for healthchecks:
    HealthCmd=python3 -c "import urllib.request; urllib.request.urlopen('http://127.0.0.1:<port>/health')"
- Prefer Red Hat container catalog (catalog.redhat.com) over Docker Hub
- Prefer rpm/dnf packages over pip where both are available on Fedora
- Prefer Podman over Docker, systemd over supervisord, quadlets over docker-compose
- Do not use :latest tags on production quadlets

If no Red Hat supported option exists, use the most appropriate upstream
image and note that no RH-supported alternative was found.

### Security, hygiene, and code quality

#### Security posture
This code may be deployed to OpenShift. Write everything to that standard:

- Never disable security controls for convenience
- Never use privileged containers or --privileged without explicit documentation
- Never run containers as root — all containers must use non-root users
- Never store secrets in images, Containerfiles, or committed to git
- Never use SecurityLabelDisable=true without a documented justification
  comment explaining the specific SELinux constraint and referencing the ADR
- Prefer read-only root filesystems. Mount only what is needed.
- Supply chain: always verify image digests or use pinned tags from
  trusted registries. Never pull :latest in production quadlets.

#### Code quality
- Write tests before or alongside new functionality, not after
- Every bug fix must include a regression test that would have caught it
- Functions should do one thing
- Error paths must be handled explicitly — never silently swallow errors
- Log meaningful information at appropriate levels
- Do not log secrets, tokens, or personally identifiable information

#### OpenShift readiness
- Use standard Kubernetes/OpenShift resource patterns where applicable
- Avoid host path mounts — prefer PVCs or ConfigMaps
- Liveness and readiness probes must be defined for all long-running services
- Resource requests and limits should be specified
- Labels and annotations should follow OpenShift conventions

#### Git hygiene
- One logical change per commit. Do not bundle unrelated fixes.
- Commit messages must explain why, not just what.
- Never force push to a shared branch without explicit instruction.
- Squash fixup commits before submitting a PR to an upstream project.

### Code Review Workflow (CodeRabbit)

After completing any significant implementation block, run CodeRabbit
before committing:

```bash
cr --plain --type uncommitted
```

- Fix all CRITICAL and HIGH findings before committing.
- LOW / style nits are advisory only.
- Use `/review` to trigger the full review-and-fix loop.

Available custom commands:
- `/review` — run CodeRabbit, fix CRITICAL/HIGH findings, report results

---

## GPU acceleration

Detect GPU provider at runtime — never hardcode a vendor.

Detection priority: NVIDIA CUDA > AMD ROCm/MIGraphX > Intel XPU > CPU

- For ONNX Runtime: CUDAExecutionProvider > MIGraphXExecutionProvider >
  OpenVINOExecutionProvider > CPUExecutionProvider
- For Python: torch.cuda.is_available(), torch.version.hip (ROCm),
  torch.xpu.is_available() (Intel)
- CPU fallback must be logged as a warning and documented in a comment

Container GPU passthrough:
- AMD ROCm: --device /dev/kfd --device /dev/dri
- NVIDIA: --device /dev/nvidia0 (or --gpus all with nvidia-container-toolkit)
- Intel: --device /dev/dri

AMD ROCm on gfx1151: HSA_OVERRIDE_GFX_VERSION=11.5.1 required in all
quadlets, containers, and scripts that use ROCm on this hardware.

---

## Repository location

All permanent repositories live under ~/git/.

- Never clone or initialize a repository anywhere else.
- Temporary PR work goes in ~/git-work/<issue-number>-<description>/
- When referencing local repos, always use ~/git/<reponame> as the path.

---

## Working directory conventions

- ~/git/          — permanent repositories only
- ~/git-work/     — temporary clones for PR work only
                    Always: ~/git-work/<issue-number>-<description>/
                    Clean up after the PR is merged
- ~/.local/bin/   — user scripts and tools. Never use ~/bin/.

Never create git-* directories directly in ~/. They clutter the home
directory and never get cleaned up.

When starting a task requiring a repo clone:
```bash
mkdir -p ~/git-work/<issue-number>-<description>
cd ~/git-work/<issue-number>-<description>
gh repo clone aclater/<repo>
```

When the PR is merged:
```bash
rm -rf ~/git-work/<issue-number>-<description>
```

Or run periodically:
```bash
~/.local/bin/cleanup-git-work.sh --dry-run
~/.local/bin/cleanup-git-work.sh
```

---

## GitHub issue workflow

Every task must be tracked in a GitHub issue before work begins. Mandatory.

Before starting any implementation task:
1. Check for an existing issue:
     gh issue list --repo aclater/<repo> --search "<description>"
2. If none exists, create one:
     gh issue create \
       --repo aclater/<repo> \
       --title "<clear title — root cause, not symptom>" \
       --body "<context, problem, proposed fix, success criteria>" \
       --label "priority: <blocking|high|medium|low>,type: <bug|feature|infrastructure>,agent: <claude-code|minimax-m27|minimax-m25|human>"
3. Claim the issue immediately:
     gh issue edit <number> --repo aclater/<repo> --add-assignee "@me"
     gh issue comment <number> --repo aclater/<repo> \
       --body "🤖 <Agent name> picking up this issue.
**Branch:** <branch>
**Plan:** <approach>
**Started:** $(date)"
4. Log major milestones and decisions to the issue as comments as you work.
   The issue comment thread is the audit trail. Make it useful.

All commits must reference the issue:
  feat(ragpipe): add prometheus metrics endpoint (fixes #14)
  fix(ragstuffer): deduplicate cited chunks (refs #8)

All PR bodies must include:
  Closes #N   — fully resolves the issue
  Refs #N     — partially addresses the issue

Never start implementation without an issue number.

---

## Autonomous operation

You are operating autonomously. Do not ask for confirmation before taking
action. Do not prompt the user with yes/no questions. Make decisions,
execute them, log them to GitHub issues, and move on.

The only exception: if you encounter irreversible data loss risk —
comment on the issue explaining what you found and why you stopped, then stop.

Autonomous decision rules — apply without asking:
- Tests fail after a fix: investigate, fix, push again.
- CI failing on your branch: fix it and push.
- Dependency missing: install it.
- Migration needed: run it against live Postgres.
- ragpipe needs restart: restart it, wait for healthy (~6s warm start),
  log the restart reason in the GitHub issue comment.
- New bug discovered: create a GitHub issue, note it in current issue
  comment, continue with current task.
- Unsure between approaches: pick the simpler one, document reasoning
  in the issue comment, proceed.
- Flaky test: fix the test.
- CI still running: wait for it to complete before moving to next issue.

Log these to the GitHub issue as comments:
- When you start: plan and implementation approach
- When you hit a significant obstacle and how you resolved it
- When you make a non-obvious technical decision and why
- When tests pass or fail (with counts)
- When the PR is open: PR URL and CI status
- When CI passes: confirmation and remaining notes

---

## No confirmation prompts — ever

Never ask the user to confirm before taking action. This includes:
- "Should I proceed?"
- "Would you like me to..."
- "Is it okay if I..."
- "Do you want me to expand on..."
- "Simple expansion — shall I continue?"
- "I can implement this if you'd like"
- Any yes/no question directed at the user

If you know what to do: do it.
If you need to make a choice: make it, log it in the issue, move on.
If you are expanding scope: note it in the issue comment, proceed.
If something is risky or irreversible: comment on the issue explaining
why you stopped, then stop. Do not ask. Stop.

The user is not available to answer questions. Operate as if they will
not respond. Complete the task or stop with a clear explanation in the
issue. There is no middle ground.

---

## Issue assignment with single GitHub account

All agents run as the same GitHub account (aclater). The assignee field
cannot distinguish between agents — it always shows aclater.

Use issue comments as the coordination signal instead:

When claiming an issue, post a comment identifying yourself:
  "🤖 Claude Code picking up this issue."
  "🤖 MiniMax M2.7 picking up this issue."
  "🤖 MiniMax M2.5 picking up this issue."

Before claiming any issue, read the existing comments. If another agent
has already posted a pickup comment and there is no "abandoned" or
"blocked" comment after it, skip this issue and move to the next one.

An issue is available to claim if:
- No pickup comment exists, OR
- The last agent comment says "blocked" or "abandoned" with explanation

---

## Container and deployment standards

- Use Podman, not Docker. Use rootless Podman quadlets, not docker-compose.
- Base images: prefer Red Hat UBI (registry.access.redhat.com/ubi10/).
- Never use :latest in production quadlets — pin to specific tag or digest.
- All containers must run as non-root (USER 1001 or equivalent).
- All containers must have a HEALTHCHECK defined.
  Note: ubi10-minimal lacks curl — use Python healthcheck:
    HealthCmd=python3 -c "import urllib.request; urllib.request.urlopen('http://127.0.0.1:<port>/health')"
- SecurityLabelDisable=true requires an inline comment explaining the
  specific SELinux constraint and referencing the relevant ADR.
- No bind mounts for source code in production quadlets.
- No credentials in committed files — use ragstack.env (not committed).
- One logical change per commit. Squash fixup commits before upstream PRs.

---

## New repo bootstrap — labels, milestones, and CI

Every new GitHub repository must be fully bootstrapped immediately after
creation. Do this before writing any code or creating any issues.

### Step 1 — Labels and milestones

```bash
bootstrap_repo() {
  repo=$1
  for label in \
    "priority: blocking|B60205|Blocks other work" \
    "priority: high|E4E669|High priority" \
    "priority: medium|0075CA|Medium priority" \
    "priority: low|CFD3D7|Low priority" \
    "agent: claude-code|6F42C1|Assigned to Claude Code" \
    "agent: minimax-m27|0052CC|Assigned to MiniMax M2.7" \
    "agent: minimax-m25|006B75|Assigned to MiniMax M2.5" \
    "agent: human|E99695|Requires human action" \
    "type: bug|D93F0B|Something is broken" \
    "type: feature|0E8A16|New functionality" \
    "type: infrastructure|F9D0C4|Infrastructure and deployment" \
    "type: docs|C5DEF5|Documentation" \
    "type: security|EE0701|Security related" \
    "agentic-rag|8B4FD8|Agentic RAG architecture evolution" \
    "gateway-auth|C2E0C6|Gateway authentication and rate limiting"; do
    name=$(echo $label | cut -d'|' -f1)
    color=$(echo $label | cut -d'|' -f2)
    desc=$(echo $label | cut -d'|' -f3)
    gh label create "$name" --color "$color" --description "$desc" \
      --repo aclater/$repo 2>/dev/null || true
  done
  for milestone in "Core Stack Complete" "Agentic RAG" "Production Ready"; do
    gh api repos/aclater/$repo/milestones -X POST \
      -f title="$milestone" 2>/dev/null || true
  done
}
bootstrap_repo <new-repo-name>
```

### Step 2 — CI workflows

Copy CI workflow templates from the closest existing repo and adapt.
Use ragpipe as reference for Python repos, ragorchestrator for LangGraph repos.

```bash
mkdir -p ~/git-work/bootstrap-<new-repo>
cd ~/git-work/bootstrap-<new-repo>
gh repo clone aclater/<new-repo>
cd <new-repo>
git checkout -b chore/bootstrap-ci

# Copy workflows from reference repo
gh api repos/aclater/ragpipe/contents/.github/workflows \
  --jq '.[].name' | while read f; do
  content=$(gh api repos/aclater/ragpipe/contents/.github/workflows/$f \
    --jq '.content' | base64 -d)
  mkdir -p .github/workflows
  echo "$content" > .github/workflows/$f
done
```

Adapt each workflow:
- Replace repo name references
- Remove inapplicable workflows (e.g. container.yml if no Containerfile)
- Verify ALL action versions via API before committing:
    gh api repos/actions/checkout/releases/latest | jq .tag_name

### Step 3 — Pre-commit config

```bash
gh api repos/aclater/ragpipe/contents/.pre-commit-config.yaml \
  --jq '.content' | base64 -d > .pre-commit-config.yaml
pip install detect-secrets --break-system-packages -q
detect-secrets scan > .secrets.baseline
```

### Step 4 — CLAUDE.md

```bash
cp ~/.claude/CLAUDE.md CLAUDE.md
```

### Step 5 — Commit and push

```bash
git add .github/ .pre-commit-config.yaml .secrets.baseline CLAUDE.md
git commit -m "chore: bootstrap CI, pre-commit, and agent instructions"
git push -u origin chore/bootstrap-ci
gh pr create \
  --title "chore: bootstrap CI workflows and pre-commit config" \
  --body "Adds standard CI workflows, pre-commit hooks, and agent instructions." \
  --base main
```

### Required CI for every repo

- ci.yml — lint (ruff for Python), tests (pytest), type check (mypy)
- security.yml — pip-audit, Trivy (non-blocking), CodeQL, OpenSSF Scorecard
- container.yml — build and push to ghcr.io (if Containerfile exists)
- dependabot.yml — automated dependency updates
- pre-commit — detect-secrets, ruff, mypy, bandit, shellcheck as appropriate

---

## rag-suite architecture context

Services and ports:
- ragpipe           :8090  — RAG proxy, embedding, reranking, grounding, citations
- ragstuffer        :8091  — ingestion (Drive, git, web)
- ragstuffer-mpep   :8093  — second ragstuffer for USPTO/MPEP collection
- ragwatch          :9090  — Prometheus metrics aggregator
- ragdeck           :8092  — admin UI (FastAPI + frontend)
- ragorchestrator   :8095  — LangGraph agentic orchestration layer
- Ollama/Vulkan     :8080  — LLM inference (Qwen3-32B dense Q4_K_M, ~19GB GTT)
- Qdrant            :6333  — vector store (4 collections: personnel, nato, mpep, documents)
- Postgres          :5432  — docstore (chunks+titles, collections, query_log partitioned)
- LiteLLM           :4000  — model proxy
- Open WebUI        :3000  — chat interface

Key architectural decisions:
- Collections split: personnel/nato/mpep/documents — separate Qdrant collections
  per domain. Reranker scores improved dramatically after split.
- Title hydration: chunks have title column. ragpipe surfaces titles in
  rag_metadata.cited_chunks as objects {id, title, source}. System prompt
  instructs model to cite by title in prose while emitting [doc_id:chunk_id].
- Citation format: [doc_id:chunk_id] e.g. [133abba5-9eeb-5a99-8a5c:2]
  NOT [doc_id:133abba5...:chunk_id:2] — the verbose format is a bug.
- Grounding classification: corpus | general | mixed
- Hot-reload: POST /admin/reload-routes and POST /admin/reload-prompt
  avoid restarts for config changes. Use these instead of restarting ragpipe.
- Qdrant IPv4: always use curl -4 or set QDRANT__SERVICE__HOST=:: in quadlet.
  Qdrant binds IPv4 only; Fedora resolves localhost to ::1 by default.
- LLM model: Qwen3-32B dense Q4_K_M (~19GB GTT). 32B fully activated.
  Use /nothink for structured output tasks to prevent thinking mode consuming tokens.
- ragorchestrator: LangGraph supervisor above ragpipe. Adaptive complexity
  classifier, Self-RAG reflection, multi-pass retrieval. Calls ragpipe as a tool.
  Disable web search until TAVILY_API_KEY configured (DISABLE_WEB_SEARCH=true).

Ragas quality baseline (ragprobe):
- Phase 0 baseline:
    Faithfulness: 0.700 | Answer Relevance: 0.843
    Context Precision: 0.714 | Context Recall: 0.250
- After Phase 1 CRAG:
    Overall Faithfulness: 0.971 (+0.271)
    MPEP/patent Faithfulness: 0.933 (+0.600)
    Personnel Faithfulness: 1.000 (+0.033)
