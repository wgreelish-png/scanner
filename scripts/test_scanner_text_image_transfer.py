import base64
import importlib.util
import io
import json
import os
from pathlib import Path
import tempfile
import unittest
from unittest.mock import patch
import zipfile

from scanner_text_image_transfer import (MAX_PART, Settings, TransferFailure,
    decrypt_payload, prepare, read_part_zip, read_settings, receive, save_part)


class ScannerTextImageTransferTests(unittest.TestCase):
    def settings(self, directory):
        return Settings(Path(directory), "a" * 32, 2)

    def test_settings_reject_invalid_sessions_and_part_counts(self):
        valid = {"IMAGE_SESSION": "a" * 32, "IMAGE_PARTS": "2", "IMAGE_WORK_DIRECTORY": "/tmp/test"}
        self.assertEqual(read_settings(valid).parts, 2)
        for field, values in (("IMAGE_SESSION", ["../test", "a" * 31, "A" * 32]),
                              ("IMAGE_PARTS", ["0", "9", "2.0"]),
                              ("IMAGE_WORK_DIRECTORY", ["", "relative"])):
            for value in values:
                with self.subTest(field=field, value=value), self.assertRaises(TransferFailure):
                    read_settings(dict(valid, **{field: value}))

    def test_part_bytes_remain_bounded_and_private(self):
        with tempfile.TemporaryDirectory() as directory:
            settings = self.settings(directory)
            save_part(settings, {"IMAGE_PART": "1", "IMAGE_PAYLOAD": "ciphertext"})
            path = settings.work / "part-01.txt"
            self.assertEqual(path.read_text(), "ciphertext")
            self.assertEqual(path.stat().st_mode & 0o777, 0o600)
            for index, value in [("2", "ciphertext"), ("-1", "ciphertext"), ("0", ""),
                                 ("0", "é"), ("0", "x" * (MAX_PART + 1))]:
                with self.assertRaises(TransferFailure):
                    save_part(settings, {"IMAGE_PART": index, "IMAGE_PAYLOAD": value})

    def archive(self, entries):
        buffer = io.BytesIO()
        with zipfile.ZipFile(buffer, "w") as archive:
            for name, value in entries:
                archive.writestr(name, value)
        return buffer.getvalue()

    def test_zip_members_are_read_without_extracting_paths(self):
        self.assertEqual(read_part_zip(self.archive([("part-00.txt", "abc")]), "part-00.txt"), "abc")
        for entries in [[("../part-00.txt", "abc")], [("part-00.txt", "abc"), ("other", "x")],
                        [("part-00.txt", "x" * (MAX_PART + 1))], [("part-00.txt", b"\xff")]]:
            with self.assertRaises(TransferFailure):
                read_part_zip(self.archive(entries), "part-00.txt")

    @unittest.skipUnless(importlib.util.find_spec("cryptography"), "cryptography is installed only for encrypted image tests")
    def test_encrypted_image_round_trip_authentication_and_private_key_cleanup(self):
        from cryptography.hazmat.primitives import hashes, serialization
        from cryptography.hazmat.primitives.asymmetric import padding
        from cryptography.hazmat.primitives.ciphers.aead import AESGCM

        with tempfile.TemporaryDirectory() as directory:
            settings = self.settings(directory)
            prepare(settings)
            private_pem = (settings.work / "private.pem").read_bytes()
            self.assertEqual((settings.work / "private.pem").stat().st_mode & 0o777, 0o600)
            public = serialization.load_pem_public_key((settings.work / "public.pem").read_bytes())
            image = b"\xff\xd8fixture-jpeg"
            key, nonce = os.urandom(32), os.urandom(12)
            envelope = {"version": 1,
                "wrapped_key": base64.b64encode(public.encrypt(key, padding.OAEP(
                    mgf=padding.MGF1(hashes.SHA256()), algorithm=hashes.SHA256(), label=None))).decode(),
                "nonce": base64.b64encode(nonce).decode(),
                "ciphertext": base64.b64encode(AESGCM(key).encrypt(nonce, image, None)).decode()}
            payload = json.dumps(envelope).encode()
            self.assertEqual(decrypt_payload(payload, private_pem), image)
            corrupted = dict(envelope, ciphertext=base64.b64encode(b"x" * 40).decode())
            with self.assertRaises(TransferFailure):
                decrypt_payload(json.dumps(corrupted).encode(), private_pem)
            split = len(payload) // 2
            archives = {1: self.archive([("part-00.txt", payload[:split])]),
                        2: self.archive([("part-01.txt", payload[split:])])}
            listing = {"artifacts": [{"name": f"scanner-image-part-{settings.session}-{index}",
                "id": index + 1, "size_in_bytes": 100, "expired": False} for index in range(2)]}

            def api(path):
                if path.endswith("?per_page=100"):
                    return json.dumps(listing).encode()
                return archives[int(path.split("/")[-2])]

            with patch("scanner_text_image_transfer.github_api", side_effect=api):
                receive(settings, {"GITHUB_REPOSITORY": "owner/repo"})
            self.assertEqual((settings.work / "image.jpg").read_bytes(), image)
            self.assertFalse((settings.work / "private.pem").exists())


if __name__ == "__main__":
    unittest.main()
