import { useMutation, useQuery, useQueryClient } from "@tanstack/react-query";
import { ChevronLeft, SendHorizontal } from "lucide-react";
import { useEffect, useMemo, useRef, useState } from "react";
import { Link, useNavigate, useParams } from "react-router";
import ReactMarkdown from "react-markdown";
import remarkGfm from "remark-gfm";
import { toast } from "sonner";

import { PushBell } from "~/components/push-bell";
import { useControlsEnabled } from "~/components/thinker-controls";
import { Button } from "~/components/ui/button";
import { LoadingDots } from "~/components/ui/loading-dots";
import { Textarea } from "~/components/ui/textarea";
import { useAutosizeTextarea } from "~/hooks/use-autosize-textarea";
import { fetchActivity, fetchChat, fetchThinkers, sendChat } from "~/lib/api";
import type { ChatMessage } from "~/lib/types";
import { getPwaName, pwaSender, setLastIdentity } from "~/lib/pwa";
import { cn } from "~/lib/utils";

export function meta({ params }: { params: { identityId?: string } }) {
  return [{ title: params.identityId ? `${params.identityId} · talk` : "Headlong · talk" }];
}

// After a send: poll fast for this long so the reply lands near-instantly.
const FAST_POLL_WINDOW_MS = 60_000;
const FAST_POLL_MS = 700;
const IDLE_POLL_MS = 2000;
// Backstop only: the dots are already gated on verifiable thinker activity,
// and slow replies (a busy monolith, a long task) can legitimately take
// minutes. Declines surface instantly via outcome stamps, not this timer.
const TYPING_TIMEOUT_MS = 180_000;

interface PendingMessage {
  key: number;
  content: string;
  failed: boolean;
}

/** iOS doesn't shrink the layout viewport for the keyboard — it pans the
 * page and (in installed PWAs) often leaves it panned after dismiss,
 * stranding the chat with phantom margins. Track visualViewport (which
 * does follow the keyboard) into a CSS var, and snap the pan back when
 * the keyboard goes away. No-op on browsers without the API. */
function useKeyboardViewport() {
  useEffect(() => {
    const vv = window.visualViewport;
    if (!vv) return;
    const root = document.documentElement;
    const update = () => {
      root.style.setProperty("--talk-height", `${vv.height}px`);
      if (vv.height >= window.innerHeight - 1) {
        window.scrollTo(0, 0);
      }
    };
    update();
    vv.addEventListener("resize", update);
    vv.addEventListener("scroll", update);
    return () => {
      vv.removeEventListener("resize", update);
      vv.removeEventListener("scroll", update);
      root.style.removeProperty("--talk-height");
    };
  }, []);
}

function messageTime(ts: string | null): string {
  if (!ts) return "";
  const date = new Date(ts);
  if (Number.isNaN(date.getTime())) return "";
  return date.toLocaleTimeString([], { hour: "2-digit", minute: "2-digit" });
}

function Bubble({ message, mine }: { message: ChatMessage; mine: boolean }) {
  return (
    <div className={cn("msg-in flex", mine ? "justify-end" : "justify-start")}>
      <div
        className={cn(
          "max-w-[85%] rounded-2xl px-3.5 py-2",
          mine
            ? "rounded-br-md bg-primary text-primary-foreground"
            : "rounded-bl-md border bg-card"
        )}
      >
        {mine ? (
          <div className="whitespace-pre-wrap break-words text-sm">
            {message.content}
          </div>
        ) : (
          <div className="prose prose-sm max-w-none break-words dark:prose-invert">
            <ReactMarkdown remarkPlugins={[remarkGfm]}>
              {message.content}
            </ReactMarkdown>
          </div>
        )}
        <div
          className={cn(
            "mt-0.5 text-right font-mono text-[10px]",
            mine ? "text-primary-foreground/60" : "text-muted-foreground"
          )}
        >
          {messageTime(message.ts)}
        </div>
      </div>
    </div>
  );
}

