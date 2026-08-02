#!/usr/bin/env python3
"""Insert or replace a single release entry in a Sparkle appcast.

Sparkle's own generate_appcast wants a directory holding every archive ever
shipped, which CI does not have. This keeps the published appcast.xml as the
source of truth and edits one <item> into it per release.
"""

import argparse
import sys
import xml.etree.ElementTree as ET
from datetime import datetime, timezone
from email.utils import format_datetime

SPARKLE_NS = "http://www.andymatuschak.org/xml-namespaces/sparkle"
ET.register_namespace("sparkle", SPARKLE_NS)


def sparkle(tag):
    return f"{{{SPARKLE_NS}}}{tag}"


def empty_appcast(title, link, description):
    rss = ET.Element("rss", {"version": "2.0"})
    channel = ET.SubElement(rss, "channel")
    ET.SubElement(channel, "title").text = title
    ET.SubElement(channel, "link").text = link
    ET.SubElement(channel, "description").text = description
    ET.SubElement(channel, "language").text = "en"
    return ET.ElementTree(rss)


def load(path, args):
    try:
        tree = ET.parse(path)
    except (FileNotFoundError, ET.ParseError):
        return empty_appcast(args.channel_title, args.channel_link, args.channel_description)
    if tree.getroot().find("channel") is None:
        sys.exit(f"{path}: no <channel> element, refusing to overwrite")
    return tree


def build_item(args):
    item = ET.Element("item")
    ET.SubElement(item, "title").text = f"Version {args.short_version}"
    ET.SubElement(item, sparkle("version")).text = args.version
    ET.SubElement(item, sparkle("shortVersionString")).text = args.short_version
    if args.minimum_system_version:
        ET.SubElement(item, sparkle("minimumSystemVersion")).text = args.minimum_system_version
    if args.release_notes_url:
        ET.SubElement(item, sparkle("releaseNotesLink")).text = args.release_notes_url
    if args.full_release_notes_url:
        ET.SubElement(item, sparkle("fullReleaseNotesLink")).text = args.full_release_notes_url
    if args.critical:
        ET.SubElement(item, sparkle("criticalUpdate"))
    pub_date = args.pub_date or format_datetime(datetime.now(timezone.utc))
    ET.SubElement(item, "pubDate").text = pub_date
    ET.SubElement(
        item,
        "enclosure",
        {
            "url": args.url,
            sparkle("edSignature"): args.signature,
            "length": str(args.length),
            "type": "application/octet-stream",
        },
    )
    return item


def main():
    p = argparse.ArgumentParser(description=__doc__)
    p.add_argument("appcast", help="path to appcast.xml (created if missing)")
    p.add_argument("--version", required=True, help="CFBundleVersion — Sparkle's ordering key")
    p.add_argument("--short-version", required=True, help="CFBundleShortVersionString, e.g. 1.2.0")
    p.add_argument("--url", required=True, help="download URL of the .zip enclosure")
    p.add_argument("--length", required=True, type=int, help="enclosure size in bytes")
    p.add_argument("--signature", required=True, help="EdDSA signature from sign_update")
    p.add_argument("--minimum-system-version", default="")
    p.add_argument("--release-notes-url", default="")
    p.add_argument("--full-release-notes-url", default="")
    p.add_argument("--critical", action="store_true")
    p.add_argument("--pub-date", default="", help="RFC 2822 date; defaults to now")
    p.add_argument("--max-items", type=int, default=10, help="keep at most N most recent entries")
    p.add_argument("--channel-title", default="Palium")
    p.add_argument("--channel-link", default="https://mgruszkiewicz.github.io/palium/appcast.xml")
    p.add_argument("--channel-description", default="Most recent Palium releases")
    args = p.parse_args()

    tree = load(args.appcast, args)
    channel = tree.getroot().find("channel")

    # Re-releasing the same build replaces the old entry rather than duplicating it.
    for existing in channel.findall("item"):
        node = existing.find(sparkle("version"))
        if node is not None and node.text == args.version:
            channel.remove(existing)

    items = channel.findall("item")
    insert_at = list(channel).index(items[0]) if items else len(list(channel))
    channel.insert(insert_at, build_item(args))

    for stale in channel.findall("item")[args.max_items:]:
        channel.remove(stale)

    ET.indent(tree, space="    ")
    tree.write(args.appcast, encoding="utf-8", xml_declaration=True)
    print(f"{args.appcast}: wrote {args.short_version} (build {args.version})")


if __name__ == "__main__":
    main()
