-- 030: 组队邀请（排位 / 休闲）也是一种私聊类型（bug提交及修复.docx 第 10 条，2026-10-07）
--
-- 配套实现：backend/app/routes/party.py 的 invite()、backend/app/chat.py 的
-- PARTY_INVITE_KIND 与 _check_party_invite_rules()。
-- 001–029 一个字都不改 —— 编号只增不改，见 database/README.md。
--
-- ## 为什么需要这个文件
--
-- 020 给 chat_messages.kind 加了一条 check 约束，只允许 'text' / 'room_invite'。
-- 那个文件自己写明了理由：「客户端不认识的新类型，只能靠**先发迁移、再加客户端**
-- 来引入，不会出现【服务端悄悄开始发一种老客户端渲染不了的 kind】」。
--
-- 第 10 条给组队邀请加了第三种 kind='party_invite'，**迁移漏了**。后果：
--
--   insert … kind='party_invite'  →  asyncpg CheckViolationError
--                                 →  不在 routes/party.py 的 except chat.ChatRejected 内
--                                 →  冒到接口层  →  HTTP 500
--
-- 真机表现（10-07，排位房间点「邀请好友」）：**「服务器出错了（HTTP 500），稍后再试」**。
-- 更坏的是 routes/party.py 里 `party.current().invite()` **已经先改完内存状态**了，
-- 于是邀请在服务端生效、房主看到报错、被邀请人因为下面那条 party_invite 推送
-- 还没发到而完全不知情 —— 看起来就是「排位拉不了好友」。
--
-- ★ 这个文件就是 020 预留的那次「放宽一条 check 约束」。按 database/README.md 的
--   代价表这是 🟢：改的是**取值集合**，不动列的含义、不动任何既有行。
--
-- ## 为什么是 drop + add，而且两条都带 if[not] exists
--
-- 本文件要人在 Supabase Dashboard → SQL Editor 里**手工跑一次**（见 README「怎么跑」）。
-- 手工跑就可能贴两遍。若写成「直接 add constraint」，第二遍会报
-- 「constraint "chat_message_kind_allowed" already exists」而整段中断。
-- 带上 `if exists` / `if not exists` 之后重复执行是安全的：先摘旧的再装新的，结果一致。
-- （020 当初是一条全新约束，没有这个问题，所以那边没有这套写法。）
--
-- ## 顺带补的部分索引
--
-- 去重键是 (队伍, 收件人)，判在数据库上（chat.py 的 _check_party_invite_rules）：
--   where kind='party_invite' and payload->>'party_id' = $2
--     and ((low_id=$3 and high_id=$4) or (low_id=$4 and high_id=$3))
-- 与 020 给 room_invite 补的两个部分索引同一个道理 —— 普通文本占绝大多数行，
-- 只索引邀请那几行就好。队伍号是 secrets.token_urlsafe(12) 生成的文本，直接比较，
-- 不存在 room_id 那种「整数写成文本」的前导零问题。

alter table chat_messages
  drop constraint if exists chat_message_kind_allowed;

alter table chat_messages
  add constraint chat_message_kind_allowed
    check (kind in ('text', 'room_invite', 'party_invite'));

comment on column chat_messages.kind is
  '消息类型：text=普通文本，room_invite=房间邀请（payload 带 room_id），party_invite=组队邀请（payload 带 party_id）。';

comment on column chat_messages.payload is
  '类型相关的机器可读数据。text 为 null；room_invite 为 {"room_id": <bigint>}；party_invite 为 {"party_id": <text>, "mode": "casual"|"ranked"}。';

create index if not exists chat_messages_by_party_invite_target
  on chat_messages (low_id, high_id, (payload ->> 'party_id'))
  where kind = 'party_invite';