function PendingBubble({
  message,
  onRetry,
}: {
  message: PendingMessage;
  onRetry: () => void;
}) {
  return (
    <div className="msg-in flex justify-end">
      <div
        className={cn(
          "max-w-[85%] rounded-2xl rounded-br-md bg-primary px-3.5 py-2 text-primary-foreground",
          !message.failed && "opacity-70"
        )}
      >
        <div className="whitespace-pre-wrap break-words text-sm">
          {message.content}
        </div>
        {message.failed ? (
          <button
            type="button"
            className="mt-0.5 block w-full text-right font-mono text-[10px] text-red-200 underline"
            onClick={onRetry}
          >
            failed to send — tap to retry
          </button>
        ) : (
          <div className="mt-0.5 text-right font-mono text-[10px] text-primary-foreground/60">
            sending…
          </div>
        )}
      </div>
    </div>
  );
}

function TypingBubble() {
  return (
    <div className="msg-in flex justify-start">
      <div className="rounded-2xl rounded-bl-md border bg-card px-4 py-3">
        <div className="flex gap-1">
          <span className="typing-dot h-1.5 w-1.5 rounded-full bg-muted-foreground" />
          <span className="typing-dot h-1.5 w-1.5 rounded-full bg-muted-foreground" />
          <span className="typing-dot h-1.5 w-1.5 rounded-full bg-muted-foreground" />
        </div>
      </div>
    </div>
  );
}

