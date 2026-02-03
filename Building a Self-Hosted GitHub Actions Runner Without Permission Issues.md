# Building a Self-Hosted GitHub Actions Runner Without Permission Issues

Self-hosted GitHub Actions runners provide speed, control, and cost savings — until Docker enters the picture and starts breaking your builds with permission errors.

This guide shows how to build a **production-grade Linux self-hosted runner** that **never fails due to file permission issues**, even when using Docker-based actions such as **Azure Static Web Apps**.

This setup is battle-tested and designed to work **without modifying workflows** in every repository.

---

## The Problem: Why Permission Issues Happen

On Linux self-hosted runners:

- The GitHub runner service runs as a **non-root user**
- Many GitHub Actions run **Docker containers**
- Docker containers default to **UID 0 (root)**
- Containers write files into the GitHub workspace
- Those files become **root-owned**
- On the next job, GitHub Actions attempts cleanup and fails

This is expected Linux behavior — not a GitHub bug.

---

## Design Goals

1. Runner never runs as root  
2. Docker is allowed safely  
3. No workflow hacks  
4. Crash-safe recovery  
5. Scales to multiple runners per host  

---

## High-Level Solution

We use **GitHub Actions Runner Job Hooks**:

- `job-started`: fixes leftovers from failed jobs
- `job-completed`: fixes files created during the job

Hooks run on the host and normalize file ownership automatically.

---

## Architecture Overview

- Linux user: `cliff`
- Runner installed as a systemd service
- Docker enabled
- Restricted passwordless `sudo chown`
- Automatic workspace ownership repair

---

## Step 1: Create a Dedicated Runner User

```bash
sudo useradd -m -s /bin/bash cliff
sudo usermod -aG wheel,docker cliff
su - cliff
```

---

## Step 2: Install the GitHub Actions Runner

```bash
mkdir ~/actions-runner
cd ~/actions-runner
curl -O -L https://github.com/actions/runner/releases/download/v2.331.0/actions-runner-linux-x64-2.331.0.tar.gz
tar xzf actions-runner-linux-x64-2.331.0.tar.gz
./config.sh --url https://github.com/ORG/REPO --token <TOKEN>
sudo ./svc.sh install
sudo ./svc.sh start
```

---

## Step 3: Allow Safe Permission Fixing

```bash
sudo bash -c 'cat > /etc/sudoers.d/90-github-runner-perms << "EOF"
cliff ALL=(root) NOPASSWD: /bin/chown
EOF
chmod 0440 /etc/sudoers.d/90-github-runner-perms
visudo -cf /etc/sudoers.d/90-github-runner-perms
```
---

## Step 4: Create Job Hooks

```bash
mkdir -p ~/actions-runner/hooks
```

### job-started
```bash
cat > ~/actions-runner/hooks/job-started.sh <<'EOF'
#!/usr/bin/env bash
if [[ -n "${GITHUB_WORKSPACE:-}" ]]; then
  sudo chown -R "$(id -u)":"$(id -g)" "$GITHUB_WORKSPACE" || true
fi
EOF
chmod +x ~/actions-runner/hooks/job-started.sh
```

### job-completed
```bash
cat > ~/actions-runner/hooks/job-completed.sh <<'EOF'
#!/usr/bin/env bash
if [[ -n "${GITHUB_WORKSPACE:-}" ]]; then
  sudo chown -R "$(id -u)":"$(id -g)" "$GITHUB_WORKSPACE" || true
fi
EOF
chmod +x ~/actions-runner/hooks/job-completed.sh
```

---

## Step 5: Register Hooks

```bash
cat > ~/actions-runner/.env <<'EOF'
ACTIONS_RUNNER_HOOK_JOB_STARTED=/home/cliff/actions-runner/hooks/job-started.sh
ACTIONS_RUNNER_HOOK_JOB_COMPLETED=/home/cliff/actions-runner/hooks/job-completed.sh
EOF
sudo systemctl restart actions.runner.<RUNNER_NAME>.service
```

---

## Multiple Runners on One Host

Recommended layout:

```
/home/cliff/actions-runner-repoA
/home/cliff/actions-runner-repoB
```

Each runner has its own workspace and service.

---

## Anti-Patterns

- Running runners as root
- Sharing runner directories
- Blanket sudo permissions

---

## Final Result

- No permission-related CI failures
- Docker-compatible
- Secure and scalable
- Zero workflow changes required

---
Adapting This for Multiple Runners on One Host

Running multiple runners on one machine is common and safe if done correctly.

Recommended Layout
/home/cliff/actions-runner-repoA
/home/cliff/actions-runner-repoB
/home/cliff/actions-runner-repoC


Each runner:

has its own _work directory

has its own systemd service

uses the same hook logic, scoped to its workspace

Installing an Additional Runner
cd /home/cliff
mkdir actions-runner-repoB
cd actions-runner-repoB

curl -O -L https://github.com/actions/runner/releases/download/v2.331.0/actions-runner-linux-x64-2.331.0.tar.gz
tar xzf actions-runner-linux-x64-2.331.0.tar.gz

./config.sh --url https://github.com/ORG/REPO_B --token <TOKEN>
sudo ./svc.sh install
sudo ./svc.sh start

Reusing Hooks Across Runners

Copy hooks into each runner directory:

for d in /home/cliff/actions-runner-*; do
  mkdir -p "$d/hooks"
  cp /home/cliff/actions-runner/hooks/*.sh "$d/hooks/"
  chmod +x "$d/hooks/"*.sh
done


Create a .env per runner:

cat > /home/cliff/actions-runner-repoB/.env <<'EOF'
ACTIONS_RUNNER_HOOK_JOB_STARTED=/home/cliff/actions-runner-repoB/hooks/job-started.sh
ACTIONS_RUNNER_HOOK_JOB_COMPLETED=/home/cliff/actions-runner-repoB/hooks/job-completed.sh
EOF


Restart the runner:

sudo systemctl restart actions.runner.<REPO_B_RUNNER>.service

Why This Is Safe

Each runner has its own workspace

GITHUB_WORKSPACE is guaranteed to be runner-specific

Hooks only touch the active workspace

Docker side effects are neutralized automatically
*End of document*
