---
name: browser-as-me
description: 用用户「专用 CDP Chrome 实例」操作浏览器，复用其中已经登录过的 cookie / session。底层走 Chrome DevTools Protocol (CDP)，由 launchd 常驻一个独立 Chrome（user-data-dir=~/.chrome-cdp-profile，端口 9222），第一次访问某站时由用户在这个 Chrome 里登录一次，之后 cookie 永久持有，Claude 操作时不再问用户要 cookie。当用户说「用我的浏览器」「用我登录态」「我浏览器里」「带 cookie 打开」「我已经登录过的 X」「browser-as-me」「/browser-as-me」「CDP Chrome」时触发。也用于需要登录态才能拿到内容的页面（飞书 doc 网页版、公司内网、淘宝、京东、各种需登录的 SaaS）。不要在用户问的是「打开公开网页」「fetch 一个 URL」「抓取无需登录的内容」时触发——那是 WebFetch / 普通 curl 的活；本 skill 仅在「需要登录态」时才有性价比。也不要在用户问「怎么自动登录 X」时触发——本 skill 不做自动登录，只复用用户已经手动登录好的 session。
metadata:
  type: infrastructure
---

> 不实现【第 1 项 产出 artifact】，因为本 skill 是基础设施 / 工具适配层，其产出取决于具体任务（截图、网页文本、cookie dump、操作回执），不应固化输出格式。具体调用方任务自行决定要不要落地 artifact。
>
> 不实现【第 3 项 新建 vs 更新】，理由同上——没有固定输出文件需要"更新模式"。

## 概念解释

- **CDP (Chrome DevTools Protocol)**: Chrome 暴露的 WebSocket 调试协议，外部进程可以读 DOM、操作 page、拿 cookie，等同于"打开 Chrome 的开发者工具"但走程序化。
- **CDP Chrome 专用实例**: 由 `~/Library/LaunchAgents/com.local.chrome-cdp.plist` 常驻拉起的一个独立 Chrome 进程，`--user-data-dir=~/.chrome-cdp-profile`，**端口 9222**。和用户日常 Chrome（默认 profile）**完全隔离**，互不影响。
- **context / page**: Playwright 概念。context = 一个浏览器会话（包含 cookie / 存储），page = 一个 tab。本 skill 用 `connect_over_cdp` 连上 CDP Chrome 后拿到 `browser.contexts[0]`，里面的 pages 就是 CDP Chrome 里正在开的 tabs。

## 为什么不复用日常 Chrome 的 cookie

Chrome 2024 mid 加了安全策略：`--remote-debugging-port` 在**默认 user-data-dir** 下被禁用（防恶意软件偷 cookie，realpath 比较，symlink 绕不过）。所以只能用一个独立 profile。代价：用户需要在 CDP Chrome 里**第一次访问某站时登一次**，之后 cookie 长期持有。

## 执行流程

### Step 0: 先查 workflows/index.md 看历史是否有可复用的流程

```bash
cat ~/.claude/skills/browser-as-me/workflows/index.md 2>/dev/null
```

`index.md` 是所有场景一张表（场景 slug + 触发短语 + 关键产物）。只读 index.md，不要 ls 全目录。

命中后进入 `workflows/<slug>/README.md` 读完整流程。如果 index 不存在或没匹配 → 按 Step 1 起手，结束后回 Step 6 沉淀。

> 公版 fork 默认 workflows/ 为空（业务场景大多是私有信息）；用户自己用时按 Step 6 累积自己的 workflow 库。

### Step 1: 确认 CDP 可用

```bash
~/.claude/skills/browser-as-me/scripts/ensure_chrome.sh
```

- 9222 通 → OK，继续
- 不通 → 脚本会自动 `launchctl kickstart` 重启 LaunchAgent，再等最多 15 秒
- 仍不通 → 报错，让用户 `launchctl print gui/$UID/com.local.chrome-cdp` 自查

### Step 2: 列 tabs 看看用户在 CDP Chrome 里有什么

```bash
~/.claude/skills/browser-as-me/scripts/cdp list-tabs
```

输出格式：`<index> | <url> | <title>`。如果一个 tab 都没有（刚被 launchd 起来的新 Chrome），说明这是干净状态。

### Step 3: 判断本次任务在 CDP Chrome 里有没有需要的登录态

