-- 004: 玩家资料的展示字段
--
-- 配套设计文档：docs/玩家资料系统设计.md（每一条「为什么」都在那里）。
-- 001 / 002 / 003 一个字都不改 —— 编号只增不改，见 database/README.md。
--
-- 本文件分三段，**顺序不能换**：
--   ① 加列（可空 / 带默认）          🟢 瞬时完成，不锁表
--   ② 回填 friend_code               ← 给已存在的行补值
--   ③ 加 not null + unique 约束      🟡 必须在 ② 之后
--
-- ② 就是 database/README.md 代价表里那行「给已有列加 not null 要先回填老数据」。
-- 现在做成本约等于零（players 表基本是空的）；等有几万玩家再做，
-- 就要写迁移脚本、处理生成冲突、分批执行避免锁表。所以现在是对的时机。


-- ============================================================================
-- 好友码的生成函数
-- ============================================================================
--
-- 为什么要好友码，而不是用 player_id 前 4 位：
--
-- 001 里定的「同名玩家靠 player_id 前 4 位区分，例如 Leno #52c7」是**显示区分符**
-- —— 用于「同一个列表里几个同名的人」。它撑不起全局搜索：
-- 默认名是 'Player'，匿名登录意味着绝大多数玩家都叫 Player，
-- 而四位 hex 只有 65536 种 —— 按生日悖论，同名玩家到 **300 人左右**
-- 就有 50% 概率撞短 ID。
--
-- 显示区分符要的是「局部可分辨、好念」，查找键要的是「全局唯一」，
-- 两者要求不同，所以是两个东西。
--
-- 字母表排掉 0 O 1 I L：它是给玩家互相抄的，这几个字符抄错率最高。
-- 31 个字符 ^ 8 位 ≈ 8.5 x 10^11 种。
create or replace function glory_new_friend_code() returns text
language plpgsql
volatile
as $$
declare
  alphabet constant text := '23456789ABCDEFGHJKMNPQRSTUVWXYZ';
  n        constant int  := 31;
  -- 刻意**不用 random()**。它是每会话播种的普通 PRNG，观察到若干个码之后
  -- 可以预测后续 —— 好友码是公开的查找键，不是秘密，但也不该可枚举。
  -- gen_random_uuid() 是 PostgreSQL 13+ 内置的密码学随机，不需要装扩展。
  raw      bytea := decode(replace(gen_random_uuid()::text, '-', ''), 'hex');
  out_code text := '';
  i        int;
begin
  for i in 0..7 loop
    -- 256 mod 31 = 8，所以前 8 个字符出现概率略高。对一个**非秘密**的查找键
    -- 这点偏置无关紧要；真要消掉得做拒绝采样，不值得。
    out_code := out_code || substr(alphabet, 1 + (get_byte(raw, i) % n), 1);
  end loop;
  return out_code;
end;
$$;

comment on function glory_new_friend_code() is
  '生成 8 位好友码。字母表排掉易混字符；随机源是 gen_random_uuid，不是 random()。';


-- ============================================================================
-- ① 加列
-- ============================================================================

-- 头像放 players 而不是 player_bio：002 的分表理由是「players 每个请求都读，
-- bio 一个月读一次」。头像和昵称是同一个访问模式 —— 名牌、房间列表、战绩页
-- 都要 —— 所以它属于热表。
--
-- **一列而不是两列**（不做 preset_avatar + avatar_url）：两列会出现
-- 「都有值时听谁的」，这类分歧不会报错，只会让两台设备显示不同头像。
-- 带 scheme 前缀的单列以后接自定义上传时只是放宽正则 —— 🟢。
alter table players add column avatar text not null default 'preset:avatar_001';

-- 头像框。UI 这一版只有默认框，列先建好 —— 全部同类游戏都有它，
-- 而且它是最便宜的奖励载体（一张图、零逻辑）。现在加列 10 分钟，以后加要写迁移。
alter table players add column avatar_frame text not null default 'preset:frame_default';

alter table players add column friend_code text;

-- 改名冷却判在这里，**不能用 backend/app/rate_limit.py** ——
-- 那是进程内滑动窗口，重启即清零、多 worker 各算各的。
-- null = 从没改过名（首次改名免费，因为默认名 'Player' 谁都要改一次）。
alter table players add column name_changed_at timestamptz;

-- 资料页上的展示宠物。**纯展示、客户端自报、服务端不校验拥有权。**
-- 伪造的代价只是「显示了一只自己没有的宠物」，不构成任何权益。
-- 绝不可以被当成拥有权依据 —— 真正的拥有权要等进度同步项目（RFC 9.5）。
--
-- ⚠️ 这一列继承了 database/README.md「内容 id 会改名」那条义务：
-- SaveSchema.PET_ID_RENAMES 以后再改宠物 id，这里要跟着写一个新编号迁移。
alter table players add column showcase_pet text;

