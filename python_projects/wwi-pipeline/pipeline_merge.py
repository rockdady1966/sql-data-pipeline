import os
import re
from pathlib import Path

import pandas as pd
import pyodbc
from config import CONN_STRING, DB_PASSWORD, DB_USER, SERVER


def _resolve_odbc_driver() -> str:
    """Resolves the SQL Server ODBC driver name safely across environments."""
    configured = os.getenv("DB_ODBC_DRIVER", "").strip()
    if configured:
        return configured

    try:
      installed = pyodbc.drivers()
    except (pyodbc.Error, RuntimeError):
        installed = []

    for candidate in (
        "ODBC Driver 18 for SQL Server",
        "ODBC Driver 17 for SQL Server",
    ):
        if candidate in installed:
            return candidate

    versioned = []
    for drv in installed:
        match = re.fullmatch(r"ODBC Driver (\d+) for SQL Server", drv.strip())
        if match:
            versioned.append((int(match.group(1)), drv.strip()))

    if versioned:
        versioned.sort(key=lambda item: item[0], reverse=True)
        return versioned[0][1]

    return "ODBC Driver 17 for SQL Server"


def build_dw_conn_string(
    server: str = SERVER,
    database: str = "WideWorldImportersDW",
    user: str | None = DB_USER,
    password: str | None = DB_PASSWORD,
    driver: str | None = None,
    trust_server_cert: bool | None = None,
) -> str:
    """Builds a hardened ODBC connection string targeting the data warehouse."""
    if not server or not database:
        raise ValueError("Both 'server' and 'database' must be non-empty.")

    resolved_driver = (driver or _resolve_odbc_driver()).strip()
    clean_driver = resolved_driver.removeprefix("{").removesuffix("}")

    if trust_server_cert is None:
        env_trust = os.getenv("DB_TRUST_SERVER_CERT", "").strip().lower()
        if env_trust in {"1", "true", "yes"}:
            trust_server_cert = True
        elif env_trust in {"0", "false", "no"}:
            trust_server_cert = False
        else:
            trust_server_cert = (
                "Driver 18" in clean_driver or "Driver 19" in clean_driver
            )

    parts = [
        f"DRIVER={{{clean_driver}}}",
        f"SERVER={server}",
        f"DATABASE={database}",
    ]

    if user and password:
        parts.append(f"UID={user}")
        parts.append(f"PWD={password}")
    else:
        parts.append("Trusted_Connection=yes")

    if trust_server_cert:
        parts.append("TrustServerCertificate=yes")

    return ";".join(parts) + ";"


def extract_customers(conn_str: str = CONN_STRING) -> pd.DataFrame:
    """Extracts customer data from WideWorldImporters transactional source."""
    print("--- EXTRACT PHASE: Customers ---")
    query = """
    SELECT
        CustomerID,
        CustomerName,
        PhoneNumber,
        1 AS IsActive
    FROM Sales.Customers;
    """
    try:
        with pyodbc.connect(conn_str) as conn:
            df = pd.read_sql(query, conn)
        print(f"Extracted {len(df)} customer records from source OLTP.")
        return df
    except (pyodbc.Error, ValueError, RuntimeError) as e:
        print(f"Customer extraction failed: {e}")
        return pd.DataFrame()


def transform_and_export(
    df: pd.DataFrame, output_dir: str | Path = "output"
) -> Path | None:
    """Transforms data and writes local staging CSV files."""
    print("--- TRANSFORM & EXPORT PHASE ---")
    if df.empty:
        print("No data to export.")
        return None

    out_path = Path(output_dir)
    out_path.mkdir(parents=True, exist_ok=True)

    cust_path = out_path / "stg_customers.csv"
    df.to_csv(cust_path, index=False)
    print(f"Staged file generated locally: {cust_path}")
    return cust_path


def load_and_merge_dw(df: pd.DataFrame, conn_str: str | None = None) -> None:
    """Truncates DW staging, bulk loads via fast_executemany, and runs merge SP."""
    print("--- LOAD & MERGE PHASE (WideWorldImportersDW) ---")
    if df.empty:
        print("DataFrame is empty. Skipping load.")
        return

    target_conn_str = conn_str or build_dw_conn_string()

    try:
        with pyodbc.connect(target_conn_str) as conn:
            cursor = conn.cursor()
            cursor.fast_executemany = True

            print("Truncating staging table etl.StgCustomers in DW...")
            cursor.execute("TRUNCATE TABLE etl.StgCustomers;")

            print("Bulk loading data into DW staging table...")
            insert_query = """
            INSERT INTO etl.StgCustomers (CustomerID, CustomerName, PhoneNumber, IsActive)
            VALUES (?, ?, ?, ?)
            """
            records = list(df.itertuples(index=False, name=None))
            cursor.executemany(insert_query, records)
            print(f"Successfully staged {len(records)} rows into DW.")

            print("Executing DW merge stored procedure (etl.usp_UpsertCustomers)...")
            cursor.execute("EXEC etl.usp_UpsertCustomers;")
            conn.commit()
            print("Merge procedure executed successfully in WideWorldImportersDW!")

    except (pyodbc.Error, ValueError, RuntimeError) as e:
        print(f"DW Load & Merge failed: {e}")


if __name__ == "__main__":
    raw_customers = extract_customers()
    transform_and_export(raw_customers)
    load_and_merge_dw(raw_customers)
