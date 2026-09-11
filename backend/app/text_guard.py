"""玩家可见文本（昵称、签名）的校验。

**这不是「敏感词系统」，不要这么叫它。** 能真正扛住的中文过滤要处理谐音、拆字、
同形字、插入符号，那是独立项目或者接第三方（阿里云 / 腾讯云内容安全）。
这里做的是三层里性价比最高的那部分：

    ① 结构管控   零宽字符、控制字符、双向覆写、Zalgo、空白规范、长度
    ② 引流模式   URL、微信/QQ/Telegram、长数字串（**只对签名**）
    ③ 词表       可外挂文件，补词不用改代码

上线时诚实的说法是「有基础管控 + 举报后处理」，见 docs/玩家资料系统设计.md 第六节。

为什么 ② 只对签名：昵称 24 字、签名 60 字且更自由。手游签名栏里 90% 的违规
内容是**代练与外挂引流**（「加V:xxx」「Q群 12345」），不是脏话 —— 一份词表
覆盖不了两种滥用，所以分开处理。
"""

from __future__ import annotations

import os
import pathlib
import re
import unicodedata

# 与 database/001_players.sql 的 player_name_length、
# database/004_profile_display.sql 的 signature_length 必须一致。
# 数据库那层是最后一道，这里是第一道；两边对不上会表现为「前端说可以、后端 500」。
NAME_MIN, NAME_MAX = 1, 24
SIGNATURE_MAX = 60

# 私聊单条上限。与 database/007_chat.sql 的 chat_body_length、
# 客户端 ChatService.MAX_BODY_CHARS 必须一致（tools/chat_check.gd 钉着）。
CHAT_MAX = 200

_REPO_ROOT = pathlib.Path(__file__).resolve().parents[2]
_BLOCKLIST_PATH = pathlib.Path(
    os.environ.get("GLORY_BLOCKLIST_PATH", _REPO_ROOT / "data" / "blocked_words.txt")
)


class TextRejected(ValueError):
    """校验不通过。

    code 是**稳定的机器标识**，给日志、门禁与客户端分支用；
    message 是给玩家看的中文。两者分开的理由同 AccountManager.Failure：
    改一句提示文案不该让日志里的历史记录对不上。
    """

    def __init__(self, code: str, message: str) -> None:
        super().__init__(message)
        self.code = code
        self.message = message


# --- ① 结构管控 ---------------------------------------------------------------

# 零宽与不可见字符。它们能做到：昵称看起来和别人一模一样（冒充）、
# 用空串绕过「非空」检查、把一个 24 字的名字撑成几百字节。
# ⚠️ **本文件的字符集一律用码位数字构造，源码里绝不出现字面量。**
#
# 这几行的全部作用就是「挡住看不见的字符」。把它们写成字面量，
# 代码本身就变成了没人能审查的东西 —— 打开文件只看到一段空白。
def _char_class(*ranges: tuple[int, int], prefix: str = "") -> str:
    body = "".join(
        chr(lo) if lo == hi else "%s-%s" % (chr(lo), chr(hi)) for lo, hi in ranges
    )
    return "[" + prefix + body + "]"


# 零宽与不可见字符。它们能做到：昵称看起来和别人一模一样（冒充）、
# 用空串绕过「非空」检查、把一个 24 字的名字撑成几百字节。
_INVISIBLE = re.compile(
    _char_class(
        (0x200B, 0x200F),  # 零宽空格 / 非连接符 / 连接符 + LRM / RLM
        (0x2060, 0x2064),  # word joiner 与不可见运算符
        (0xFEFF, 0xFEFF),  # BOM 被当成普通字符插进来
        (0x00AD, 0x00AD),  # 软连字符
        (0x180E, 0x180E),  # 蒙文元音分隔符，历史上被当零宽用
    )
)

# 双向文本覆写。用它可以让 "gnitaehc" 显示成 "cheating"，
# 也可以让一个名字在列表里盖到隔壁行。昵称与签名里没有任何正当用途。
_BIDI = re.compile(
    _char_class(
        (0x202A, 0x202E),  # LRE / RLE / PDF / LRO / RLO
        (0x2066, 0x2069),  # LRI / RLI / FSI / PDI
    )
)

