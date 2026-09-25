// Glory 运营后台（docs/运营后台设计.md）。不用框架、不用打包：部署还是 update.sh 一步。
//
// 🔴 所有来自服务器的文字（昵称、标题、原因…）一律走 textContent，绝不拼进 innerHTML ——
// 玩家昵称是玩家自己填的，拼进去就是一个现成的脚本注入口。
"use strict";

// ---------------------------------------------------------------------------
// 小工具
// ---------------------------------------------------------------------------

function h(tag, attrs, ...children) {
  const el = document.createElement(tag);
  for (const [key, value] of Object.entries(attrs || {})) {
    if (value === null || value === undefined || value === false) continue;
    if (key.startsWith("on")) el.addEventListener(key.slice(2), value);
    else if (key === "class") el.className = value;
    else if (key === "value") el.value = value;
    else if (key === "checked") el.checked = !!value;
    else el.setAttribute(key, value === true ? "" : value);
  }
  for (const child of children.flat()) {
    if (child === null || child === undefined || child === false) continue;
    el.append(child instanceof Node ? child : document.createTextNode(String(child)));
  }
  return el;
}

const MYT_MS = 8 * 3600 * 1000;

// 服务器给的 UTC 时间 → 马来西亚时间文字。页面上所有时间都按马来西亚时间显示（顶栏写着）。
function fmt(iso) {
  if (!iso) return "—";
  const d = new Date(Date.parse(iso) + MYT_MS);
  if (isNaN(d)) return String(iso);
  return d.toISOString().slice(0, 16).replace("T", " ");
}

// <input type="datetime-local"> 的值（当马来西亚时间）↔ 带时区的 ISO。
function toLocalInput(iso) {
  return iso ? new Date(Date.parse(iso) + MYT_MS).toISOString().slice(0, 16) : "";
}
function fromLocalInput(value) {
  return value ? value + ":00+08:00" : null;
}

function num(n) {
  return Number(n || 0).toLocaleString("en-US");
}

function newKey() {
  if (crypto.randomUUID) return crypto.randomUUID();
  const b = crypto.getRandomValues(new Uint8Array(16));
  b[6] = (b[6] & 0x0f) | 0x40; b[8] = (b[8] & 0x3f) | 0x80;
  const x = [...b].map((v) => v.toString(16).padStart(2, "0")).join("");
  return `${x.slice(0, 8)}-${x.slice(8, 12)}-${x.slice(12, 16)}-${x.slice(16, 20)}-${x.slice(20)}`;
}

class ApiError extends Error {
  constructor(status, message) { super(message); this.status = status; }
}

async function api(method, path, body, raw) {
  const init = { method, credentials: "same-origin", headers: { "X-Glory-Admin": "1" } };
  if (raw) {
    init.body = raw;
    init.headers["Content-Type"] = raw.type || "application/octet-stream";
  } else if (body !== undefined) {
    init.body = JSON.stringify(body);
    init.headers["Content-Type"] = "application/json";
  }
  let resp;
  try {
    resp = await fetch(path, init);
  } catch (e) {
    throw new ApiError(0, "连不上服务器，检查网络后再试");
  }
  let data = {};
  try { data = await resp.json(); } catch (e) { /* 非 JSON 响应 */ }
  if (resp.status === 401 && !path.startsWith("/admin/api/login")) {
    state.admin = null;
    render();
  }
  if (!resp.ok) {
    let detail = data.detail;
    if (Array.isArray(detail)) detail = detail.map((d) => d.msg).join("；");
    throw new ApiError(resp.status, detail || `请求失败（HTTP ${resp.status}）`);
  }
  return data;
}

function notice(kind, text) {
  return h("div", { class: `notice ${kind}` }, text);
}

// 按钮点下去 → 跑 fn → 期间禁用，结果写进 box。
function action(button, box, fn) {
  return async () => {
    button.disabled = true;
    box.replaceChildren();
    try {
      const message = await fn();
      if (message) box.append(notice("ok", message));
    } catch (e) {
      box.append(notice("error", e.message));
    } finally {
      button.disabled = false;
    }
  };
}

function table(headers, rows) {
  if (!rows.length) return h("p", { class: "muted" }, "（没有）");
  return h("div", { class: "table-wrap" },
    h("table", {},
      h("thead", {}, h("tr", {}, headers.map((t) => h("th", {}, t)))),
      h("tbody", {}, rows)));
}

function field(label, input, grow) {
  return h("label", { class: grow ? "field grow" : "field" }, h("span", {}, label), input);
}

// ---------------------------------------------------------------------------
// 状态与骨架
// ---------------------------------------------------------------------------

const state = { admin: null, environment: "", tab: "players", pending: 0 };
const app = document.getElementById("app");

const TABS = [
  ["players", "玩家"],
  ["requests", "审批"],
  ["mails", "邮件"],
  ["announcements", "公告"],
  ["audit", "操作记录"],
];

async function boot() {
  try {
    const me = await api("GET", "/admin/api/me");
    state.admin = me.name;
    state.environment = me.environment;
  } catch (e) {
    state.admin = null;
  }
  render();
}