export default function TalkChat() {
  const { identityId = "" } = useParams();
  const navigate = useNavigate();
  const controlsEnabled = useControlsEnabled();
  useKeyboardViewport();
  const queryClient = useQueryClient();
  const [draft, setDraft] = useState("");
  const [pending, setPending] = useState<PendingMessage[]>([]);
  const [lastSentAt, setLastSentAt] = useState<number | null>(null);
  const [typingExpired, setTypingExpired] = useState(false);
  const pendingKey = useRef(0);
  const draftRef = useAutosizeTextarea(draft);
  const lastSentAtRef = useRef<number | null>(null);
  lastSentAtRef.current = lastSentAt;
  const hasActivePartialRef = useRef(false);
  const awaitingRef = useRef(false);
  const scrollerRef = useRef<HTMLDivElement>(null);
  const bottomRef = useRef<HTMLDivElement>(null);
  const nearBottomRef = useRef(true);
  const didInitialScroll = useRef(false);

  const name = getPwaName();
  useEffect(() => {
    if (!name) navigate("/talk", { replace: true });
    else setLastIdentity(identityId);
  }, [name, identityId, navigate]);
  const myName = name ? pwaSender(name) : "";

  const { data: chat, isLoading } = useQuery({
    queryKey: ["chat", identityId, myName],
    queryFn: () => fetchChat(identityId, 200, myName),
    refetchInterval: () => {
      const sent = lastSentAtRef.current;
      if (hasActivePartialRef.current) return FAST_POLL_MS;
      const awaiting =
        awaitingRef.current && sent && Date.now() - sent < FAST_POLL_WINDOW_MS;
      return awaiting ? FAST_POLL_MS : IDLE_POLL_MS;
    },
    enabled: !!myName,
  });

  const { data: thinkerStatus } = useQuery({
    queryKey: ["thinkers", identityId],
    queryFn: () => fetchThinkers(identityId),
    // Faster while awaiting a reply — this feed is what turns the dots on.
    refetchInterval: () => (awaitingRef.current ? 1000 : 5000),
  });
  const dispatcherRunning = thinkerStatus?.dispatcher.running ?? true;

  const { data: activity } = useQuery({
    queryKey: ["activity", identityId],
    queryFn: () => fetchActivity(identityId),
    refetchInterval: () => (awaitingRef.current ? 2000 : 5000),
  });
  // My message is sitting in the pending queue behind a busy run — say so
  // instead of letting the typing dots silently expire.
  const queuedMine =
    (activity?.state === "working" || activity?.state === "stalled") &&
    (activity?.queued_messages ?? []).some((m) => m.from === myName);

  const messages = useMemo(() => chat?.messages ?? [], [chat]);
  const outcomes = chat?.outcomes ?? {};

  const hasActivePartial = messages.some((message) => message.partial);
  hasActivePartialRef.current = hasActivePartial;

  // A final reply arriving ends the waiting state; an active partial keeps
  // fast polling so the bubble can keep growing.
  const lastMessage = messages[messages.length - 1];
  useEffect(() => {
    if (lastMessage && lastMessage.from !== myName && !lastMessage.partial) {
      setLastSentAt(null);
    }
  }, [lastMessage, myName]);

  // Optimistic bubbles disappear once the server echoes the real message.
  const confirmedContents = useMemo(
    () => new Set(messages.filter((m) => m.from === myName).map((m) => m.content)),
    [messages, myName]
  );
  useEffect(() => {
    setPending((prev) =>
      prev.filter((p) => p.failed || !confirmedContents.has(p.content))
    );
  }, [confirmedContents]);
  const visiblePending = pending.filter(
    (p) => p.failed || !confirmedContents.has(p.content)
  );

  // Typing dots time out — NO_REPLY is a legitimate outcome.
  useEffect(() => {
    if (lastSentAt === null) {
      setTypingExpired(false);
      return;
    }
    setTypingExpired(false);
    const timer = setTimeout(() => setTypingExpired(true), TYPING_TIMEOUT_MS);
    return () => clearTimeout(timer);
  }, [lastSentAt]);

  // The last message I sent this session, and what the mind log says
  // happened to it: "replied" / "no-reply" / "failed" / undefined (undecided).
  const lastMine = [...messages].reverse().find((m) => m.from === myName);
  const lastOutcome = lastMine?.step_id ? outcomes[lastMine.step_id] : undefined;

  const waitingForReply =
    lastSentAt !== null &&
    lastOutcome === undefined &&
    (hasActivePartial ||
      visiblePending.some((p) => !p.failed) ||
      (lastMessage ? lastMessage.from === myName : false));

  // Dots only when the agent is verifiably on it: dispatcher up AND a
  // thinker either mid-step or with a queued message. No theater.
  const thinkerBusy = (thinkerStatus?.thinkers ?? []).some(
    (t) => t.steps_in_flight > 0 || t.pending.includes("message")
  );
  const showTyping =
    waitingForReply &&
    !hasActivePartial &&
    dispatcherRunning &&
    thinkerBusy &&
    !typingExpired;
  const showDeclinedNote =
    lastSentAt !== null &&
    lastOutcome === "no-reply" &&
    (lastMessage ? lastMessage.from === myName : false);
  const showFailedNote =
    lastSentAt !== null &&
    lastOutcome === "failed" &&
    (lastMessage ? lastMessage.from === myName : false);
  const showNoReplyNote =
    waitingForReply &&
    typingExpired &&
    !hasActivePartial &&
    !showDeclinedNote &&
    !showFailedNote;
  awaitingRef.current = waitingForReply;

  // Follow new messages only when already reading the latest ones.
  const itemCount =
    messages.length +
    visiblePending.length +
    (showTyping || showDeclinedNote || showFailedNote || showNoReplyNote ? 1 : 0);
  useEffect(() => {
    if (itemCount === 0) return;
    if (!didInitialScroll.current) {
      didInitialScroll.current = true;
      bottomRef.current?.scrollIntoView({ block: "end" });
      return;
    }
    if (nearBottomRef.current) {
      bottomRef.current?.scrollIntoView({ behavior: "smooth", block: "end" });
    }
  }, [itemCount]);

  const sendMutation = useMutation({
    mutationFn: (content: string) => sendChat(identityId, content, myName),
    onMutate: (content: string) => {
      const key = ++pendingKey.current;
      setPending((prev) => [...prev, { key, content, failed: false }]);
      setDraft("");
      setLastSentAt(Date.now());
      return { key };
    },
    onSuccess: () => {
      queryClient.invalidateQueries({ queryKey: ["chat", identityId, myName] });
    },
    onError: (error: Error, _content, context) => {
      setPending((prev) =>
        prev.map((p) => (p.key === context?.key ? { ...p, failed: true } : p))
      );
      toast.error(error.message);
    },
  });

  const retryPending = (message: PendingMessage) => {
    setPending((prev) => prev.filter((p) => p.key !== message.key));
    sendMutation.mutate(message.content);
  };

  const identityName = chat?.identity.name ?? identityId.split("~").pop();

  return (
    <div
      className="flex h-dvh flex-col"
      style={{ height: "var(--talk-height, 100dvh)" }}
    >
      <header className="flex select-none items-center gap-1 border-b px-2 pb-2 pt-[calc(env(safe-area-inset-top)+0.5rem)]">
        <Link
          to="/talk?pick=1"
          className="flex h-9 w-9 items-center justify-center rounded-full active:bg-accent"
          aria-label="Back to identity list"
        >
          <ChevronLeft className="size-5" />
        </Link>
        <div className="flex flex-1 items-center gap-2">
          <span className="font-medium">{identityName}</span>
          <span
            className={cn(
              "inline-block h-2 w-2 rounded-full",
              chat?.live ? "bg-green-500" : "bg-muted-foreground/30"
            )}
            title={chat?.live ? "live" : "idle"}
          />
        </div>
        {myName && <PushBell name={myName} />}
        <span className="pr-2 font-mono text-[10px] text-muted-foreground">
          {myName}
        </span>
      </header>

      {!dispatcherRunning && (
        <div className="border-b border-amber-300 bg-amber-50 px-4 py-2 text-xs text-amber-900 dark:border-amber-800 dark:bg-amber-950 dark:text-amber-200">
          {identityName} is asleep (thinkers stopped) — messages will wait
          until it wakes.
        </div>
      )}
      {dispatcherRunning && queuedMine && (
        <div className="border-b border-sky-300 bg-sky-50 px-4 py-2 text-xs text-sky-900 dark:border-sky-800 dark:bg-sky-950 dark:text-sky-200">
          {identityName} is mid-task — your message is queued and will be
          seen when the current run finishes.
        </div>
      )}

      <div
        ref={scrollerRef}
        className="flex-1 space-y-2 overflow-y-auto px-3 py-3"
        onScroll={() => {
          const el = scrollerRef.current;
          if (!el) return;
          nearBottomRef.current =
            el.scrollHeight - el.scrollTop - el.clientHeight < 120;
        }}
      >
        {isLoading ? (
          <div className="flex justify-center py-10">
            <LoadingDots />
          </div>
        ) : messages.length === 0 && visiblePending.length === 0 ? (
          <div className="py-10 text-center text-sm text-muted-foreground">
            No messages yet. Say hello.
          </div>
        ) : (
          <>
            {messages.map((message, idx) => (
              <Bubble
                key={message.step_id ?? idx}
                message={message}
                mine={message.from === myName}
              />
            ))}
            {visiblePending.map((message) => (
              <PendingBubble
                key={`pending-${message.key}`}
                message={message}
                onRetry={() => retryPending(message)}
              />
            ))}
            {showTyping && <TypingBubble />}
            {showDeclinedNote && (
              <div className="py-2 text-center font-mono text-[10px] text-muted-foreground">
                {identityName} read it and chose not to answer
              </div>
            )}
            {showFailedNote && (
              <div className="py-2 text-center font-mono text-[10px] text-muted-foreground">
                {identityName} tried to reply but it failed — try again
              </div>
            )}
            {showNoReplyNote && (
              <div className="py-2 text-center font-mono text-[10px] text-muted-foreground">
                no reply yet — {identityName} may still be busy
              </div>
            )}
          </>
        )}
        <div ref={bottomRef} />
      </div>

      {controlsEnabled && (
        <form
          className="flex select-none items-end gap-2 border-t px-3 pt-2 pb-[calc(env(safe-area-inset-bottom)+0.5rem)]"
          onSubmit={(event) => {
            event.preventDefault();
            const content = draft.trim();
            if (content && !sendMutation.isPending) sendMutation.mutate(content);
          }}
        >
          <Textarea
            ref={draftRef}
            rows={1}
            value={draft}
            onChange={(event) => setDraft(event.target.value)}
            enterKeyHint="enter"
            placeholder={`Message ${identityName}…`}
            className="max-h-40 min-h-10 flex-1 rounded-3xl px-4 py-2.5"
            autoComplete="off"
          />
          <Button
            type="submit"
            size="icon"
            className="h-10 w-10 shrink-0 rounded-full"
            disabled={sendMutation.isPending || !draft.trim()}
            aria-label="Send"
          >
            <SendHorizontal className="size-4" />
          </Button>
        </form>
      )}
    </div>
  );
}
