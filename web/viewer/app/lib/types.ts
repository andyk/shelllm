// Wire types for the shellm web viewer API.

export interface Config {
  root: string;
  version: string;
  controls_enabled: boolean;
  self_update_enabled: boolean;
  default_send_from: string | null;
  git_commit: string | null;
  git_branch: string | null;
}

export interface LlmHealthIdentity {
  id: string;
  name: string;
  live: boolean;
  failures_1h: number;
  failures_15m: number;
  last_failure: { ts: string; content: string } | null;
  cadence: {
    recent_median_s: number;
    baseline_median_s: number | null;
    recent_n: number;
  } | null;
}

export interface LlmLastCall {
  ok: boolean;
  ts: string | null;
  provider: string | null;
  model: string | null;
  kind: "credit" | "auth" | "rate" | "other" | null;
  http_code: number | string | null;
  message: string | null;
}

export interface LlmHealth {
  status: "ok" | "degraded" | "erroring" | "unknown";
  failures_15m: number;
  failures_1h: number;
  cadence_slow: boolean;
  checked_at: string;
  identities: LlmHealthIdentity[];
  last_call?: LlmLastCall | null;
}

export interface LlmProbeResult {
  ok: boolean;
  latency_ms: number;
  model: string | null;
  provider?: string | null;
  error?: string;
}

export interface SelfUpdateResult {
  ok: boolean;
  updated: boolean;
  restarting: boolean;
  commit?: string;
  from_commit?: string;
  to_commit?: string;
}

export interface DispatcherStatus {
  running: boolean;
  pid: number | null;
}

export interface Identity {
  id: string;
  name: string;
  path_rel: string;
  created: string | null;
  root_trajectory: string | null;
  group: string;
  live: boolean;
  last_activity_ts: string | null;
  step_count: number;
  dispatcher: DispatcherStatus;
  thinkers_total: number;
  thinkers_active: number;
  steps_in_flight: number;
}

export type ThinkerState =
  | "stopped"
  | "idle"
  | "active"
  | "running"
  | "draining"
  | "disabled";

export interface ThinkerInfo {
  name: string;
  state: ThinkerState;
  steps_in_flight: number;
  pid: number | null;
  types: string[];
  trigger_self: boolean;
  pending: string[];
  log_bytes: number | null;
  log_mtime: string | null;
}

export interface ThinkersStatus {
  identity: { id: string; name: string };
  dispatcher: DispatcherStatus;
  active_thinkers: number;
  thinkers_total: number;
  thinkers_disabled: number;
  steps_in_flight: number;
  pending_total: number;
  thinkers: ThinkerInfo[];
}

export interface ControlResult {
  ok: boolean;
  action: string;
  names: string[];
  exit_code?: number;
  stdout?: string;
  stderr?: string;
}

export interface ChatMessage {
  ts: string | null;
  step_id: string | null;
  from: string;
  to: string;
  content: string;
  reply_to: string | null;
  filename: string | null;
  source_url: string | null;
  partial?: boolean;
}

export interface ChatLog {
  identity: { id: string; name: string };
  live: boolean;
  messages: ChatMessage[];
  // sent step_id -> "replied" | "no-reply" | "failed"; absent = undecided
  outcomes: Record<string, string>;
}

export interface EnvEntry {
  key: string;
  value: string; // full value for non-secrets, redacted peek for secrets
  secret: boolean;
  overridden?: boolean; // inherited entries only
}

export type ThinkerSyncState =
  | "in_sync"
  | "outdated"
  | "not_installed"
  | "local_only";

export interface ThinkerSyncEntry {
  name: string;
  status: ThinkerSyncState;
  changed_files: string[];
  bundled_version: string | null; // "shorthash · date" of the bundled copy
}

export interface ThinkerSyncStatus {
  bundled_root: string | null;
  thinkers: ThinkerSyncEntry[];
  note: string;
}

export interface ThinkerSyncResult {
  ok: boolean;
  results: { name: string; action: string; files: string[] }[];
}

export interface OpenRouterModel {
  id: string;
  name: string | null;
  context_length: number | null;
  prompt_usd_per_m: number | null;
  completion_usd_per_m: number | null;
}

