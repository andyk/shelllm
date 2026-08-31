// The phone composer keeps Return as a newline and uses the Send button.

import { QueryClient, QueryClientProvider } from "@tanstack/react-query";
import { cleanup, fireEvent, render, screen, waitFor } from "@testing-library/react";
import { MemoryRouter, Route, Routes } from "react-router";
import { afterEach, beforeEach, describe, expect, it, vi } from "vitest";

import type {
  ChatLog,
  Config,
  IdentityActivity,
  ThinkersStatus,
} from "~/lib/types";
import { fetchChat } from "~/lib/api";
import { setPwaName } from "~/lib/pwa";
import TalkChat from "~/routes/talk-chat";

Element.prototype.scrollIntoView ??= () => {};

vi.mock("~/components/push-bell", () => ({ PushBell: () => null }));

const sendChat = vi.fn(
  async (_identityId: string, _content: string, from: string) => ({
    ok: true,
    from,
    to: "ada",
  })
);

vi.mock("~/lib/api", async (importOriginal) => {
  const mod = await importOriginal<typeof import("~/lib/api")>();
  return {
    ...mod,
    fetchConfig: vi.fn(
      async (): Promise<Config> => ({
        root: "/root",
        version: "0",
        controls_enabled: true,
        self_update_enabled: false,
        default_send_from: "you",
        git_commit: null,
        git_branch: null,
      })
    ),
    fetchActivity: vi.fn(
      async (): Promise<IdentityActivity> => ({
        state: "idle",
        dispatcher_running: true,
        steps_in_flight: 0,
        pending_total: 0,
        busy_thinkers: [],
        last_step_ts: null,
        last_step_age_s: null,
        run_seconds: null,
        stall_after_s: 60,
        cadence_s: null,
        queued_messages: [],
      })
    ),
    fetchChat: vi.fn(
      async (): Promise<ChatLog> => ({
        identity: { id: "ada", name: "ada" },
        live: false,
        messages: [],
        outcomes: {},
      })
    ),
    fetchThinkers: vi.fn(
      async (): Promise<ThinkersStatus> => ({
        identity: { id: "ada", name: "ada" },
        dispatcher: { running: true, pid: 1 },
        active_thinkers: 0,
        thinkers_total: 0,
        thinkers_disabled: 0,
        steps_in_flight: 0,
        pending_total: 0,
        thinkers: [],
      })
    ),
    sendChat: (...args: Parameters<typeof sendChat>) => sendChat(...args),
  };
});

function renderTalkChat() {
  const client = new QueryClient({
    defaultOptions: { queries: { retry: false } },
  });
  return render(
    <MemoryRouter initialEntries={["/talk/ada"]}>
      <QueryClientProvider client={client}>
        <Routes>
          <Route path="/talk/:identityId" element={<TalkChat />} />
        </Routes>
      </QueryClientProvider>
    </MemoryRouter>
  );
}

beforeEach(() => {
  sendChat.mockClear();
  setPwaName("nick");
});
afterEach(cleanup);

describe("phone chat composer", () => {
  it("leaves Return for newlines and sends multiline text with the button", async () => {
    renderTalkChat();
    const box = await screen.findByPlaceholderText("Message ada…");
    fireEvent.change(box, { target: { value: "line one" } });

    const allowedNativeBehavior = fireEvent.keyDown(box, { key: "Enter" });
    expect(allowedNativeBehavior).toBe(true);
    expect(sendChat).not.toHaveBeenCalled();

    fireEvent.change(box, { target: { value: "line one\nline two" } });
    fireEvent.click(screen.getByRole("button", { name: "Send" }));
    await waitFor(() => expect(sendChat).toHaveBeenCalledTimes(1));
    expect(sendChat).toHaveBeenCalledWith(
      "ada",
      "line one\nline two",
      "pwa-nick"
    );
  });
});

const EMPTY_CHAT: ChatLog = {
  identity: { id: "ada", name: "ada" },
  live: false,
  messages: [],
  outcomes: {},
};
const FINAL_REPLY_TEXT = "here is the finished reply";

describe("completed reply settles the waiting state", () => {
  afterEach(() => {
    vi.mocked(fetchChat).mockResolvedValue(EMPTY_CHAT);
  });

  it("renders a non-partial incoming reply and clears the pending-send state", async () => {
    // A final (partial: false) message from the other side must take the
    // `!lastMessage.partial` branch that resets lastSentAt, unlike a partial
    // bubble which keeps the fast-poll/typing affordances alive.
    vi.mocked(fetchChat).mockResolvedValue({
      ...EMPTY_CHAT,
      messages: [
        {
          ts: "2026-01-01T00:00:00Z",
          step_id: "s1",
          from: "ada",
          to: "pwa-nick",
          content: FINAL_REPLY_TEXT,
          reply_to: null,
          filename: null,
          source_url: null,
          partial: false,
        },
      ],
    });

    renderTalkChat();

    expect(await screen.findByText(FINAL_REPLY_TEXT)).toBeTruthy();
    // No typing dots once the completed reply has arrived.
    expect(document.querySelectorAll(".typing-dot").length).toBe(0);
  });
});
