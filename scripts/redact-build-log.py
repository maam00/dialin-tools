#!/usr/bin/env python3
"""Redact build output before it reaches disk. No network or device calls."""
import os
import re
import sys


def redact(line: str, secrets: tuple[str, ...] = ()) -> str:
    for secret in sorted({s for s in secrets if s}, key=len, reverse=True):
        line = line.replace(secret, "<redacted>")
    return re.sub(r"(?i)((?:x-app-token|app_token|dialin_app_token|authorization)\s*[:=]\s*)(?:Bearer\s+)?(?:\"[^\"]*\"|'[^']*'|[^\s,;]+)", r"\1<redacted>", line)


if __name__ == "__main__":
    secrets = tuple(os.environ.get(key, "") for key in ("DIALIN_BUILD_APP_TOKEN", "APP_TOKEN", "ANTHROPIC_API_KEY"))
    for line in sys.stdin:
        sys.stdout.write(redact(line, secrets))
        sys.stdout.flush()
