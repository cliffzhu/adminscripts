# Building a Self-Hosted GitHub Actions Runner Without Permission Issues

Self-hosted GitHub Actions runners provide speed, control, and cost savings — but Docker-based actions can produce Linux file-permission failures when containers create root-owned files in the workspace.

This guide shows how to build a production-grade Linux self-hosted runner that avoids file permission issues (even for Docker-based actions) without modifying your workflows.

Table of contents
- Prerequisites
- The problem: why permission issues happen
- Design goals
- High-level solution
- Architecture overview
- Steps
  - Step 1: Create a dedicated runner user
  - Step 2: Install the GitHub Actions runner
  - Step 3: Allow safe permission fixing
  - Step 4: Create job hooks
  - Step 5: Register hooks
- Multiple runners on one host
- Anti-patterns
- Final result

---

Prerequisites
- A Linux host with Docker installed (if you want to run Docker-based actions).
- root or sudo access to configure users and systemd.
- Decide on:
  - RUNNER_USER (example: cliff)
  - RUNNER_HOME (example: /home/cliff/actions-runner)
  - RUNNER_NAME (the name you used when configuring the runner service)
  - ORG/REPO and a registration TOKEN for the runner

---

The problem: why permission issues happen
- The GitHub runner service runs as a non-root user.
- Many GitHub Actions run inside Docker containers.
- Containers often run as UID 0 (root).
- Containers write files into the GitHub workspace.
- Those files become root-owned on the host.
- On the next job, the runner attempts cleanup and may fail with permission errors.

This is expected Linux behavior — not a GitHub bug.

---

Design goals
1. Runner never runs as root.  
2. Docker is allowed safely.  
3. No workflow hacks or per-repo changes.  
4. Crash-safe recovery.  
5. Scales to multiple runners per host.  

---

High-level solution
Use GitHub Actions Runner Job Hooks:
- job-started: fix leftovers from prior failed jobs.
- job-completed: fix files created during the job.

Hooks run on the host and normalize file ownership automatically (chown back to the runner user).

---

Architecture overview
- Linux user: RUNNER_USER (example: cliff)  
- Runner installed as a systemd service (installed via svc.sh)  
- Docker enabled on the host  
- Restricted, passwordless sudo allowed for chown (only what’s necessary)  
- Hooks automatically repair workspace ownership

---

Steps

Step 1: Create a dedicated runner user
Replace RUNNER_USER with your chosen user.
```bash
# example
sudo useradd -m -s /bin/bash cliff
sudo usermod -aG wheel,docker cliff
su - cliff
```

Step 2: Install the GitHub Actions Runner
Replace ORG/REPO and <TOKEN> with your organization/repo and registration token. Adjust runner version as needed.
```bash
RUNNER_HOME="$HOME/actions-runner"
mkdir -p "$RUNNER_HOME"
cd "$RUNNER_HOME"

curl -O -L https://github.com/actions/runner/releases/download/v2.331.0/actions-runner-linux-x64-2.331.0.tar.gz
tar xzf actions-runner-linux-x64-2.331.0.tar.gz

# configure (replace URL and token)
./config.sh --url https://github.com/ORG/REPO --token <TOKEN>

# install and start the service (may require sudo)
sudo ./svc.sh install
sudo ./svc.sh start
```

Step 3: Allow safe permission fixing
Create a sudoers drop-in that allows the runner user to run chown without a password. This example keeps the command general; if you want to lock it down further, restrict the allowed arguments or the path(s) under which chown may operate.

```bash
sudo bash -c 'cat > /etc/sudoers.d/90-github-runner-perms << "EOF"
cliff ALL=(root) NOPASSWD: /bin/chown
EOF'
sudo chmod 0440 /etc/sudoers.d/90-github-runner-perms
sudo visudo -cf /etc/sudoers.d/90-github-runner-perms
```

Notes:
- Replace `cliff` with your RUNNER_USER.
- For stricter security you can allow only a chown invocation that targets the runner workspace root(s).