- 任务涉及的域名（如 `feishu.cn` / `your-corp.example.com`），看 tabs/cookie 里有没有该域的 session
- 没有 → **立刻停下来**，告诉用户："请在 CDP Chrome（dock 里 user-data-dir=~/.chrome-cdp-profile 那个 Chrome）登录一下 `<domain>`，登好告诉我"
- 有 → 继续

### Step 4: 执行任务（在 cc 自己的代码里 import）

最小模板（参考 `references/recipes.md` 拿更复杂的）：

```python
#!/usr/bin/env python3
from playwright.sync_api import sync_playwright

with sync_playwright() as pw:
    browser = pw.chromium.connect_over_cdp("http://localhost:9222")
    ctx = browser.contexts[0]
    page = ctx.new_page()
    try:
        page.goto("https://feishu.cn/some-doc")
        # ... 任务代码 ...
        content = page.content()
    finally:
        page.close()  # 关 page 不关 browser（browser 是常驻的）
```

**关键纪律**：
- **永远 `page.close()`，不要 `browser.close()`**。browser.close() 会杀掉 LaunchAgent 那个 Chrome，所有登录态消失（虽然下次会被自动拉起，但 session 没了）。
- 不要 `ctx.close()`。复用用户的 context。
- 如果创建了多个 page，全部 close。
- **不要写 `page.bring_to_front()`**。会让 CDP Chrome 抢走当前 Space 的焦点，打断用户正在做的事。绝大多数操作（`fill` / `click` / `screenshot` / `evaluate` / `set_input_files` / `goto`）走 DOM 不需要前台，背景 tab 一样跑。仅在合成键盘事件（`page.keyboard.press(...)`）时焦点才有意义，且优先用**元素级** `locator.press("Escape")` 而不是全窗口 `bring_to_front` —— 元素级 press 只 focus 那个元素，不抢窗口焦点。

### Step 5: 任务结束后自动进化询问

```
这次结果哪里要改？1) 内容（本次操作有问题）2) 流程（skill 设计有问题）3) 都还行。回数字。
```

回 2 → 给用户 SKILL.md diff，确认后写入 + 加 evolution log。

### Step 6: 沉淀 workflow（任务完成后强制做）

把本次任务沉淀成 `workflows/<scenario-slug>/README.md`（每场景独立子目录），方便下次复用：

1. 查 `workflows/index.md` 现状：
   - **有且基本一致** → 不动
   - **有但本次有新坑 / 新优化** → 更新对应 `<slug>/README.md`，末尾追加 changelog
   - **有但本次走的是同场景下的不同分支** → 加 `## 分支：<情况>` section
   - **完全没有** → 创建 `workflows/<slug>/` + README.md + **在 index.md 表里加一行**
2. 两份 workflow 高度雷同 → 合并
3. 场景配套的脚本 / 数据 / SOP 都放本子目录（不散到 `scripts/` 或 `references/`）

模板见 `workflows/README.md`。

## 参数 / CLI

`scripts/cdp` 是一个小 CLI，给 cc 用来速查 / 速操作（重活仍然让 cc 自己写 playwright 代码）：

```
cdp list-tabs                  # 列 CDP Chrome 当前所有 tabs
cdp open <url>                 # 新开一个 tab 打开 URL，输出 tab id
cdp screenshot <url> [out.png] # 在 CDP Chrome 截图，默认输出到 /tmp/cdp-shot.png
cdp cookie <domain>            # dump 该域的所有 cookie 为 JSON
cdp exec <url> <js-expression> # 在该 URL 上执行 JS 表达式，返回 stringified 结果
```

## 减少抢焦点 / Space 隔离

CDP Chrome 自带「容易抢焦点」属性 —— `bring_to_front()` / 新 tab event / SSO 跳转都可能把它推到当前 Space 最前。两层防御一起用：

1. **代码层**（默认）：永远不写 `page.bring_to_front()`。见上文「关键纪律」。这一条覆盖 95% 抢焦点场景。
2. **环境层**（一次性手动设置）：把 CDP Chrome 窗口拖到独立 Space。Mission Control 打开 → 把 CDP Chrome 拖到 Desktop 2 固定。日常工作在 Desktop 1，CDP 怎么 activate 都在另一个 Space，不会跨 Space 抢焦点。需要人眼看 CDP（OTP 输入 / WhatsApp QR 扫码）时手动 `ctrl + →` 切过去。

