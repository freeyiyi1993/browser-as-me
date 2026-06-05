# browser-as-me

> **让 AI agent（Claude Code / 任意 Playwright 脚本）复用你已经登录好的 Chrome session，不需要复制 cookie、不需要重新过 SSO / 2FA。** 由一个 launchd 常驻的独立 Chrome 实例 + Chrome DevTools Protocol (CDP) 实现。

[English below ↓](#english)

---

## 这是什么

启动一个**第二个**专用 Chrome 实例（独立 profile，和你日常 Chrome 完全隔离），通过 `--remote-debugging-port=9222` 暴露 CDP；由 macOS launchd 拉起并 `KeepAlive`。

**第一次访问某个网站时，你像人一样手动登录一次**（输密码、过 2FA、点 SSO 设备信任）。之后这个 session 永久驻留在这个独立 Chrome 里。从此 Claude / Playwright 脚本通过 `connect_over_cdp("http://localhost:9222")` 接管 → 操作浏览器、读 DOM、截图、嗅探 XHR、dump cookie，**全程不再向你索取任何凭据**。

一句话场景：你跟 Claude 说"把那个飞书 doc 的内容拿出来贴到我剪贴板"。Claude 写 10 行 Playwright 脚本对准本地 9222，因为飞书的 session 已经在 CDP Chrome 里，秒拿。

---

## 原理：为什么是这套设计

### 1. Chrome 2024 mid 的安全补丁

历史上你可以直接给日常 Chrome 加 `--remote-debugging-port` 就能拿到 CDP。**但 Chrome 团队在 2024 年中加了一个安全策略**：当 `--user-data-dir` 等于默认 profile 路径时，CDP 直接被禁用（realpath 比较，软链接也绕不过）。

**为什么禁**：恶意软件如果能给你正在跑的 Chrome 后台开一个 CDP，就能静默 dump 全部 cookie、读你登录过的所有网站。这是 [CVE 级别的攻击面](https://www.google.com/search?q=chromium+remote-debugging-port+default+profile+blocked+security)。Google 选择直接堵死，不留例外。

### 2. 绕开的唯一合法路径：独立 profile

既然默认 profile 不让，**那就用一个不是默认的 profile**：`--user-data-dir=~/.chrome-cdp-profile`。这个 profile 完全独立——和你日常 Chrome 不共享 cookie / 历史 / 扩展 / 书签。

代价：每个站第一次需要在这个独立 Chrome 里登录。但因为可以**登同一个 Google 账号开同步**（密码 / 书签 / 扩展一键拉下来），实际上只需要点"登录"按钮 + 过 2FA，不是重新敲密码。如果不想开同步，也可以直接把日常 Chrome 的 `Cookies` 文件拷到 `~/.chrome-cdp-profile/Default/` 做一次性批量迁移（两个 profile 在同一台 Mac 上，解密用的是同一把 Keychain key，能直接读）。收益：一旦登好，那个 session 长期驻留，AI 操作时不再问你要凭据。

### 3. 用 launchd 让它常驻（可选）

Chrome 进程崩了 / 你 Cmd+Q 了 / 你重启 Mac 了——这些情况下你不希望 session 消失。launchd 的 `KeepAlive=true` 让这个 Chrome 进程死了自动复活；`RunAtLoad=true` 让登录就拉起。从你的视角，它就是"一直在那"。

**不用 launchd 也完全能跑。**手动启动效果一样，session 复用 / profile 隔离 / CDP 这些核心能力一个不少：

```bash
/Applications/Google\ Chrome.app/Contents/MacOS/Google\ Chrome \
  --remote-debugging-port=9222 \
  --user-data-dir=$HOME/.chrome-cdp-profile \
  --no-first-run \
  --no-default-browser-check &
```

launchd 只省掉"重启后记得手动跑"和"不小心 Cmd+Q 了自己复活"这两个事。如果你已经有其他进程管理习惯（`crontab @reboot`、Hammerspoon 等），完全不需要 launchd。README 把它当默认只是因为 macOS 自带、零依赖。

### 4. context / page 复用

Playwright `connect_over_cdp` 拿到的 `browser` 对象里，`browser.contexts[0]` 就是这个独立 Chrome 的会话上下文（含所有 cookie / localStorage）。`ctx.new_page()` 在里面开新 tab，跑完任务 `page.close()` —— **永远不要 `browser.close()` / `ctx.close()`**，那会杀掉 Chrome 进程 / 销毁 context，长期养出来的 session 就没了。

---

## 同类方案对比

| 方案 | 痛点 | browser-as-me 怎么解 |
|---|---|---|
| **Playwright `codegen` 录脚本** | 录的是「点击 + 输入」回放，不是 session。SSO / 2FA / 设备指纹一变，脚本第二次跑就挂 | 复用真实 session，不录脚本 |
| **复制 cookie 到 headless Chrome** | CSRF token / fingerprint / IP 一致性检查越来越严，复制完几小时就失效；多账号切换噩梦 | 在原始 Chrome 进程里持有 session，不脱离 |
| **Selenium / Puppeteer + 临时 profile** | 每次启动都是新 profile，session 为零，自动登录又过不了 2FA | profile 持久化 + 你手动登录一次 |
| **Chrome 扩展** | 扩展只能在浏览器内跑 JS，没法被 AI agent 反向驱动（除非自己写 native messaging） | CDP 是浏览器外部协议，任何语言都能驱动 |
| **自动登录脚本（自动填用户名密码）** | 2FA / OTP / 短信验证码 / 设备信任 99% 过不去；密码存哪都不安全 | 不做自动登录，让你 1 次人工登录覆盖永久 |
| **`puppeteer-extra-plugin-stealth` 等反检测库** | 治标不治本，不解决"session 哪来"的问题 | 直接用真实人类登录的 session，从根上没有"机器人嫌疑" |
| **共享浏览器服务（如 Browserless / Browserbase）** | session 跑在云端不在你本地，公司 SSO 走不通；隐私顾虑 | 100% 本地，cookie 不离开你的 Mac |

**核心差异化**：本项目不解决"如何登录"，只解决"如何**复用**已经登录的 session"。把"登录"这个最难自动化、最容易出岔子的环节交给人，把"登录之后的重复操作"交给 AI agent。

---

## 安装

前置：macOS（launchd 仅 macOS）+ Python 3.9+ + 已装 Google Chrome。

```bash
git clone https://github.com/freeyiyi1993/browser-as-me.git
cd browser-as-me

# 1. Python 依赖
pip install playwright
python -m playwright install chromium   # 可选——CDP 复用系统已装的 Chrome

# 2. 装 LaunchAgent（先把 REPLACE_HOME 替换成你的 $HOME 绝对路径）
sed "s|REPLACE_HOME|$HOME|g" launchagent/com.local.chrome-cdp.plist \
  > ~/Library/LaunchAgents/com.local.chrome-cdp.plist
launchctl bootstrap gui/$(id -u) ~/Library/LaunchAgents/com.local.chrome-cdp.plist

# 3. 验证
curl -s http://localhost:9222/json/version | head -1
# 应该返回 {"Browser": "Chrome/...", ...}

# 4. 在刚弹出来的新 Chrome 窗口里，登录你想让 AI 之后操作的站点。
#    这是一个独立 profile, 不会影响你日常 Chrome。
```

---

## 使用

### 方式 1: 命令行 CLI（高频一次性操作）

```bash
./scripts/cdp list-tabs                          # 列当前所有 tabs
./scripts/cdp open https://example.com           # 新开一个 tab
./scripts/cdp screenshot https://example.com /tmp/x.png
./scripts/cdp cookie example.com                 # dump 该域所有 cookie
./scripts/cdp exec https://example.com 'document.title'
```

### 方式 2: 在你自己的 Python 脚本里

```python
from playwright.sync_api import sync_playwright

with sync_playwright() as pw:
    browser = pw.chromium.connect_over_cdp("http://localhost:9222")
    ctx = browser.contexts[0]            # 复用已登录的 session
    page = ctx.new_page()
    try:
        page.goto("https://your-saas.example.com/dashboard")
        print(page.inner_text(".some-data"))
    finally:
        page.close()                     # 关 tab, 千万别关 browser
```

**铁律**：永远不要 `browser.close()` 或 `ctx.close()`——那会杀掉 launchd 拉起的 Chrome，长期累积的 session 全没。

### 方式 3: 作为 Claude Code skill

把这个目录放到 `~/.claude/skills/browser-as-me/`。`SKILL.md` 的 frontmatter 已经声明了触发短语（"用我的浏览器"、"use my logged-in browser" 等）。完整的 agent 契约见 [SKILL.md](./SKILL.md)。

### 更多 Playwright 配方

`references/recipes.md` 含 9 个开箱即用片段：连接 + cookie dump、XHR 拦截拿原始 JSON、操作已存在的 tab、SSO 跳转处理、async 版本等。

---

## 项目结构

```
browser-as-me/
├── SKILL.md                 # Claude Code skill 契约（触发条件、执行流程）
├── README.md                # 本文件
├── LICENSE                  # MIT
├── launchagent/
│   └── com.local.chrome-cdp.plist   # launchd plist 模板（装之前替换 REPLACE_HOME）
├── scripts/
│   ├── ensure_chrome.sh     # 幂等的「CDP 通吗?不通就重启」探针
│   └── cdp                  # 小型 Python CLI, 覆盖高频单点操作
└── references/
    └── recipes.md           # 可复制粘贴的 Playwright 片段
```

---

## 故障处理

| 症状 | 排查 |
|---|---|
| `ECONNREFUSED 127.0.0.1:9222` | `./scripts/ensure_chrome.sh`；仍不行看 `/tmp/chrome-cdp.err.log` |
| Cmd+Q 关了 Chrome 又自己起来 | 这是 `KeepAlive=true` 的预期行为。要彻底关：`launchctl bootout gui/$(id -u) ~/Library/LaunchAgents/com.local.chrome-cdp.plist` |
| CDP Chrome 抢前台焦点烦人 | 把它的窗口拖到独立 macOS Space，从此互不打扰；代码层永远不要写 `page.bring_to_front()` |
| 某站登录态过期 | 在 CDP Chrome 那个窗口里重登一次即可 |
| dock 里看到两个 Chrome 图标 | 这是预期：日常 Chrome + CDP Chrome 是两个独立实例 |

---

## 局限

- **仅 macOS** 的 launchd 集成。Playwright / CDP 部分本身跨平台——Linux / Windows 可以自己用同样的 flag 拉 Chrome。
- **不做自动登录**：本项目复用 session，不创建 session。登录步骤交给人，1 次到位。
- **`bring_to_front()` 是反模式**：99% 的 DOM 操作（fill / click / screenshot / evaluate）不需要前台，背景 tab 一样跑。仅在需要合成键盘事件 (`keyboard.press`) 时焦点才重要，且优先用元素级 `locator.press("Escape")` 而非窗口级 `bring_to_front`。

---

## License

MIT — 见 [LICENSE](./LICENSE)。

---

## Acknowledgements

- [Chrome DevTools Protocol](https://chromedevtools.github.io/devtools-protocol/) — 底层协议
- [Playwright](https://playwright.dev/python/) — 示例使用的客户端库

---

<a name="english"></a>

## English

**TL;DR**: Reuse your already-logged-in Chrome session from any Playwright / CDP client without copy-pasting cookies. A dedicated, isolated Chrome instance kept alive by macOS launchd holds your sessions; you log in **once** like a human, your AI agents reuse them indefinitely.

### Why this exists

Chrome blocks `--remote-debugging-port` on the default profile (security patch against cookie-exfiltrating malware). Most tutorials work around this by launching a fresh headless Chrome with copied-in cookies — which dies the moment SSO / 2FA / device fingerprinting kicks in. This skill takes the other path: a **persistent** second Chrome (isolated profile), you log in like a human once, then your AI agent reuses the session forever.

### Differentiation

- vs **Playwright codegen**: records clicks, not sessions — breaks on SSO refresh
- vs **copy cookies into headless**: dies within hours under modern anti-fraud
- vs **Selenium with temp profile**: no persistent session at all
- vs **Chrome extensions**: extensions can't be driven from an external AI agent
- vs **Browserless / Browserbase cloud**: not local — corp SSO won't work, privacy concerns
- vs **stealth / anti-detection plugins**: doesn't solve where the session comes from

### Install & Use

See the Chinese sections above — install is `sed` + `launchctl bootstrap`; use is `pw.chromium.connect_over_cdp("http://localhost:9222")` then `browser.contexts[0]`. CLI helper in `scripts/cdp`, more recipes in `references/recipes.md`.

### Hard rules

- **Never `browser.close()` or `ctx.close()`** — kills the daemon and burns your session
- **Never `page.bring_to_front()`** from automation — steals focus from your Mac
- **Always `page.close()`** the tabs you opened

### License

MIT.
