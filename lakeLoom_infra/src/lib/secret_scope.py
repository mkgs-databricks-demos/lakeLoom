"""Secret scope provisioning utilities.

Provides functions to store secrets, list keys, manage ACLs, and
read secret values at runtime. Used by platform bootstrap notebooks
to establish the credential contract for the lakeLoom Databricks App
and ZeroBus SDK.
"""

from typing import Optional, Set, Tuple

from databricks.sdk import WorkspaceClient
from databricks.sdk.service.workspace import AclPermission


def put_secret(
    client: WorkspaceClient, scope: str, key: str, value: str
) -> None:
    """Store a string value in the specified secret scope (idempotent)."""
    client.secrets.put_secret(scope=scope, key=key, string_value=value)


def list_secret_keys(client: WorkspaceClient, scope: str) -> Set[str]:
    """Return the set of key names currently stored in a secret scope."""
    return {item.key for item in client.secrets.list_secrets(scope=scope)}


def ensure_scope_read_acl(
    client: WorkspaceClient, scope: str, principal: str
) -> None:
    """Grant READ permission on a secret scope to a principal (idempotent).

    Args:
        client: Authenticated WorkspaceClient instance.
        scope: The secret scope name.
        principal: The principal identifier (SPN application_id or user email).
    """
    client.secrets.put_acl(
        scope=scope, principal=principal, permission=AclPermission.READ
    )


def try_get_secret_value(
    scope: str, key: str
) -> Tuple[Optional[str], Optional[str]]:
    """Attempt to read a secret value using dbutils.

    This function requires a Spark session with dbutils available
    (Databricks notebook or serverless environment).

    Args:
        scope: The secret scope name.
        key: The key to read.

    Returns:
        Tuple of (secret_value_or_None, error_message_or_None).
        Exactly one of the two will be non-None.
    """
    try:
        from pyspark.dbutils import DBUtils
        from pyspark.sql import SparkSession

        spark = (
            SparkSession.getActiveSession()
            or SparkSession.builder.getOrCreate()
        )
        dbutils = DBUtils(spark)
        return dbutils.secrets.get(scope=scope, key=key), None
    except Exception as exc:
        return None, str(exc)