function render() {
  if (!state.admin) {
    app.replaceChildren(loginView());
    return;
  }
  const prod = state.environment === "prod";
  const tabs = h("nav", { class: "tabs" }, TABS.map(([key, label]) =>
    h("button", { class: state.tab === key ? "on" : "", onclick: () => { state.tab = key; render(); } },
      label, key === "requests" && state.pending ? h("span", { class: "badge" }, state.pending) : null)));
  const bar = h("header", { class: "topbar" },
    h("h1", {}, "Glory 运营后台"),
    h("span", { class: prod ? "env prod" : "env dev" }, prod ? "正式服" : `测试环境（${state.environment}）`),
    tabs,
    h("span", { class: "who" }, `${state.admin} · 时间均为马来西亚时间`),
    h("button", { class: "btn small", onclick: logout }, "退出"));
  const main = h("main", {});
  app.replaceChildren(bar, main);
  const views = { players: playersView, requests: requestsView, mails: mailsView,
                  announcements: announcementsView, audit: auditView };
  views[state.tab](main);
  refreshPendingCount();
}

async function refreshPendingCount() {
  try {
    const data = await api("GET", "/admin/api/requests");
    const count = data.requests.length;
    if (count !== state.pending) {
      state.pending = count;
      const tab = app.querySelector(".tabs button:nth-child(2)");
      if (tab) tab.replaceChildren("审批", count ? h("span", { class: "badge" }, count) : "");
    }
  } catch (e) { /* 顶栏上的数字，拿不到不影响别的 */ }
}

async function logout() {
  try { await api("POST", "/admin/api/logout"); } catch (e) { /* 反正要回登录页 */ }
  state.admin = null;
  render();
}

// ---------------------------------------------------------------------------
// 登录：邮箱密码 → 手机验证器（第一次先扫码绑定）
// ---------------------------------------------------------------------------

function loginView() {
  const box = h("div", {});
  const email = h("input", { type: "email", autocomplete: "username", required: true });
  const password = h("input", { type: "password", autocomplete: "current-password", required: true });
  const submit = h("button", { class: "btn primary", type: "submit" }, "下一步");
  const form = h("form", { class: "card login" },
    h("h2", {}, "Glory 运营后台"),
    field("邮箱", email, true), field("密码", password, true), submit, box);
  form.addEventListener("submit", async (event) => {
    event.preventDefault();
    submit.disabled = true;
    box.replaceChildren();
    try {
      const answer = await api("POST", "/admin/api/login", { email: email.value, password: password.value });
      app.replaceChildren(codeView(answer));
    } catch (e) {
      box.append(notice("error", e.message));
    } finally {
      submit.disabled = false;
    }
  });
  return form;
}

function codeView(answer) {
  const box = h("div", {});
  const code = h("input", { inputmode: "numeric", autocomplete: "one-time-code", maxlength: "6",
                            pattern: "\\d{6}", required: true });
  const submit = h("button", { class: "btn primary", type: "submit" }, "登录");
  const parts = [h("h2", {}, answer.step === "enroll" ? "第一次登录：绑定手机验证器" : "输入验证码")];
  if (answer.step === "enroll") {
    parts.push(
      h("p", { class: "hint" }, "用手机上的验证器 App（Google Authenticator、Microsoft Authenticator 都行）扫下面的码，"
        + "然后输入 App 里显示的 6 位数字。以后每次登录都要这一步。"),
      h("img", { class: "qr", src: answer.qr_code, alt: "验证器二维码" }),
      h("p", { class: "hint" }, "扫不了码就手动输入这串密钥：", h("b", { class: "mono" }, answer.secret)),
      h("p", { class: "hint" }, "手动输入：Google Authenticator 右下角「+」→「输入设置密钥」→ 账号随便填（例如 Glory后台），"
        + "密钥填上面那串，类型选「基于时间」→ 添加。"));
  } else {
    parts.push(h("p", { class: "hint" }, "打开手机上的验证器 App，输入 Glory 后台那一行的 6 位数字。"));
  }
  const form = h("form", { class: "card login" }, parts, field("6 位验证码", code, true), submit,
    h("p", { class: "hint" }, "10 分钟内有效。过期了要重新输入邮箱密码"
      + (answer.step === "enroll" ? "，那时密钥会换一串新的，手机里要按新的重新添加。" : "。")), box);
  form.addEventListener("submit", async (event) => {
    event.preventDefault();
    submit.disabled = true;
    box.replaceChildren();
    try {
      const done = await api("POST", "/admin/api/login/code", { code: code.value.trim() });
      state.admin = done.name;
      await boot();
    } catch (e) {
      box.append(notice("error", e.message));
      if (e.status === 401 && /过期/.test(e.message)) setTimeout(() => app.replaceChildren(loginView()), 1500);
    } finally {
      submit.disabled = false;
    }
  });
  return form;
}

// ---------------------------------------------------------------------------
// 玩家
// ---------------------------------------------------------------------------

