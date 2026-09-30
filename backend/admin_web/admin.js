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

const state = { admin: null, environment: "", tab: "players", pending: 0, openReports: 0 };
const app = document.getElementById("app");

const TABS = [
  ["players", "玩家"],
  ["data", "数据"],
  ["requests", "审批"],
  ["mails", "邮件"],
  ["announcements", "公告"],
  ["reports", "举报"],
  ["world", "世界频道"],
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
  const counts = { requests: state.pending, reports: state.openReports };
  const tabs = h("nav", { class: "tabs" }, TABS.map(([key, label]) =>
    h("button", { class: state.tab === key ? "on" : "", "data-tab": key, onclick: () => { state.tab = key; render(); } },
      label, counts[key] ? h("span", { class: "badge" }, counts[key]) : null)));
  const bar = h("header", { class: "topbar" },
    h("h1", {}, "Glory 运营后台"),
    h("span", { class: prod ? "env prod" : "env dev" }, prod ? "正式服" : `测试环境（${state.environment}）`),
    tabs,
    h("span", { class: "who" }, `${state.admin} · 时间均为马来西亚时间`),
    h("button", { class: "btn small", onclick: logout }, "退出"));
  const main = h("main", {});
  app.replaceChildren(bar, main);
  const views = { players: playersView, data: dataView, requests: requestsView, mails: mailsView,
                  announcements: announcementsView, reports: reportsView, world: worldView, audit: auditView };
  views[state.tab](main);
  refreshPendingCount();
  refreshOpenReports();
}

// 顶栏页签上的数字（等批准的申请、待处理的举报）。拿不到不影响别的。
function setTabBadge(key, label, count) {
  const tab = app.querySelector(`.tabs button[data-tab="${key}"]`);
  if (tab) tab.replaceChildren(label, count ? h("span", { class: "badge" }, count) : "");
}

async function refreshPendingCount() {
  try {
    const data = await api("GET", "/admin/api/requests");
    const count = data.requests.length;
    if (count !== state.pending) {
      state.pending = count;
      setTabBadge("requests", "审批", count);
    }
  } catch (e) { /* 顶栏上的数字，拿不到不影响别的 */ }
}

async function refreshOpenReports() {
  try {
    const data = await api("GET", "/admin/api/reports?status=open");
    const count = data.reports.length;
    if (count !== state.openReports) {
      state.openReports = count;
      setTabBadge("reports", "举报", count);
    }
  } catch (e) { /* 019 没跑时这里 503，页签上不显示数字 */ }
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
  // 从举报 / 世界频道页点「看这个人」跳过来的：直接打开他。
  if (state.focusPlayer) {
    showPlayer(state.focusPlayer, detail);
    state.focusPlayer = null;
    return;
  }
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
  into.replaceChildren(header, banCard(p, d, who, reload), muteCard(p, d, who, reload),
    worldCard(d.world_recent, reload, "他最近在世界频道说的（30 条，含已删）"),
    reportsCard(d.reports_against, "别人对他的举报（最近 20 条）"),
    walletCard(p, d, who, reload), tagCard(p, d, who, reload), historyCards(d));
}

// 内部账号（员工 / 测试 / 压测）：运营数据里不算他。只影响统计，不影响他玩。
const TAG_KINDS = { staff: "员工", qa: "测试", loadtest: "压测" };

function tagCard(p, d, who, reload) {
  const box = h("div", {});
  const card = h("section", { class: "card" }, h("h2", {}, "运营数据"), box);
  if (d.tag) {
    const t = d.tag;
    card.append(notice("warn", `内部账号（${TAG_KINDS[t.kind] || t.kind}）：不算进日活、留存、在线人数。`
      + `${t.tagged_by} ${fmt(t.tagged_at)} 标的${t.note ? "：" + t.note : ""}`));
    const btn = h("button", { class: "btn" }, "改回普通玩家");
    btn.addEventListener("click", action(btn, box, async () => {
      if (!confirm(`把 ${who} 改回普通玩家？\n他以前的日活、留存也会一起算回统计里。`)) return "";
      await api("POST", `/admin/api/players/${p.player_id}/untag`);
      reload();
      return "已改回";
    }));
    card.append(btn);
  } else if (!p.deleted_at) {
    const kind = h("select", {}, Object.entries(TAG_KINDS).map(([value, label]) => h("option", { value }, label)));
    const note = h("input", { maxlength: "200", placeholder: "例如：美术那台测试机" });
    const btn = h("button", { class: "btn" }, "标为内部账号");
    btn.addEventListener("click", action(btn, box, async () => {
      const label = TAG_KINDS[kind.value];
      if (!confirm(`把 ${who} 标为内部账号（${label}）？\n他以前和以后的日活、留存都不再算进统计。`)) return "";
      await api("POST", `/admin/api/players/${p.player_id}/tag`, { kind: kind.value, note: note.value });
      reload();
      return "已标记";
    }));
    card.append(
      h("p", { class: "hint" }, "员工、测试、压测用的号要标上，不然会混进日活和留存。只影响统计，不影响他玩；随时能改回。"),
      h("div", { class: "row" }, field("类型", kind), field("备注", note, true), btn));
  }
  return card;
}

// 禁言（世界频道）：被禁的人照常能玩、能私聊，只是不能在世界频道说话。和封号是两回事。
const MUTE_PRESETS = [["1", "1 小时"], ["24", "1 天"], ["72", "3 天"], ["168", "7 天"], ["720", "30 天"], ["", "永久"]];

