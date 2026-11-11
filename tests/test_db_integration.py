import pytest
import pandas as pd
from sqlalchemy import text
from testcontainers.postgres import PostgresContainer
from pipeline.db import get_db_engine

@pytest.fixture(scope="module")
def postgres_engine():
    with PostgresContainer("postgres:16-alpine") as postgres:
        engine = get_db_engine(postgres.get_connection_url())
        yield engine

def test_database_table_creation(postgres_engine):
    with postgres_engine.connect() as conn:
        conn.execute(text("CREATE TABLE test_runs (id INT, status VARCHAR(20));"))
        conn.execute(text("INSERT INTO test_runs VALUES (1, 'SUCCESS');"))
        conn.commit()
        
        res = conn.execute(text("SELECT status FROM test_runs WHERE id = 1;")).scalar()
        assert res == "SUCCESS"