function playersView(main) {
  const query = h("input", { placeholder: "好友码 / 玩家编号 / 昵称" });
  const go = h("button", { class: "btn primary" }, "查");
  const box = h("div", {});
  const results = h("div", {});
  const detail = h("div", {});
  const search = action(go, box, async () => {
    const data = await api("GET", "/admin/api/players?q=" + encodeURIComponent(query.value.trim()));
    detail.replaceChildren();
    results.replaceChildren(table(["好友码", "昵称", "注册", "最后在线", ""], data.players.map((p) =>
      h("tr", { class: "click", onclick: () => showPlayer(p.player_id, detail) },
        h("td", { class: "mono" }, p.friend_code), h("td", {}, p.player_name),
        h("td", {}, fmt(p.created_at)), h("td", {}, fmt(p.last_seen_at)),
        h("td", {}, p.deleted_at ? h("span", { class: "tag" }, "已注销") : "")))));
    if (data.players.length === 1) showPlayer(data.players[0].player_id, detail);
  });
  go.addEventListener("click", search);
  query.addEventListener("keydown", (e) => { if (e.key === "Enter") search(); });
  main.append(h("section", { class: "card" },
    h("h2", {}, "找玩家"),
    h("p", { class: "hint" }, "好友码、完整玩家编号是精确查找；昵称只给候选（昵称不唯一），点开确认是谁再操作。"),
    h("div", { class: "row" }, field("", query, true), go), box, results), detail);
  query.focus();
}

async function showPlayer(playerId, into) {
  into.replaceChildren(h("p", { class: "muted" }, "加载中…"));
  let d;
  try {
    d = await api("GET", "/admin/api/players/" + playerId);
  } catch (e) {
    into.replaceChildren(notice("error", e.message));
    return;
  }
  const p = d.player;
  const reload = () => showPlayer(playerId, into);
  const who = `${p.player_name}（${p.friend_code}）`;
  const header = h("section", { class: d.ban ? "card banned" : "card" },
    h("h2", {}, p.player_name, " ",
      d.online ? h("span", { class: "tag green" }, "在线") : h("span", { class: "tag" }, "不在线"),
      d.ban ? h("span", { class: "tag red" }, "封号中") : "",
      p.deleted_at ? h("span", { class: "tag" }, "已注销") : ""),
    h("div", { class: "facts" },
      h("div", {}, h("span", {}, "好友码"), h("b", { class: "mono" }, p.friend_code)),
      h("div", {}, h("span", {}, "玩家编号"), h("span", { class: "mono" }, p.player_id)),
      h("div", {}, h("span", {}, "注册"), fmt(p.created_at)),
      h("div", {}, h("span", {}, "最后登录"), fmt(p.last_seen_at)),
      p.deleted_at ? h("div", {}, h("span", {}, "注销于"), fmt(p.deleted_at)) : null));
  into.replaceChildren(header, banCard(p, d, who, reload), walletCard(p, d, who, reload), historyCards(d));
}

function banCard(p, d, who, reload) {
  const box = h("div", {});
  const card = h("section", { class: "card" }, h("h2", {}, "封号"), box);
  if (d.ban) {
    card.append(notice("error", `正在封禁：${d.ban.reason}（${d.ban.ends_at ? "到 " + fmt(d.ban.ends_at) : "永久"}）`));
    const note = h("input", { placeholder: "为什么解封（内部备注）" });
    const btn = h("button", { class: "btn" }, "解封");
    btn.addEventListener("click", action(btn, box, async () => {
      if (!confirm(`解封 ${who}？\n他现在生效的封号会全部撤销。`)) return "";
      await api("POST", `/admin/api/players/${p.player_id}/unban`, { note: note.value });
      reload();
      return "已解封";
    }));
    card.append(h("div", { class: "row" }, field("备注", note, true), btn));
  } else if (!p.deleted_at) {
    const days = h("input", { type: "number", min: "1", max: "3650", placeholder: "空 = 永久" });
    const reason = h("input", { maxlength: "200", placeholder: "例如：使用外挂" });
    const note = h("input", { maxlength: "500", placeholder: "证据在哪、对应哪条举报" });
    const btn = h("button", { class: "btn danger" }, "封号");
    btn.addEventListener("click", action(btn, box, async () => {
      const n = days.value.trim() ? parseInt(days.value, 10) : null;
      const span = n ? `${n} 天` : "永久";
      if (!confirm(`封号 ${who}：${span}\n玩家会看到的原因：${reason.value}\n\n在线的话会被立刻踢下线；正在打的那一局照常打完。`)) return "";
      const r = await api("POST", `/admin/api/players/${p.player_id}/ban`,
        { days: n, reason: reason.value, note: note.value });
      reload();
      return r.kicked ? "已封号，并已踢下线" : "已封号";
    }));
    card.append(
      h("p", { class: "hint" }, "封号不用审批，随时能解封。玩家会在登录画面看到原因和解封时间。"),
      h("div", { class: "row" }, field("天数", days), field("给玩家看的原因", reason, true),
        field("内部备注（玩家看不到）", note, true), btn));
  }
  if (d.bans.length) {
    card.append(h("h3", {}, "封号记录"), table(["时间", "到", "原因", "备注", "操作人", "解封"], d.bans.map((b) =>
      h("tr", {}, h("td", {}, fmt(b.created_at)), h("td", {}, b.ends_at ? fmt(b.ends_at) : "永久"),
        h("td", {}, b.reason), h("td", { class: "muted" }, b.note || ""), h("td", {}, b.actor),
        h("td", {}, b.revoked_at ? `${b.revoked_by} ${fmt(b.revoked_at)}${b.revoke_note ? "：" + b.revoke_note : ""}` : "")))));
  }
  return card;
}

