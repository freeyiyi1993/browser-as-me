"""Helpers for opening CDP Chrome tabs without stealing macOS focus.

Usage (sync):

    from cdp_background import background_page
    from playwright.sync_api import sync_playwright

    with sync_playwright() as pw:
        browser = pw.chromium.connect_over_cdp("http://localhost:9222")
        ctx = browser.contexts[0]
        with background_page(browser, ctx) as page:
            page.goto("https://example.com")
            text = page.evaluate("document.body.innerText")
"""
from contextlib import asynccontextmanager, contextmanager


@contextmanager
def background_page(browser, ctx, timeout=10000):
    """Create a new page through raw CDP with background=true.

    Playwright's ctx.new_page() activates the Chrome window on macOS. Target
    creation in the background keeps the dedicated CDP Chrome behind whatever
    app you're currently using.
    """
    session = browser.new_browser_cdp_session()
    with ctx.expect_page(timeout=timeout) as info:
        session.send("Target.createTarget", {"url": "about:blank", "background": True})
    page = info.value
    try:
        yield page
    finally:
        try:
            page.close()
        except Exception:
            pass


@asynccontextmanager
async def async_background_page(browser, ctx, timeout=10000):
    """Async variant of background_page."""
    session = await browser.new_browser_cdp_session()
    async with ctx.expect_page(timeout=timeout) as info:
        await session.send("Target.createTarget", {"url": "about:blank", "background": True})
    page = await info.value
    try:
        yield page
    finally:
        try:
            await page.close()
        except Exception:
            pass
