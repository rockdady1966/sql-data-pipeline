import pandas as pd


def transform_sales_data(df: pd.DataFrame) -> pd.DataFrame:
    """Transforms raw sales data: cleans nulls and calculates net revenue."""
    if df.empty:
        return pd.DataFrame(columns=["customer_id", "gross_amount", "discount", "net_amount"])
    
    df = df.dropna(subset=["customer_id"]).copy()
    df["discount"] = df["discount"].fillna(0.0)
    df["net_amount"] = df["gross_amount"] - df["discount"]
    return df