const CURRENCY = { diamond_paid: "付费钻石", diamond_free: "赠送钻石", coin: "黄金" };

function walletCard(p, d, who, reload) {
  const w = d.wallet;
  const box = h("div", {});
  const card = h("section", { class: "card" }, h("h2", {}, "钱包"),
    h("div", { class: "money" },
      h("div", {}, h("b", {}, num(w.diamond_paid + w.diamond_free)), h("span", {}, "钻石（游戏里显示的总数）")),
      h("div", {}, h("b", {}, num(w.diamond_paid)), h("span", {}, "其中付费")),
      h("div", {}, h("b", {}, num(w.diamond_free)), h("span", {}, "其中赠送")),
      h("div", {}, h("b", {}, num(w.coin)), h("span", {}, "黄金（账号，不是局内金币）"))),
    box);
  if (!p.deleted_at) {
    let key = newKey();
    const kind = h("select", {}, h("option", { value: "grant_diamonds" }, "赠送钻石"),
      h("option", { value: "grant_coin" }, "黄金"));
    const amount = h("input", { type: "number", min: "1", step: "1" });
    const reason = h("input", { maxlength: "200", placeholder: "例如：9/20 掉单补偿 工单 #12" });
    const btn = h("button", { class: "btn primary" }, "提交审批");
    btn.addEventListener("click", action(btn, box, async () => {
      const n = parseInt(amount.value, 10);
      const label = kind.value === "grant_coin" ? "黄金" : "赠送钻石";
      if (!confirm(`给 ${who} 发 ${num(n)} ${label}\n原因：${reason.value}\n\n提交后要另一个管理员批准才会到账。`)) return "";
      const r = await api("POST", `/admin/api/players/${p.player_id}/grant`,
        { kind: kind.value, amount: n, reason: reason.value, request_key: key });
      key = newKey();
      amount.value = "";
      refreshPendingCount();
      return r.replayed ? `这笔已经提交过了（申请 #${r.request_id}）` : `已提交申请 #${r.request_id}，等另一个管理员批准`;
    }));
    card.append(
      h("p", { class: "hint" }, "发钱要另一个管理员批准（自己不能批自己）。只进赠送钻石 / 黄金，永远不进付费钻石。"),
      h("div", { class: "row" }, field("发什么", kind), field("数量", amount), field("原因", reason, true), btn));
  }
  card.append(h("h3", {}, "流水（最近 50 笔）"), table(["时间", "币种", "变动", "之后余额", "来源", "操作人", "备注"],
    d.ledger.map((l) => h("tr", {}, h("td", {}, fmt(l.created_at)), h("td", {}, CURRENCY[l.currency] || l.currency),
      h("td", { class: "num " + (l.delta > 0 ? "pos" : "neg") }, (l.delta > 0 ? "+" : "") + num(l.delta)),
      h("td", { class: "num" }, num(l.balance_after)),
      h("td", {}, l.source, l.mail_id ? ` #${l.mail_id}` : ""), h("td", {}, l.actor || ""),
      h("td", { class: "muted" }, l.note || "")))));
  return card;
}

