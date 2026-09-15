-- 008: 公告（docs/公告系统设计.md）
--
-- 001–007 一个字都不改 —— 编号只增不改，见 database/README.md。
-- 本文件只建一张新表，🟢（加新表零风险）。
--
-- ## 谁写这张表
--
-- **管理员在 Supabase 后台（Table Editor）直接改行**（2026-09-15 定：管理员只有两个人，
-- 本来就有 Supabase 权限；等有不碰代码的运营 / 客服了再做正式后台，写的还是这张表）。
-- 所以约束写得比别的表严：后台表格里填错不会有任何提示，只有约束能当场拒绝。
--
-- 账号服务器（backend/app/announcements.py）每 30 秒读一次，**只写 problem 一列** ——
-- 图片取不到、太大、预览好友码写错时把原因写在那里，管理员刷新表格就看得到。
--
-- ## 时间一律带时区写
--
-- 后台里填 `2026-09-20 20:00+08`，不要只写 `2026-09-20 20:00` ——
-- 不带时区会按 UTC 算，差出你们所在时区的小时数（UTC+8 就差 8 小时）。
-- 「现在该不该显示」按**服务器**的钟判断，不看玩家手机的钟。

create table announcements (
  announcement_id bigserial primary key,

  -- 页签：event 活动 / news 系统 / update 更新 / urgent 紧急。
  -- urgent 在变成可见的那一刻推给所有在线玩家（屏幕顶部横条，只推标题）。
  -- 与 backend/app/announcements.py 的 KINDS 一致（backend/tests/test_announcements.py 钉着）。
  kind          text not null default 'news',

  -- draft 草稿（只有 preview_codes 里的人看得到）/ published 已发布 / withdrawn 已撤下。
  -- **撤下不删**：删了就没有「发过什么」的记录了。
  status        text not null default 'draft',

  title_zh      text not null,
  body_zh       text not null default '',
  -- 英文空着时英文玩家看中文，不会看到空白。
  title_en      text not null default '',
  body_en       text not null default '',

  -- Storage 公开桶（默认叫 announcements）里的文件路径，例如 2026-09/summer.jpg。空 = 没图。
  -- 只许英文字母、数字、. _ - 和 /。**换图就传新文件名**，不要覆盖旧文件 ——
  -- 服务器每个路径只取一次，发现不了覆盖。
  image         text not null default '',

  -- 进主菜单时弹一次（与列表共用同一张图）。弹过哪条、哪个 revision 记在玩家手机上。
  popup         boolean not null default false,

  -- 越大越靠前；一样大的按开始时间新的在前。置顶就给一个大数。
  sort_order    integer not null default 0,

  starts_at     timestamptz not null default now(),
  -- 空 = 不自动下线。
  ends_at       timestamptz,

  -- 大改（改时间、改内容）时手动 +1：玩家会重新看到红点，要弹窗的会再弹一次。
  -- 改错别字不要加，否则全服重新弹一遍。
  revision      integer not null default 1,

  -- 草稿 / 还没到时间的公告先给哪些好友码看，逗号或空格分隔，例如 `AAAA2222, BBBB3333`。
  -- 这些人也会在游戏里看到 problem 的内容。
  preview_codes text not null default '',

  -- 服务器写回的问题说明。管理员不用填，填了也会被下一轮覆盖。
  problem       text not null default '',

  created_at    timestamptz not null default now(),

  constraint announcement_kind check (kind in ('event', 'news', 'update', 'urgent')),
  constraint announcement_status check (status in ('draft', 'published', 'withdrawn')),
  constraint announcement_title_zh check (char_length(btrim(title_zh)) between 1 and 60),
  constraint announcement_title_en check (char_length(title_en) <= 80),
  constraint announcement_body_zh check (char_length(body_zh) <= 4000),
  constraint announcement_body_en check (char_length(body_en) <= 8000),
  -- 与 backend/app/announcements.py 的 is_valid_image_path 同一条规则。
  constraint announcement_image_path check (
    image = ''
    or (char_length(image) <= 200
        and image ~ '^[A-Za-z0-9_.-]+(/[A-Za-z0-9_.-]+)*$'
        and image !~ '(^|/)\.\.?(/|$)')
  ),
  constraint announcement_window check (ends_at is null or ends_at > starts_at),
  constraint announcement_revision check (revision >= 1),
  constraint announcement_preview_codes check (char_length(preview_codes) <= 200)
);

alter table announcements enable row level security;

comment on table announcements is
  '公告。管理员在 Supabase 后台直接改；账号服务器每 30 秒读一次，只写 problem 列。撤下不删。';
comment on column announcements.revision is
  '大改时手动 +1，玩家重新看到红点与弹窗。改错别字不要加。';
comment on column announcements.problem is
  '服务器写回的问题（图片取不到、太大、预览好友码写错）。不用填，填了会被覆盖。';
