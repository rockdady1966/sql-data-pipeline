import pandas as pd

from pipeline.transform import transform_sales_data


def test_transform_sales_data_net_calculation():
    raw_data = pd.DataFrame({
        "customer_id": [101, 102],
        "gross_amount": [100.0, 250.0],
        "discount": [10.0, None]
    })
    
    result = transform_sales_data(raw_data)
    
    assert len(result) == 2
    assert result.loc[0, "net_amount"] == 90.0
    assert result.loc[1, "net_amount"] == 250.0  # None converted to 0.0