function historyCards(d) {
  const outcome = { team_a: "A 队胜", team_b: "B 队胜", draw: "平局" };
  return h("div", {},
    h("section", { class: "card" }, h("h2", {}, "订单与拥有"),
      table(["时间", "商品", "价格", "状态", "来源"], d.orders.map((o) => h("tr", {},
        h("td", {}, fmt(o.created_at)), h("td", { class: "mono" }, o.item_id),
        h("td", { class: "num" }, `${num(o.price_snapshot)} ${o.currency}`), h("td", {}, o.status), h("td", {}, o.source)))),
      h("h3", {}, "拥有"),
      table(["内容", "来源", "获得", "收回"], d.entitlements.map((e) => h("tr", {},
        h("td", { class: "mono" }, e.item_id), h("td", {}, e.source), h("td", {}, fmt(e.granted_at)),
        h("td", {}, e.revoked_at ? fmt(e.revoked_at) : ""))))),
    h("section", { class: "card" }, h("h2", {}, "发给他的邮件（不含全服）"),
      table(["#", "时间", "标题", "附件", "已读", "已领", "状态"], d.mails.map((m) => h("tr", {},
        h("td", {}, m.mail_id), h("td", {}, fmt(m.created_at)), h("td", {}, m.title_zh),
        h("td", {}, attachmentText(m)), h("td", {}, m.read_at ? "是" : ""),
        h("td", {}, m.claimed_at ? fmt(m.claimed_at) : ""),
        h("td", {}, mailStatus(m)))))),
    h("section", { class: "card" }, h("h2", {}, "排位与信誉"),
      h("p", {}, d.ranked ? `第 ${d.ranked.season} 赛季 · ${d.ranked.score} 分（第 ${d.ranked.tier + 1} 段）· ${d.ranked.games} 局 ${d.ranked.wins} 胜` : "没打过排位"),
      h("p", {}, d.credit ? `信誉分 ${d.credit.score}` + (d.credit.banned_until ? ` · 排位禁赛到 ${fmt(d.credit.banned_until)}` : "") : "信誉分 100（没有记录）"),
      h("p", { class: "hint" }, "排位禁赛是信誉分系统自动给的，和上面的封号是两回事。"),
      h("h3", {}, "最近对局"),
      table(["结束", "模式", "回合", "结果", "他在", "终局在线"], d.matches.map((m) => h("tr", {},
        h("td", {}, fmt(m.ended_at)), h("td", {}, m.mode), h("td", {}, m.rounds), h("td", {}, outcome[m.outcome] || m.outcome),
        h("td", {}, m.team === 0 ? "A 队" : "B 队"), h("td", {}, m.online_at_end ? "是" : h("span", { class: "neg" }, "否")))))),
    h("section", { class: "card" }, h("h2", {}, "后台对他做过的操作"), auditTable(d.audit, false)));
}

function attachmentText(m) {
  const parts = [];
  if (m.diamond) parts.push(`${num(m.diamond)} 钻石`);
  if (m.coin) parts.push(`${num(m.coin)} 黄金`);
  if (m.items && m.items.length) parts.push(m.items.join("、"));
  return parts.join("，") || "—";
}

function mailStatus(m) {
  if (m.withdrawn_at) return h("span", { class: "tag" }, "已撤回");
  if (m.problem) return h("span", { class: "tag red", title: m.problem }, "有问题");
  if (Date.parse(m.expires_at) < Date.now()) return h("span", { class: "tag" }, "已过期");
  return h("span", { class: "tag green" }, "有效");
}

// ---------------------------------------------------------------------------
// 审批
// ---------------------------------------------------------------------------

const REQUEST_STATUS = { pending: ["等批准", "yellow"], done: ["已执行", "green"], rejected: ["已拒绝", ""],
                         cancelled: ["已撤回", ""], failed: ["执行失败", "red"] };

async function requestsView(main) {
  const box = h("div", {});
  const pending = h("section", { class: "card" }, h("h2", {}, "等批准"),
    h("p", { class: "hint" }, "发钱（钻石 / 黄金 / 带附件的邮件）要另一个管理员批准，批准的那一刻就执行。自己提交的只能撤回。"),
    box);
  const history = h("section", { class: "card" }, h("h2", {}, "最近 100 条"));
  main.append(pending, history);
  let data;
  try {
    [data] = await Promise.all([api("GET", "/admin/api/requests?all=true")]);
  } catch (e) {
    box.append(notice("error", e.message));
    return;
  }
  const open = data.requests.filter((r) => r.status === "pending");
  pending.append(open.length ? table(["#", "内容", "原因", "申请人", "时间", ""], open.map((r) => {
    const cell = h("td", {});
    const mine = r.requested_by === state.admin;
    const note = h("input", { placeholder: "备注（可空）" });
    if (mine) {
      const btn = h("button", { class: "btn small" }, "撤回");
      btn.addEventListener("click", action(btn, box, async () => {
        await api("POST", `/admin/api/requests/${r.request_id}/cancel`);
        rerender();
        return "";
      }));
      cell.append(h("span", { class: "muted" }, "自己的申请 "), btn);
    } else {
      const yes = h("button", { class: "btn small primary" }, "批准并执行");
      const no = h("button", { class: "btn small" }, "拒绝");
      yes.addEventListener("click", action(yes, box, async () => {
        if (!confirm(`批准 #${r.request_id}：${r.summary}\n原因：${r.reason}\n申请人：${r.requested_by}\n\n批准后立刻执行，发出去的收不回来。`)) return "";
        await api("POST", `/admin/api/requests/${r.request_id}/approve`, { note: note.value });
        rerender();
        return "";
      }));
      no.addEventListener("click", action(no, box, async () => {
        await api("POST", `/admin/api/requests/${r.request_id}/reject`, { note: note.value });
        rerender();
        return "";
      }));
      cell.append(note, " ", yes, " ", no);
    }
    return h("tr", {}, h("td", {}, r.request_id), h("td", {}, r.summary), h("td", {}, r.reason),
      h("td", {}, r.requested_by), h("td", {}, fmt(r.requested_at)), cell);
  })) : h("p", { class: "muted" }, "没有等批准的申请"));
  history.append(table(["#", "内容", "原因", "申请人", "状态", "处理人", "结果"], data.requests.map((r) => {
    const [label, color] = REQUEST_STATUS[r.status] || [r.status, ""];
    let result = "";
    if (r.result && r.result.error) result = r.result.error;
    else if (r.result && r.result.mail_id) result = `邮件 #${r.result.mail_id}`;
    else if (r.result && r.result.balance_after !== undefined) result = `之后余额 ${num(r.result.balance_after)}`;
    return h("tr", {}, h("td", {}, r.request_id), h("td", {}, r.summary), h("td", {}, r.reason),
      h("td", {}, `${r.requested_by} ${fmt(r.requested_at)}`),
      h("td", {}, h("span", { class: `tag ${color}` }, label)),
      h("td", {}, r.decided_by ? `${r.decided_by} ${fmt(r.decided_at)}` : "", r.decision_note ? `：${r.decision_note}` : ""),
      h("td", { class: "muted" }, result));
  })));
}