剩下 5% 真的需要 activate 的场景（如某些站要求 window focused 才发某个事件、或用户交互），用 `osascript -e 'tell application "Google Chrome" to activate'` 显式拉起，告诉用户「我现在需要切过去看一下」，而不是后台静默抢焦点。

## 故障处理

| 症状 | 排查 |
|---|---|
| `ECONNREFUSED 127.0.0.1:9222` | 跑 `ensure_chrome.sh`；仍不行看 `/tmp/chrome-cdp.err.log` |
| Chrome 被 Cmd+Q 关了又自己起来 | 这是 KeepAlive=true 的预期行为。要彻底关：`launchctl bootout gui/$UID ~/Library/LaunchAgents/com.local.chrome-cdp.plist` |
| 某站登录态过期 | 在 CDP Chrome 里重登一次。CDP Chrome 不在 dock 显示也能从 Activity Monitor / `osascript` 切到前台 |
| dock 里看到两个 Chrome | 这是预期：日常 Chrome + CDP Chrome 是两个独立实例 |
| CDP Chrome cookie 想 sync 到日常 Chrome | 不支持。两个 profile 完全隔离，按设计如此（如果能 sync，整个安全模型就破了） |

## 参考资料

> URL 按可信度分级：[官网]=主页几乎肯定对；[搜索]=构造性搜索链接肯定可用；[⚠️ 记忆]=模型记忆可能过时或错误。

**关键工具 / 协议**
- **Chrome DevTools Protocol** — Chrome 暴露的程序化操作协议
  - 🏠 [官网](https://chromedevtools.github.io/devtools-protocol/) `[官网]`
- **Playwright** — 微软出的浏览器自动化框架，原生支持 `connect_over_cdp`
  - 🏠 [官网](https://playwright.dev/python/) `[官网]`
  - 📖 [connect_over_cdp 文档搜索](https://www.google.com/search?q=playwright+python+connect_over_cdp+chromium) `[搜索]`

**Chrome 2024 安全策略（为什么不能复用默认 profile）**
- Chrome 中禁止默认 user-data-dir 启用 CDP（防恶意软件偷 cookie 的安全补丁）
  - 📖 [搜索 chromium remote-debugging-port default profile blocked](https://www.google.com/search?q=chromium+remote-debugging-port+default+profile+blocked+security) `[搜索]`
  - 📖 [搜索 chromium DevToolsRemoteDebugging non-default data directory](https://www.google.com/search?q=chromium+%22non-default+data+directory%22+devtools) `[搜索]`

**同族 / 配套 skill**
- 需要登录态访问公司内部站 → 本 skill + 用户手动登企业 SSO
- 需要操作飞书 doc 但**走 API**而不是网页 → 用[飞书开放平台 SDK](https://open.feishu.cn/document/home/index)（性能 / 稳定性都更好）
- 需要操作飞书 doc 网页版（API 不覆盖的功能，如多人协作 cursor / 评论 UI）→ 本 skill

**配置文件**
- LaunchAgent: `~/Library/LaunchAgents/com.local.chrome-cdp.plist`
- CDP Chrome profile: `~/.chrome-cdp-profile/`
- 错误日志: `/tmp/chrome-cdp.err.log` / `/tmp/chrome-cdp.out.log`

## evolution log

- 2026-06-05 · 加「不要 `bring_to_front()`」反模式 + 「Space 隔离」段落。源自 cigna 报销 session 实战：每次填表 / 截图前习惯性 `bring_to_front()`，多次打断用户在 Mac 上正在做的事。事后核对：本次所有操作（fill/click/screenshot/set_input_files/keyboard.press("Escape")）其实都不需要前台，`bring_to_front()` 是纯多余。
- 2026-06-19 · 加「workflows/ 自我沉淀」机制：Step 0 起手先查历史 workflow，Step 6 结尾必沉淀，多份雷同自动合并。同时把「不抢焦点」实施到代码：`scripts/cdp` 改用 raw CDP `Target.createTarget {background:true}`；`scripts/ensure_chrome.sh` 加 frontmost app 抓取 + EXIT trap 还焦点；新增 `scripts/cdp_background.py` standalone helper。同步私版 → 公版 fork。
