#!/usr/bin/env python3
"""Mint a short-lived Google Drive access token for a service account (local/dev).

Never commit the SA JSON key. Example:

  export DRIVEFLOW_SA_KEY_PATH="$HOME/Library/Application Support/Driveflow/service-account.json"
  eval "$(./scripts/mint-sa-token.py --print-exports)"
  # → sets DRIVEFLOW_SHARE_EMAIL and DRIVEFLOW_SHARE_ACCESS_TOKEN for the app process

Or write a tiny local mint HTTP server response shape for DRIVEFLOW_SHARE_MINT_URL.
"""

from __future__ import annotations

import argparse
import json
import os
import sys
import time
import urllib.parse
import urllib.request
from pathlib import Path

try:
    from cryptography.hazmat.primitives import hashes, serialization
    from cryptography.hazmat.primitives.asymmetric import padding
except ImportError:
    print(
        "error: install cryptography (`pip install cryptography`) to mint SA tokens",
        file=sys.stderr,
    )
    sys.exit(1)

SCOPE = "https://www.googleapis.com/auth/drive.readonly"
TOKEN_URI = "https://oauth2.googleapis.com/token"


def b64url(data: bytes) -> str:
    import base64

    return base64.urlsafe_b64encode(data).rstrip(b"=").decode("ascii")


def load_key(path: Path) -> dict:
    with path.open("r", encoding="utf-8") as handle:
        return json.load(handle)


def make_jwt(key: dict) -> str:
    now = int(time.time())
    header = {"alg": "RS256", "typ": "JWT", "kid": key["private_key_id"]}
    claims = {
        "iss": key["client_email"],
        "sub": key["client_email"],
        "scope": SCOPE,
        "aud": key.get("token_uri", TOKEN_URI),
        "iat": now,
        "exp": now + 3600,
    }
    signing_input = f"{b64url(json.dumps(header, separators=(',', ':')).encode())}.{b64url(json.dumps(claims, separators=(',', ':')).encode())}"
    private_key = serialization.load_pem_private_key(
        key["private_key"].encode("utf-8"),
        password=None,
    )
    signature = private_key.sign(
        signing_input.encode("ascii"),
        padding.PKCS1v15(),
        hashes.SHA256(),
    )
    return f"{signing_input}.{b64url(signature)}"


def exchange(assertion: str, token_uri: str) -> dict:
    body = urllib.parse.urlencode(
        {
            "grant_type": "urn:ietf:params:oauth:grant-type:jwt-bearer",
            "assertion": assertion,
        }
    ).encode()
    request = urllib.request.Request(
        token_uri,
        data=body,
        headers={"Content-Type": "application/x-www-form-urlencoded"},
        method="POST",
    )
    with urllib.request.urlopen(request, timeout=30) as response:
        return json.load(response)


def default_key_path() -> Path:
    env = os.environ.get("DRIVEFLOW_SA_KEY_PATH")
    if env:
        return Path(env).expanduser()
    return Path.home() / "Library/Application Support/Driveflow/service-account.json"


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument(
        "--key",
        type=Path,
        default=None,
        help="Path to service-account JSON (default: Application Support or DRIVEFLOW_SA_KEY_PATH)",
    )
    parser.add_argument(
        "--print-exports",
        action="store_true",
        help="Print shell export lines for DRIVEFLOW_SHARE_EMAIL / DRIVEFLOW_SHARE_ACCESS_TOKEN",
    )
    parser.add_argument(
        "--json",
        action="store_true",
        help="Print mint API-shaped JSON to stdout",
    )
    args = parser.parse_args()
    key_path = args.key or default_key_path()
    if not key_path.is_file():
        print(f"error: missing service-account key at {key_path}", file=sys.stderr)
        return 1

    key = load_key(key_path)
    assertion = make_jwt(key)
    token = exchange(assertion, key.get("token_uri", TOKEN_URI))
    share_email = key["client_email"]
    access_token = token["access_token"]
    expires_in = int(token.get("expires_in", 3600))

    if args.print_exports:
        print(f'export DRIVEFLOW_SHARE_EMAIL="{share_email}"')
        print(f'export DRIVEFLOW_SHARE_ACCESS_TOKEN="{access_token}"')
        print(f'export DRIVEFLOW_SHARE_TOKEN_EXPIRES_IN="{expires_in}"')
        return 0

    print(json.dumps(payload, indent=2))
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
