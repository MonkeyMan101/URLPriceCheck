import re
import os
import ssl
from datetime import datetime
import subprocess
import urllib.error
import urllib.request

# The URL for Halo Wars 2 Complete Edition
url = "https://www.xbox.com/en-GB/games/store/halo-wars-2-complete-edition/c1c13ggxm7jg"

HEADERS = {"User-Agent": "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7)"}


def _ssl_context():
    """Use macOS system CAs first; certifi if installed."""
    for cafile in (
        "/etc/ssl/cert.pem",
        "/private/etc/ssl/cert.pem",
    ):
        if os.path.isfile(cafile):
            return ssl.create_default_context(cafile=cafile)
    try:
        import certifi

        return ssl.create_default_context(cafile=certifi.where())
    except ImportError:
        pass
    return ssl.create_default_context()


def fetch_page(page_url):
    req = urllib.request.Request(page_url, headers=HEADERS)
    try:
        with urllib.request.urlopen(req, context=_ssl_context(), timeout=30) as response:
            return response.read().decode("utf-8")
    except urllib.error.URLError as exc:
        if "CERTIFICATE_VERIFY_FAILED" not in str(exc):
            raise
        # curl uses the Mac system trust store and avoids Python's broken CA bundle
        result = subprocess.run(
            ["curl", "-fsSL", "-A", HEADERS["User-Agent"], page_url],
            capture_output=True,
            text=True,
            timeout=30,
            check=False,
        )
        if result.returncode != 0:
            raise RuntimeError(
                "SSL verification failed for Python and curl. "
                f"curl exit {result.returncode}: {result.stderr.strip()}"
            ) from exc
        return result.stdout


def notify(message, *, ok=True):
    """Show a Mac notification so you can see each run finished."""
    ran_at = datetime.now().strftime("%H:%M")
    title = "URLPriceCheck (HALO WARS 2) ran" if ok else "URLPriceCheck failed"
    subtitle = f"Finished at {ran_at}"
    safe_msg = message.replace("\\", "\\\\").replace('"', '\\"')
    safe_title = title.replace("\\", "\\\\").replace('"', '\\"')
    safe_sub = subtitle.replace("\\", "\\\\").replace('"', '\\"')
    os.system(
        f"osascript -e 'display notification \"{safe_msg}\" "
        f'with title "{safe_title}" subtitle "{safe_sub}" sound name "Pop"\''
    )


try:
    html = fetch_page(url)

    prices = re.findall(r"£\d+\.\d{2}", html)

    if prices:
        current_price_str = prices[0]
        current_price_num = float(current_price_str.replace("£", ""))

        if current_price_num <= 20.00:
            hint = "BUY NOW — your £20 credit covers it!"
        else:
            hint = "Above £20 — wait for a sale."

        notify(f"Current price: {current_price_str}. {hint}")
    else:
        notify("Ran OK, but no price found on the store page.", ok=False)
        print("Price not found on page.")

except Exception as e:
    notify(f"Error: {e}", ok=False)
    print(f"Error: {e}")