Step 4: Create job hooks
Create a hooks directory under the runner home and add `job-started` and `job-completed` scripts. Use the runner user's UID:GID to restore ownership.

```bash
RUNNER_HOME="/home/cliff/actions-runner"
mkdir -p "$RUNNER_HOME/hooks"
```

job-started (fix any leftovers before a job starts)
```bash
cat > "$RUNNER_HOME/hooks/job-started.sh" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail

if [[ -n "${GITHUB_WORKSPACE:-}" ]]; then
  # Restore ownership of the workspace to the runner user
  sudo /bin/chown -R "$(id -u)":"$(id -g)" "$GITHUB_WORKSPACE" || true
fi
EOF
chmod +x "$RUNNER_HOME/hooks/job-started.sh"
```

job-completed (fix files created during the job)
```bash
cat > "$RUNNER_HOME/hooks/job-completed.sh" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail

if [[ -n "${GITHUB_WORKSPACE:-}" ]]; then
  sudo /bin/chown -R "$(id -u)":"$(id -g)" "$GITHUB_WORKSPACE" || true
fi
EOF
chmod +x "$RUNNER_HOME/hooks/job-completed.sh"
```

Step 5: Register hooks
Create or update the runner's `.env` to point to the hook scripts and restart the runner service. Replace paths and RUNNER_NAME as appropriate.
```bash
cat > "$RUNNER_HOME/.env" <<EOF
ACTIONS_RUNNER_HOOK_JOB_STARTED=$RUNNER_HOME/hooks/job-started.sh
ACTIONS_RUNNER_HOOK_JOB_COMPLETED=$RUNNER_HOME/hooks/job-completed.sh
EOF

# restart the runner service (replace <RUNNER_NAME> with your runner service name)
sudo systemctl restart actions.runner.<RUNNER_NAME>.service
```

---

Multiple runners on one host
Recommended layout (per-runner directories):
```
/home/cliff/actions-runner-repoA
/home/cliff/actions-runner-repoB
/home/cliff/actions-runner-repoC
```

Each runner:
- has its own _work directory and workspace,
- runs as the same runner user (or a different user if you prefer),
- has its own systemd service,
- uses the same hook logic, but each .env should point to that runner’s hooks.

Installing another runner (example)
```bash
cd /home/cliff
mkdir actions-runner-repoB
cd actions-runner-repoB

curl -O -L https://github.com/actions/runner/releases/download/v2.331.0/actions-runner-linux-x64-2.331.0.tar.gz
tar xzf actions-runner-linux-x64-2.331.0.tar.gz

./config.sh --url https://github.com/ORG/REPO_B --token <TOKEN>
sudo ./svc.sh install
sudo ./svc.sh start
```

Copy hooks into each runner and create a per-runner `.env`:
```bash
for d in /home/cliff/actions-runner-*; do
  mkdir -p "$d/hooks"
  cp /home/cliff/actions-runner/hooks/*.sh "$d/hooks/"
  chmod +x "$d/hooks/"*.sh

  cat > "$d/.env" <<EOF
ACTIONS_RUNNER_HOOK_JOB_STARTED=$d/hooks/job-started.sh
ACTIONS_RUNNER_HOOK_JOB_COMPLETED=$d/hooks/job-completed.sh
EOF
done
```

Then restart each runner service:
```bash
sudo systemctl restart actions.runner.<REPO_B_RUNNER>.service
```

Why this is safe
- GITHUB_WORKSPACE is runner-specific, so hooks only touch that workspace.
- Hooks run on the host with the runner user's privileges (sudo only used for chown).
- Docker side effects are neutralized automatically because hooks normalize ownership before/after jobs.

---

Anti-patterns
- Running the runner as root.
- Sharing runner directories between services.
- Granting blanket sudo permissions beyond the minimum required.
- Modifying workflows to try to handle root-owned files (this solution avoids that).

---

Final result
- No permission-related CI failures caused by Docker-created files.
- Docker-compatible workflows continue to work without modification.
- Secure, scalable setup that supports multiple runners on one host.

End of document.