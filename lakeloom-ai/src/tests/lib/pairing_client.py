"""Reusable iOS pairing test client for lakeLoom test notebooks.

Encapsulates the full QR-pair-auth lifecycle:
  1. SPN token acquisition (Xcode M2M OAuth)
  2. QR code fetch (browser-auth simulation via SPN)
  3. ECDSA P-256 device key generation
  4. Canonical message signing (matches server's buildCanonicalMessage)
  5. Pairing confirm (Layer 0+1+2 auth)
  6. Authenticated request signing for subsequent API calls

Usage:
    import sys
    sys.path.insert(0, '/Workspace/.../lakeloom-ai/src/tests')
    from lib.pairing_client import PairingTestClient

    client = PairingTestClient(
        app_url="https://lakeloom-ai-dev-...",
        workspace_host="https://fevm-hls-fde.cloud.databricks.com",
        xcode_client_id=dbutils.secrets.get(...),
        xcode_client_secret=dbutils.secrets.get(...),
    )
    client.acquire_spn_token()
    session = client.pair_device(
        device_label="My Test Device",
        device_id=str(uuid.uuid4()),
    )

    # Make authenticated requests
    resp = session.get("/api/projects/.../captures")
    resp = session.post("/api/sessions/.../events", json_body={...})
    resp = session.upload("/api/captures/.../audio", file_bytes, extra_fields={...})
"""

from __future__ import annotations

import base64
import hashlib
import json
import time
import uuid
from dataclasses import dataclass, field
from typing import Any

import requests
from cryptography.hazmat.backends import default_backend
from cryptography.hazmat.primitives import hashes, serialization
from cryptography.hazmat.primitives.asymmetric import ec


def _b64url_encode(data: bytes) -> str:
    """Base64url encode without padding (matches iOS/server convention)."""
    return base64.urlsafe_b64encode(data).decode().rstrip('=')


def _sha256_hex(data: bytes) -> str:
    return hashlib.sha256(data).hexdigest()


def _build_multipart_body(
    fields: dict[str, str],
    file_field_name: str,
    filename: str,
    mime_type: str,
    file_bytes: bytes,
) -> tuple[str, bytes]:
    """Build a raw multipart/form-data body.

    Returns (boundary, body_bytes) so we can hash the full body for signing.
    """
    boundary = f'----lakeloom{uuid.uuid4().hex}'
    parts: list[bytes] = []

    for name, value in fields.items():
        parts.append(f'--{boundary}\r\n'.encode())
        parts.append(f'Content-Disposition: form-data; name="{name}"\r\n\r\n'.encode())
        parts.append(str(value).encode())
        parts.append(b'\r\n')

    parts.append(f'--{boundary}\r\n'.encode())
    parts.append(f'Content-Disposition: form-data; name="{file_field_name}"; filename="{filename}"\r\n'.encode())
    parts.append(f'Content-Type: {mime_type}\r\n\r\n'.encode())
    parts.append(file_bytes)
    parts.append(b'\r\n')
    parts.append(f'--{boundary}--\r\n'.encode())

    return boundary, b''.join(parts)


@dataclass
class PairedSession:
    """An authenticated paired session - can sign and make API requests."""

    app_url: str
    spn_token: str
    session_token: str
    paired_session_id: str
    device_id: str | None
    device_label: str
    username: str | None
    _private_key: Any = field(repr=False)

    def sign_request(
        self, method: str, path: str, body: str | bytes | None = None
    ) -> tuple[str, str]:
        """Sign a request using ECDSA P-256. Returns (timestamp, signature_b64url).

        body can be:
          - str: JSON body (encoded to bytes for hashing)
          - bytes: raw body (e.g. multipart) hashed directly
          - None: empty body (sha256 of b'')
        """
        timestamp = str(int(time.time()))
        if isinstance(body, str):
            body_hash = _sha256_hex(body.encode())
        elif isinstance(body, bytes):
            body_hash = _sha256_hex(body)
        else:
            body_hash = _sha256_hex(b'')
        canonical = f"{method}\n{path}\n{timestamp}\n{body_hash}"
        sig_der = self._private_key.sign(canonical.encode(), ec.ECDSA(hashes.SHA256()))
        return timestamp, _b64url_encode(sig_der)

    def _build_headers(
        self, method: str, path: str, body: str | bytes | None = None
    ) -> dict[str, str]:
        """Build full iOS auth headers for a request."""
        timestamp, signature = self.sign_request(method, path, body)
        headers = {
            'Authorization': f'Bearer {self.spn_token}',
            'X-Lakeloom-Session-Token': self.session_token,
            'X-Lakeloom-Timestamp': timestamp,
            'X-Lakeloom-Signature': signature,
        }
        if isinstance(body, str):
            headers['Content-Type'] = 'application/json'
        return headers

    def get(self, path: str, **kwargs) -> requests.Response:
        """Authenticated GET request."""
        headers = self._build_headers('GET', path)
        return requests.get(
            f'{self.app_url}{path}', headers=headers,
            timeout=kwargs.pop('timeout', 15), allow_redirects=False, **kwargs,
        )

    def post(self, path: str, json_body: dict | None = None, **kwargs) -> requests.Response:
        """Authenticated POST request (JSON body)."""
        body_json = json.dumps(json_body, separators=(',', ':'), ensure_ascii=False) if json_body else None
        headers = self._build_headers('POST', path, body_json)
        return requests.post(
            f'{self.app_url}{path}', headers=headers, data=body_json,
            timeout=kwargs.pop('timeout', 30), allow_redirects=False, **kwargs,
        )

    def upload(
        self,
        path: str,
        file_bytes: bytes,
        file_field: str = 'file',
        mime_type: str = 'audio/wav',
        filename: str = 'test.wav',
        extra_fields: dict[str, str] | None = None,
        timeout: int = 60,
    ) -> requests.Response:
        """Authenticated multipart upload (replicates iOS upload flow).

        Builds multipart body manually so we can sign over the full body bytes
        (matching the server's canonical message verification).
        """
        fields = extra_fields or {}
        boundary, body_bytes = _build_multipart_body(
            fields=fields,
            file_field_name=file_field,
            filename=filename,
            mime_type=mime_type,
            file_bytes=file_bytes,
        )
        timestamp, signature = self.sign_request('POST', path, body_bytes)
        headers = {
            'Authorization': f'Bearer {self.spn_token}',
            'Content-Type': f'multipart/form-data; boundary={boundary}',
            'X-Lakeloom-Session-Token': self.session_token,
            'X-Lakeloom-Timestamp': timestamp,
            'X-Lakeloom-Signature': signature,
        }
        return requests.post(
            f'{self.app_url}{path}', headers=headers, data=body_bytes,
            timeout=timeout, allow_redirects=False,
        )


