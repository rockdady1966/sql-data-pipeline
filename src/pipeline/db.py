import os

from sqlalchemy import create_engine
from sqlalchemy.engine import Engine


def get_db_engine(connection_string: str | None = None) -> Engine:
    conn_str = connection_string or os.getenv(
        "DB_CONNECTION_STRING", "sqlite:///:memory:"
    )
    return create_engine(conn_str)