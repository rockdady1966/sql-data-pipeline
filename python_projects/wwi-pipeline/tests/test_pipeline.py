import os
import pandas as pd
import pyodbc
import pytest
import pipeline_merge
from pipeline_merge import (
    build_dw_conn_string,
    load_and_merge_dw,
    transform_and_export,
)

def test_transform_and_export_creates_csv(tmp_path):
    df = pd.DataFrame([
        {"CustomerID": 1, "CustomerName": "Wingtip Toys", "PhoneNumber": "(555) 010-0001", "IsActive": 1},
        {"CustomerID": 2, "CustomerName": "Tailspin Toys", "PhoneNumber": "(555) 010-0002", "IsActive": 1},
    ])

    result_path = transform_and_export(df, output_dir=tmp_path)

    assert result_path is not None
    assert result_path.exists()
    written = pd.read_csv(result_path)
    assert len(written) == 2
    assert list(written.columns) == ["CustomerID", "CustomerName", "PhoneNumber", "IsActive"]


def test_transform_and_export_empty_df(tmp_path):
    empty_df = pd.DataFrame(columns=["CustomerID", "CustomerName", "PhoneNumber", "IsActive"])

    result_path = transform_and_export(empty_df, output_dir=tmp_path)

    assert result_path is None
    assert not (tmp_path / "stg_customers.csv").exists()


@pytest.mark.skipif(not os.getenv("TEST_DW_CONN_STR"), reason="TEST_DW_CONN_STR not set")
def test_load_and_merge_dw_integration():
    conn_str = os.environ["TEST_DW_CONN_STR"]

    df_initial = pd.DataFrame([
        {"CustomerID": 9001, "CustomerName": "Test Co A", "PhoneNumber": "555-1111", "IsActive": 1},
        {"CustomerID": 9002, "CustomerName": "Test Co B", "PhoneNumber": "555-2222", "IsActive": 1},
    ])
    load_and_merge_dw(df_initial, conn_str=conn_str)

    df_delta = pd.DataFrame([
        {"CustomerID": 9001, "CustomerName": "Test Co A Updated", "PhoneNumber": "555-1111", "IsActive": 1},
        {"CustomerID": 9003, "CustomerName": "Test Co C", "PhoneNumber": "555-3333", "IsActive": 1},
    ])
    load_and_merge_dw(df_delta, conn_str=conn_str)

    with pyodbc.connect(conn_str) as conn:
        rows = conn.execute(
            """
            SELECT CustomerID, CustomerName, IsActive
            FROM etl.TargetCustomers
            WHERE CustomerID IN (9001, 9002, 9003)
            ORDER BY CustomerID
            """
        ).fetchall()

    assert [(r.CustomerID, r.CustomerName, r.IsActive) for r in rows] == [
        (9001, "Test Co A Updated", 1),
        (9002, "Test Co B", 0),
        (9003, "Test Co C", 1),
    ]





def test_build_dw_conn_string_env_overrides_and_brace_stripping(monkeypatch):
  monkeypatch.setenv("DB_ODBC_DRIVER", "{ODBC Driver 18 for SQL Server}")
  monkeypatch.setenv("DB_TRUST_SERVER_CERT", "false")

  conn_str = build_dw_conn_string(
      server="192.168.0.133,1433",
      database="WideWorldImportersDW",
      user="svc_etl",
      password="secret_password",
  )

  assert "DRIVER={ODBC Driver 18 for SQL Server};" in conn_str
  assert "DRIVER={{ODBC Driver 18 for SQL Server}};" not in conn_str
  assert "SERVER=192.168.0.133,1433;" in conn_str
  assert "DATABASE=WideWorldImportersDW;" in conn_str
  assert "UID=svc_etl;" in conn_str
  assert "PWD=secret_password;" in conn_str
  assert "TrustServerCertificate=yes;" not in conn_str


def test_build_dw_conn_string_driver_18_defaults_trust_cert(monkeypatch):
  monkeypatch.delenv("DB_ODBC_DRIVER", raising=False)
  monkeypatch.delenv("DB_TRUST_SERVER_CERT", raising=False)
  monkeypatch.setattr(
      pipeline_merge.pyodbc,
      "drivers",
      lambda: ["ODBC Driver 18 for SQL Server"],
  )

  conn_str = build_dw_conn_string(
      server="localhost,1433",
      database="WideWorldImportersDW",
      user="sa",
      password="StrongTestPassword!2026",
  )

  assert "DRIVER={ODBC Driver 18 for SQL Server};" in conn_str
  assert "TrustServerCertificate=yes;" in conn_str


@pytest.mark.parametrize(
    ("trust_arg", "env_val", "expected_present"),
    [
        (True, "false", True),  # Explicit argument wins over env var
        (False, "true", False),  # Explicit argument False wins over env var
        (None, "true", True),  # Env var enables TrustServerCertificate
        (None, "false", False),  # Env var disables TrustServerCertificate
    ],
)
def test_build_dw_conn_string_trust_server_cert_precedence(
    monkeypatch, trust_arg, env_val, expected_present
):
  monkeypatch.setenv("DB_ODBC_DRIVER", "ODBC Driver 17 for SQL Server")
  monkeypatch.setenv("DB_TRUST_SERVER_CERT", env_val)

  conn_str = build_dw_conn_string(
      server="localhost,1433",
      database="WideWorldImportersDW",
      user="sa",
      password="StrongTestPassword!2026",
      trust_server_cert=trust_arg,
  )

  has_cert_flag = "TrustServerCertificate=yes;" in conn_str
  assert has_cert_flag is expected_present