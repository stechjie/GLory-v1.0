-- 020: 房间邀请好友（bug提交和修复.docx 第 2 条，2026-09-27）
--
-- 配套设计文档：docs/交友系统设计.md（好友关系、presence）、
-- docs/聊天系统设计.md（私聊走 ② 的 HTTPS 发送 + WebSocket 推送）。
-- 001–019 一个字都不改 —— 编号只增不改，见 database/README.md。
--
-- ## 为什么邀请是「一条带类型的私聊」，而不是新表 + 新推送
--
-- 要求是「被邀请人会在聊天功能朋友消息里收到朋友邀请，有新消息的音效提示，和红点提示」。
-- 做成 kind='room_invite' 的私聊，这三件事全部复用 007 已经验过的那条链路：
-- 发送走 HTTPS、推送走 ② WebSocket 的 dm 分支、红点与音效在客户端 ChatService。
-- 新开一张表 + 一套推送，等于把红点、音效、未读、断线补拉全部再实现一遍，
-- 而每一处漏掉都表现为「有时收不到」这种最难复现的 bug。
--
-- ## 代价表（database/README.md）
--
-- 给 chat_messages **加两列**是 🟢（加列、带默认值、不改既有列的含义）。
-- kind 用文本枚举而不是 bool：现在只有两态，但放宽一条 check 约束是 🟢，
-- 而 bool → enum 是 🔴 的「改一列的含义」。多写几个字换掉一次数据迁移
-- （同 005 的 presence_visibility、004 的显示名）。
--
-- ## 有效期判定为什么**不在**这里
--
-- 要求 5 的四个失效条件（离房 / 房间解散 / 对局已开始 / 过去 20 分钟）里有三个
-- 是**当下的房间状态**，不是消息的属性 —— 存一个 expires_at 只能覆盖「20 分钟」那一条，
-- 另外三条要靠 ENet 的实时状态。所以有效期一律**在加入那一刻由客户端判**
-- （scripts/multiplayer/RoomInvite.gd 的 is_expired，判据只有那一份）。
-- 服务端只**记**这条邀请是什么时候发的，不替它过期。
--
-- ⚠️ 邀请消息会占「每对好友 200 条」的名额（chat.py 的 KEEP_PER_CONVERSATION）——
-- 这是刻意的：它就是一条消息，玩家能看见、能举报，没有理由不占名额。


-- ============================================================================
-- chat_messages：加 kind 与 payload
-- ============================================================================

alter table chat_messages
  add column kind text not null default 'text';

alter table chat_messages
  add column payload jsonb;

-- 只允许这两态。加上这条之后，「客户端不认识的新类型」只能靠**先发迁移再加客户端**
-- 来引入，不会出现「服务端悄悄开始发一种老客户端渲染不了的 kind」。
alter table chat_messages
  add constraint chat_message_kind_allowed check (kind in ('text', 'room_invite'));

comment on column chat_messages.kind is
  '消息类型：text=普通文本，room_invite=房间邀请（payload 里带 room_id）。';
comment on column chat_messages.payload is
  '类型相关的机器可读数据。text 为 null；room_invite 为 {"room_id": <bigint>}。';

-- 去重与限流都要按「谁在什么时候发过邀请」扫，且只扫邀请。
-- 部分索引：普通文本占了绝大多数行，没必要进这个索引。
create index chat_messages_by_room_invite
  on chat_messages (sender_id, created_at desc)
  where kind = 'room_invite';

-- 去重键：同一邀请人 + 同一房间 + 同一位好友。
-- payload->>'room_id' 是文本比较；room_id 由服务端从整数写成，不存在前导零之类的问题。
create index chat_messages_by_room_invite_target
  on chat_messages (sender_id, high_id, low_id, (payload ->> 'room_id'))
  where kind = 'room_invite';
