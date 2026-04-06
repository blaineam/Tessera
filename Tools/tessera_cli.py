#!/usr/bin/env python3
"""Tessera License Management CLI — Ed25519-based license key generation and verification."""

import argparse
import base64
import json
import os
import sys
import time
import uuid

from cryptography.hazmat.primitives.asymmetric.ed25519 import (
    Ed25519PrivateKey,
    Ed25519PublicKey,
)
from cryptography.hazmat.primitives import serialization


# ---------------------------------------------------------------------------
# Base64URL helpers (RFC 4648 §5, no padding)
# ---------------------------------------------------------------------------

def b64url_encode(data: bytes) -> str:
    return base64.urlsafe_b64encode(data).rstrip(b"=").decode("ascii")


def b64url_decode(s: str) -> bytes:
    # Re-add padding
    padding = 4 - len(s) % 4
    if padding != 4:
        s += "=" * padding
    return base64.urlsafe_b64decode(s)


# ---------------------------------------------------------------------------
# Key I/O
# ---------------------------------------------------------------------------

def load_private_key(path: str) -> Ed25519PrivateKey:
    with open(path, "rb") as f:
        return serialization.load_pem_private_key(f.read(), password=None)


def load_public_key(path: str) -> Ed25519PublicKey:
    with open(path, "rb") as f:
        data = f.read()
    # Support both PEM and raw-base64 (32-byte) public keys
    try:
        return serialization.load_pem_public_key(data)
    except Exception:
        raw = base64.b64decode(data.strip())
        return Ed25519PublicKey.from_public_bytes(raw)


# ---------------------------------------------------------------------------
# Commands
# ---------------------------------------------------------------------------

def cmd_generate_keypair(args):
    output_dir = args.output_dir or "."
    os.makedirs(output_dir, exist_ok=True)

    private_key = Ed25519PrivateKey.generate()

    # Save private key PEM
    priv_path = os.path.join(output_dir, "private.pem")
    with open(priv_path, "wb") as f:
        f.write(
            private_key.private_bytes(
                encoding=serialization.Encoding.PEM,
                format=serialization.PrivateFormat.PKCS8,
                encryption_algorithm=serialization.NoEncryption(),
            )
        )
    os.chmod(priv_path, 0o600)

    # Save public key PEM
    public_key = private_key.public_key()
    pub_path = os.path.join(output_dir, "public.pem")
    with open(pub_path, "wb") as f:
        f.write(
            public_key.public_bytes(
                encoding=serialization.Encoding.PEM,
                format=serialization.PublicFormat.SubjectPublicKeyInfo,
            )
        )

    # Print raw 32-byte public key as standard base64 (for Swift embedding)
    raw_pub = public_key.public_bytes(
        encoding=serialization.Encoding.Raw,
        format=serialization.PublicFormat.Raw,
    )
    pub_b64 = base64.b64encode(raw_pub).decode("ascii")

    print(f"Private key saved to: {priv_path}")
    print(f"Public key saved to:  {pub_path}")
    print(f"Public key (base64, 32 bytes — embed in Swift):\n  {pub_b64}")


def cmd_generate(args):
    private_key = load_private_key(args.private_key)

    now = int(time.time())
    if args.perpetual:
        exp = 0
    else:
        exp = now + args.duration * 86400

    payload = {
        "lid": str(uuid.uuid4()),
        "iat": now,
        "exp": exp,
        "tier": args.tier,
        "feat": int(args.features),
        "v": 1,
    }

    payload_json = json.dumps(payload, separators=(",", ":"), sort_keys=False).encode("utf-8")
    signature = private_key.sign(payload_json)

    license_key = f"TESS-{b64url_encode(payload_json)}.{b64url_encode(signature)}"

    print(f"License ID:  {payload['lid']}")
    print(f"Tier:        {payload['tier']}")
    if exp == 0:
        print("Expiry:      perpetual")
    else:
        print(f"Expiry:      {exp} ({time.strftime('%Y-%m-%d', time.gmtime(exp))})")
    print(f"Features:    {payload['feat']}")
    print(f"License Key: {license_key}")


