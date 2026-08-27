# Terraform: shellm demo box (AWS + Cloudflare Zero Trust)

One `terraform apply` builds the whole stack from `deploy/DEPLOY.md`:

- **AWS**: a t4g.large Ubuntu 24.04 (arm64) instance with a 40 GB gp3 disk,
  a security group with **zero inbound rules**, and an SSM instance profile
  so you get a shell without SSH. First boot runs `deploy/setup.sh`
  (app under `/opt/shellm/app`, systemd service on `127.0.0.1:8080`),
  installs cloudflared with the tunnel token, and pins CORS to your
  hostname.
- **Cloudflare**: a remotely-configured tunnel with an ingress rule to
  `localhost:8080`, the proxied CNAME (`agents.example.com` →
  `<tunnel>.cfargotunnel.com`), and an Access application + email-allowlist
  policy. Auth lives entirely here; the app has none.

## Prerequisites

- Terraform >= 1.5
- AWS credentials in your environment (`AWS_PROFILE` / `aws configure`)
  with rights to manage EC2, IAM roles/instance profiles, and security
  groups.
- A Cloudflare API token in `CLOUDFLARE_API_TOKEN` with:
  - **Account → Cloudflare Tunnel → Edit**
  - **Account → Access: Apps and Policies → Edit**
  - **Account → Access: Organizations, Identity Providers, and Groups → Edit**
    (for the email-OTP login method)
  - **Zone → DNS → Edit** (scoped to your zone)
- Your Cloudflare **account ID** and the zone's **zone ID** (both on the
  dashboard).

## AWS permissions

Granularity is IAM policy on the user/role your CLI credentials belong to
(the CLI itself is just a passthrough). Two sane options:

- **Personal/sandbox account:** attach `AdministratorAccess` and move on.
- **Scoped:** attach `aws-policy.json` from this directory. It grants full
  EC2 (Terraform's describe/create/destroy churn makes narrower EC2
  painful), IAM confined to `shellm-*` roles/instance-profiles (including
  the sensitive `iam:PassRole`), and the SSM actions for shell sessions:

  ```bash
  aws iam create-policy --policy-name shellm-terraform \
      --policy-document file://aws-policy.json
  aws iam attach-user-policy --user-name <you> \
      --policy-arn arn:aws:iam::<account-id>:policy/shellm-terraform
  ```

For the SSM shell you'll also need the client plugin — see "Install the
tools" below. (It's first-party AWS, Apache-2.0, open source at
github.com/aws/session-manager-plugin; not a daemon — the CLI spawns it
per session.)

## What goes where

- **`terraform.tfvars`** — facts about the infrastructure (region, account
  and zone IDs, domain, emails, branch). No secrets live here; edit when
  the infra should change. (Gitignored regardless.)
- **Shell environment** — credentials for the tools: AWS creds live in
  `~/.aws` via `aws configure` (no export needed for the default profile),
  and `CLOUDFLARE_API_TOKEN` is the one real export, handled by direnv:
  `.envrc` (from `envrc.example`) loads it — via 1Password — when you cd
  into this directory and unloads it when you leave. direnv refuses to run
  an edited `.envrc` until you `direnv allow` it again. Prefer no plugin?
  `env.sh.example` is the manual `source` equivalent.

## Setup

### 0. Install the tools (macOS / brew)

```bash
brew install awscli                       # AWS CLI v2
brew tap hashicorp/tap
brew install hashicorp/tap/terraform      # brew core's terraform is frozen at 1.5.7
brew install --cask session-manager-plugin
brew install --cask 1password-cli         # the `op` command (optional but recommended)
brew install direnv
echo 'eval "$(direnv hook bash)"' >> ~/.bashrc && exec bash
```

`session-manager-plugin` is the client-side helper that gives
`aws ssm start-session` an interactive terminal — the box has no SSH and
no inbound ports, so SSM sessions (relayed outbound through AWS,
authorized by your IAM creds) are the only shell path. The AWS CLI finds
the plugin on PATH; you never invoke it directly.

For `op`: in the 1Password app enable Settings → Developer →
"Integrate with 1Password CLI", then store the Cloudflare token once:

```bash
op item create --category=apiCredential --title=cloudflare-tf \
    --vault=Private credential=<paste-token>
```

Verify everything:

```bash
aws sts get-caller-identity        # AWS creds work
terraform version                  # from the hashicorp tap
session-manager-plugin             # "...was installed successfully"
op vault list                      # 1Password CLI integrated + unlocked
```