function muteCard(p, d, who, reload) {
  const box = h("div", {});
  const card = h("section", { class: "card" }, h("h2", {}, "禁言（世界频道）"), box);
  if (d.mute) {
    card.append(notice("warn", `正在禁言：${d.mute.reason}（${d.mute.ends_at ? "到 " + fmt(d.mute.ends_at) : "永久"}）`));
    const note = h("input", { placeholder: "为什么解除（内部备注）" });
    const btn = h("button", { class: "btn" }, "解除禁言");
    btn.addEventListener("click", action(btn, box, async () => {
      if (!confirm(`解除 ${who} 的禁言？`)) return "";
      await api("POST", `/admin/api/players/${p.player_id}/unmute`, { note: note.value });
      reload();
      return "已解除";
    }));
    card.append(h("div", { class: "row" }, field("备注", note, true), btn));
  } else if (!p.deleted_at) {
    const hours = h("select", {}, MUTE_PRESETS.map(([value, label]) => h("option", { value }, label)));
    hours.value = "24";
    const reason = h("input", { maxlength: "200", placeholder: "例如：世界频道刷屏 / 辱骂" });
    const note = h("input", { maxlength: "500", placeholder: "对应哪条举报" });
    const btn = h("button", { class: "btn danger" }, "禁言");
    btn.addEventListener("click", action(btn, box, async () => {
      const n = hours.value ? parseInt(hours.value, 10) : null;
      const span = hours.options[hours.selectedIndex].textContent;
      if (!confirm(`禁言 ${who}：${span}\n他在世界频道发言时会看到的原因：${reason.value}`)) return "";
      await api("POST", `/admin/api/players/${p.player_id}/mute`, { hours: n, reason: reason.value, note: note.value });
      reload();
      return "已禁言";
    }));
    card.append(
      h("p", { class: "hint" }, "禁言不用审批，随时能解除。只管世界频道：照常能玩、能私聊。"),
      h("div", { class: "row" }, field("多久", hours), field("给玩家看的原因", reason, true),
        field("内部备注（玩家看不到）", note, true), btn));
  }
  if (d.mutes && d.mutes.length) {
    card.append(h("h3", {}, "禁言记录"), table(["时间", "到", "原因", "备注", "操作人", "解除"], d.mutes.map((m) =>
      h("tr", {}, h("td", {}, fmt(m.created_at)), h("td", {}, m.ends_at ? fmt(m.ends_at) : "永久"),
        h("td", {}, m.reason), h("td", { class: "muted" }, m.note || ""), h("td", {}, m.actor),
        h("td", {}, m.revoked_at ? `${m.revoked_by} ${fmt(m.revoked_at)}${m.revoke_note ? "：" + m.revoke_note : ""}` : "")))));
  }
  return card;
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
// 举报与世界频道（database/019，docs/聊天系统设计.md 批次 E）
// ---------------------------------------------------------------------------
//
// 处理一条举报 = 看证据（服务器在举报那一刻复制的，不是举报人上传的）→ 需要的话删消息、
// 去玩家页禁言 / 封号 → 把举报标成「已处理」或「不成立」。标记本身不处罚任何人。

const REPORT_CONTEXT = { world: "世界频道", profile: "资料页", dm: "私聊", match: "房间 / 对局" };
const REPORT_REASON = { abuse: "辱骂骚扰", ads: "广告引流", cheat: "外挂作弊", name: "不当昵称 / 头像 / 签名", other: "其他" };
const REPORT_STATUS = { open: ["待处理", "yellow"], resolved: ["已处理", "green"], dismissed: ["不成立", ""] };

function statusTag(map, key) {
  const [label, color] = map[key] || [key, ""];
  return h("span", { class: `tag ${color}` }, label);
}

// 跳到玩家页并打开这个人（封号、禁言都在那里）。
function openPlayer(playerId) {
  state.focusPlayer = playerId;
  state.tab = "players";
  render();
}

function openReport(reportId) {
  state.focusReport = reportId;
  state.tab = "reports";
  render();
}

// 世界频道消息表。玩家页、举报证据、世界频道页共用；三处给的行长得不完全一样（证据里是快照）。
function worldCard(messages, reload, title, withSender) {
  const box = h("div", {});
  const rows = (messages || []).map((m) => {
    const hidden = m.hidden_at || m.hidden;
    const cell = h("td", {});
    if (!hidden) {
      const btn = h("button", { class: "btn small danger" }, "删除");
      btn.addEventListener("click", action(btn, box, async () => {
        const why = prompt(`删除这条世界频道消息？正开着世界频道的人那边会当场消失。\n\n「${m.body}」\n\n原因（内部备注，可空）：`, "");
        if (why === null) return "";
        await api("POST", `/admin/api/world/${m.message_id}/hide`, { reason: why });
        reload();
        return "已删除";
      }));
      cell.append(btn);
    }
    return h("tr", {},
      h("td", {}, fmt(m.created_at)),
      withSender ? h("td", { class: "mono" }, m.friend_code || "") : null,
      h("td", {}, m.sender_name || m.name || ""),
      h("td", {}, m.body),
      h("td", {}, hidden
        ? h("span", { class: "tag", title: m.hidden_reason || "" },
          m.hidden_by ? `已删（${m.hidden_by}${m.hidden_reason ? "：" + m.hidden_reason : ""}）` : "已删")
        : ""),
      withSender && m.sender_id
        ? h("td", {}, h("button", { class: "btn small", onclick: () => openPlayer(m.sender_id) }, "看这个人"))
        : null,
      cell);
  });
  const headers = ["时间"].concat(withSender ? ["好友码"] : []).concat(["昵称（当时）", "内容", "状态"])
    .concat(withSender ? [""] : []).concat([""]);
  return h("section", { class: "card" }, h("h2", {}, title), box, table(headers, rows));
}

function reportsCard(reports, title) {
  return h("section", { class: "card" }, h("h2", {}, title),
    table(["#", "时间", "场合", "原因", "举报人", "说明", "状态"], (reports || []).map((r) =>
      h("tr", { class: "click", onclick: () => openReport(r.report_id) },
        h("td", {}, r.report_id), h("td", {}, fmt(r.created_at)), h("td", {}, REPORT_CONTEXT[r.context] || r.context),
        h("td", {}, REPORT_REASON[r.reason] || r.reason),
        h("td", {}, `${r.reporter_name}（${r.reporter_code}）`),
        h("td", { class: "muted" }, r.note_from_reporter || ""), h("td", {}, statusTag(REPORT_STATUS, r.status))))));
}

async function reportsView(main) {
  const filter = h("select", {}, Object.entries({ open: "待处理", resolved: "已处理", dismissed: "不成立", all: "全部" })
    .map(([value, label]) => h("option", { value }, label)));
  filter.value = state.reportFilter || "open";
  const box = h("div", {});
  const list = h("div", {});
  const detail = h("div", {});
  const load = async () => {
    state.reportFilter = filter.value;
    list.replaceChildren(h("p", { class: "muted" }, "加载中…"));
    try {
      const data = await api("GET", "/admin/api/reports?status=" + filter.value);
      list.replaceChildren(table(["#", "时间", "被举报", "场合", "原因", "举报人", "说明", "状态"], data.reports.map((r) =>
        h("tr", { class: "click", onclick: () => showReport(r.report_id, detail, load) },
          h("td", {}, r.report_id), h("td", {}, fmt(r.created_at)),
          h("td", {}, h("b", {}, r.target_name), ` ${r.target_code}`),
          h("td", {}, REPORT_CONTEXT[r.context] || r.context), h("td", {}, REPORT_REASON[r.reason] || r.reason),
          h("td", {}, `${r.reporter_name}（${r.reporter_code}）`),
          h("td", { class: "muted" }, r.note_from_reporter || ""), h("td", {}, statusTag(REPORT_STATUS, r.status))))));
    } catch (e) {
      list.replaceChildren(notice("error", e.message));
    }
  };
  filter.addEventListener("change", load);
  main.append(h("section", { class: "card" }, h("h2", {}, "举报"),
    h("p", { class: "hint" }, "证据是服务器在举报那一刻复制的（不是举报人上传的）。同一个人对同一个人、同一种场合，"
      + "处理前只算一条。处理完标「已处理」或「不成立」—— 标记本身不处罚任何人，封号 / 禁言去玩家页。"),
    h("div", { class: "row" }, field("看哪些", filter)), box, list), detail);
  await load();
  if (state.focusReport) {
    showReport(state.focusReport, detail, load);
    state.focusReport = null;
  }
}

async function showReport(reportId, into, reloadList) {
  into.replaceChildren(h("p", { class: "muted" }, "加载中…"));
  let r;
  try {
    r = await api("GET", "/admin/api/reports/" + reportId);
  } catch (e) {
    into.replaceChildren(notice("error", e.message));
    return;
  }
  const reload = () => { showReport(reportId, into, reloadList); reloadList(); };
  const ev = r.evidence || {};
  const prof = ev.profile || {};
  const box = h("div", {});
  const head = h("section", { class: "card" },
    h("h2", {}, `举报 #${r.report_id} `, statusTag(REPORT_STATUS, r.status)),
    h("div", { class: "facts" },
      h("div", {}, h("span", {}, "被举报"), h("b", {}, r.target_name), ` ${r.target_code} `,
        h("button", { class: "btn small", onclick: () => openPlayer(r.target_id) }, "去他的玩家页（封号 / 禁言）")),
      h("div", {}, h("span", {}, "举报人"), `${r.reporter_name}（${r.reporter_code}）`),
      h("div", {}, h("span", {}, "时间"), fmt(r.created_at)),
      h("div", {}, h("span", {}, "场合 / 原因"), `${REPORT_CONTEXT[r.context] || r.context} · ${REPORT_REASON[r.reason] || r.reason}`),
      h("div", {}, h("span", {}, "被多少个不同的人举报过"), String(r.reporters_against_target)),
      r.handled_by ? h("div", {}, h("span", {}, "处理"), `${r.handled_by} ${fmt(r.handled_at)}${r.handled_note ? "：" + r.handled_note : ""}`) : null),
    r.note_from_reporter ? h("p", {}, h("b", {}, "举报人说："), r.note_from_reporter) : null,
    h("h3", {}, "当时的资料（举报那一刻）"),
    h("p", {}, `昵称：${prof.player_name || "—"}　签名：${prof.signature || "（没有）"}　头像：${prof.avatar || "—"}`),
    box);
  if (r.status === "open") {
    const note = h("input", { maxlength: "500", placeholder: "处理说明（例如：已禁言 1 天）" });
    const done = h("button", { class: "btn primary" }, "标为已处理");
    const reject = h("button", { class: "btn" }, "标为不成立");
    const decide = (status, label) => async () => {
      if (!confirm(`把举报 #${r.report_id} 标为「${label}」？`)) return "";
      await api("POST", `/admin/api/reports/${r.report_id}/resolve`, { status, note: note.value });
      refreshOpenReports();
      reload();
      return `已标为${label}`;
    };
    done.addEventListener("click", action(done, box, decide("resolved", "已处理")));
    reject.addEventListener("click", action(reject, box, decide("dismissed", "不成立")));
    head.append(h("div", { class: "row" }, field("处理说明", note, true), done, reject));
  }
  const parts = [head];
  if (ev.world_message !== undefined) {
    parts.push(worldCard(ev.world_message ? [ev.world_message] : [], reload, "被举报的那一条"));
  }
  if (ev.world_recent) parts.push(worldCard(ev.world_recent, reload, "他当时最近在世界频道说的（含已删）"));
  if (ev.dm_recent) {
    parts.push(h("section", { class: "card" }, h("h2", {}, "他们最近的私聊（举报那一刻，最多 50 条）"),
      table(["时间", "谁说的", "内容"], ev.dm_recent.map((m) => h("tr", {},
        h("td", {}, fmt(m.created_at)), h("td", {}, m.from === "target" ? h("b", {}, "被举报人") : "举报人"),
        h("td", {}, m.body))))));
  }
  if (r.context === "match") {
    parts.push(notice("warn", "房间 / 对局里的聊天服务器不存，这条举报只有资料快照。"));
  }
  into.replaceChildren(...parts);
  into.scrollIntoView({ behavior: "smooth" });
}

async function worldView(main) {
  const code = h("input", { placeholder: "只看某个好友码（可空）", maxlength: "8" });
  const refresh = h("button", { class: "btn" }, "刷新");
  const list = h("div", {});
  const load = async () => {
    list.replaceChildren(h("p", { class: "muted" }, "加载中…"));
    try {
      const data = await api("GET", "/admin/api/world");
      const want = code.value.trim().toUpperCase();
      const rows = want ? data.messages.filter((m) => m.friend_code === want) : data.messages;
      list.replaceChildren(worldCard(rows, load, `最近 200 条（新的在上面）${want ? " · 只看 " + want : ""}`, true));
    } catch (e) {
      list.replaceChildren(notice("error", e.message));
    }
  };
  refresh.addEventListener("click", load);
  code.addEventListener("keydown", (e) => { if (e.key === "Enter") load(); });
  main.append(h("section", { class: "card" }, h("h2", {}, "世界频道"),
    h("p", { class: "hint" }, "第一版只有本地规则（联系方式、词表）自动拦，其余靠举报和这里人工删。删除是打标记，"
      + "库里留着（举报要看上下文），玩家那边当场消失。库里只存 7 天。"),
    h("div", { class: "row" }, field("好友码", code), refresh)), list);
  await load();
}

// ---------------------------------------------------------------------------
// 数据（docs/运营数据.md）。口径都在页面的灰字里 —— 数字会被截图发给别人，口径要跟着走。
// ---------------------------------------------------------------------------

const SVG_NS = "http://www.w3.org/2000/svg";

function svg(tag, attrs, ...children) {
  const el = document.createElementNS(SVG_NS, tag);
  for (const [key, value] of Object.entries(attrs || {})) el.setAttribute(key, value);
  for (const child of children.flat()) if (child) el.append(child);
  return el;
}

function pct(numerator, denominator) {
  return denominator ? `${(100 * numerator / denominator).toFixed(1)}%` : "—";
}

const WEEKDAYS = "日一二三四五六";

// "2026-10-01" → "10-01 周四"
function dayLabel(iso) {
  return `${iso.slice(5)} 周${WEEKDAYS[new Date(iso + "T00:00:00Z").getUTCDay()]}`;
}

// 服务器给的 UTC 时间 → 马来西亚时间当天第几分钟。
function minuteOfDay(iso) {
  const d = new Date(Date.parse(iso) + MYT_MS);
  return d.getUTCHours() * 60 + d.getUTCMinutes();
}

function dash(value, render) {
  return value === null || value === undefined ? "—" : (render ? render(value) : value);
}

// 导出给别人用。文字格子以 = + - @ 开头的前面加 '，免得 Excel 当成公式执行；带 BOM，Excel 才认中文。
function downloadCsv(name, headers, rows) {
  const cell = (value) => {
    let text = value === null || value === undefined ? "" : String(value);
    if (typeof value === "string" && /^[=+\-@]/.test(text)) text = "'" + text;
    return /[",\r\n]/.test(text) ? `"${text.replace(/"/g, '""')}"` : text;
  };
  const body = [headers, ...rows].map((row) => row.map(cell).join(",")).join("\r\n");
  const url = URL.createObjectURL(new Blob(["﻿" + body], { type: "text/csv;charset=utf-8" }));
  const link = h("a", { href: url, download: name });
  document.body.append(link);
  link.click();
  link.remove();
  setTimeout(() => URL.revokeObjectURL(url), 1000);
}

function csvButton(fn) {
  const btn = h("button", { class: "btn small" }, "导出 CSV");
  btn.addEventListener("click", fn);
  return btn;
}

const DATA_RANGES = [["14", "近 14 天"], ["30", "近 30 天"], ["60", "近 60 天"], ["90", "近 90 天"]];

async function dataView(main) {
  const range = h("select", {}, DATA_RANGES.map(([value, label]) => h("option", { value }, label)));
  range.value = state.dataDays || "30";
  const refresh = h("button", { class: "btn" }, "刷新");
  const top = h("div", {});
  const boxes = [h("div", {}), h("div", {}), h("div", {}), h("div", {}), h("div", {})];
  // 游戏上报的那几块（026）单独拉：库还没跑 026 时只这一块报错，上面照常。
  const client = h("div", {});
  main.append(h("section", { class: "card" }, h("h2", {}, "运营数据"),
    h("p", { class: "hint" }, "全部按马来西亚时间的自然日。员工 / 测试 / 压测号（在玩家页标）全部不算。"
      + "「没记」「未到」「—」都表示没有这个数，不是 0。"),
    h("div", { class: "row" }, field("范围", range), refresh), top), ...boxes.slice(0, 4), client, boxes[4]);
  const load = async () => {
    state.dataDays = range.value;
    top.replaceChildren(h("p", { class: "muted" }, "加载中…"));
    for (const box of boxes) box.replaceChildren();
    loadClientReport(client, range.value);
    let ov, ret, games, tags;
    try {
      [ov, ret, games, tags] = await Promise.all([
        api("GET", `/admin/api/analytics/overview?days=${range.value}`),
        api("GET", `/admin/api/analytics/retention?days=${range.value}`),
        api("GET", `/admin/api/analytics/matches?days=${range.value}`),
        api("GET", "/admin/api/analytics/tags"),
      ]);
    } catch (e) {
      top.replaceChildren(notice("error", e.message));
      return;
    }
    top.replaceChildren(nowStrip(ov));
    boxes[0].append(dailyCard(ov));
    boxes[1].append(curveCard(ov));
    boxes[2].append(retentionCard(ret));
    boxes[3].append(matchesCard(games, range.value));
    boxes[4].append(tagsCard(tags.tags));
  };
  range.addEventListener("change", load);
  refresh.addEventListener("click", load);
  await load();
}

function stat(value, label) {
  return h("div", {}, h("b", {}, value), h("span", {}, label));
}

function nowStrip(ov) {
  const today = ov.days[0];
  return h("div", {},
    ov.collection_started_at ? null
      : notice("warn", "还没有任何数据：数据库跑过 025_analytics.sql、账号服务器更新之后才开始记。之前的日子补不回来。"),
    h("div", { class: "money" },
      stat(num(ov.now.players), "现在在线"),
      stat(num(ov.now.queued), "现在排队"),
      stat(dash(today && today.active, num), "今天来过"),
      stat(dash(today && today.peak, num), "今天最高在线"),
      stat(num(ov.ever_active), "开始记录以来来过的人")),
    h("p", { class: "hint" }, `从 ${fmt(ov.collection_started_at)} 开始记录 · 内部账号 ${ov.internal_accounts} 个`
      + `（现在在线 ${ov.now.internal} 个，都没算进上面）· 数据截至 ${fmt(ov.as_of)}`));
}

function coverageTag(value) {
  if (value === null) return "—";
  const p = Math.floor(value * 100);
  return h("span", { class: p >= 95 ? "tag green" : p >= 50 ? "tag yellow" : "tag red" }, `${p}%`);
}

function dailyCard(ov) {
  const headers = ["日期", "日活", "近 7 天来过", "新注册", "最高在线", "在几点", "平均在线",
                   "人均在线（分钟）", "中位 / 前 10%", "打完的对局", "采集覆盖"];
  const rows = ov.days.map((d) => h("tr", {},
    h("td", {}, dayLabel(d.day)),
    h("td", { class: "num" }, d.recorded ? h("b", {}, num(d.active)) : h("span", { class: "muted" }, "没记")),
    h("td", { class: "num" }, d.recorded ? [num(d.weekly_active), d.weekly_partial ? " *" : ""] : "—"),
    h("td", { class: "num" }, num(d.registered)),
    h("td", { class: "num" }, dash(d.peak, num)),
    h("td", {}, d.peak_at ? fmt(d.peak_at).slice(11) : ""),
    h("td", { class: "num" }, dash(d.avg_online)),
    h("td", { class: "num" }, dash(d.minutes_avg)),
    h("td", { class: "num" }, d.minutes_p50 === null ? "—" : `${d.minutes_p50} / ${d.minutes_p90}`),
    h("td", { class: "num" }, num(d.matches)),
    h("td", {}, coverageTag(d.coverage))));
  const csv = csvButton(() => downloadCsv(`glory_daily_${ov.today}.csv`,
    ["日期", "日活", "近7天来过", "近7天不完整", "新注册", "内部账号新注册", "最高在线", "最高在线时刻(MYT)", "平均在线",
     "人均在线分钟", "在线分钟中位", "在线分钟P90", "打完的对局", "采集覆盖"],
    ov.days.map((d) => [d.day, d.active, d.weekly_active, d.weekly_partial ? "是" : "", d.registered, d.registered_internal,
      d.peak, d.peak_at ? fmt(d.peak_at) : "", d.avg_online, d.minutes_avg, d.minutes_p50, d.minutes_p90, d.matches,
      d.coverage === null ? "" : d.coverage.toFixed(3)])));
  return h("section", { class: "card" }, h("h2", {}, "每天 ", csv),
    h("ul", { class: "hint" },
      h("li", {}, "日活：那天游戏开着、连上过账号服务器的人，一个人一天只算一次。"),
      h("li", {}, "近 7 天来过：到那天为止 7 天里来过的人，按人去重（不是 7 天日活相加）。带 * 的是 7 天里有几天还没开始记，偏小。"),
      h("li", {}, "新注册：那天第一次打开游戏自动建的号。卸载重装、换手机会再建一个新号，所以新注册 ≥ 新来的人。"),
      h("li", {}, "在线：每 15 秒数一次此刻连着的真人（一个人几台设备算一个）；最高在线是那天数到的最大值，平均在线是那天所有采样的平均。"),
      h("li", {}, "人均在线：连着的时长，只算当天来过的人。手机切后台不算；电脑版最小化会算进去（偏多）。"),
      h("li", {}, "打完的对局：那天结束、并且有人交了战报的局。中途散掉的局不在这里。"),
      h("li", {}, "采集覆盖：那天真正采到了多少时间。不到 100% 的那段是服务器重启或数据库一时写不进，那段在线人数没有数，不是没人。"
        + "开始记录的第一天本来就不满。")),
    table(headers, rows));
}

function curveCard(ov) {
  const card = h("section", { class: "card" }, h("h2", {}, "在线曲线"));
  const days = ov.days.filter((d) => d.recorded);
  if (!days.length) {
    card.append(h("p", { class: "muted" }, "还没有数据"));
    return card;
  }
  const pick = h("select", {}, days.map((d) => h("option", { value: d.day }, dayLabel(d.day))));
  const box = h("div", {});
  const load = async () => {
    box.replaceChildren(h("p", { class: "muted" }, "加载中…"));
    try {
      box.replaceChildren(curveChart(await api("GET", "/admin/api/analytics/online?day=" + pick.value)));
    } catch (e) {
      box.replaceChildren(notice("error", e.message));
    }
  };
  pick.addEventListener("change", load);
  card.append(h("p", { class: "hint" }, "每分钟一个点（那一分钟里最高的一次采样），横轴是马来西亚时间 0–24 点。"
    + "蓝线 = 在线，黄线 = 排队（有人排队时才有）。线断开 = 那段没采到，不是 0 人；红色虚线 = 账号服务器重新启动。"),
    h("div", { class: "row" }, field("哪一天", pick)), box);
  load();
  return card;
}

// 纵轴四格，每格一个整数的「好看」人数（1、2、5、10、15、20、25、50…）。
function gridStep(value) {
  if (value <= 1) return 1;
  const base = Math.pow(10, Math.floor(Math.log10(value)));
  for (const m of [1, 1.5, 2, 2.5, 3, 4, 5, 6, 8, 10]) {
    if (m * base >= value && Number.isInteger(m * base)) return m * base;
  }
  return 10 * base;
}

function curveChart(data) {
  if (!data.points.length) return h("p", { class: "muted" }, "这一天没有采到");
  const W = 1440, H = 200;
  const peakPoint = data.points.reduce((best, p) => (p[1] > best[1] ? p : best), data.points[0]);
  const step = gridStep(Math.max(...data.points.map((p) => Math.max(p[1], p[2]))) / 4);
  const top = step * 4;
  const y = (v) => (H - (v / top) * H).toFixed(1);
  // 连续的分钟连成一段，中间缺超过 2 分钟就断开：缺的那段不能画成连着的线。
  const lines = (index) => {
    const segments = [];
    let seg = [];
    let last = -10;
    for (const p of data.points) {
      if (p[0] - last > 2 && seg.length) { segments.push(seg); seg = []; }
      seg.push([p[0], p[index]]);
      last = p[0];
    }
    if (seg.length) segments.push(seg);
    return segments.map((s) => {
      if (s.length === 1) s.push([s[0][0] + 1, s[0][1]]);
      return s.map(([m, v]) => `${m},${y(v)}`).join(" ");
    });
  };
  const queued = data.points.some((p) => p[2] > 0);
  const chart = svg("svg", { class: "chart", viewBox: `0 0 ${W} ${H}`, preserveAspectRatio: "none",
                             role: "img", "aria-label": `${data.day} 在线曲线` },
    [1, 2, 3].map((i) => svg("line", { class: "grid", x1: 0, x2: W, y1: (H * i) / 4, y2: (H * i) / 4 })),
    [1, 2, 3, 4, 5, 6, 7].map((i) => svg("line", { class: "grid", x1: i * 180, x2: i * 180, y1: 0, y2: H })),
    data.restarts.map((iso) => {
      const m = minuteOfDay(iso);
      return svg("line", { class: "restart", x1: m, x2: m, y1: 0, y2: H });
    }),
    queued ? lines(2).map((points) => svg("polyline", { class: "queue", points })) : [],
    lines(1).map((points) => svg("polyline", { class: "line", points })));
  const hh = (m) => `${String(Math.floor(m / 60)).padStart(2, "0")}:${String(m % 60).padStart(2, "0")}`;
  return h("div", {},
    h("p", {}, `最高 ${num(peakPoint[1])} 人（${hh(peakPoint[0])}）· 纵轴满格 ${num(top)} 人，横线每格 ${num(step)} 人`
      + (data.restarts.length ? ` · 这天重启了 ${data.restarts.length} 次` : "")),
    chart,
    h("div", { class: "chart-hours" }, [0, 3, 6, 9, 12, 15, 18, 21, 24].map((hour) => h("span", {}, `${hour}`))));
}

function retentionBucket(rate) {
  return rate >= 0.5 ? 4 : rate >= 0.3 ? 3 : rate >= 0.15 ? 2 : rate >= 0.05 ? 1 : 0;
}

function retentionCell(cell, size) {
  if (cell.state === "future") return h("td", { class: "ret future" }, "未到");
  const today = cell.state === "today";
  return h("td", { class: today ? "ret today" : `ret r${retentionBucket(size ? cell.returned / size : 0)}`,
                   title: today ? "今天还没过完，这个数还会涨" : "" },
    h("b", {}, pct(cell.returned, size), today ? "…" : ""), h("span", {}, `${cell.returned}/${size}`));
}

function retentionCard(ret) {
  const label = (n) => (n === 0 ? "当天" : `D${n}`);
  const card = h("section", { class: "card" }, h("h2", {}, "留存（按注册日）"),
    h("ul", { class: "hint" },
      h("li", {}, "D1 = 注册后第二天那一整天来过；D7 = 第 8 天那一天来过（例：10-01 注册，D1 看 10-02，D7 看 10-08）。不是「几天之内来过一次」。"),
      h("li", {}, "每格：回来的人 / 那天注册的人。「当天」是注册那天有没有真的进过游戏。"),
      h("li", {}, "合计 = 各天回来的人相加 / 各天人数相加，只算已经过完的格子（不是把百分比平均）。「…」= 今天还没过完。"),
      h("li", {}, "只算开始记录之后注册、没注销的号；内部账号不算。人数少于 30 的行波动很大，别单独下结论。")));
  if (!ret.cohorts.length) {
    card.append(h("p", { class: "muted" }, ret.collection_started_at ? "开始记录之后还没有新注册的号" : "还没开始记录"));
    return card;
  }
  const headers = ["注册日", "人数", ...ret.offsets.map(label)];
  const rows = ret.cohorts.map((c) => h("tr", {},
    h("td", {}, dayLabel(c.day)),
    h("td", { class: c.size < 30 ? "num muted" : "num", title: c.size < 30 ? "样本少" : "" }, num(c.size)),
    c.cells.map((cell) => retentionCell(cell, c.size))));
  rows.push(h("tr", { class: "total" }, h("td", {}, "合计（已过完的）"), h("td", {}, ""),
    ret.total.map((t) => (t.size
      ? h("td", { class: "ret", title: `${t.cohorts} 天合计` }, h("b", {}, pct(t.returned, t.size)), h("span", {}, `${t.returned}/${t.size}`))
      : h("td", { class: "ret future" }, "未到")))));
  const csv = csvButton(() => downloadCsv(`glory_retention_${ret.today}.csv`,
    ["注册日", "人数", ...ret.offsets.map((n) => `${label(n)}回来`), ...ret.offsets.map((n) => `${label(n)}状态`)],
    ret.cohorts.map((c) => [c.day, c.size, ...c.cells.map((cell) => cell.returned),
      ...c.cells.map((cell) => ({ done: "已过完", today: "今天未完", future: "未到" }[cell.state]))])
      .concat([["合计(已过完)", "", ...ret.total.map((t) => (t.size ? `${t.returned}/${t.size}` : "")),
        ...ret.total.map(() => "")]])));
  card.querySelector("h2").append(" ", csv);
  card.append(table(headers, rows));
  return card;
}

const MODE_NAMES = { custom: "自定义房间", casual: "休闲匹配", ranked: "排位" };
const ROUND_KINDS = { boss: "Boss", pvp: "PVP", normal: "普通" };

function matchesCard(data, days) {
  const card = h("section", { class: "card" }, h("h2", {}, `对局（近 ${days} 天打完的）`),
    h("ul", { class: "hint" },
      h("li", {}, "只有打完、并且有人交了战报的局。中途散掉、全员掉线没人交的局这里没有（要等战斗服务器直接上报，下一批做）。"),
      h("li", {}, "真人座位 = 有账号的座位；AI 座位 = 一开始就是 AI（房主加的）。中途离开 = 真人座位到最后不在线（掉线后回来的不算）。"),
      h("li", {}, `结束回合：整局在第几回合结束（一方法阵归零，或打满 ${data.final_round} 回合）。内部账号的局也算在里面。`)));
  if (!data.modes.length) {
    card.append(h("p", { class: "muted" }, "这段时间没有"));
    return card;
  }
  card.append(table(["模式", "局数", "平均结束回合", `打满 ${data.final_round} 回合`, "6 个都是真人", "平局",
                     "真人座位", "AI 座位", "中途离开", "时长中位（分钟）"],
    data.modes.map((m) => h("tr", {},
      h("td", {}, MODE_NAMES[m.mode] || m.mode), h("td", { class: "num" }, num(m.matches)),
      h("td", { class: "num" }, m.avg_rounds),
      h("td", { class: "num" }, `${num(m.full_length)}（${pct(m.full_length, m.matches)}）`),
      h("td", { class: "num" }, `${num(m.all_human)}（${pct(m.all_human, m.matches)}）`),
      h("td", { class: "num" }, num(m.draws)),
      h("td", { class: "num" }, num(m.humans)), h("td", { class: "num" }, num(m.bots)),
      h("td", { class: "num" }, `${num(m.left_early)}（${pct(m.left_early, m.humans)}）`),
      h("td", { class: "num" }, m.median_minutes)))));
  for (const m of data.modes) {
    card.append(h("h3", {}, `${MODE_NAMES[m.mode] || m.mode}：在第几回合结束`),
      table(["回合", "类型", "局数", "占比", ""], m.end_rounds.map(([round, kind, n]) => h("tr", {},
        h("td", { class: "num" }, round), h("td", {}, ROUND_KINDS[kind] || kind), h("td", { class: "num" }, num(n)),
        h("td", { class: "num" }, pct(n, m.matches)),
        h("td", {}, h("progress", { max: m.matches, value: n }))))));
  }
  return card;
}

// --- 游戏上报的事件（第二批，docs/运营数据.md 第六节）---------------------------------------

const TUTORIAL_STEP_NAMES = {
  BUY_3: "购买棋子", PLACE_3: "上阵布阵", START_PVE_1: "首场战斗", UPGRADE_2: "升到 2 星",
  START_PVE_2: "第二场战斗", TAKE_TREASURE_1: "选择宝藏", UPGRADE_3: "升到 3 星", UPGRADE_OTHERS: "继续升星",
  BOND_HINT: "查看羁绊", VIEW_TREASURE: "查看宝藏", FORMATION_HP: "了解法阵", CARROT_CAMP: "萝卜营地",
  HARVEST_UPGRADE: "升级采集", START_BOSS: "挑战首领", TAKE_TREASURE_2: "再选宝藏", CARROT_HARVEST: "收获萝卜",
  DRAW_STONE: "抽升级石", FOUR_STAR: "升到四星", HIRE_MERC: "召唤佣兵", FILL_7: "补满七人", START_PVP: "玩家对战",
};
const REASON_EVENTS = { replay_failed: "战斗播放失败", reconnect: "重连失败", room_action_failed: "进房 / 建房失败",
                        match_leave: "中途离开" };
const PERF_CONTEXT = { menu: "主菜单 / 大厅", tutorial: "新手教学", match: "对局中" };
const CLIENT_MODES = [["all", "全部模式"], ["custom", "自定义房间"], ["casual", "休闲匹配"], ["ranked", "排位"]];

async function loadClientReport(into, days, mode) {
  into.replaceChildren(h("section", { class: "card" }, h("p", { class: "muted" }, "游戏上报的数据加载中…")));
  let cr;
  try {
    cr = await api("GET", `/admin/api/analytics/client?days=${days}&mode=${mode || "all"}`);
  } catch (e) {
    into.replaceChildren(h("section", { class: "card" }, h("h2", {}, "游戏上报的数据"), notice("error", e.message)));
    return;
  }
  into.replaceChildren(
    h("section", { class: "card" }, h("h2", {}, "游戏上报的数据（第二批）"),
      h("p", { class: "hint" }, "下面几块是游戏自己报上来的，只有装了新包的人才有。分母都是「报过的人」，"
        + "所以先看「新包覆盖」：覆盖低的时候，下面的比例只代表已经更新的那部分玩家。")),
    coverageCard(cr), tutorialCard(cr.tutorial), firstPlayCard(cr.first_play),
    roundsCard(cr, into, days), qualityCard(cr.quality));
}

function coverageCard(cr) {
  return h("section", { class: "card" }, h("h2", {}, "新包覆盖"),
    h("p", { class: "hint" }, "每天报过事件的人 / 那天的日活。新包刚发的几天会低，越接近 100% 下面的数越能代表全体。"
      + "版本号 0 = 从编辑器里跑的（内部测试）。"),
    table(["日期", "报过事件的人", "日活", "覆盖", "事件条数"], cr.coverage.map((d) => h("tr", {},
      h("td", {}, dayLabel(d.day)), h("td", { class: "num" }, num(d.players)), h("td", { class: "num" }, dash(d.active, num)),
      h("td", { class: "num" }, d.active ? pct(d.players, d.active) : "—"), h("td", { class: "num" }, num(d.events))))),
    h("h3", {}, "按包的版本"),
    table(["版本号", "人数", "最近一次"], cr.builds.map((b) => h("tr", {},
      h("td", { class: "num" }, b.build), h("td", { class: "num" }, num(b.players)), h("td", {}, fmt(b.last_seen))))));
}

function tutorialCard(t) {
  const card = h("section", { class: "card" }, h("h2", {}, "新手教学漏斗"),
    h("p", { class: "hint" }, "这段时间开始过教学的人，之后每一步走到哪（重玩的算一个人）。到达第 N 步 = 完成了上一步。"
      + "「停在这步」= 到了这一步、没完成也没跳过（可能退出了游戏，也可能还没玩完）。耗时只算游戏开着的时间，切后台不算。"));
  if (!t.started) {
    card.append(h("p", { class: "muted" }, "这段时间没有人开始教学"));
    return card;
  }
  const others = t.started - t.completed - t.skipped;
  card.append(h("div", { class: "money" },
    stat(num(t.started), "开始教学"), stat(`${num(t.completed)}（${pct(t.completed, t.started)}）`, "完成"),
    stat(`${num(t.skipped)}（${pct(t.skipped, t.started)}）`, "跳过"),
    stat(`${num(Math.max(0, others))}（${pct(Math.max(0, others), t.started)}）`, "既没完成也没跳过")));
  card.append(table(["步", "内容", "到达", "完成", "跳过", "停在这步", "", "中位耗时（秒）", "慢的 10%（秒）"],
    t.steps.map((s) => h("tr", {},
      h("td", { class: "num" }, s.index), h("td", {}, TUTORIAL_STEP_NAMES[s.step] || s.step || "—"),
      h("td", { class: "num" }, num(s.reached)), h("td", { class: "num" }, num(s.done)),
      h("td", { class: "num" }, s.skipped ? num(s.skipped) : ""),
      h("td", { class: s.stuck ? "num neg" : "num" }, s.stuck ? `${num(s.stuck)}（${pct(s.stuck, s.reached)}）` : ""),
      h("td", {}, h("progress", { max: t.started, value: s.reached })),
      h("td", { class: "num" }, dash(s.p50_sec)), h("td", { class: "num" }, dash(s.p90_sec))))));
  return card;
}

function firstPlayCard(f) {
  const rows = [
    ["注册并打开了新包", f.players], ["开始新手教学", f.tutorial_started], ["教学完成", f.tutorial_done],
    ["跳过教学（没完成）", f.tutorial_skipped], ["开了第一局对局", f.match_started], ["打完过一整局", f.match_finished],
  ];
  return h("section", { class: "card" }, h("h2", {}, "新玩家第一次体验"),
    h("p", { class: "hint" }, "这段时间注册、装的是新包的号，各走到了哪一步（每一行都是占注册人数的比例）。"
      + "第二天回来只算注册后第二天已经过完的人。内部账号不算。"),
    f.players ? table(["", "人数", "占注册", ""], rows.map(([label, n]) => h("tr", {},
      h("td", {}, label), h("td", { class: "num" }, num(n)), h("td", { class: "num" }, pct(n, f.players)),
      h("td", {}, h("progress", { max: f.players, value: n })))).concat([h("tr", {},
      h("td", {}, "第二天回来"), h("td", { class: "num" }, `${num(f.d1_back)} / ${num(f.d1_ready)}`),
      h("td", { class: "num" }, pct(f.d1_back, f.d1_ready)), h("td", {}, h("progress", { max: f.d1_ready || 1, value: f.d1_back })))]))
      : h("p", { class: "muted" }, "这段时间还没有装新包的新注册玩家"));
}

function roundsCard(cr, into, days) {
  const mode = h("select", {}, CLIENT_MODES.map(([value, label]) => h("option", { value }, label)));
  mode.value = cr.mode;
  mode.addEventListener("change", () => loadClientReport(into, days, mode.value));
  const card = h("section", { class: "card" }, h("h2", {}, "回合难度"),
    h("ul", { class: "hint" },
      h("li", {}, "一支队伍打一个回合算一次（同队三个人都报，只算一次）。数据是战斗服务器算好、经游戏转来的。"),
      h("li", {}, "「这回合输了」是这一场战斗输了（法阵扣血）；「法阵归零」= 整局在这一回合输掉。"),
      h("li", {}, "越往后的回合到达的队伍越少，别拿第 20 回合的输率跟第 1 回合的比人数。自定义房间里有 AI 座位，和匹配分开看。")),
    h("div", { class: "row" }, field("模式", mode)));
  if (!cr.rounds.length) {
    card.append(h("p", { class: "muted" }, "这段时间没有"));
    return card;
  }
  card.append(table(["回合", "类型", "到达的队伍", "这回合输了", "法阵归零", "平均剩余法阵"], cr.rounds.map((r) => h("tr", {},
    h("td", { class: "num" }, r.round), h("td", {}, ROUND_KINDS[r.kind] || r.kind || ""),
    h("td", { class: "num" }, num(r.teams)), h("td", { class: "num" }, `${num(r.lost)}（${pct(r.lost, r.teams)}）`),
    h("td", { class: r.eliminated ? "num neg" : "num" }, r.eliminated ? `${num(r.eliminated)}（${pct(r.eliminated, r.teams)}）` : ""),
    h("td", { class: "num" }, dash(r.avg_hp))))));
  return card;
}

function qualityCard(q) {
  const replays = q.replay_done + q.replay_failed;
  return h("section", { class: "card" }, h("h2", {}, "技术问题"),
    h("div", { class: "money" },
      stat(`${num(q.replay_failed)} / ${num(replays)}`, `战斗播放失败（${pct(q.replay_failed, replays)}）`),
      stat(num(q.reconnects), "重连次数（成功 + 失败）"),
      stat(`${num(q.match_leave_players)} 人`, `中途退出对局（共 ${num(q.match_leaves)} 次，开局 ${num(q.matches_started)} 次）`),
      stat(q.launch.launches ? `${dash(q.launch.t3_p50_sec)} / ${dash(q.launch.t3_p90_sec)} 秒` : "—",
        "启动到能点（中位 / 慢的 10%）"),
      stat(num(q.events_dropped), "手机上攒满丢掉的记录")),
    h("h3", {}, "失败原因"),
    table(["哪一类", "原因", "次数", "人数"], q.reasons.map((r) => h("tr", {},
      h("td", {}, REASON_EVENTS[r.event] || r.event), h("td", { class: "mono" }, r.reason || "—"),
      h("td", { class: "num" }, num(r.times)), h("td", { class: "num" }, num(r.players))))),
    h("h3", {}, "帧率（每 5 分钟报一次）"),
    table(["在哪", "人数", "中位帧率", "最差 10% 的帧率", "每分钟卡顿（一帧超过 50 毫秒）"], q.perf.map((p) => h("tr", {},
      h("td", {}, PERF_CONTEXT[p.ctx] || p.ctx), h("td", { class: "num" }, num(p.players)),
      h("td", { class: "num" }, dash(p.fps_p50)), h("td", { class: "num" }, dash(p.fps_p10)),
      h("td", { class: "num" }, dash(p.slow_per_min))))),
    h("h3", {}, "报错（按影响人数排，最多 30 种）"),
    h("p", { class: "hint" }, "同一次启动里同一种报错只报第一次。报错文字里的 IP、电脑路径、长串令牌已经在手机上抹掉。"),
    table(["类型", "位置", "内容", "次数", "人数", "版本", "最近"], q.errors.map((e) => h("tr", {},
      h("td", {}, e.kind), h("td", { class: "mono" }, e.where), h("td", { class: "muted" }, e.msg),
      h("td", { class: "num" }, num(e.times)), h("td", { class: "num" }, num(e.players)),
      h("td", { class: "num" }, dash(e.build)), h("td", {}, fmt(e.last_seen))))));
}

function tagsCard(tags) {
  return h("section", { class: "card" }, h("h2", {}, `内部账号（统计时排除，${tags.length} 个）`),
    h("p", { class: "hint" }, "在「玩家」页打开一个人，「运营数据」那一栏标。员工、测试、压测的号都要标，不然会混进日活和留存。点一行去他的玩家页。"),
    table(["好友码", "昵称", "类型", "备注", "谁标的", "什么时候"], tags.map((t) => h("tr", { class: "click", onclick: () => openPlayer(t.player_id) },
      h("td", { class: "mono" }, t.friend_code), h("td", {}, t.player_name), h("td", {}, TAG_KINDS[t.kind] || t.kind),
      h("td", { class: "muted" }, t.note || ""), h("td", {}, t.tagged_by), h("td", {}, fmt(t.tagged_at))))));
}

// ---------------------------------------------------------------------------
// 操作记录
// ---------------------------------------------------------------------------

const ACTIONS = {
  ban: "封号", unban: "解封", "mail.send": "发邮件", "mail.withdraw": "撤回邮件",
  "request.create": "提交发钱申请", "request.approve": "批准", "request.reject": "拒绝", "request.cancel": "撤回申请",
  "announcement.save": "保存公告", "announcement.image": "上传公告图",
  mute: "禁言", unmute: "解除禁言", "world.hide": "删世界频道消息",
  "report.resolved": "举报：已处理", "report.dismissed": "举报：不成立",
  "analytics.tag": "标为内部账号", "analytics.untag": "改回普通玩家",
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
