# ERD e-commerce Documentation

## T-SQL Implementation DDL

```sql
CREATE TABLE Categories (
    Category_ID INT IDENTITY(1,1) PRIMARY KEY,
    Category_name VARCHAR(100) NOT NULL,
    Category_type VARCHAR(50) NULL
);

CREATE TABLE Products (
    Product_ID INT IDENTITY(1,1) PRIMARY KEY,
    Product_name VARCHAR(150) NOT NULL,
    Category_ID INT NOT NULL,
    CONSTRAINT FK_Products_Categories FOREIGN KEY (Category_ID)
        REFERENCES Categories(Category_ID)
);

CREATE TABLE Customer (
    Customer_ID INT IDENTITY(1,1) PRIMARY KEY,
    Name VARCHAR(100) NOT NULL,
    Email VARCHAR(255) NOT NULL UNIQUE,
    Adress VARCHAR(255) NULL
);

CREATE TABLE Delivery (
    Delivery_ID INT IDENTITY(1,1) PRIMARY KEY,
    Type VARCHAR(50) NOT NULL,
    Status VARCHAR(50) NOT NULL
);

CREATE TABLE [Order] (
    Order_ID INT IDENTITY(1,1) PRIMARY KEY,
    Order_date DATETIME2 DEFAULT GETDATE(),
    Delivery_ID INT NOT NULL,
    Customer_ID INT NOT NULL,
    CONSTRAINT FK_Order_Delivery FOREIGN KEY (Delivery_ID)
        REFERENCES Delivery(Delivery_ID),
    CONSTRAINT FK_Order_Customer FOREIGN KEY (Customer_ID)
        REFERENCES Customer(Customer_ID)
);

CREATE TABLE Order_Products (
    Order_ID INT NOT NULL,
    Product_ID INT NOT NULL,
    Quantity INT DEFAULT 1,
    CONSTRAINT PK_Order_Products PRIMARY KEY (Order_ID, Product_ID),
    CONSTRAINT FK_OrderProducts_Order FOREIGN KEY (Order_ID)
        REFERENCES [Order](Order_ID),
    CONSTRAINT FK_OrderProducts_Products FOREIGN KEY (Product_ID)
        REFERENCES Products(Product_ID)
);
```