### 1. Configure and apply

```bash
aws configure                                  # once; verify: aws sts get-caller-identity
cd deploy/terraform
cp terraform.tfvars.example terraform.tfvars   # fill in IDs, domain, emails
cp envrc.example .envrc                        # wire up the CF token (via op or paste)
direnv allow                                   # re-run after any .envrc edit
terraform init
terraform plan
terraform apply
```

First boot takes ~5 minutes (apt, uv/bun install, frontend build). Then
open the `url` output — you'll hit the Access login; anyone not on
`allowed_emails` gets blocked.

### The .env (API keys + model choice)

The box's whole `.env` lives in **one SSM SecureString parameter** — the
provider API key(s) plus config like `SHELLM_MODEL`. This is the only
secrets path: nothing sensitive enters tfvars or Terraform state. Upload
from your laptop:

```bash
aws ssm put-parameter --name /shellm/env --type SecureString \
    --value "$(cat /path/to/headlong/.env)" --overwrite \
    --region <your-region>
```

**First boot** writes the parameter to `/opt/shellm/app/.env` (mode 600),
so instance rebuilds self-heal; the instance role can read exactly that
one parameter and nothing else. Parameter name = the `env_parameter`
variable (default `/shellm/env`; `""` disables). Standard-tier parameters
cap at 4 KB — plenty for an env file.

Which key(s) to include is a `SHELLM_MODEL` decision — e.g.
`SHELLM_MODEL=openai/gpt-oss-120b` routes via OpenRouter and needs
`OPENROUTER_API_KEY`; a `claude-*` model needs `ANTHROPIC_API_KEY`.
An `openai.gpt-*` model routes through Amazon Bedrock Mantle and needs
`AWS_BEARER_TOKEN_BEDROCK` plus the matching `AWS_REGION`.
Host installs may instead use `AWS_PROFILE`; Headlong refreshes the profile's
credentials through AWS CLI and inherits its configured Region.
Switching providers is just a different parameter value. Optional:
`SHELLM_FAST_MODEL` sets a cheap model class for utility calls (run
summaries, `mem search`) — worth setting when `SHELLM_MODEL` is an
expensive model; pointless when it's already a cheap one.

**Rotating keys / changing model** — user-data runs *once per instance*,
so after `put-parameter` the box needs one of:

```bash
# option A: rebuild (clean, ~5 min gap; identities are wiped)
terraform apply -replace=aws_instance.shellm

# option B: re-fetch in place (in an SSM session, no downtime)
sudo -u shellm bash -c 'aws ssm get-parameter --name /shellm/env \
    --with-decryption --region <your-region> \
    --query Parameter.Value --output text > /opt/shellm/app/.env'
```

With option B, a rotated *key* applies from the next LLM call (`llm` and
`shellm` re-read `.env` on every invocation) — but a changed
`SHELLM_MODEL` needs a thinker stop/start in the UI: running dispatchers
export the model they started with.

**Fallback — parameter missing at boot:** the bootstrap warns and
continues with the seeded stub; install the `.env` by hand in an SSM
session (`read -rs` keeps the key out of history and `ps`):

```bash
$(terraform output -raw ssm_session_command)
read -rs KEY                              # paste the key, press enter
printf 'OPENROUTER_API_KEY=%s\nSHELLM_MODEL=openai/gpt-oss-120b\n' "$KEY" \
    | sudo -u shellm tee /opt/shellm/app/.env >/dev/null
unset KEY
```

Whatever the provider: use a **dedicated key with a hard spend limit**
(OpenRouter: prepaid credits *are* the cap; Anthropic: set a spend cap).
The agent executes arbitrary bash on this box; the cap is the real
safety net.

## Day-2 operations

