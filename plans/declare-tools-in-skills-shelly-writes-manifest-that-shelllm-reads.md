# Plan: Docker tool mounting via skill-declared dependencies

## Context

When shellm runs in Docker, only `shellm` itself is mounted (`-v shellm_path:/usr/local/bin/shellm:ro`). Companion tools (`mem`, `skills`) aren't available inside the container, and env vars like `MEM_DIR`, `SKILLS_DIR`, `SHELLY_KERNEL_DIR` aren't forwarded. Their target directories aren't mounted either. This means skills don't work on the first turn of a conversation — only on resume turns, which run locally.

The fix: skills declare their tool dependencies in SKILL.md frontmatter. shelly reads these, resolves binary paths, and writes a manifest file in the workspace. shellm reads the manifest during Docker setup to mount binaries and forward env vars + directories. No new user-facing env vars.

## Files to modify

1. **`shellm`** — Read manifest in `docker_setup()`, mount binaries, forward env vars + auto-mount directories
2. **`shelly`** — Write manifest before calling shellm, add `tools:` to bootstrapped mem SKILL.md

## SKILL.md format change

Add `tools:` to frontmatter — a YAML list of binary names the skill needs at runtime:

```yaml
---
name: mem
description: Life context and memory system
tools: [mem]
---
```

## Manifest format: `.shellm-docker.conf`

Written by shelly to the workspace (`$run_dir/`) before calling shellm:

```
mount-bin=/usr/local/bin/mem
mount-bin=/usr/local/bin/skills
forward-env=MEM_DIR
forward-env=SKILLS_DIR
forward-env=SHELLY_KERNEL_DIR
```

shellm reads this in `docker_setup()`. If the file doesn't exist (standalone shellm usage), no extra mounts happen.

---

## Changes to `shellm`

### 1. New global array (~line 28, with other internal state)

```bash
_DOCKER_FORWARD_ENVS=()
```

### 2. Modify `docker_setup()` (~line 304, after building `extra_mounts` for context files)

Read `.shellm-docker.conf` from workspace:
- `mount-bin=PATH` → resolve basename, append `-v "$path:/usr/local/bin/$name:ro"` to `extra_mounts` (with `seen_dirs` dedup to avoid double-mounting)
- `forward-env=VAR` → read `${!var}` from env; if value is an existing directory, resolve to absolute path and append mount to `extra_mounts`; store var name in `_DOCKER_FORWARD_ENVS`

### 3. Modify `run_loop()` env_vars building (~line 969, after existing env_vars entries)

Append each `_DOCKER_FORWARD_ENVS` entry:
```bash
for var in "${_DOCKER_FORWARD_ENVS[@]+"${_DOCKER_FORWARD_ENVS[@]}"}"; do
    local val="${!var:-}"
    [[ -n "$val" ]] && env_vars+=("$var=$val")
done
```

---

## Changes to `shelly`

### 1. New helper: `write_docker_manifest()` (after `ensure_kernel()`, ~line 104)

```bash
write_docker_manifest() {
    local run_dir="$1"
    local manifest="$run_dir/.shellm-docker.conf"
    local -a lines=()

    # Kernel skills declare tools in frontmatter
    if [[ -d "$SHELLY_KERNEL_DIR" ]]; then
        for skill_dir in "$SHELLY_KERNEL_DIR"/*/; do
            [[ -f "${skill_dir}SKILL.md" ]] || continue
            local tools_line
            tools_line=$(sed -n '/^---$/,/^---$/{ /^tools:/{ s/^tools:[[:space:]]*//; p; } }' "${skill_dir}SKILL.md")
            [[ -z "$tools_line" ]] && continue
            # Parse [mem, skills] or mem
            local tool
            while IFS= read -r tool; do
                [[ -z "$tool" ]] && continue
                local tool_path
                tool_path=$(command -v "$tool" 2>/dev/null) || continue
                lines+=("mount-bin=$tool_path")
            done < <(printf '%s' "$tools_line" | tr -d '[]' | tr ',' '\n' | sed 's/^[[:space:]]*//;s/[[:space:]]*$//')
        done
    fi

    # Kernel-kernel: always mount skills binary
    local skills_path
    skills_path=$(command -v skills 2>/dev/null) || true
    [[ -n "$skills_path" ]] && lines+=("mount-bin=$skills_path")

    # Forward env vars that shelly sets
    lines+=("forward-env=MEM_DIR")
    lines+=("forward-env=SKILLS_DIR")
    lines+=("forward-env=SHELLY_KERNEL_DIR")

    printf '%s\n' "${lines[@]}" > "$manifest"
}
```

Uses the same sed-based frontmatter parsing already used in `assemble_context()` (line 192).

### 2. Modify `cmd_send()` (~line 249, before shellm invocation)

Create run_dir and write manifest before calling shellm:

```bash
mkdir -p "$run_dir"
write_docker_manifest "$run_dir"
```

### 3. Update `ensure_kernel()` (~line 78)

Add `tools: [mem]` to the bootstrapped mem SKILL.md frontmatter:

```yaml
---
name: mem
description: Life context and memory system
tools: [mem]
---
```

---

## Verification

```bash
# Syntax check both scripts
bash -n shellm && bash -n shelly

# Verify manifest content
shelly reset
mkdir -p .shelly/identities/shelly/run
# Temporarily source write_docker_manifest or run shelly send and inspect:
cat .shelly/identities/shelly/run/.shellm-docker.conf

# Test with Docker: mem should work on first turn
shelly reset && shelly send "Run: mem list"

# Test without Docker: no regression
SHELLM_NO_DOCKER=1 shelly send "What is 2+2?"
```
