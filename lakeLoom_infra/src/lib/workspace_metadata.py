"""Workspace metadata discovery utilities.

Provides functions to resolve workspace identity and regional infrastructure
endpoints. Used by platform bootstrap notebooks to derive ZeroBus connection
details and store them in the secret scope.
"""

import os
from typing import Optional

from databricks.sdk import WorkspaceClient

# Manual overrides for workspaces whose hostname doesn't encode the region.
WORKSPACE_REGION_OVERRIDES: dict[str, str] = {
    "fevm-hls-fde.cloud.databricks.com": "us-east-1",
}


def get_workspace_id(client: WorkspaceClient) -> Optional[str]:
    """Discover the workspace ID from SDK, environment variables, or config.

    Tries (in order):
      1. WorkspaceClient.get_workspace_id()
      2. DATABRICKS_WORKSPACE_ID env var
      3. WORKSPACE_ID env var
    """
    try:
        workspace_id = client.get_workspace_id()
        if workspace_id:
            return str(workspace_id)
    except Exception:
        pass

    for env_key in ("DATABRICKS_WORKSPACE_ID", "WORKSPACE_ID"):
        value = os.environ.get(env_key, "").strip()
        if value:
            return value

    return None


def get_region(workspace_url: str) -> str:
    """Determine the AWS region for ZeroBus endpoint construction.

    Resolution order:
      1. AWS_REGION / AWS_DEFAULT_REGION env vars
      2. Spark conf spark.databricks.clusterUsageTags.region
      3. WORKSPACE_REGION_OVERRIDES lookup table
      4. Hostname segment parsing (e.g. adb-xxx.2.azuredatabricks.net → 2)

    Raises:
        RuntimeError: If no region can be determined.
    """
    for env_key in ("AWS_REGION", "AWS_DEFAULT_REGION"):
        value = os.environ.get(env_key, "").strip()
        if value:
            return value

    try:
        from pyspark.sql import SparkSession

        spark = SparkSession.getActiveSession() or SparkSession.builder.getOrCreate()
        region = spark.conf.get(
            "spark.databricks.clusterUsageTags.region", ""
        ).strip()
        if region:
            return region
    except Exception:
        pass

    host = workspace_url.replace("https://", "").replace("http://", "").rstrip("/")
    if host in WORKSPACE_REGION_OVERRIDES:
        return WORKSPACE_REGION_OVERRIDES[host]

    parts = host.split(".")
    if len(parts) >= 5 and parts[1] not in {"cloud", "apps"}:
        return parts[1]

    raise RuntimeError(
        "Could not determine the AWS region for ZeroBus endpoint. "
        "Set AWS_REGION, extend WORKSPACE_REGION_OVERRIDES, or run on "
        "compute that exposes spark.databricks.clusterUsageTags.region."
    )


def get_zerobus_endpoint(workspace_id: str, region: str) -> str:
    """Construct the ZeroBus gRPC endpoint URL from workspace ID and region."""
    return f"https://{workspace_id}.zerobus.{region}.cloud.databricks.com"
