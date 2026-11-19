// 桥接插件的分支逻辑测试：不依赖 DSH、不依赖 iPhone，直接跑插件本身。
//
// 覆盖「桌面审批到底什么时候弹」这件事：
//   1. 没有手机信号   → 立刻走桌面，不扣留
//   2. 手机在线并决定 → 只等手机，桌面不弹
//   3. 手机在线但静默 → 宽限期后回退桌面，并撤掉那条待审批
//   4. 桌面自己轮询   → 不算手机信号（修复前就是这么被冒充的）
//
// 运行：node --test Integrations/DSHBridge/test/bridge.test.mjs

import assert from "node:assert/strict";
import { mkdtempSync, readFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { test } from "node:test";

const PORT = 47897;
const PHONE_WINDOW_MS = 800;
const PHONE_GRACE_MS = 600;

// 隔离 HOME：插件会把 token 写到 ~/.flowcue，不能碰真实的那份。
const home = mkdtempSync(join(tmpdir(), "flowcue-bridge-test-"));
process.env.HOME = home;
process.env.FLOWCUE_DSH_PORT = String(PORT);
process.env.FLOWCUE_BRIDGE_PHONE_WINDOW_MS = String(PHONE_WINDOW_MS);
process.env.FLOWCUE_BRIDGE_PHONE_GRACE_MS = String(PHONE_GRACE_MS);
// 关掉「手机最近出现过」的粘性窗口，单测只验轮询窗口。
process.env.FLOWCUE_BRIDGE_PHONE_PAIR_MS = "0";

const { apply } = await import("../index.js");

const base = `http://127.0.0.1:${PORT}`;
const tokenFile = join(home, ".flowcue/dsh-bridge.json");

// --- 最小 cordis context -------------------------------------------------

const generators = [];
const listeners = [];

const ctx = {
  logger: { warn() {} },
  agents: { list: () => [], get: () => undefined },
  attachments: { admitPromptContent: async (content) => content },
  on(event, handler) {
    const entry = { event, handler };
    listeners.push(entry);
    return () => {
      const index = listeners.indexOf(entry);
      if (index >= 0) listeners.splice(index, 1);
    };
  },
  // 跑到第一个 yield 就够了：那一步注册 approval/request 监听器。
  // 迭代器自己留着，测试结束时再 next() 一次拿到清理函数关掉 HTTP server。
  effect(effect) {
    const iterator = typeof effect === "function" ? effect() : effect;
    generators.push(iterator);
    iterator.next();
  },
};

apply(ctx);

const sleep = (ms) => new Promise((resolve) => setTimeout(resolve, ms));

async function token() {
  for (let attempt = 0; attempt < 50; attempt += 1) {
    try {
      return JSON.parse(readFileSync(tokenFile, "utf8")).token;
    } catch {
      await sleep(20);
    }
  }
  throw new Error("bridge token file never appeared");
}

async function poll(source) {
  const query = source ? `?source=${source}` : "";
  const response = await fetch(`${base}/v1/pending${query}`, {
    headers: { authorization: `Bearer ${await token()}` },
  });
  assert.equal(response.status, 200);
  return (await response.json()).pending;
}

async function decide(id, decision) {
  const response = await fetch(`${base}/v1/decide`, {
    method: "POST",
    headers: { authorization: `Bearer ${await token()}`, "content-type": "application/json" },
    body: JSON.stringify({ id, decision }),
  });
  return response.status;
}

// 等 HTTP server 起来再开始，否则第一条请求会 ECONNREFUSED。
for (let attempt = 0; attempt < 100; attempt += 1) {
  try {
    await poll();
    break;
  } catch {
    await sleep(20);
  }
}

// --- 审批替身 -------------------------------------------------------------

function approval() {
  return {
    toolName: "bash",
    callId: "call-1",
    reason: "test approval",
    displayReason: { en: "test approval", zh: "测试审批" },
    signal: new AbortController().signal,
  };
}

/** next() 替身：记录被调用的次数和时刻，模拟桌面审批给出的结论。 */
function desktop(outcome = "allowed-once") {
  const calls = [];
  return {
    calls,
    next: () => {
      calls.push(Date.now());
      return Promise.resolve(outcome);
    },
  };
}

function handler() {
  const entry = listeners.find((candidate) => candidate.event === "approval/request");
  assert.ok(entry, "approval/request listener was never registered");
  return entry.handler;
}

/** 让「手机在线」的窗口过期，保证下一条用例从干净状态开始。 */
async function waitForPhoneWindowToExpire() {
  await sleep(PHONE_WINDOW_MS + 100);
}

// --- 用例 -----------------------------------------------------------------

test("没有手机信号时立刻走桌面审批，不扣留", async () => {
  await waitForPhoneWindowToExpire();
  const { next, calls } = desktop("allowed-once");

  const started = Date.now();
  const outcome = await handler()(approval(), next);

  assert.equal(outcome, "allowed-once");
  assert.equal(calls.length, 1, "next() 应该被调用一次");
  assert.ok(Date.now() - started < 300, "桌面审批应当立刻可用");
  assert.deepEqual(await poll(), []);
});

test("手机在线并给出决定时只等手机，不弹桌面卡", async () => {
  await waitForPhoneWindowToExpire();
  assert.deepEqual(await poll("phone"), []);
  const { next, calls } = desktop("allowed-once");

  const pendingOutcome = handler()(approval(), next);
  await sleep(250);

  // 扣住：桌面没被叫起来，而且手机上能看见这条。
  assert.equal(calls.length, 0, "手机在线时不应该同时走桌面");
  const visible = await poll("phone");
  assert.equal(visible.length, 1);
  // 插件对多语言对象取 zh 优先，客户端拿到的是纯文本而不是原始 JSON。
  assert.equal(visible[0].displayReason, "测试审批");

  assert.equal(await decide(visible[0].id, "rejected"), 200);

  const outcome = await pendingOutcome;
  assert.equal(outcome, "rejected");
  assert.equal(calls.length, 0, "手机已经决定了，桌面不该再弹");
  assert.deepEqual(await poll("phone"), []);
});

test("手机静默超过宽限期时回退桌面，并撤掉那条待审批", async () => {
  await waitForPhoneWindowToExpire();
  await poll("phone");
  const { next, calls } = desktop("allowed-once");

  const pendingOutcome = handler()(approval(), next);
  await sleep(PHONE_GRACE_MS / 2);
  assert.equal(calls.length, 0, "宽限期内应该还在等手机");

  const outcome = await pendingOutcome;
  assert.equal(outcome, "allowed-once");
  assert.equal(calls.length, 1, "宽限期过后应该回退到桌面");
  assert.deepEqual(await poll(), [], "回退后不能给手机留下幽灵审批");
});

test("桌面自己的轮询不算手机在线", async () => {
  await waitForPhoneWindowToExpire();
  await poll(); // 不带 source：菜单栏角标那种
  const { next, calls } = desktop("allowed-once");

  const outcome = await handler()(approval(), next);

  assert.equal(outcome, "allowed-once");
  assert.equal(calls.length, 1, "桌面轮询不能冒充手机，否则审批会被扣住");
});

test.after(async () => {
  // 跑到第二个 yield 拿到插件注册的清理函数，关掉 HTTP server，否则进程不退。
  for (const iterator of generators) {
    // 生成器现在会 yield 多个注册器，必须走到最后一个 yield 才是清理函数。
    let disposer;
    let step = iterator.next();
    while (!step.done) {
      disposer = step.value;
      step = iterator.next();
    }
    if (typeof disposer === "function") await disposer();
  }
});
