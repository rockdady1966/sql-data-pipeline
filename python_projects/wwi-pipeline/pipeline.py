import pandas as pd
import pyodbc
from config import CONN_STRING

def extract_data():
    """Extracts recent customer orders and lines from WideWorldImporters."""
    print("--- EXTRACT PHASE ---")
    
    query = """
    SELECT TOP 1000
        o.OrderID,
        o.OrderDate,
        o.CustomerID,
        ol.OrderLineID,
        ol.StockItemID,
        ol.Quantity,
        ol.UnitPrice
    FROM Sales.Orders o
    JOIN Sales.OrderLines ol ON o.OrderID = ol.OrderID
    ORDER BY o.OrderDate DESC;
    """
    
    try:
        conn = pyodbc.connect(CONN_STRING)
        print("Connected successfully to SQL Server!")
        # Read directly into a Pandas DataFrame
        df = pd.read_sql(query, conn)
        conn.close()
        print(f"Extracted {len(df)} rows from WideWorldImporters.")
        return df
    except Exception as e:
        print(f"Extraction failed: {e}")
        return pd.DataFrame()

def transform_data(df):
    """Transforms and cleans the extracted dataset."""
    print("--- TRANSFORM PHASE ---")
    if df.empty:
        print("No data to transform.")
        return df

    # 1. Type validation and casting
    df['OrderDate'] = pd.to_datetime(df['OrderDate'])
    df['Quantity'] = df['Quantity'].astype(int)
    df['UnitPrice'] = df['UnitPrice'].astype(float)

    # 2. Add calculated/derived columns (Line Total)
    df['LineTotal'] = df['Quantity'] * df['UnitPrice']

    # 3. Handle missing values (if any exist)
    df = df.fillna({'Quantity': 0, 'UnitPrice': 0.0})

    print(f"Transformation complete. Added 'LineTotal' column. Cleaned shape: {df.shape}")
    return df

def load_data(df):
    """Loads transformed data (can target WideWorldImportersDW staging tables)."""
    print("--- LOAD PHASE ---")
    if df.empty:
        print("No data to load.")
        return

    # For this learning step, we export to a staging CSV and show how it maps 
    # to writing back into a SQL table using fast_executemany.
    output_path = "output/staging_orders.csv"
    df.to_csv(output_path, index=False)
    print(f"Successfully staged transformed data to local file: {output_path}")
    
    # Optional pattern for loading back into SQL Server DW:
    # conn = pyodbc.connect(CONN_STRING)
    # cursor = conn.cursor()
    # cursor.fast_executemany = True
    # # Insert logic loops or executemany statements go here...
    # conn.commit()
    # conn.close()

if __name__ == "__main__":
    raw_data = extract_data()
    clean_data = transform_data(raw_data)
    load_data(clean_data)