The common ones are wrapped as scripts in `deploy/scripts/` (they need AWS
creds + this directory's terraform state, but not the Cloudflare token):

| Script | Does |
|---|---|
| `deploy/scripts/update` | Deploy the latest **pushed** commit: streams deploy/update.sh on the box (pull, rebuild, restart, health check). Warns when your local branch is ahead of origin. `--dry-run` to preview. |
| `deploy/scripts/status` | Instance state + service health + deployed commit |
| `deploy/scripts/shell` | Interactive SSM shell on the box |
| `deploy/scripts/stop` / `start` | Pause/resume billing (disk + identities survive) |

There's also an in-dash path: click the **build stamp** in the navbar →
"Pull latest & restart" (the server pulls its repo and restarts itself via
systemd; enabled by `HEADLONG_WEB_SELF_UPDATE=1` in the unit).

| Task | How |
|---|---|
| Shell on the box | `deploy/scripts/shell` (or `$(terraform output -raw ssm_session_command)`) |
| Watch first-boot progress | in a session: `tail -f /var/log/shellm-bootstrap.log` |
| App logs | `journalctl -u headlong-web -f` |
| Update the app (after pushing!) | `deploy/scripts/update` (or `eval "$(terraform output -raw update_command)"`) |
| Add/remove viewers | edit `allowed_emails`, `terraform apply` |
| Rotate keys / change model | `aws ssm put-parameter ... --overwrite`, then rebuild or re-fetch in place — see "The .env" above |
| Panic | Kill All in the UI → `headlong-killall` on the box → stop the instance |
| Rebuild from scratch | `terraform destroy && terraform apply` — `.env` self-heals from the SSM parameter (identities/trajectories are lost — copy them off first if they matter) |
| Pause billing | stop the instance in the console (~$3/mo for the disk); the tunnel reconnects on start |

## Troubleshooting

- **Bootstrap log ends with `deploy/setup.sh: No such file or directory`**:
  the box cloned a ref that predates the `deploy/` folder — almost always
  `shellm_branch` unset/commented in tfvars (default is `main`). Set the
  branch, push anything missing, and `terraform apply` (user_data changed,
  so the instance replaces itself).
- **Golden rule: the box runs what's *pushed* to `shellm_branch`, never
  your laptop's working tree.** Any local fix needs commit+push before the
  box can see it. Verify what the remote actually has with
  `git ls-tree -r origin/<branch> --name-only | grep <file>`.
- **Thinker logs loop with `<PROVIDER>_API_KEY is not set`**: the box's
  `.env` is missing, stale, or lacks the key that `SHELLM_MODEL` implies
  (e.g. an `openai/...` OpenRouter model with no `OPENROUTER_API_KEY`).
  Check the SSM parameter's contents and redo "The .env" steps.

## Notes & caveats

- **State contains secrets** (the tunnel token). State and
  `terraform.tfvars` are gitignored — keep it that way, or move state to
  a private S3 bucket once this outlives the demo.
- The Cloudflare provider is **pinned to v4** (`~> 4.52`). v5 renamed and
  reshaped the tunnel/Access resource schemas; upgrading means rewriting
  those ~5 resources, so don't bump the pin casually.
- The instance lives in your **default VPC** in a public subnet (it needs
  outbound internet for the tunnel and LLM APIs; nothing can dial in).
  If your account has no default VPC, add a small vpc module or create
  one first.
- `user_data_replace_on_change = true` means changing repo/branch/emails
  that feed user_data **recreates the instance** on apply — that's the
  burnable-box philosophy working as intended, but remember it wipes
  identities.
- SSM Session Manager needs no SG rules or public IP settings changes —
  the agent is preinstalled on Ubuntu AMIs and dials out, same as the
  tunnel.

## Cheatsheet

```bash
cd deploy/terraform          # direnv loads CLOUDFLARE_API_TOKEN on cd

# deploy / apply infra changes (instance replaces on user_data changes)
terraform plan
terraform apply

# follow first boot until "shellm bootstrap done" (~5 min)
$(terraform output -raw ssm_session_command)
tail -f /var/log/shellm-bootstrap.log

# confirm the .env landed from SSM (key names only)
sudo cut -d= -f1 /opt/shellm/app/.env

# rotate the node WITHOUT any terraform/code change (fresh box, same infra;
# wipes identities, re-pulls branch + .env parameter on boot)
terraform apply -replace=aws_instance.shellm

# update secrets/model, then rotate (or re-fetch in place, see above)
aws ssm put-parameter --name /shellm/env --type SecureString \
    --value "$(cat ../../.env)" --overwrite --region <your-region>
terraform apply -replace=aws_instance.shellm

# shut down the node (stops billing ~$60/mo -> ~$3/mo for the disk;
# tunnel shows down, everything on disk survives)
aws ec2 stop-instances --region <your-region> \
    --instance-ids "$(terraform output -raw instance_id)"

# start it back up (tunnel + headlong-web come back via systemd)
aws ec2 start-instances --region <your-region> \
    --instance-ids "$(terraform output -raw instance_id)"

# destroy everything (instance, tunnel, DNS, Access app)
terraform destroy
```
