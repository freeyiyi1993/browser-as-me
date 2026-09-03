# browser-as-me · playwright recipes

> 给 cc 用的复制即用代码片段。所有片段都假设 CDP Chrome 已经在 9222（如果不在，先跑 `scripts/ensure_chrome.sh`）。

shebang 用任意装了 `playwright` 的 python（建议 venv / pipx 隔离）：
```
#!/usr/bin/env python3
```

或在终端跑：
```bash
python3 <<'PY'
... 代码 ...
PY
```

> 前置：`pip install playwright && python -m playwright install chromium`

---

## 1. 连接 + 拿 cookie

```python
from playwright.sync_api import sync_playwright

with sync_playwright() as pw:
    browser = pw.chromium.connect_over_cdp("http://localhost:9222")
    ctx = browser.contexts[0]
    # 所有 cookie
    for c in ctx.cookies():
        print(c["domain"], c["name"])
```

## 2. 在已登录站取页面内容

```python
with sync_playwright() as pw:
    browser = pw.chromium.connect_over_cdp("http://localhost:9222")
    ctx = browser.contexts[0]
    page = ctx.new_page()
    try:
        page.goto("https://example.com/protected", wait_until="domcontentloaded")
        # 等关键元素出现再读，避免 SPA 还没渲染
        page.wait_for_selector(".content", timeout=10000)
        text = page.inner_text(".content")
        print(text)
    finally:
        page.close()
```

## 3. 拦截 XHR / API 调用拿原始 JSON

适用于"网页好看但我想要后端 API 数据"的场景：

```python
captured = []

def on_response(resp):
    if "api/v1/something" in resp.url and resp.status == 200:
        try:
            captured.append(resp.json())
        except Exception:
            pass

with sync_playwright() as pw:
    browser = pw.chromium.connect_over_cdp("http://localhost:9222")
    ctx = browser.contexts[0]
    page = ctx.new_page()
    page.on("response", on_response)
    try:
        page.goto("https://example.com/page-that-triggers-api")
        page.wait_for_load_state("networkidle")
    finally:
        page.close()

print(captured)
```

## 4. 操作已存在的 tab（不开新 tab）

```python
with sync_playwright() as pw:
    browser = pw.chromium.connect_over_cdp("http://localhost:9222")
    ctx = browser.contexts[0]
    # 找已经打开的 feishu doc tab
    target = next((p for p in ctx.pages if "feishu.cn" in p.url), None)
    if not target:
        raise SystemExit("no feishu tab open — open one in CDP Chrome first")
    title = target.title()
    print(title)
    # 不要 close — 这是用户已经打开的 tab
```

## 5. 截图（高频调试）

```python
with sync_playwright() as pw:
    browser = pw.chromium.connect_over_cdp("http://localhost:9222")
    page = browser.contexts[0].new_page()
    try:
        page.goto("https://example.com/protected")
        page.screenshot(path="/tmp/shot.png", full_page=True)
    finally:
        page.close()
```

## 6. 处理需要 SSO 跳转的页面

很多企业内网站点会跳第三方 SSO（如 `corp-sso.example.com`）。已登录就秒回，没登录就停在 SSO 页：

```python
SSO_HOST = "corp-sso.example.com"  # 改成你的 SSO host

page.goto(target_url, wait_until="domcontentloaded", timeout=30000)
# 等待跳转完成（URL 变成 target 域名）或 SSO 失败
page.wait_for_url(lambda u: SSO_HOST not in u, timeout=15000)
if "login" in page.url.lower():
    raise SystemExit("登录态过期，请在 CDP Chrome 重新登一下")
```

## 7. 长任务的 timeout 兜底

```python
# Playwright 默认 30s navigation timeout。复杂 SPA 可能不够。
page.set_default_navigation_timeout(60000)
page.set_default_timeout(60000)
```

## 8. 不能做 / 容易踩坑

- ❌ `browser.close()` — 会杀掉 LaunchAgent 那个 Chrome
- ❌ `ctx.close()` — 复用主人的 context，关了下次没了
- ❌ `pw.chromium.launch(...)` — 那是启动新 Chrome，不是连现有的
- ❌ `page.bring_to_front()` — 抢主人 Mac 当前 Space 焦点。99% 操作不需要前台（DOM-level fill/click/screenshot/evaluate/set_input_files/goto 都行）。需要键盘事件时用元素级 `locator.press("Escape")` 而不是窗口级 `bring_to_front`。详见 SKILL.md「减少抢焦点 / Space 隔离」
- ✅ 永远 `page.close()` 自己开的 tab
- ✅ 永远 `with sync_playwright()` 用 context manager，进程退出时 pw 自动清理

## 9. async 版本（如果任务很复杂需要并发）

