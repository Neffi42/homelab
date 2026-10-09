#!/usr/bin/env python3
"""Fetch the last 24h of Hacker News RSS and post a digest to Discord."""

import json
import os
import sys
import urllib.request
from datetime import datetime, timedelta, timezone
from email.utils import parsedate_to_datetime
from xml.etree import ElementTree

RSS_URL = "https://news.ycombinator.com/rss"
HEADER = "\U0001f5de️ **Your Daily Hacker News Brief**\n"
DISCORD_MAX_LEN = 2000


def fetch_items(url: str) -> list[dict]:
    with urllib.request.urlopen(url, timeout=30) as resp:
        root = ElementTree.fromstring(resp.read())

    items = []
    for item in root.findall("./channel/item"):
        title = item.findtext("title", default="").strip()
        link = item.findtext("link", default="").strip()
        pub_date_raw = item.findtext("pubDate", default="").strip()
        if not (title and link and pub_date_raw):
            continue
        items.append(
            {
                "title": title,
                "link": link,
                "pub_date": parsedate_to_datetime(pub_date_raw),
            }
        )
    return items


def filter_last_24h(items: list[dict], now: datetime) -> list[dict]:
    cutoff = now - timedelta(days=1)
    return [item for item in items if item["pub_date"] >= cutoff]


def build_messages(items: list[dict]) -> list[str]:
    msg = HEADER
    messages = []

    for item in items:
        date_str = item["pub_date"].astimezone(timezone.utc).strftime("%d/%m/%Y")
        line = f"> • [{item['title']}]({item['link']}) — _{date_str}_\n"

        if len(msg) + len(line) >= DISCORD_MAX_LEN:
            messages.append(msg)
            msg = line
        else:
            msg += line

    if msg:
        messages.append(msg)

    return messages


def post_to_discord(webhook_url: str, message: str) -> None:
    payload = json.dumps({"content": message}).encode("utf-8")
    req = urllib.request.Request(
        webhook_url,
        data=payload,
        headers={
            "Content-Type": "application/json",
            "User-Agent": "hackernews-digest (forgejo action)",
        },
        method="POST",
    )
    with urllib.request.urlopen(req, timeout=30) as resp:
        if resp.status >= 300:
            raise RuntimeError(f"discord webhook returned HTTP {resp.status}")


def main() -> int:
    dry_run = "--dry-run" in sys.argv[1:]

    items = filter_last_24h(fetch_items(RSS_URL), datetime.now(timezone.utc))
    messages = build_messages(items)

    if not messages:
        print("no items in the last 24h, nothing to post")
        return 0

    if dry_run:
        for i, message in enumerate(messages, 1):
            print(f"--- message {i}/{len(messages)} ---")
            print(message)
        return 0

    webhook_url = os.environ.get("DISCORD_WEBHOOK_URL")
    if not webhook_url:
        print("DISCORD_WEBHOOK_URL is not set", file=sys.stderr)
        return 1

    for message in messages:
        post_to_discord(webhook_url, message)

    return 0


if __name__ == "__main__":
    sys.exit(main())