function rerender() {
  render();
}

// ---------------------------------------------------------------------------
// 邮件
// ---------------------------------------------------------------------------

async function mailsView(main) {
  const box = h("div", {});
  let data;
  try {
    data = await api("GET", "/admin/api/mails");
  } catch (e) {
    main.append(notice("error", e.message));
    return;
  }
  let key = newKey();
  let target = null;   // 单人邮件：查到的玩家
  const mode = h("select", {}, h("option", { value: "one" }, "单人（按好友码）"), h("option", { value: "all" }, "全服"));
  const code = h("input", { placeholder: "好友码", maxlength: "8" });
  const who = h("span", { class: "muted" }, "");
  const newbies = h("input", { type: "checkbox" });
  const newbiesLabel = h("label", { class: "check" }, newbies, "之后注册的新玩家也能收到（只能用于不带奖励的全服邮件）");
  const titleZh = h("input", { maxlength: "60" });
  const bodyZh = h("textarea", { maxlength: "2000" });
  const titleEn = h("input", { maxlength: "60", placeholder: "空着 = 英文玩家看中文" });
  const bodyEn = h("textarea", { maxlength: "2000" });
  const diamond = h("input", { type: "number", min: "0", value: "0" });
  const coin = h("input", { type: "number", min: "0", value: "0" });
  const days = h("input", { type: "number", min: "1", max: "365", value: "30" });
  const note = h("input", { maxlength: "200", placeholder: "为什么发、对应哪次事故（带附件时必填）" });
  const items = data.catalog.map((c) => ({ id: c.content_id, box: h("input", { type: "checkbox" }), name: c.name }));
  const send = h("button", { class: "btn primary" }, "发送");

  const sync = () => {
    const all = mode.value === "all";
    code.disabled = all;
    newbiesLabel.style.display = all ? "" : "none";
    const paid = Number(diamond.value) > 0 || Number(coin.value) > 0 || items.some((i) => i.box.checked);
    send.textContent = paid ? "提交审批" : "发送";
  };
  [mode, diamond, coin].forEach((el) => el.addEventListener("input", sync));
  items.forEach((i) => i.box.addEventListener("change", sync));
  code.addEventListener("change", async () => {
    target = null;
    who.textContent = "";
    const q = code.value.trim();
    if (!q) return;
    try {
      const r = await api("GET", "/admin/api/players?q=" + encodeURIComponent(q));
      const p = r.players.find((x) => x.friend_code === q.toUpperCase() && !x.deleted_at);
      if (p) { target = p; who.textContent = `→ ${p.player_name}`; }
      else who.textContent = "→ 没有这个好友码";
    } catch (e) { who.textContent = "→ " + e.message; }
  });

  send.addEventListener("click", action(send, box, async () => {
    const all = mode.value === "all";
    if (!all && !target) throw new Error("先填一个存在的好友码");
    const body = {
      to: all ? "all" : target.player_id, title_zh: titleZh.value, body_zh: bodyZh.value,
      title_en: titleEn.value, body_en: bodyEn.value, diamond: Number(diamond.value || 0),
      coin: Number(coin.value || 0), items: items.filter((i) => i.box.checked).map((i) => i.id),
      days: Number(days.value || 30), include_new_players: all && newbies.checked, note: note.value,
      request_key: key,
    };
    const toText = all ? "全服" : `${target.player_name}（${target.friend_code}）`;
    const attach = attachmentText(body);
    if (!confirm(`发邮件给 ${toText}\n标题：${body.title_zh}\n附件：${attach}\n有效 ${body.days} 天`
      + (attach !== "—" ? "\n\n带附件：提交后要另一个管理员批准才会发出。" : ""))) return "";
    const r = await api("POST", "/admin/api/mails", body);
    key = newKey();
    refreshPendingCount();
    if (r.queued) return r.replayed ? `这封已经提交过了（申请 #${r.request_id}）` : `已提交申请 #${r.request_id}，等另一个管理员批准`;
    setTimeout(render, 800);
    return `已发出，邮件 #${r.mail_id}（在线玩家 30 秒内收到提示）`;
  }));

  main.append(h("section", { class: "card" }, h("h2", {}, "发系统邮件"),
    h("p", { class: "hint" }, "没附件的当场发；带钻石 / 黄金 / 物品的要另一个管理员批准。钻石进赠送那一列。"
      + "附件只能是商城里卖的东西；玩家已经拥有的会跳过、不折算。"),
    h("div", { class: "row" }, field("收件人", mode), field("好友码", code), who),
    newbiesLabel,
    h("div", { class: "row" }, field("中文标题（必填，60 字内）", titleZh, true), field("英文标题", titleEn, true)),
    h("div", { class: "row" }, field("中文正文", bodyZh, true), field("英文正文", bodyEn, true)),
    h("div", { class: "row" }, field("钻石", diamond), field("黄金", coin), field("有效天数", days),
      h("div", { class: "field" }, h("span", {}, "物品"), h("div", {}, items.map((i) =>
        h("label", { class: "check" }, i.box, `${i.name}（${i.id}）`))))),
    h("div", { class: "row" }, field("内部备注 / 原因（玩家看不到）", note, true), send), box));
  sync();

  const listBox = h("div", {});
  main.append(h("section", { class: "card" }, h("h2", {}, "最近 100 封"),
    h("p", { class: "hint" }, "撤回只让没领的人看不到；已经领走的收不回来。"), listBox,
    table(["#", "时间", "收件人", "标题", "附件", "已领人数", "状态", "操作人", ""], data.mails.map((m) => {
      const cell = h("td", {});
      if (!m.withdrawn_at && Date.parse(m.expires_at) > Date.now()) {
        const btn = h("button", { class: "btn small" }, "撤回");
        btn.addEventListener("click", action(btn, listBox, async () => {
          if (!confirm(`撤回邮件 #${m.mail_id}《${m.title_zh}》？\n已经有 ${m.claimed} 人领了，领走的收不回来。`)) return "";
          const r = await api("POST", `/admin/api/mails/${m.mail_id}/withdraw`);
          setTimeout(render, 800);
          return `已撤回。撤回前已领 ${r.already_claimed} 人。`;
        }));
        cell.append(btn);
      }
      return h("tr", {}, h("td", {}, m.mail_id), h("td", {}, fmt(m.created_at)),
        h("td", {}, m.player_id ? h("span", { class: "mono" }, m.friend_code || "?") : (m.include_new_players ? "全服（含新玩家）" : "全服")),
        h("td", {}, m.title_zh), h("td", {}, attachmentText(m)), h("td", { class: "num" }, num(m.claimed)),
        h("td", {}, mailStatus(m), m.problem ? h("div", { class: "muted" }, m.problem) : ""),
        h("td", {}, m.actor), cell);
    }))));
}

