import argparse
import json
import os
from typing import Optional, Tuple

import requests
from databricks.sdk import WorkspaceClient
from databricks.sdk.service.workspace import AclPermission


parser = argparse.ArgumentParser(description="lakeLoom platform bootstrap")
parser.add_argument("--catalog_use", required=True)
parser.add_argument("--schema_use", required=True)
parser.add_argument("--secret_scope_name", required=True)
parser.add_argument("--client_id_dbs_key", required=True)
parser.add_argument("--client_secret_dbs_key", required=True)
parser.add_argument("--zerobus_stream_pool_size", required=True)
args = parser.parse_args()


def print_header(title: str) -> None:
    print("\n" + "=" * 72)
    print(title)
    print("=" * 72)


def set_task_value(key: str, value: str) -> None:
    try:
        from pyspark.dbutils import DBUtils
        from pyspark.sql import SparkSession

        spark = SparkSession.getActiveSession() or SparkSession.builder.getOrCreate()
        dbutils = DBUtils(spark)
        dbutils.jobs.taskValues.set(key=key, value=value)
        print(f"Set task value {key} = {value}")
    except Exception as exc:
        print(f"Could not set task value {key}: {exc}")


def get_workspace_id(client: WorkspaceClient) -> Optional[str]:
    candidates = []

    try:
        workspace_id = client.get_workspace_id()
        if workspace_id:
            candidates.append(str(workspace_id))
    except Exception:
        pass

    for env_key in ("DATABRICKS_WORKSPACE_ID", "WORKSPACE_ID"):
        value = os.environ.get(env_key, "").strip()
        if value:
            candidates.append(value)

    for candidate in candidates:
        if candidate:
            return candidate
    return None


def get_region(workspace_url: str) -> str:
    for env_key in ("AWS_REGION", "AWS_DEFAULT_REGION"):
        value = os.environ.get(env_key, "").strip()
        if value:
            return value

    try:
        from pyspark.sql import SparkSession

        spark = SparkSession.getActiveSession() or SparkSession.builder.getOrCreate()
        region = spark.conf.get("spark.databricks.clusterUsageTags.region", "").strip()
        if region:
            return region
    except Exception:
        pass

    host = workspace_url.replace("https://", "").replace("http://", "")
    parts = host.split(".")
    if len(parts) >= 5 and parts[1] not in {"cloud", "apps"}:
        return parts[1]

    raise RuntimeError(
        "Could not determine the AWS region needed to construct the ZeroBus endpoint. "
        "Set AWS_REGION or run on compute that exposes spark.databricks.clusterUsageTags.region."
    )


def get_or_create_service_principal(client: WorkspaceClient, display_name: str):
    existing = list(client.service_principals.list(filter=f'displayName eq "{display_name}"'))
    if existing:
        return existing[0], False

    try:
        created = client.service_principals.create(display_name=display_name, active=True)
        return created, True
    except Exception:
        existing = list(client.service_principals.list(filter=f'displayName eq "{display_name}"'))
        if existing:
            return existing[0], False
        raise


def put_secret(client: WorkspaceClient, scope: str, key: str, value: str) -> None:
    client.secrets.put_secret(scope=scope, key=key, string_value=value)


def list_secret_keys(client: WorkspaceClient, scope: str) -> set[str]:
    return {item.key for item in client.secrets.list_secrets(scope=scope)}


def try_get_secret_value(scope: str, key: str) -> Tuple[Optional[str], Optional[str]]:
    try:
        from pyspark.dbutils import DBUtils
        from pyspark.sql import SparkSession

        spark = SparkSession.getActiveSession() or SparkSession.builder.getOrCreate()
        dbutils = DBUtils(spark)
        return dbutils.secrets.get(scope=scope, key=key), None
    except Exception as exc:
        return None, str(exc)


def verify_client_credentials(workspace_url: str, client_id: str, client_secret: str) -> Tuple[bool, int, str]:
    response = requests.post(
        f"{workspace_url}/oidc/v1/token",
        auth=(client_id, client_secret),
        data={"grant_type": "client_credentials", "scope": "all-apis"},
        timeout=30,
    )
    preview = response.text[:500].replace("\n", " ")
    return response.ok, response.status_code, preview


print_header("Input Parameters")
print(f"Catalog:                 {args.catalog_use}")
print(f"Schema:                  {args.schema_use}")
print(f"Secret scope:            {args.secret_scope_name}")
print(f"Client ID key:           {args.client_id_dbs_key}")
print(f"Client secret key:       {args.client_secret_dbs_key}")
print(f"ZeroBus stream pool:     {args.zerobus_stream_pool_size}")