export interface OpenRouterModels {
  source: "key" | "public" | null; // "key": filtered to this org's key
  has_key: boolean;
  count: number;
  models: OpenRouterModel[];
  error: string | null;
  fetched_at: string;
}

export interface IdentityEnv {
  identity: { id: string; name: string };
  env: EnvEntry[];
  inherited: EnvEntry[];
  note: string;
}

export interface KillallResult {
  ok: boolean;
  dry_run: boolean;
  stdout: string;
  stderr: string;
}

export interface ImportResult {
  ok: boolean;
  imported: { id: string; name: string }[];
}

export interface RecapStepRef {
  step: string;
  note: string;
}

export interface RecapTheme {
  name: string;
  description: string;
  episodes: number[];
  key_steps: RecapStepRef[];
}

export interface RecapEpisode {
  idx: number;
  first_step: string;
  last_step: string;
  first_ts: string;
  last_ts: string;
  n_steps: number;
  partial: boolean;
  title: string;
  summary: string;
  themes: string[];
  notable_steps: RecapStepRef[];
}

export interface Recap {
  identity: { id: string; name: string };
  available: boolean;
  refreshing: boolean;
  new_steps?: number;
  themes?: {
    generated_at: string;
    model: string;
    arc: string;
    themes: RecapTheme[];
  };
  episodes?: RecapEpisode[];
}

/** One UTC day of the usage series (see headlong_web/usage.py). */
export interface UsageDay {
  rows: number;
  in_msg: number;
  out_msg: number;
  runs: number;
  reasoning: number;
  calls: number;
  in: number;
  out: number;
  think: number;
  /** Where calls/tokens came from: the bin/llm ledger (every call) or the
   * mind log's reasoning-step stamps (shellm runs only, older days). */
  source: "ledger" | "mindlog";
}

export interface UsageModel {
  calls: number;
  in: number;
  out: number;
  think: number;
}

export interface Usage {
  identity: { id: string; name: string };
  available: boolean;
  refreshing: boolean;
  /** Bytes appended to the mind log since the cache was computed. */
  pending_bytes: number;
  generated?: string;
  rows?: number;
  skipped?: number;
  /** The bin/llm usage ledger: lines read, lines without usable usage, and
   * the first day it covers (null when it has no calls yet). */
  ledger?: { rows: number; skipped: number; since: string | null };
  daily?: [string, UsageDay][];
  by_model?: Record<string, UsageModel>;
  totals?: {
    in: number;
    out: number;
    think: number;
    calls: number;
    in_msg: number;
    out_msg: number;
    runs: number;
  };
}

export interface IdentityStatus {
  live: boolean;
  pid_alive: boolean;
  dispatcher_pid: number | null;
  mindlog_mtime: string | null;
  mindlog_bytes: number | null;
  step_count: number;
}

export type ActivityState = "working" | "stalled" | "idle" | "asleep";

export interface QueuedMessage {
  thinker: string;
  from: string | null;
  preview: string | null;
  ts: string | null;
  age_s: number | null;
}

export interface IdentityActivity {
  state: ActivityState;
  dispatcher_running: boolean;
  steps_in_flight: number;
  busy_thinkers: string[];
  last_step_ts: string | null;
  last_step_age_s: number | null;
  run_seconds: number | null;
  stall_after_s: number;
  cadence_s: number | null;
  queued_messages: QueuedMessage[];
  pending_total: number;
}

export interface ResponseEvent {
  ts: string | null;
  from: string;
  outcome: "replied" | "declined";
  path: "inline" | "fast" | null;
  response_s: number;
}

export interface PathStats {
  n: number;
  median_s: number | null;
  p90_s: number | null;
}

export interface InjectionEvent {
  ts: string | null;
  from: string;
  inject_ms: number;
  wait_s: number | null;
  model_s: number | null;
  total_s: number | null;
  path: "inline" | "fast" | null;
}

export interface ModelDaily {
  day: string;
  calls: number;
  in_tok: number;
  out_tok: number;
  think_tok: number;
}

export interface ModelStats {
  calls: number;
  llm_p50_s: number | null;
  llm_p90_s: number | null;
  in_tok: number;
  out_tok: number;
  think_tok: number;
  daily: ModelDaily[];
}