// ---------------------------------------------------------------------------
// 公告
// ---------------------------------------------------------------------------

const KINDS = { news: "系统", event: "活动", update: "更新", urgent: "紧急（推给所有在线玩家）" };
const STATUSES = { draft: "草稿（只有预览好友码看得到）", published: "已发布", withdrawn: "已撤下" };

async function announcementsView(main) {
  let data;
  try {
    data = await api("GET", "/admin/api/announcements");
  } catch (e) {
    main.append(notice("error", e.message));
    return;
  }
  const editor = h("div", {});
  const newBtn = h("button", { class: "btn primary" }, "新建公告");
  newBtn.addEventListener("click", () => editAnnouncement(null, editor));
  main.append(h("section", { class: "card" }, h("h2", {}, "公告"),
    h("p", { class: "hint" }, "保存后账号服务器 30 秒内读到。撤下不删。图片、预览好友码有问题时，「问题」一栏会写原因。"),
    newBtn,
    table(["#", "页签", "状态", "标题", "显示时间", "版本", "问题", ""], data.announcements.map((a) =>
      h("tr", {}, h("td", {}, a.announcement_id), h("td", {}, (KINDS[a.kind] || a.kind).split("（")[0]),
        h("td", {}, (STATUSES[a.status] || a.status).split("（")[0]), h("td", {}, a.title_zh),
        h("td", {}, `${fmt(a.starts_at)} → ${a.ends_at ? fmt(a.ends_at) : "不下线"}`), h("td", {}, a.revision),
        h("td", { class: "neg" }, a.problem || ""),
        h("td", {}, h("button", { class: "btn small", onclick: () => editAnnouncement(a, editor) }, "编辑")))))),
    editor);
}

