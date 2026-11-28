/* FlowCue remote node web console. No external dependencies. */
(() => {
  "use strict";

  const APPLE_OFFSET = 978307200;
  const state = {
    info: null,
    threads: [],
    activeId: null,
    messages: [],
    messageSignature: "",
    search: "",
    loadingThreads: false,
    loadingMessages: false,
    sending: false,
    approvals: [],
    threadTimer: null,
    messageTimer: null,
    approvalTimer: null,
  };

  const $ = (id) => document.getElementById(id);
  const isDesktop = () => window.matchMedia("(min-width: 901px)").matches;

  function el(tag, className, text) {
    const node = document.createElement(tag);
    if (className) node.className = className;
    if (text !== undefined && text !== null) node.textContent = text;
    return node;
  }

  function clear(node) {
    while (node && node.firstChild) node.removeChild(node.firstChild);
  }

  function uuid() {
    if (window.crypto && typeof window.crypto.randomUUID === "function") {
      return window.crypto.randomUUID();
    }
    const bytes = window.crypto.getRandomValues(new Uint8Array(16));
    bytes[6] = (bytes[6] & 0x0f) | 0x40;
    bytes[8] = (bytes[8] & 0x3f) | 0x80;
    const hex = [...bytes].map((b) => b.toString(16).padStart(2, "0")).join("");
    return `${hex.slice(0, 8)}-${hex.slice(8, 12)}-${hex.slice(12, 16)}-${hex.slice(16, 20)}-${hex.slice(20)}`;
  }

  function toDate(seconds) {
    return new Date((Number(seconds) + APPLE_OFFSET) * 1000);
  }

  function relativeTime(seconds) {
    if (!seconds) return "";
    const date = toDate(seconds);
    const diff = (Date.now() - date.getTime()) / 1000;
    if (diff < 60) return "刚刚";
    if (diff < 3600) return `${Math.floor(diff / 60)} 分`;
    if (diff < 86400) return `${Math.floor(diff / 3600)} 小时`;
    if (diff < 172800) return "昨天";
    return `${date.getMonth() + 1}/${date.getDate()}`;
  }

  function clockTime(seconds) {
    if (!seconds) return "";
    const date = toDate(seconds);
    return `${String(date.getHours()).padStart(2, "0")}:${String(date.getMinutes()).padStart(2, "0")}`;
  }

  function platformName(platform) {
    switch (platform) {
      case "darwin": return "macOS";
      case "windows": return "Windows";
      case "linux": return "Linux";
      default: return platform || "节点";
    }
  }

  function baseName(path) {
    if (!path) return "";
    const parts = String(path).split(/[\\/]/).filter(Boolean);
    return parts.length ? parts[parts.length - 1] : path;
  }

  function badgeClass(agentID) {
    return agentID === "claude" ? "claude" : agentID === "dsh" ? "dsh" : "codex";
  }

  function badgeLetter(agentID) {
    return agentID === "claude" ? "✳" : agentID === "dsh" ? "D" : "C";
  }

  function agentName(agentID) {
    const agent = (state.info?.agents || []).find((item) => item.id === agentID);
    return agent?.displayName || (agentID === "codex" ? "Codex" : agentID);
  }

  let toastTimer = null;
  function showToast(text) {
    const toast = $("toast");
    toast.textContent = text;
    toast.classList.add("show");
    clearTimeout(toastTimer);
    toastTimer = setTimeout(() => toast.classList.remove("show"), 2200);
  }

  async function api(path, options = {}) {
    const response = await fetch(path, {
      credentials: "same-origin",
      ...options,
      headers: { "Content-Type": "application/json", ...(options.headers || {}) },
    });
    if (response.status === 401) {
      showPairing();
      throw new Error("unauthorized");
    }
    if (!response.ok) {
      const body = await response.text().catch(() => "");
      const error = new Error(`HTTP ${response.status}${body ? `: ${body.slice(0, 120)}` : ""}`);
      error.status = response.status;
      throw error;
    }
    return response.json();
  }

  /* ---------------- pairing ---------------- */

  function showPairing(message) {
    const overlay = $("pairing");
    overlay.hidden = false;
    $("pairHost").textContent = location.host || "本机";
    $("pairError").textContent = message || "";
    setTimeout(() => $("codeInput").focus(), 80);
  }

  function hidePairing() {
    $("pairing").hidden = true;
    $("pairError").textContent = "";
  }

  function setPairingBusy(busy) {
    $("pairBtn").disabled = busy;
    $("pairBtn").textContent = busy ? "连接中…" : "连接";
    $("codeInput").disabled = busy;
  }

  $("pairForm").addEventListener("submit", async (event) => {
    event.preventDefault();
    const code = $("codeInput").value.trim();
    if (!/^[0-9]{6}$/.test(code)) {
      $("pairError").textContent = "请输入 6 位数字配对码。";
      return;
    }
    setPairingBusy(true);
    $("pairError").textContent = "";
    try {
      const response = await fetch("/v1/session", {
        method: "POST",
        headers: { "Content-Type": "application/json" },
        body: JSON.stringify({ code }),
      });
      if (!response.ok) {
        $("pairError").textContent = "配对码不对，或节点已经重启。";
        return;
      }
      await boot();
    } catch (error) {
      $("pairError").textContent = "连不上节点，检查地址和 Wi-Fi。";
    } finally {
      setPairingBusy(false);
    }
  });

  $("codeInput").addEventListener("input", (event) => {
    event.target.value = event.target.value.replace(/[^0-9]/g, "").slice(0, 6);
  });

  async function logout() {
    try {
      await fetch("/v1/session/logout", { method: "POST", credentials: "same-origin" });
    } catch (_) { /* ignore */ }
    stopPolling();
    state.info = null;
    state.threads = [];
    state.activeId = null;
    state.messages = [];
    $("sessions").replaceChildren();
    $("mSessions").replaceChildren();
    $("messagesInner").replaceChildren();
    $("chatHead").hidden = true;
    $("composer").hidden = true;
    showPairing();
  }

  $("logout").addEventListener("click", logout);
  $("mLogout").addEventListener("click", logout);

  /* ---------------- boot ---------------- */

  async function boot() {
    try {
      state.info = await api("/v1/node/info");
      hidePairing();
      renderNode();
      document.title = `FlowCue · ${state.info.hostname || state.info.name || "Node"}`;
      await refreshThreads();
      await refreshApprovals();
      startPolling();
    } catch (error) {
      if (error.message !== "unauthorized") {
        showPairing(`无法连接节点：${error.message}`);
      }
    }
  }

  function startPolling() {
    stopPolling();
    state.threadTimer = setInterval(() => {
      if (!document.hidden) refreshThreads();
    }, 8000);
    state.messageTimer = setInterval(() => {
      if (!document.hidden && state.activeId) loadMessages();
    }, 3000);
    state.approvalTimer = setInterval(() => {
      if (!document.hidden) refreshApprovals();
    }, 2500);
  }

  function stopPolling() {
    if (state.threadTimer) clearInterval(state.threadTimer);
    if (state.messageTimer) clearInterval(state.messageTimer);
    if (state.approvalTimer) clearInterval(state.approvalTimer);
    state.threadTimer = null;
    state.messageTimer = null;
    state.approvalTimer = null;
  }

  /* ---------------- node ---------------- */

  function renderNode() {
    const info = state.info;
    const host = info.hostname || info.name || "FlowCue Node";
    const platform = platformName(info.platform);
    const online = `${platform} · 在线`;

    $("deviceName").textContent = host;
    $("deviceMeta").textContent = online;
    $("deviceDot").className = "dot ok";
    $("mDeviceName").textContent = host;
    $("mDeviceMeta").textContent = online;
    $("mDeviceDot").className = "dot ok";

    $("conn").textContent = `已连接 · ${location.host}`;
    $("nodeName").textContent = host;
    $("nodeMeta").textContent = `${platform} · FlowCue Node ${info.appVersion} · 协议 v${info.protocol}`;
    $("nodeStatus").textContent = "局域网直连";
    $("inspNode").textContent = host;
    $("inspWorkspace").textContent = info.workspace || "—";

    clear($("inspAgents"));
    const agents = info.agents || [];
    if (!agents.length) {
      $("inspAgents").appendChild(el("div", "sidebar-empty", "没有检测到 agent"));
    }
    for (const agent of agents) {
      const row = el("div", "agent-row");
      row.appendChild(el("span", `badge ${badgeClass(agent.id)}`, badgeLetter(agent.id)));
      const text = el("span");
      text.appendChild(el("div", "name", agent.displayName || agent.id));
      const count = agent.id === "codex" ? state.threads.length : 0;
      text.appendChild(el("div", "meta2", `${count} 个会话`));
      row.appendChild(text);
      row.appendChild(el("span", "dot ok"));
      $("inspAgents").appendChild(row);
    }

    clear($("mAgents"));
    for (const agent of agents) {
      const row = el("div", "m-agent");
      row.appendChild(el("span", `badge ${badgeClass(agent.id)}`, badgeLetter(agent.id)));
      const text = el("span");
      text.appendChild(el("div", "name", agent.displayName || agent.id));
      const count = agent.id === "codex" ? state.threads.length : 0;
      text.appendChild(el("div", "sub", `${count} 个会话`));
      row.appendChild(text);
      row.appendChild(el("span", "dot ok"));
      $("mAgents").appendChild(row);
    }
  }

  /* ---------------- threads ---------------- */

  async function refreshThreads() {
    if (state.loadingThreads || !state.info) return;
    state.loadingThreads = true;
    try {
      const threads = await api("/v1/threads");
      state.threads = Array.isArray(threads) ? threads : [];
      $("sessionCount").textContent = String(state.threads.length);
      renderSessions();
      renderMobileSessions();
      renderNode();
      if (!state.activeId && state.threads.length && isDesktop()) {
        const preferred = state.threads.find((thread) => thread.lastReply) || state.threads[0];
        await selectThread(preferred.id, { keepView: true });
      }
    } catch (error) {
      if (error.message !== "unauthorized") showToast(`刷新会话失败：${error.message}`);
    } finally {
      state.loadingThreads = false;
    }
  }

  function filteredThreads() {
    if (!state.search) return state.threads;
    return state.threads.filter((thread) => {
      const haystack = `${thread.title} ${thread.lastReply} ${thread.projectDirectory || ""}`.toLowerCase();
      return haystack.includes(state.search);
    });
  }

  function sessionRow(thread) {
    const row = el("button", "session");
    row.type = "button";
    row.dataset.id = thread.id;
    if (thread.id === state.activeId) row.classList.add("active");

    row.appendChild(el("span", "badge codex", "C"));
    const main = el("span", "session-main");
    const top = el("span", "session-top");
    top.appendChild(el("span", "session-title", thread.title || "未命名会话"));
    top.appendChild(el("span", "session-time", relativeTime(thread.updatedAt)));
    main.appendChild(top);
    const preview = (thread.lastReply || "").replace(/\s+/g, " ").trim();
    main.appendChild(el("span", "session-preview", preview || "还没有回复"));
    const tags = el("span", "session-tags");
    tags.appendChild(el("span", "tag", "Codex"));
    if (thread.projectDirectory) tags.appendChild(el("span", "tag", baseName(thread.projectDirectory)));
    main.appendChild(tags);
    row.appendChild(main);

    row.addEventListener("click", () => selectThread(thread.id));
    return row;
  }

  function renderSessions() {
    const container = $("sessions");
    clear(container);
    const threads = filteredThreads();
    if (!threads.length) {
      container.appendChild(el("div", "sidebar-empty", state.search ? "没有匹配的会话" : "这台节点上还没有 Codex 会话"));
      return;
    }
    for (const thread of threads) container.appendChild(sessionRow(thread));
  }

  function renderMobileSessions() {
    const container = $("mSessions");
    clear(container);
    const threads = filteredThreads();
    if (!threads.length) {
      container.appendChild(el("div", "sidebar-empty", state.search ? "没有匹配的会话" : "还没有会话"));
      return;
    }
    for (const thread of threads) container.appendChild(sessionRow(thread));
  }

  /* ---------------- approvals ---------------- */

  async function refreshApprovals() {
    if (!state.info) return;
    try {
      const data = await api("/v1/approvals");
      state.approvals = Array.isArray(data?.pending) ? data.pending : [];
      renderApprovals();
    } catch (error) {
      if (error.message !== "unauthorized") {
        // A node without approval support returns available:false; stay quiet.
      }
    }
  }

  function renderApprovals() {
    for (const panel of [$("approvalPanel"), $("mApprovalPanel")]) {
      if (!panel) continue;
      clear(panel);
      if (!state.approvals.length) {
        panel.hidden = true;
        continue;
      }
      panel.hidden = false;
      for (const approval of state.approvals) panel.appendChild(approvalCard(approval));
    }
  }

  function approvalCard(approval) {
    const card = el("div", "approval-card");
    const head = el("div", "approval-head");
    head.appendChild(el("span", "", "APPROVAL REQUIRED"));
    card.appendChild(head);
    card.appendChild(el("div", "approval-title", approval.title || "Codex needs approval"));
    if (approval.detail) card.appendChild(el("div", "approval-detail", approval.detail));
    const actions = el("div", "approval-actions");
    const allow = el("button", "btn primary", "Allow once");
    const deny = el("button", "btn", "Deny");
    allow.type = "button";
    deny.type = "button";
    allow.addEventListener("click", () => decideApproval(approval, "accept", [allow, deny]));
    deny.addEventListener("click", () => decideApproval(approval, "decline", [allow, deny]));
    actions.appendChild(allow);
    actions.appendChild(deny);
    card.appendChild(actions);
    return card;
  }

  async function decideApproval(approval, decision, buttons) {
    buttons.forEach((button) => { button.disabled = true; });
    try {
      await api(`/v1/approvals/${encodeURIComponent(approval.id)}`, {
        method: "POST",
        body: JSON.stringify({ decision }),
      });
      state.approvals = state.approvals.filter((item) => item.id !== approval.id);
      renderApprovals();
      showToast(decision === "accept" ? "Approved. Codex is continuing." : "Denied.");
    } catch (error) {
      buttons.forEach((button) => { button.disabled = false; });
      showToast(`Could not answer: ${error.message}`);
    }
  }

  /* ---------------- chat ---------------- */

  async function selectThread(id, options = {}) {
    const thread = state.threads.find((item) => item.id === id);
    if (!thread) return;
    state.activeId = id;
    state.messages = [];
    state.messageSignature = "";
    renderSessions();
    renderMobileSessions();
    renderChatHeader(thread);

    if (!options.keepView && !isDesktop()) {
      document.body.classList.remove("screen-list");
      document.body.classList.add("screen-chat");
    }

    for (const view of messageViews()) {
      clear(view.inner);
      const loading = el("div", "loading-line");
      loading.appendChild(el("span", "spinner"));
      loading.appendChild(el("span", "", "正在读取会话…"));
      view.inner.appendChild(loading);
    }

    await loadMessages(true);
  }

  function renderChatHeader(thread) {
    $("chatHead").hidden = false;
    $("composer").hidden = false;
    $("chatTitle").textContent = thread.title || "未命名会话";
    $("chatSub").textContent = `Codex · ${thread.projectDirectory || "无工作区"}`;
    $("mChatTitle").textContent = thread.title || "未命名会话";
    $("mChatSub").textContent = `Codex · ${state.info?.hostname || "节点"}`;

    $("inspTitle").textContent = thread.title || "未命名会话";
    $("inspAgent").textContent = "Codex";
    $("inspWorkspace").textContent = thread.projectDirectory || state.info?.workspace || "—";
    $("inspStatus").textContent = "可读写";
  }

  async function loadMessages(force = false) {
    const id = state.activeId;
    if (!id || state.loadingMessages) return;
    state.loadingMessages = true;
    try {
      const messages = await api(`/v1/threads/${encodeURIComponent(id)}/messages`);
      if (state.activeId !== id) return;
      const list = Array.isArray(messages) ? messages : [];
      const signature = list.map((message) => `${message.id}:${message.role}:${message.text.length}`).join("|");
      if (!force && signature === state.messageSignature) return;
      state.messages = list;
      state.messageSignature = signature;
      renderMessages(list);
    } catch (error) {
      if (error.message !== "unauthorized") {
        const message = error.status === 404
          ? "这台机器上还没有这个会话的本地记录"
          : `读取消息失败：${error.message}`;
        for (const view of messageViews()) {
          clear(view.inner);
          const empty = el("div", "empty");
          empty.appendChild(el("div", "empty-mark", "?"));
          empty.appendChild(el("div", "empty-title", message));
          empty.appendChild(el("div", "empty-sub", "换一个会话试试，或者在这个会话里发一句话。"));
          view.inner.appendChild(empty);
        }
      }
    } finally {
      state.loadingMessages = false;
    }
  }

  function messageViews() {
    const desktopInner = $("messagesInner");
    return [
      { inner: desktopInner, scroll: desktopInner ? desktopInner.parentElement : null },
      { inner: $("mMessages"), scroll: $("mMessages") },
    ].filter((view) => view.inner);
  }

  function renderMessages(messages) {
    for (const view of messageViews()) {
      const { inner, scroll } = view;
      const atBottom = scroll ? scroll.scrollHeight - scroll.scrollTop - scroll.clientHeight < 140 : true;
      clear(inner);

      if (!messages.length) {
        inner.appendChild(el("div", "empty-title", "这个会话还没有消息"));
        inner.appendChild(el("div", "empty-sub", "在下面发一句话，就会进入当前 Codex 会话。"));
        continue;
      }

      const first = messages.find((message) => message.timestamp);
      if (first) {
        const day = toDate(first.timestamp);
        inner.appendChild(el("div", "day", `${day.getMonth() + 1} 月 ${day.getDate()} 日`));
      }

      for (const message of messages) {
        if (message.role !== "user" && message.role !== "assistant") continue;
        const wrapper = el("div", `msg ${message.role}`);
        wrapper.appendChild(el("div", "bubble", message.text));
        const meta = clockTime(message.timestamp);
        if (meta) wrapper.appendChild(el("div", "meta", meta));
        inner.appendChild(wrapper);
      }

      if (atBottom && scroll) scroll.scrollTop = scroll.scrollHeight;
    }
  }

  async function sendMessage(input) {
    if (state.sending) return;
    const text = input.value.trim();
    if (!text) return;
    if (!state.activeId) {
      showToast("先选择一个会话");
      return;
    }

    state.sending = true;
    const sendButtons = [$("send"), $("mSend")];
    sendButtons.forEach((button) => { button.disabled = true; });
    $("composerInput").disabled = true;
    $("mInput").disabled = true;
    input.value = "";

    const thread = state.threads.find((item) => item.id === state.activeId);
    const pending = [];
    for (const view of messageViews()) {
      const wrapper = el("div", "msg user");
      wrapper.appendChild(el("div", "bubble", text));
      wrapper.appendChild(el("div", "meta", "发送中…"));
      view.inner.appendChild(wrapper);
      if (view.scroll) view.scroll.scrollTop = view.scroll.scrollHeight;
      pending.push(wrapper);
    }

    try {
      const result = await api("/v1/send", {
        method: "POST",
        body: JSON.stringify({
          id: uuid(),
          threadID: state.activeId,
          text,
          createdAt: Date.now() / 1000 - APPLE_OFFSET,
        }),
      });
      if (result.state === "delivered") {
        showToast("已发送，等待 Codex 回复");
      } else {
        showToast(`发送未确认：${result.state || "unknown"}`);
      }
      setTimeout(() => loadMessages(true), 900);
      setTimeout(() => loadMessages(true), 3000);
      setTimeout(refreshApprovals, 1200);
      setTimeout(refreshApprovals, 3500);
      if (!thread) return;
    } catch (error) {
      showToast(`发送失败：${error.message}`);
      for (const wrapper of pending) {
        const meta = wrapper.querySelector(".meta");
        if (meta) meta.textContent = "发送失败";
      }
    } finally {
      state.sending = false;
      sendButtons.forEach((button) => { button.disabled = false; });
      $("composerInput").disabled = false;
      $("mInput").disabled = false;
    }
  }

  /* ---------------- events ---------------- */

  $("search").addEventListener("input", (event) => {
    state.search = event.target.value.trim().toLowerCase();
    renderSessions();
    renderMobileSessions();
  });

  $("send").addEventListener("click", () => sendMessage($("composerInput")));
  $("mSend").addEventListener("click", () => sendMessage($("mInput")));

  for (const id of ["composerInput", "mInput"]) {
    $(id).addEventListener("keydown", (event) => {
      if (event.key === "Enter" && !event.shiftKey) {
        event.preventDefault();
        sendMessage(event.target);
      }
    });
  }

  $("mBack").addEventListener("click", () => {
    document.body.classList.remove("screen-chat");
    document.body.classList.add("screen-list");
  });

  $("mDevice").addEventListener("click", () => {
    document.body.classList.remove("screen-chat");
    document.body.classList.add("screen-list");
  });

  document.addEventListener("visibilitychange", () => {
    if (!document.hidden && state.info) {
      refreshThreads();
      if (state.activeId) loadMessages(true);
    }
  });

  document.body.classList.remove("screen-list", "screen-chat");
  document.body.classList.add(isDesktop() ? "screen-chat" : "screen-list");
  boot();
})();
