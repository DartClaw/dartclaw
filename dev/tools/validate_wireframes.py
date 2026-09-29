#!/usr/bin/env python3
"""Validate exported HTML wireframes used as implementation contracts."""

from __future__ import annotations

import argparse
from html.parser import HTMLParser
from pathlib import Path


class _Structure(HTMLParser):
    def __init__(self) -> None:
        super().__init__()
        self.tags: set[str] = set()
        self.ids: set[str] = set()
        self.states: set[str] = set()

    def handle_starttag(self, tag: str, attrs: list[tuple[str, str | None]]) -> None:
        self.tags.add(tag)
        values = dict(attrs)
        if values.get("id"):
            self.ids.add(values["id"] or "")
        if values.get("data-state"):
            self.states.add(values["data-state"] or "")


COMMON_SEARCH_STATES = {
    "search-loading",
    "search-empty",
    "search-failure",
    "authorization-revoked",
    "missing-target",
}
BUILT_INS = {f"/{name}" for name in ("new", "reset", "stop", "status", "fork", "settle", "model", "effort", "help")}


def validate(path: Path) -> list[str]:
    errors: list[str] = []
    if not path.is_file():
        return [f"{path}: file does not exist"]
    source = path.read_text(encoding="utf-8")
    parser = _Structure()
    parser.feed(source)
    if not source.lstrip().lower().startswith("<!doctype html>"):
        errors.append(f"{path}: missing HTML doctype")
    for tag in ("html", "head", "body", "main", "h1"):
        if tag not in parser.tags:
            errors.append(f"{path}: missing <{tag}>")
    if path.name in {"chat-command-palette.html", "command-palette-global.html"}:
        missing_states = COMMON_SEARCH_STATES - parser.states
        if missing_states:
            errors.append(f"{path}: missing states {sorted(missing_states)}")
        missing_commands = {command for command in BUILT_INS if f">{command}<" not in source}
        if missing_commands:
            errors.append(f"{path}: missing built-ins {sorted(missing_commands)}")
    if path.name == "chat-command-palette.html":
        for value in ("provider-passthrough", "current-search-match", "Send to provider", "/help (skill)"):
            if value not in source:
                errors.append(f"{path}: missing {value!r}")
    if path.name == "command-palette-global.html":
        for value in ("global-search-results", "sessionless", "Lifecycle", "Project", "/help (skill)"):
            if value not in source:
                errors.append(f"{path}: missing {value!r}")
    return errors


def main() -> int:
    argument_parser = argparse.ArgumentParser()
    argument_parser.add_argument("--files", nargs="+", type=Path, required=True)
    args = argument_parser.parse_args()
    errors = [error for path in args.files for error in validate(path)]
    if errors:
        print("\n".join(errors))
        return 1
    print(f"validated {len(args.files)} wireframe(s)")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