```python
import asyncio
from playwright.async_api import async_playwright

async def main():
    async with async_playwright() as pw:
        browser = await pw.chromium.connect_over_cdp("http://localhost:9222")
        ctx = browser.contexts[0]
        page = await ctx.new_page()
        try:
            await page.goto("https://example.com")
            ...
        finally:
            await page.close()

asyncio.run(main())
```

## 10. 反检测 + 拟人行为（强风控站，如电商 / 内容社区）

**何时用**：目标站会基于 `navigator.webdriver`、行为指纹、请求时序等做反爬判定。症状：登录态在但搜不出结果、403、「访问频繁」、账号被封限流。

**前置**：`pip install playwright-stealth`

```python
#!/usr/bin/env python3
import random, time, urllib.parse
from playwright.sync_api import sync_playwright
from playwright_stealth import Stealth

def jitter(low=0.4, high=1.2):
    time.sleep(random.uniform(low, high))

def mouse_wiggle(page, n=None):
    """随机鼠标小幅移动, 模拟空闲手。"""
    for _ in range(n or random.randint(2, 4)):
        page.mouse.move(random.randint(200, 1000), random.randint(200, 600),
                        steps=random.randint(8, 20))
        jitter(0.2, 0.6)

def human_scroll(page, steps=5):
    """wheel-based 滚动, 不要直接 scrollTo(bottom)。"""
    for _ in range(steps):
        page.mouse.wheel(0, random.randint(300, 700))
        jitter(0.6, 1.8)

KEYWORD = "你的关键词"
SEARCH_URL = f"https://target.com/search?q={urllib.parse.quote(KEYWORD)}"

# Stealth.use_sync 包裹 sync_playwright → 自动给 new_page() 注入 init script
with Stealth().use_sync(sync_playwright()) as pw:
    browser = pw.chromium.connect_over_cdp("http://localhost:9222")
    ctx = browser.contexts[0]
    page = ctx.new_page()
    try:
        # 关键: 先访问主页打热 referer, 再跳目标; 不要"主页都没看过直接深链 jump"
        page.goto("https://target.com/", wait_until="domcontentloaded", timeout=30000)
        jitter(1.5, 3.0)
        mouse_wiggle(page)
        jitter(0.8, 1.5)

        page.goto(SEARCH_URL, wait_until="domcontentloaded", timeout=30000)
        jitter(2.0, 3.5)
        mouse_wiggle(page)
        human_scroll(page, steps=4)

        # blocked 自检
        body = page.evaluate("() => document.body.innerText.slice(0, 500)")
        if any(k in body for k in ["访问频繁", "异常", "登录后查看", "稍后再试", "验证"]):
            raise SystemExit(f"BLOCKED: {body[:200]}")

        # stealth 是否生效自检 (第一次接新站必跑一次)
        fp = page.evaluate("() => ({wd: navigator.webdriver, "
                           "plugins: navigator.plugins.length, "
                           "langs: navigator.languages})")
        assert fp["wd"] is False, f"webdriver leak: {fp}"

        # ... 真正的抓取逻辑 ...
    finally:
        page.close()
```

**反检测纪律 (按命中风险从高到低)**

| 反模式 | 触发什么 | 改成 |
|---|---|---|
| `connect_over_cdp` 无 stealth → `navigator.webdriver = true` | 一行 JS 就识破 | `Stealth().use_sync(...)` 包裹 |
| `goto` → 立即 `evaluate` | 0 dwell, 行为指纹异常 | jitter 1.5-3s + mouse_wiggle |
| `window.scrollTo(0, height)` 瞬时到底 | 滚动速度异常 | `mouse.wheel` 多步 + 每步 jitter |
| 没访问主页直接深链 / 搜索 URL | 缺 referer + session 路径不自然 | 先 `goto(homepage)` 暖身 |

补充纪律：

| 反模式 | 风险 | 建议 |
|---|---|---|
| 同一账号短时间重复运行 | 触发限流或账号风控 | 降低频率；失败后停止重试并等待冷却 |
| 所有 selector 都无限等待 | 限流后继续请求，放大风险 | 设置合理 timeout；失败后退出并记录原因 |
| 只抓取、不做必要的页面停留 | 行为轨迹单一 | 只在业务确实需要时打开详情并短暂停留 |

**Stealth 验证模板**（接入新站时先做一次）：

```python
print(page.evaluate("() => ({"
    "wd: navigator.webdriver,"
    "plugins: navigator.plugins.length,"
    "langs: navigator.languages,"
    "ua: navigator.userAgent,"
    "vendor: navigator.vendor,"
    "platform: navigator.platform"
"})"))
# 期望：wd=false、plugins>0、langs 非空，且 UA/vendor/platform 与真实 Chrome 一致
```

如果页面出现明确的 blocked / rate-limit 提示，应停止当前任务，不要继续尝试。