alter table players
  add constraint avatar_format
    check (avatar ~ '^(preset|upload):[A-Za-z0-9_-]{1,64}$'),
  add constraint avatar_frame_format
    check (avatar_frame ~ '^(preset|upload):[A-Za-z0-9_-]{1,64}$'),
  -- 同 001 的昵称：任何来自客户端的字符串都要有上限（A12）。
  add constraint showcase_pet_format
    check (showcase_pet is null or showcase_pet ~ '^[a-z0-9_]{1,64}$');

comment on column players.avatar is
  '头像。scheme 前缀区分来源：preset:<清单 id> / upload:<对象存储 key>。id 与单位 id 刻意脱钩，见 data/avatars.json。';
comment on column players.friend_code is
  '玩家可见的全局唯一查找键。与「player_id 前 4 位」那个显示区分符是两回事，见本文件顶部。';
comment on column players.showcase_pet is
  '展示用出战宠物。客户端自报，服务端不校验拥有权，绝不可作为拥有权依据。';


-- 签名进 player_bio 而不是 players：它是自愿填写的展示资料，和性别生日同类，
-- 而且玩家要求删除个人资料时删这一行即可（002 的分表理由之一）。
alter table player_bio add column signature text;

-- 可见性用**文本枚举而不是 bool**。现在只有 public / private 两态，bool 更省事；
-- 但等有了好友系统要加 'friends'，bool -> enum 是 README 代价表里 🔴 的
-- 「改一列的含义」，而放宽一条 check 约束是 🟢。多写四个字换掉一次数据迁移。
--
-- 默认 public：玩家填这些字段本来就是为了给人看。不想给看的走「不显示」，
-- 那正是这三列存在的意义 —— 它们**就是**删除功能，所以不另做「清空资料」。
alter table player_bio add column gender_visibility text not null default 'public';
alter table player_bio add column birth_visibility  text not null default 'public';
alter table player_bio add column region_visibility text not null default 'public';

alter table player_bio
  add constraint signature_length
    check (signature is null or char_length(signature) between 1 and 60),
  add constraint gender_visibility_allowed
    check (gender_visibility in ('public', 'private')),
  add constraint birth_visibility_allowed
    check (birth_visibility in ('public', 'private')),
  add constraint region_visibility_allowed
    check (region_visibility in ('public', 'private'));

comment on column player_bio.signature is
  '个性签名。**刻意不给可见性开关** —— 签名是表达，不存在「写了但不给你看」；清空文字就是不显示。性别/生日/地区是事实，「填了但不公开」是真实需求，所以那三个有开关。';
comment on column player_bio.birth_visibility is
  '生日的可见性。必须是独立开关，不能做成生日字段的一个值 —— 生日只能设置一次，把「不显示」做成值会让玩家用掉唯一一次机会，此后再也填不了真生日。';


-- ============================================================================
-- ② 回填 friend_code
-- ============================================================================
--
-- 逐行生成 + 查重。行数多时很慢，但这正是「现在做」的理由：
-- 表基本是空的，跑完不到一秒。
do $$
declare
  r         record;
  candidate text;
  tries     int;
begin
  for r in select player_id from players where friend_code is null loop
    tries := 0;
    loop
      candidate := glory_new_friend_code();
      exit when not exists (select 1 from players where friend_code = candidate);
      tries := tries + 1;
      if tries > 100 then
        -- 连撞 100 次不可能是运气问题，一定是生成函数坏了（例如字母表被改空）。
        -- 宁可整个迁移失败，也不要悄悄留下一批没有码的玩家。
        raise exception '好友码连续冲突 100 次，检查 glory_new_friend_code()';
      end if;
    end loop;
    update players set friend_code = candidate where player_id = r.player_id;
  end loop;
end;
$$;


-- ============================================================================
-- ③ 加约束（必须在 ② 之后）
-- ============================================================================

alter table players
  alter column friend_code set default glory_new_friend_code(),
  alter column friend_code set not null,
  -- 与 glory_new_friend_code() 的字母表逐字对应：2-9 A-H J K M N P-Z，共 31 个。
  -- 注意 **不能写成 [J-N]** —— 那会放进 L，而 L 正是被排掉的易混字符之一。
  add constraint friend_code_format check (friend_code ~ '^[2-9A-HJKMNP-Z]{8}$'),
  add constraint friend_code_unique unique (friend_code);

-- 查询方向：拿着好友码问「这是谁」。unique 约束已经建了索引，不再另建。
--
-- 公开视图刻意用好友码定位（GET /v1/players/by-code/{code}）而不是 player_id ——
-- player_id 是内部身份，没必要出现在客户端可见的地址里。
