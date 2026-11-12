#!/usr/bin/env python3
"""Transfer a test image to one runner without publishing its plaintext.

Only the runner owns the ephemeral RSA private key. Workflow inputs/artifacts
contain authenticated ciphertext; image bytes and keys never enter stdout.
"""

import base64
from dataclasses import dataclass
import io
import json
import os
from pathlib import Path
import re
import subprocess
import sys
import time
import zipfile


MAX_PART = 50_000
MAX_PARTS = 8
MAX_PAYLOAD = MAX_PART * MAX_PARTS
MAX_IMAGE = 2_000_000
MAX_ARCHIVE = 5_000_000


class TransferFailure(Exception):
    """Messages describe a stage, never private input or subprocess output."""


@dataclass(frozen=True)
class Settings:
    work: Path
    session: str
    parts: int


def read_settings(environ):
    session = environ.get("IMAGE_SESSION", "")
    raw_parts = environ.get("IMAGE_PARTS", "")
    work = environ.get("IMAGE_WORK_DIRECTORY", "")
    if not re.fullmatch(r"[a-f0-9]{32}", session):
        raise TransferFailure("Invalid image-test session")
    if not re.fullmatch(r"[1-8]", raw_parts):
        raise TransferFailure("Invalid encrypted part count")
    if not work or not Path(work).is_absolute():
        raise TransferFailure("An absolute temporary work directory is required")
    return Settings(Path(work), session, int(raw_parts))


def private_write(path, data):
    descriptor = os.open(path, os.O_WRONLY | os.O_CREAT | os.O_EXCL, 0o600)
    with os.fdopen(descriptor, "wb") as handle:
        handle.write(data)


def prepare(settings):
    from cryptography.hazmat.primitives import serialization
    from cryptography.hazmat.primitives.asymmetric import rsa

    settings.work.mkdir(parents=True, exist_ok=True, mode=0o700)
    key = rsa.generate_private_key(public_exponent=65537, key_size=2048)
    private_write(settings.work / "private.pem", key.private_bytes(
        serialization.Encoding.PEM, serialization.PrivateFormat.PKCS8,
        serialization.NoEncryption()))
    private_write(settings.work / "public.pem", key.public_key().public_bytes(
        serialization.Encoding.PEM, serialization.PublicFormat.SubjectPublicKeyInfo))


def save_part(settings, environ):
    raw_index = environ.get("IMAGE_PART", "")
    payload = environ.get("IMAGE_PAYLOAD", "")
    if not re.fullmatch(r"[0-7]", raw_index) or int(raw_index) >= settings.parts:
        raise TransferFailure("Invalid encrypted part index")
    if not payload or not payload.isascii() or len(payload) > MAX_PART:
        raise TransferFailure("Invalid encrypted part size")
    settings.work.mkdir(parents=True, exist_ok=True, mode=0o700)
    private_write(settings.work / f"part-{int(raw_index):02d}.txt", payload.encode("ascii"))


def read_part_zip(archive, expected_name):
    if len(archive) > MAX_ARCHIVE:
        raise TransferFailure("Encrypted part archive is too large")
    try:
        with zipfile.ZipFile(io.BytesIO(archive)) as zipped:
            entries = zipped.infolist()
            if len(entries) != 1 or entries[0].filename != expected_name or not (1 <= entries[0].file_size <= MAX_PART):
                raise TransferFailure("Unexpected encrypted part archive contents")
            payload = zipped.read(entries[0])
        return payload.decode("ascii")
    except TransferFailure:
        raise
    except Exception:
        raise TransferFailure("Encrypted part archive could not be read") from None