# 连续组合符（Zalgo）。正常文字最多叠两个（例如越南语），三个以上是在糊屏幕。
_ZALGO = re.compile(
    _char_class(
        (0x0300, 0x036F),  # 组合用变音符号
        (0x1AB0, 0x1AFF),  # 组合用变音符号扩展
        (0x20D0, 0x20F0),  # 组合用符号记号
    )
    + "{3,}"
)

# 空白规范化：把「看着像空格但不是空格」的字符换成普通空格，并把连续空白压成一个。
#
# 制表与换行**不在这里处理** —— 它们是 Cc，在上面那轮分类检查里就被拒了。
# 昵称里出现换行只有一种可能：有人在试着破坏列表排版。
_WEIRD_SPACE = re.compile(
    _char_class(
        (0x00A0, 0x00A0),  # 不换行空格
        (0x1680, 0x1680),  # 欧甘文空格
        (0x2000, 0x200A),  # 各种排版空格
        (0x202F, 0x202F),  # 窄不换行空格
        (0x205F, 0x205F),  # 中数学空格
        (0x3000, 0x3000),  # 全角空格
        prefix=r"\s",
    )
    + "+"
)


def _structural_check(raw: str, field: str) -> str:
    if _INVISIBLE.search(raw):
        raise TextRejected("invisible_char", "不能包含不可见字符")
    if _BIDI.search(raw):
        raise TextRejected("bidi_override", "不能包含改变文字方向的控制符")
    if _ZALGO.search(raw):
        raise TextRejected("zalgo", "不能包含连续的组合符号")

    # NFC 规范化。同一个字有多种编码写法，不统一的话「重名检测」「词表匹配」
    # 都能被绕过。放在不可见字符检查**之后** —— 先拒掉，再规范化。
    text = unicodedata.normalize("NFC", raw)

    for ch in text:
        # Cc = 控制字符，Cs = 代理项，Cn = 未分配码位。
        # Cf（格式字符）里的零宽已经在上面拒了，剩下的也没有正当用途。
        if unicodedata.category(ch) in {"Cc", "Cs", "Cn", "Cf"}:
            raise TextRejected("control_char", "不能包含控制字符")

    text = _WEIRD_SPACE.sub(" ", text).strip()
    if not text:
        raise TextRejected("empty", "%s不能为空" % field)
    return text


# --- ② 引流模式（只对签名）----------------------------------------------------

_CONTACT_PATTERNS: tuple[tuple[str, re.Pattern[str]], ...] = (
    ("url", re.compile(r"(https?://|www\.|\.com|\.cn|\.net|\.io|\.xyz)", re.I)),
    # 「加V」「+v」「wx」「vx」「微信」后面跟内容的形态。单独一个「微信」不拦，
    # 拦的是「微信 xxx」这种给号的写法。
    ("wechat", re.compile(r"(微信|加\s*[vV]|[wWvV][xX])\s*[:：]?\s*\S", re.I)),
    ("qq", re.compile(r"([qQ]{2}|扣扣|企鹅)\s*(群)?\s*[:：]?\s*\d{5,}")),
    ("telegram", re.compile(r"(telegram|电报|飞机|@[A-Za-z0-9_]{5,32}\b)", re.I)),
    # 9 位以上连续数字：手机号、QQ 号、群号的共同形态。
    ("long_number", re.compile(r"\d{9,}")),
)


def _contact_check(text: str) -> None:
    for code, pattern in _CONTACT_PATTERNS:
        if pattern.search(text):
            raise TextRejected("contact_%s" % code, "签名里不能留联系方式或外链")


# --- ③ 词表 -------------------------------------------------------------------

_blocklist_cache: tuple[float, frozenset[str]] | None = None