export interface ResponseStats {
  window_days: number;
  replied: number;
  declined: number;
  undecided: number;
  duplicates: number;
  median_s: number | null;
  p90_s: number | null;
  max_s: number | null;
  paths: { fast: PathStats; inline: PathStats };
  injections: InjectionEvent[];
  model: ModelStats;
  recent: ResponseEvent[];
}

export interface IdentityHealth {
  identity: { id: string; name: string };
  activity: IdentityActivity;
  responses: ResponseStats | null;
}

export type StepType =
  | "trajectory"
  | "thought"
  | "action"
  | "idle"
  | "observation"
  | "message"
  | "shellm-run"
  | "prompt"
  | "reasoning"
  | "shell-output"
  | "feedback"
  | "final"
  | "fork"
  | "run-summary"
  | "tp-thought"
  | "human-msg"
  | "agent-msg"
  | "merge";

export type StepSource =
  | "seed"
  | "inner_monologue"
  | "actor"
  | "chat"
  | (string & {})
  | null;

export interface ForkLink {
  child_traj_id: string;
  slug: string;
  resolved: boolean;
}

export interface WritebackLink {
  from_traj: string;
  from_step: string | null;
}

export interface NormalizedStep {
  step_id: string;
  ts: string;
  type: StepType;
  source: StepSource;
  preview: string;
  raw: Record<string, unknown>;
  run_id: string | null;
  source_url?: string | null;
  fork?: ForkLink;
  writeback?: WritebackLink;
}

export interface RunGroup {
  run_id: string;
  trigger_step_id: string | null;
  launched_by: string | null;
  step_ids: string[];
  started_ts: string;
  ended_ts: string | null;
  status: "running" | "done";
  /** Truncated on the wire when huge (head + trailing ACTION kept);
   * fetch the full text via fetchRunCommand when command_truncated. */
  command: string;
  command_truncated?: boolean;
  model: string | null;
  tldr: string | null;
  /** Step index of the last step that mutated this run (delta filtering). */
  last_touch: number;
}

export interface Mindlog {
  traj_id: string;
  dir_rel: string;
  step_count: number;
  /** The requested window (initial ?tail, ?since polls, or ?since+?until
   * history loads); the useMindlog hook stitches windows together. */
  steps: NormalizedStep[];
  runs: RunGroup[];
  live: boolean;
  /** Effective start index of `steps` in the full log (null = 0). */
  since?: number | null;
  identity: { id: string; name: string };
}

export interface SearchHit {
  /** Absolute step index in the full log — >= the loaded window's start
   * means the step is on the page and can be scrolled to. */
  index: number;
  step_id: string;
  ts: string | null;
  type: string;
  source: string | null;
  run_id: string | null;
  /** Which field matched (content, thought, cmd, stdout, …). */
  field: string;
  snippet: string;
}

export interface MindlogSearchResult {
  q: string;
  scope: "thoughts" | "all";
  total: number;
  hits: SearchHit[];
  step_count: number;
  identity: { id: string; name: string };
}

export interface StepDetail {
  step: NormalizedStep;
  index: number;
  run: RunGroup | null;
}

export interface TreeNode {
  traj_id: string;
  slug: string;
  parent_step_id: string | null;
  started_ts: string;
  last_ts: string;
  step_count: number;
  has_final: boolean;
  tldr: string | null;
  child_count: number;
  children?: TreeNode[];
}

export interface Crumb {
  traj_id: string;
  slug: string;
}

export interface SubTrajectory extends Mindlog {
  breadcrumb: Crumb[];
  parent: { traj_id: string; step_id: string | null } | null;
}

export interface LogInfo {
  name: string;
  bytes: number;
  mtime: number;
}

export interface LogTail {
  name: string;
  content: string;
  total_bytes: number;
  truncated: boolean;
}

export interface DispatchEvent {
  kind: "step" | "dispatch" | "other";
  type?: string;
  source?: string | null;
  thinker?: string;
  active?: number | null;
  raw: string;
}

export interface MemoryInfo {
  name: string;
  mtime: number;
  id: string | null;
  summary: string | null;
  type: string;
  created: string | null;
  slug: string;
}