w = WorkspaceClient()
workspace_url = w.config.host.rstrip("/")
workspace_id = get_workspace_id(w)
if not workspace_id:
    raise RuntimeError(
        "Could not determine workspace ID required for ZeroBus endpoint construction. "
        "Set DATABRICKS_WORKSPACE_ID or run on supported Databricks compute."
    )

region = get_region(workspace_url)
zerobus_endpoint = f"https://{workspace_id}.zerobus.{region}.cloud.databricks.com"
target_table_name = f"{args.catalog_use}.{args.schema_use}.transcript_events_raw"
spn_display_name = f"lakeloom-{args.schema_use}"

print_header("Workspace Metadata")
print(f"Workspace URL:           {workspace_url}")
print(f"Workspace ID:            {workspace_id}")
print(f"AWS region:              {region}")
print(f"ZeroBus endpoint:        {zerobus_endpoint}")
print(f"Target table name:       {target_table_name}")

print_header("Service Principal")
spn, is_new_spn = get_or_create_service_principal(w, spn_display_name)
spn_application_id = spn.application_id
print(f"Display name:            {spn_display_name}")
print(f"Application ID:          {spn_application_id}")
print(f"Workspace object ID:     {spn.id}")
print(f"Created this run:        {is_new_spn}")
set_task_value("spn_application_id", spn_application_id)

print_header("Secret Scope Provisioning")
secrets_to_store = {
    args.client_id_dbs_key: spn_application_id,
    "workspace_url": workspace_url,
    "zerobus_endpoint": zerobus_endpoint,
    "target_table_name": target_table_name,
    "zerobus_stream_pool_size": args.zerobus_stream_pool_size,
}

for key, value in secrets_to_store.items():
    put_secret(w, args.secret_scope_name, key, value)
    print(f"Stored {key} = {value}")

existing_keys = list_secret_keys(w, args.secret_scope_name)
credentials_provisioned = args.client_secret_dbs_key in existing_keys
print(f"Available keys:           {sorted(existing_keys)}")
print(
    f"Client secret present:    {'YES' if credentials_provisioned else 'NO — admin action required'}"
)

print_header("Secret Scope ACL")
w.secrets.put_acl(
    scope=args.secret_scope_name,
    principal=spn_application_id,
    permission=AclPermission.READ,
)
print(f"Granted READ on scope '{args.secret_scope_name}' to {spn_application_id}")

m2m_token_verified = False
m2m_verification_status = "skipped"
verification_details = "client_secret not available to this run"
client_secret_value = None
client_secret_read_error = None

if credentials_provisioned:
    client_secret_value, client_secret_read_error = try_get_secret_value(
        args.secret_scope_name,
        args.client_secret_dbs_key,
    )
    if client_secret_value:
        ok, status_code, preview = verify_client_credentials(
            workspace_url=workspace_url,
            client_id=spn_application_id,
            client_secret=client_secret_value,
        )
        m2m_token_verified = ok
        m2m_verification_status = f"http_{status_code}"
        verification_details = preview or "token response had empty body"
        if not ok:
            raise RuntimeError(
                f"OAuth client credentials verification failed with status {status_code}: {preview}"
            )
    else:
        m2m_verification_status = "skipped"
        verification_details = (
            "client_secret exists in the scope but could not be read from this runtime: "
            f"{client_secret_read_error}"
        )

summary = {
    "spn_display_name": spn_display_name,
    "spn_application_id": spn_application_id,
    "spn_workspace_object_id": spn.id,
    "created_this_run": is_new_spn,
    "workspace_url": workspace_url,
    "workspace_id": workspace_id,
    "aws_region": region,
    "zerobus_endpoint": zerobus_endpoint,
    "target_table_name": target_table_name,
    "secret_scope_name": args.secret_scope_name,
    "client_id_dbs_key": args.client_id_dbs_key,
    "client_secret_dbs_key": args.client_secret_dbs_key,
    "client_secret_present": credentials_provisioned,
    "m2m_token_verified": m2m_token_verified,
    "m2m_verification_status": m2m_verification_status,
    "m2m_verification_details": verification_details,
    "next_manual_step": (
        f"Generate and store {args.client_secret_dbs_key} in secret scope {args.secret_scope_name}"
        if not credentials_provisioned
        else "No manual secret provisioning blocked this run."
    ),
}

print_header("Bootstrap Summary")
print(json.dumps(summary, indent=2, sort_keys=True))

if not credentials_provisioned:
    print("\nADMIN ACTION REQUIRED")
    print(f"  1. Generate an OAuth secret for '{spn_display_name}'.")
    print(f"  2. Store it in secret scope '{args.secret_scope_name}' as '{args.client_secret_dbs_key}'.")
    print("  3. Re-run platform_bootstrap to verify the credentials end-to-end.")
