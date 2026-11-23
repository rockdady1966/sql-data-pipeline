USE WideWorldImportersDW;
GO

-- 1. Create ETL Schema
IF NOT EXISTS (SELECT * FROM sys.schemas WHERE name = 'etl')
    EXEC('CREATE SCHEMA etl;');
GO

-- 2. Create Target Analytical Table
IF OBJECT_ID('etl.TargetCustomers', 'U') IS NOT NULL
    DROP TABLE etl.TargetCustomers;
GO

CREATE TABLE etl.TargetCustomers (
    CustomerID INT PRIMARY KEY,
    CustomerName NVARCHAR(100),
    PhoneNumber NVARCHAR(20),
    IsActive BIT,
    LastModified DATETIME2 DEFAULT SYSDATETIME()
);
GO

-- 3. Create Staging Table (Truncated & Reloaded every run)
IF OBJECT_ID('etl.StgCustomers', 'U') IS NOT NULL
    DROP TABLE etl.StgCustomers;
GO

CREATE TABLE etl.StgCustomers (
    CustomerID INT PRIMARY KEY,
    CustomerName NVARCHAR(100),
    PhoneNumber NVARCHAR(20),
    IsActive BIT
);
GO

-- 4. Create Stored Procedure for UPSERT and DELETE (Full-Sync / Delta reconciliation)
CREATE OR ALTER PROCEDURE etl.usp_UpsertCustomers
AS
BEGIN
    SET NOCOUNT ON;
    
    BEGIN TRANSACTION;
    BEGIN TRY
        -- A. UPSERT: Insert new records & Update modified records
        MERGE INTO etl.TargetCustomers AS tgt
        USING etl.StgCustomers AS src
        ON tgt.CustomerID = src.CustomerID
        WHEN MATCHED AND (
            ISNULL(tgt.CustomerName, '') <> ISNULL(src.CustomerName, '') OR
            ISNULL(tgt.PhoneNumber, '') <> ISNULL(src.PhoneNumber, '') OR
            tgt.IsActive <> src.IsActive
        ) THEN
            UPDATE SET 
                tgt.CustomerName = src.CustomerName,
                tgt.PhoneNumber = src.PhoneNumber,
                tgt.IsActive = src.IsActive,
                tgt.LastModified = SYSDATETIME()
        WHEN NOT MATCHED BY TARGET THEN
            INSERT (CustomerID, CustomerName, PhoneNumber, IsActive, LastModified)
            VALUES (src.CustomerID, src.CustomerName, src.PhoneNumber, src.IsActive, SYSDATETIME());

        -- B. SOFT DELETE: Flag records missing from source as inactive (or perform hard delete)
        UPDATE tgt
        SET tgt.IsActive = 0, 
            tgt.LastModified = SYSDATETIME()
        FROM etl.TargetCustomers tgt
        WHERE NOT EXISTS (SELECT 1 FROM etl.StgCustomers src WHERE src.CustomerID = tgt.CustomerID)
          AND tgt.IsActive = 1;

        COMMIT TRANSACTION;
        PRINT 'Customer DW sync completed successfully.';
    END TRY
    BEGIN CATCH
        IF @@TRANCOUNT > 0
            ROLLBACK TRANSACTION;
        THROW;
    END CATCH
END;
GO