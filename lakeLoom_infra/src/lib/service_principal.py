"""Service principal lifecycle management.

Provides functions to find or create workspace service principals and
verify OAuth M2M client credentials flow. Used by platform bootstrap
notebooks to establish the shared lakeLoom SPN.
"""

from typing import Tuple

import requests
from databricks.sdk import WorkspaceClient


def get_or_create_service_principal(
    client: WorkspaceClient, display_name: str
) -> Tuple[object, bool]:
    """Find an existing service principal by display name, or create one.

    Handles the race condition where concurrent creates may occur by
    re-checking after a failed create attempt.

    Args:
        client: Authenticated WorkspaceClient instance.
        display_name: The display name for the service principal.

    Returns:
        Tuple of (ServicePrincipal, is_newly_created).
    """
    existing = list(
        client.service_principals.list(filter=f'displayName eq "{display_name}"')
    )
    if existing:
        return existing[0], False

    try:
        created = client.service_principals.create(
            display_name=display_name, active=True
        )
        return created, True
    except Exception:
        # Race condition guard: re-check after failed create
        existing = list(
            client.service_principals.list(
                filter=f'displayName eq "{display_name}"'
            )
        )
        if existing:
            return existing[0], False
        raise


def verify_client_credentials(
    workspace_url: str, client_id: str, client_secret: str
) -> Tuple[bool, int, str]:
    """Verify M2M token flow via OAuth client_credentials grant.

    Calls the workspace OIDC token endpoint with the provided client
    credentials. Use this to confirm that a service principal can
    authenticate successfully.

    Args:
        workspace_url: Full workspace URL (e.g. https://host.cloud.databricks.com).
        client_id: The SPN application_id (OAuth client identifier).
        client_secret: The OAuth client secret.

    Returns:
        Tuple of (success: bool, http_status_code: int, response_preview: str).
    """
    response = requests.post(
        f"{workspace_url}/oidc/v1/token",
        auth=(client_id, client_secret),
        data={"grant_type": "client_credentials", "scope": "all-apis"},
        timeout=30,
    )
    preview = response.text[:500].replace("\n", " ")
    return response.ok, response.status_code, preview