def cmd_verify(args):
    public_key = load_public_key(args.public_key)
    key = args.key

    if not key.startswith("TESS-"):
        print("ERROR: Invalid license format (missing TESS- prefix)", file=sys.stderr)
        sys.exit(1)

    body = key[5:]  # strip "TESS-"
    parts = body.rsplit(".", 1)
    if len(parts) != 2:
        print("ERROR: Invalid license format (missing signature)", file=sys.stderr)
        sys.exit(1)

    payload_b64, sig_b64 = parts
    payload_bytes = b64url_decode(payload_b64)
    signature = b64url_decode(sig_b64)

    try:
        public_key.verify(signature, payload_bytes)
    except Exception:
        print("INVALID: Signature verification failed", file=sys.stderr)
        sys.exit(1)

    payload = json.loads(payload_bytes)
    now = int(time.time())
    expired = payload.get("exp", 0) != 0 and payload["exp"] < now

    print("Signature:   VALID")
    print(f"License ID:  {payload['lid']}")
    print(f"Tier:        {payload['tier']}")
    if payload.get("exp", 0) == 0:
        print("Expiry:      perpetual")
    else:
        exp_str = time.strftime("%Y-%m-%d", time.gmtime(payload["exp"]))
        status = " (EXPIRED)" if expired else ""
        print(f"Expiry:      {payload['exp']} ({exp_str}){status}")
    print(f"Features:    {payload.get('feat', 0)}")
    print(f"Version:     {payload.get('v', 1)}")

    if expired:
        sys.exit(2)


def sign_revocation_list(data: dict, private_key: Ed25519PrivateKey) -> str:
    """Sign the revocation list with Ed25519.

    Canonical message: sorted revoked IDs joined by "," + ":" + updated timestamp.
    This must match the verification logic in RevocationChecker.swift.
    """
    sorted_ids = ",".join(sorted(data.get("revoked", [])))
    updated = data.get("updated", "")
    canonical = f"{sorted_ids}:{updated}"
    signature = private_key.sign(canonical.encode("utf-8"))
    return base64.b64encode(signature).decode("ascii")


def validate_license_id(lid: str) -> bool:
    """Validate that a license ID is a valid UUID (prevents comma/colon injection
    in the revocation list canonical format used for signing)."""
    try:
        uuid.UUID(lid)
        return True
    except (ValueError, AttributeError):
        return False


def cmd_revoke(args):
    revoked_file = args.revoked_file or "revoked.json"

    if os.path.exists(revoked_file):
        with open(revoked_file, "r") as f:
            data = json.load(f)
    else:
        data = {"revoked": [], "messages": {}, "updated": ""}

    # Ensure correct format
    if isinstance(data, list):
        data = {"revoked": data, "messages": {}, "updated": ""}

    lid = args.license_id
    if not validate_license_id(lid):
        print(f"ERROR: Invalid license ID format (must be a valid UUID): {lid}", file=sys.stderr)
        sys.exit(1)

    if lid not in data["revoked"]:
        data["revoked"].append(lid)

    if args.message:
        # Limit message length and strip control characters to prevent injection
        msg = args.message[:500]
        msg = "".join(c for c in msg if c.isprintable() or c == " ")
        data["messages"][lid] = msg

    data["updated"] = time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime())

    # Sign the revocation list if a private key is provided
    if args.private_key:
        private_key = load_private_key(args.private_key)
        data["signature"] = sign_revocation_list(data, private_key)
        print(f"Revocation list signed with Ed25519")
    else:
        # Remove stale signature if no key provided
        data.pop("signature", None)
        print("WARNING: No --private-key provided. Revocation list is UNSIGNED.")
        print("         Clients with signature verification enabled will reject this list.")

    with open(revoked_file, "w") as f:
        json.dump(data, f, indent=2)

    print(f"Revoked license {lid}")
    print(f"Revocation list saved to: {revoked_file}")


def cmd_sign_revocation_list(args):
    """Sign an existing revocation list without adding a new revocation."""
    revoked_file = args.revoked_file or "revoked.json"

    if not os.path.exists(revoked_file):
        print(f"ERROR: Revocation list not found: {revoked_file}", file=sys.stderr)
        sys.exit(1)

    with open(revoked_file, "r") as f:
        data = json.load(f)

    if isinstance(data, list):
        data = {"revoked": data, "messages": {}, "updated": ""}

    if not data.get("updated"):
        data["updated"] = time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime())

    private_key = load_private_key(args.private_key)
    data["signature"] = sign_revocation_list(data, private_key)

    with open(revoked_file, "w") as f:
        json.dump(data, f, indent=2)

    print(f"Revocation list signed ({len(data.get('revoked', []))} entries)")
    print(f"Saved to: {revoked_file}")


