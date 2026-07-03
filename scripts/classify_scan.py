#!/usr/bin/env python3
import argparse
import json
import re
import shutil
import unicodedata
from datetime import date
from pathlib import Path


def normalize(text):
    text = text.lower()
    text = unicodedata.normalize("NFKD", text)
    text = "".join(char for char in text if not unicodedata.combining(char))
    return re.sub(r"\s+", " ", text)


def safe_topic(topic):
    topic = re.sub(r"[/:\\\\]+", " ", topic).strip()
    topic = re.sub(r"\s+", " ", topic)
    return topic or "Unsortiert Scan"


def load_rules(path):
    with path.open("r", encoding="utf-8") as handle:
        rules = json.load(handle)
    if not isinstance(rules, list):
        raise ValueError("Topic rules must be a JSON list.")
    return rules


def classify(text, rules, fallback):
    normalized = normalize(text)
    for rule in rules:
        topic = rule.get("topic", "").strip()
        patterns = rule.get("patterns", [])
        if topic and patterns and all(re.search(pattern, normalized) for pattern in patterns):
            return topic
    return fallback


def unique_path(directory, topic, today):
    stem = f"{today}.{safe_topic(topic)}"
    candidate = directory / f"{stem}.pdf"
    counter = 2
    while candidate.exists():
        candidate = directory / f"{stem}.{counter}.pdf"
        counter += 1
    return candidate


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--pdf", required=True, type=Path)
    parser.add_argument("--text", required=True, type=Path)
    parser.add_argument("--rules", required=True, type=Path)
    parser.add_argument("--output-dir", required=True, type=Path)
    parser.add_argument("--fallback-topic", default="Unsortiert Scan")
    parser.add_argument("--topic")
    parser.add_argument("--date")
    args = parser.parse_args()

    rules = load_rules(args.rules)
    text = args.text.read_text(encoding="utf-8", errors="replace") if args.text.exists() else ""
    topic = args.topic.strip() if args.topic else classify(text, rules, args.fallback_topic)
    today = args.date or date.today().strftime("%Y--%m--%d")
    destination = unique_path(args.output_dir, topic, today)
    args.output_dir.mkdir(parents=True, exist_ok=True)
    shutil.move(str(args.pdf), destination)
    print(destination)


if __name__ == "__main__":
    main()