def _load_blocklist() -> frozenset[str]:
    """读外挂词表。文件不存在就是空表 —— **不报错**。

    词表是运营会频繁补的东西，不该因为忘了建文件就让整个接口 500。
    按 mtime 缓存，改了文件不用重启进程。
    """
    global _blocklist_cache
    try:
        mtime = _BLOCKLIST_PATH.stat().st_mtime
    except OSError:
        _blocklist_cache = None
        return frozenset()

    if _blocklist_cache is not None and _blocklist_cache[0] == mtime:
        return _blocklist_cache[1]

    words: set[str] = set()
    for line in _BLOCKLIST_PATH.read_text(encoding="utf-8").splitlines():
        word = line.strip()
        if word and not word.startswith("#"):
            words.add(unicodedata.normalize("NFC", word).casefold())
    _blocklist_cache = (mtime, frozenset(words))
    return _blocklist_cache[1]


def _blocklist_check(text: str) -> None:
    folded = text.casefold()
    for word in _load_blocklist():
        if word in folded:
            # **不回显命中的词**：一是没必要教人怎么绕，二是错误串会被
            # IssueReport 收走并贴进聊天窗口。
            raise TextRejected("blocked_word", "包含不允许的内容")


# --- 对外的两个入口 -----------------------------------------------------------


def clean_player_name(raw: str) -> str:
    """校验并规范化昵称。不通过就抛 TextRejected。"""
    text = _structural_check(raw, "昵称")
    if len(text) < NAME_MIN or len(text) > NAME_MAX:
        raise TextRejected("length", "昵称需要 %d-%d 个字" % (NAME_MIN, NAME_MAX))
    _blocklist_check(text)
    return text


def clean_signature(raw: str) -> str | None:
    """校验并规范化签名。空字符串返回 None —— **清空即删除**。

    签名刻意没有可见性开关：它是表达，不存在「写了但不给你看」。
    见 docs/玩家资料系统设计.md 第三节。
    """
    if raw is None:
        return None
    if not raw.strip():
        return None
    text = _structural_check(raw, "签名")
    if len(text) > SIGNATURE_MAX:
        raise TextRejected("length", "签名最多 %d 个字" % SIGNATURE_MAX)
    _contact_check(text)
    _blocklist_check(text)
    return text


# --- 私聊（docs/聊天系统设计.md 批次 C）--------------------------------------

# 零宽连接符（ZWJ）。它是组合 emoji 的胶水：一个「一家三口」其实是三个人形 + 两个 ZWJ。
_ZWJ = chr(0x200D)


def clean_chat_message(raw: str) -> str:
    """校验并规范化一条私聊消息。不通过就抛 TextRejected。

    与昵称、签名有三处**刻意**不同（设计文档第四节）：

      1. **不查引流**（② 那层）。已定：私聊是点对点、对方已经同意加好友，
         交换联系方式是正常社交行为。记录但不拦，靠举报后处理。
      2. **不套词表**（③ 那层）。data/blocked_words.txt 是给昵称与签名写的；
         聊天是高频海量的对话，同一份表会同时漏（谐音拆字随便过）和误杀
         （正常对话被拦，玩家不知道为什么）。聊天的内容审核归外部 provider，
         私聊在那一层是 fail-open。
      3. **换行压成空格、ZWJ 直接去掉，而不是整条拒绝。** 昵称里出现这些只可能是
         在搞破坏；聊天里多半是粘贴了一段多行文字，或者输入法发来的组合 emoji。
         整条拒掉只会让玩家对着「不能包含不可见字符」发呆。
         去掉 ZWJ 的代价是组合 emoji 退化成几个单独的 emoji —— 意思还在。

    结构层（零宽 / 双向覆写 / Zalgo / 控制字符）照旧全开：那是防显示破坏，
    与内容无关，聊天里同样有人会拿 Zalgo 糊屏幕。
    """
    if raw is None:
        raise TextRejected("empty", "消息不能为空")
    text = raw.replace("\r\n", " ").replace("\r", " ").replace("\n", " ").replace("\t", " ")
    text = text.replace(_ZWJ, "")
    text = _structural_check(text, "消息")
    if len(text) > CHAT_MAX:
        raise TextRejected("length", "消息最多 %d 个字" % CHAT_MAX)
    return text