def cmd_inspect(args):
    key = args.key

    if not key.startswith("TESS-"):
        print("ERROR: Invalid license format (missing TESS- prefix)", file=sys.stderr)
        sys.exit(1)

    body = key[5:]
    parts = body.rsplit(".", 1)
    if len(parts) != 2:
        print("ERROR: Invalid license format (missing signature)", file=sys.stderr)
        sys.exit(1)

    payload_b64, _ = parts
    payload_bytes = b64url_decode(payload_b64)
    payload = json.loads(payload_bytes)

    print("(Signature not verified — use 'verify' command with public key)")
    print(f"License ID:  {payload['lid']}")
    print(f"Issued At:   {payload['iat']} ({time.strftime('%Y-%m-%d %H:%M:%S UTC', time.gmtime(payload['iat']))})")
    if payload.get("exp", 0) == 0:
        print("Expiry:      perpetual")
    else:
        print(f"Expiry:      {payload['exp']} ({time.strftime('%Y-%m-%d %H:%M:%S UTC', time.gmtime(payload['exp']))})")
    print(f"Tier:        {payload['tier']}")
    print(f"Features:    {payload.get('feat', 0)}")
    print(f"Version:     {payload.get('v', 1)}")
    print(f"\nRaw payload:\n{json.dumps(payload, indent=2)}")


# ---------------------------------------------------------------------------
# CLI
# ---------------------------------------------------------------------------

def main():
    parser = argparse.ArgumentParser(
        prog="tessera_cli",
        description="Tessera License Management CLI",
    )
    subparsers = parser.add_subparsers(dest="command", required=True)

    # -- generate-keypair --
    kp = subparsers.add_parser("generate-keypair", help="Generate a new Ed25519 keypair")
    kp.add_argument("--output-dir", default=".", help="Directory to write keys to (default: current dir)")

    # -- generate --
    gen = subparsers.add_parser("generate", help="Generate a license key")
    gen.add_argument("--private-key", required=True, help="Path to Ed25519 private key PEM")
    gen.add_argument("--tier", required=True, choices=["personal", "pro", "team"], help="License tier")
    gen.add_argument("--duration", type=int, default=365, help="Duration in days (ignored if --perpetual)")
    gen.add_argument("--perpetual", action="store_true", help="Generate a perpetual (non-expiring) license")
    gen.add_argument("--features", default="0", help="Feature flags as integer (default: 0)")

    # -- verify --
    ver = subparsers.add_parser("verify", help="Verify a license key")
    ver.add_argument("--public-key", required=True, help="Path to Ed25519 public key")
    ver.add_argument("--key", required=True, help="License key string (TESS-...)")

    # -- revoke --
    rev = subparsers.add_parser("revoke", help="Add a license to the revocation list")
    rev.add_argument("--license-id", required=True, help="License UUID to revoke")
    rev.add_argument("--message", default="", help="Reason for revocation")
    rev.add_argument("--revoked-file", default="revoked.json", help="Path to revocation list JSON")
    rev.add_argument("--private-key", default=None, help="Path to Ed25519 private key PEM (signs the revocation list)")

    # -- sign-revocation-list --
    srl = subparsers.add_parser("sign-revocation-list", help="Sign an existing revocation list")
    srl.add_argument("--private-key", required=True, help="Path to Ed25519 private key PEM")
    srl.add_argument("--revoked-file", default="revoked.json", help="Path to revocation list JSON")

    # -- inspect --
    ins = subparsers.add_parser("inspect", help="Show license info without verifying signature")
    ins.add_argument("--key", required=True, help="License key string (TESS-...)")

    args = parser.parse_args()

    commands = {
        "generate-keypair": cmd_generate_keypair,
        "generate": cmd_generate,
        "verify": cmd_verify,
        "revoke": cmd_revoke,
        "sign-revocation-list": cmd_sign_revocation_list,
        "inspect": cmd_inspect,
    }
    commands[args.command](args)


if __name__ == "__main__":
    main()