def decrypt_payload(payload, private_pem):
    from cryptography.hazmat.primitives import hashes, serialization
    from cryptography.hazmat.primitives.asymmetric import padding
    from cryptography.hazmat.primitives.ciphers.aead import AESGCM

    if not payload or len(payload) > MAX_PAYLOAD:
        raise TransferFailure("Encrypted image payload is outside its size limit")
    try:
        envelope = json.loads(payload)
        if not isinstance(envelope, dict) or set(envelope) != {"version", "wrapped_key", "nonce", "ciphertext"} or type(envelope["version"]) is not int or envelope["version"] != 1:
            raise ValueError()
        wrapped, nonce, ciphertext = (
            base64.b64decode(envelope[field], validate=True)
            for field in ("wrapped_key", "nonce", "ciphertext"))
        if len(wrapped) != 256 or len(nonce) != 12 or len(ciphertext) < 17:
            raise ValueError()
        private = serialization.load_pem_private_key(private_pem, password=None)
        key = private.decrypt(wrapped, padding.OAEP(
            mgf=padding.MGF1(algorithm=hashes.SHA256()), algorithm=hashes.SHA256(), label=None))
        if len(key) != 32:
            raise ValueError()
        image = AESGCM(key).decrypt(nonce, ciphertext, None)
        if not (1 <= len(image) <= MAX_IMAGE) or not image.startswith(b"\xff\xd8"):
            raise ValueError()
        return image
    except Exception:
        raise TransferFailure("Encrypted image authentication or validation failed") from None


def github_api(path):
    try:
        result = subprocess.run(["gh", "api", path], stdout=subprocess.PIPE,
                                stderr=subprocess.PIPE, timeout=30, check=False)
        if result.returncode or len(result.stdout) > MAX_ARCHIVE:
            raise TransferFailure("Image-test artifact request failed")
        return result.stdout
    except (OSError, subprocess.TimeoutExpired):
        raise TransferFailure("Image-test artifact request failed") from None


def receive(settings, environ):
    repository = environ.get("GITHUB_REPOSITORY", "")
    if not re.fullmatch(r"[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+", repository):
        raise TransferFailure("Invalid image-test repository")
    prefix = f"scanner-image-part-{settings.session}-"
    expected = {prefix + str(index): index for index in range(settings.parts)}
    deadline = time.monotonic() + 300
    parts = {}
    private_path = settings.work / "private.pem"
    try:
        while len(parts) < settings.parts:
            if time.monotonic() >= deadline:
                raise TransferFailure("Timed out waiting for encrypted image parts")
            try:
                response = json.loads(github_api(f"repos/{repository}/actions/artifacts?per_page=100"))
                artifacts = response["artifacts"]
                if not isinstance(artifacts, list) or len(artifacts) > 100:
                    raise ValueError()
            except (ValueError, KeyError, TypeError):
                raise TransferFailure("Image-test artifact listing was invalid") from None
            for artifact in artifacts:
                index = expected.get(artifact.get("name"))
                if index is None or index in parts or artifact.get("expired"):
                    continue
                identifier, size = artifact.get("id"), artifact.get("size_in_bytes")
                if type(identifier) is not int or identifier <= 0 or type(size) is not int or not (1 <= size <= MAX_ARCHIVE):
                    raise TransferFailure("Encrypted part artifact metadata was invalid")
                archive = github_api(f"repos/{repository}/actions/artifacts/{identifier}/zip")
                parts[index] = read_part_zip(archive, f"part-{index:02d}.txt")
            if len(parts) < settings.parts:
                time.sleep(2)
        payload = "".join(parts[index] for index in range(settings.parts)).encode("ascii")
        image = decrypt_payload(payload, private_path.read_bytes())
        private_write(settings.work / "image.jpg", image)
    finally:
        private_path.unlink(missing_ok=True)
        for path in settings.work.glob("part-*.txt"):
            path.unlink(missing_ok=True)


def main():
    try:
        settings = read_settings(os.environ)
        operation = sys.argv[1] if len(sys.argv) == 2 else ""
        if operation == "prepare":
            prepare(settings)
        elif operation == "part":
            save_part(settings, os.environ)
        elif operation == "receive":
            receive(settings, os.environ)
        else:
            raise TransferFailure("Unknown image-test transfer operation")
        print(f"Image-test {operation} completed")
    except TransferFailure as error:
        print(f"Image-test transfer failed: {error}", file=sys.stderr)
        return 1
    except Exception:
        print("Image-test transfer failed without exposing private inputs", file=sys.stderr)
        return 1
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