function editAnnouncement(a, into) {
  const box = h("div", {});
  const creating = a === null;
  a = a || { kind: "news", status: "draft", title_zh: "", body_zh: "", title_en: "", body_en: "", image: "",
             popup: false, sort_order: 0, starts_at: new Date().toISOString(), ends_at: null, preview_codes: "" };
  const select = (options, value) => h("select", {}, Object.entries(options).map(([k, v]) =>
    h("option", { value: k, selected: k === value }, v)));
  const kind = select(KINDS, a.kind);
  const status = select(STATUSES, a.status);
  const titleZh = h("input", { maxlength: "60", value: a.title_zh });
  const bodyZh = h("textarea", { maxlength: "4000" }, a.body_zh);
  const titleEn = h("input", { maxlength: "80", value: a.title_en, placeholder: "空着 = 英文玩家看中文" });
  const bodyEn = h("textarea", { maxlength: "8000" }, a.body_en);
  const image = h("input", { maxlength: "200", value: a.image, placeholder: "Storage 里的文件名，空 = 没图" });
  const file = h("input", { type: "file", accept: "image/png,image/jpeg,image/webp" });
  const popup = h("input", { type: "checkbox", checked: a.popup });
  const sort = h("input", { type: "number", value: String(a.sort_order) });
  const starts = h("input", { type: "datetime-local", value: toLocalInput(a.starts_at) });
  const ends = h("input", { type: "datetime-local", value: toLocalInput(a.ends_at) });
  const codes = h("input", { maxlength: "200", value: a.preview_codes, placeholder: "草稿先给哪些好友码看，逗号分隔" });
  const bump = h("input", { type: "checkbox" });
  const save = h("button", { class: "btn primary" }, creating ? "创建" : "保存");

  file.addEventListener("change", action(save, box, async () => {
    if (!file.files.length) return "";
    const r = await api("POST", "/admin/api/announcements/image", undefined, file.files[0]);
    image.value = r.path;
    return `图片已上传：${r.path}（记得保存公告）`;
  }));

  save.addEventListener("click", action(save, box, async () => {
    const body = {
      kind: kind.value, status: status.value, title_zh: titleZh.value, body_zh: bodyZh.value,
      title_en: titleEn.value, body_en: bodyEn.value, image: image.value.trim(), popup: popup.checked,
      sort_order: Number(sort.value || 0), starts_at: fromLocalInput(starts.value), ends_at: fromLocalInput(ends.value),
      preview_codes: codes.value, version: a.version || null, bump_revision: bump.checked,
    };
    if (body.kind === "urgent" && body.status === "published"
        && !confirm("紧急公告发布后会立刻推给所有在线玩家（屏幕顶部横条）。确定？")) return "";
    const r = creating
      ? await api("POST", "/admin/api/announcements", body)
      : await api("PUT", `/admin/api/announcements/${a.announcement_id}`, body);
    setTimeout(render, 800);
    return `已保存 #${r.announcement_id}（版本 ${r.revision}），30 秒内生效`;
  }));

  into.replaceChildren(h("section", { class: "card" },
    h("h2", {}, creating ? "新建公告" : `编辑公告 #${a.announcement_id}`),
    a.problem ? notice("error", "服务器报的问题：" + a.problem) : null,
    h("div", { class: "row" }, field("页签", kind), field("状态", status), field("排序（大的在前）", sort),
      h("label", { class: "check" }, popup, "进主菜单时弹一次")),
    h("div", { class: "row" }, field("中文标题（必填）", titleZh, true), field("英文标题", titleEn, true)),
    h("div", { class: "row" }, field("中文正文", bodyZh, true), field("英文正文", bodyEn, true)),
    h("div", { class: "row" }, field("图片", image, true), field("上传新图（PNG/JPG/WebP，≤10 MB）", file)),
    h("div", { class: "row" }, field("开始显示（马来西亚时间）", starts), field("结束（空 = 不自动下线）", ends),
      field("预览好友码", codes, true)),
    creating ? null : h("label", { class: "check" }, bump,
      "大改（玩家重新看到红点，要弹窗的会再弹一次）—— 改错别字不要勾"),
    h("div", { class: "row" }, save), box));
  into.scrollIntoView({ behavior: "smooth" });
}

// ---------------------------------------------------------------------------
// 操作记录
// ---------------------------------------------------------------------------

const ACTIONS = {
  ban: "封号", unban: "解封", "mail.send": "发邮件", "mail.withdraw": "撤回邮件",
  "request.create": "提交发钱申请", "request.approve": "批准", "request.reject": "拒绝", "request.cancel": "撤回申请",
  "announcement.save": "保存公告", "announcement.image": "上传公告图",
};

function auditTable(rows, withPlayer) {
  const headers = ["时间", "管理员", "操作"].concat(withPlayer ? ["玩家"] : []).concat(["内容", "结果"]);
  return table(headers, rows.map((r) => h("tr", {},
    h("td", {}, fmt(r.at)), h("td", {}, r.admin_name), h("td", {}, ACTIONS[r.action] || r.action),
    withPlayer ? h("td", { class: "mono" }, r.friend_code || "") : null,
    h("td", { class: "muted mono" }, JSON.stringify(r.detail)),
    h("td", {}, r.ok ? "成功" : h("span", { class: "neg" }, "失败")))));
}

async function auditView(main) {
  try {
    const data = await api("GET", "/admin/api/audit");
    main.append(h("section", { class: "card" }, h("h2", {}, "操作记录（最近 200 条）"),
      h("p", { class: "hint" }, "只能追加，不能改也不能删（数据库触发器挡着）。"), auditTable(data.audit, true)));
  } catch (e) {
    main.append(notice("error", e.message));
  }
}

boot();