class PairingTestClient:
    """Orchestrates the full QR-pair lifecycle for test notebooks."""

    def __init__(self, app_url: str, workspace_host: str,
                 xcode_client_id: str, xcode_client_secret: str):
        self.app_url = app_url.rstrip('/')
        self.workspace_host = workspace_host.rstrip('/')
        self.xcode_client_id = xcode_client_id
        self.xcode_client_secret = xcode_client_secret
        self.spn_token: str | None = None

    def acquire_spn_token(self) -> str:
        """Acquire an M2M OAuth token from the workspace OIDC endpoint."""
        token_url = f'{self.workspace_host}/oidc/v1/token'
        resp = requests.post(
            token_url,
            data={'grant_type': 'client_credentials', 'scope': 'all-apis'},
            auth=(self.xcode_client_id, self.xcode_client_secret),
            timeout=15,
        )
        resp.raise_for_status()
        self.spn_token = resp.json()['access_token']
        return self.spn_token

    def fetch_qr(self) -> dict:
        """Fetch a QR pairing payload from the app. Requires spn_token."""
        if not self.spn_token:
            raise RuntimeError('Call acquire_spn_token() first')
        resp = requests.get(
            f'{self.app_url}/api/pairing/qr',
            headers={'Authorization': f'Bearer {self.spn_token}'},
            timeout=15, allow_redirects=False,
        )
        if resp.status_code != 200:
            raise RuntimeError(f'QR endpoint returned {resp.status_code}: {resp.text[:300]}')
        return resp.json()

    def pair_device(self, device_label: str = 'Test Device',
                    device_id: str | None = None) -> PairedSession:
        """Execute the full pairing lifecycle and return an authenticated session.

        Steps:
          1. GET /api/pairing/qr -> session token + username
          2. Generate ECDSA P-256 key pair (SPKI DER)
          3. POST /api/pairing/confirm with signed body + device_pubkey + device_id
        """
        if not self.spn_token:
            raise RuntimeError('Call acquire_spn_token() first')

        if device_id is None:
            device_id = str(uuid.uuid4())

        # Step 1: Fetch QR
        qr = self.fetch_qr()
        session_token = qr['session']['token']
        username = qr.get('user', {}).get('user_name') or None

        # Step 2: Generate ECDSA P-256 key pair
        private_key = ec.generate_private_key(ec.SECP256R1(), default_backend())
        pub_spki_der = private_key.public_key().public_bytes(
            serialization.Encoding.DER, serialization.PublicFormat.SubjectPublicKeyInfo,
        )
        device_pubkey_b64url = _b64url_encode(pub_spki_der)

        # Step 3: Confirm pairing
        body = {'device_pubkey': device_pubkey_b64url, 'device_label': device_label, 'device_id': device_id}
        body_json = json.dumps(body, separators=(',', ':'))
        path = '/api/pairing/confirm'

        timestamp = str(int(time.time()))
        body_hash = _sha256_hex(body_json.encode())
        canonical = f"POST\n{path}\n{timestamp}\n{body_hash}"
        sig_der = private_key.sign(canonical.encode(), ec.ECDSA(hashes.SHA256()))
        sig_b64url = _b64url_encode(sig_der)

        resp = requests.post(
            f'{self.app_url}{path}',
            headers={
                'Authorization': f'Bearer {self.spn_token}',
                'Content-Type': 'application/json',
                'X-Lakeloom-Session-Token': session_token,
                'X-Lakeloom-Timestamp': timestamp,
                'X-Lakeloom-Signature': sig_b64url,
            },
            data=body_json, timeout=15, allow_redirects=False,
        )

        if resp.status_code != 200:
            try:
                detail = resp.json().get('detail', resp.text[:300])
            except Exception:
                detail = resp.text[:300]
            raise RuntimeError(f'Pairing confirm failed ({resp.status_code}): {detail}')

        paired_session_id = resp.json().get('paired_session_id')

        return PairedSession(
            app_url=self.app_url,
            spn_token=self.spn_token,
            session_token=session_token,
            paired_session_id=paired_session_id,
            device_id=device_id,
            device_label=device_label,
            username=username,
            _private_key=private_key,
        )
