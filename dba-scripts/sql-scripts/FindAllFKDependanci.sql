-- Start of Script - FindAllFKDependenciesByTable.sql
/*
Find Table Reference Levels (Refactored)

This script finds table references and ranks them by level in order
to be able to load tables with FK references in the correct order.
Tables can then be loaded one level at a time from lower to higher.
This script also shows all the relationships for each table
by tables it references and by tables that reference it.

Level 0 is the root table (the table specified by parameters).
Level 1+ are tables that reference the root or its children via FK.

Uses sys catalog views directly instead of sp_fkeys for performance.
Handles circular references to prevent infinite loops.

REQUIRED PARAMETERS
@p_schemaname sysname - schema of the target table
@p_tablename sysname - name of the target table
@GetRecordCounts BIT - whether to compute affected record counts

To use GetRecordCounts you will have to customize the criteria
in the #dataset temp table section.
*/

--USE DPAS;
SET NOCOUNT ON;


-- Parameters

DECLARE @p_schemaname sysname = 'sales';
DECLARE @p_tablename sysname = 'customers';
DECLARE @GetRecordCounts BIT = 0;


-- Resolve primary key column for the target table

DECLARE @p_keyname sysname;
DECLARE @p_object_id INT;

SELECT @p_object_id = t.object_id,
       @p_keyname    = c.name
FROM sys.tables AS t
INNER JOIN sys.schemas AS s
    ON s.schema_id = t.schema_id
INNER JOIN sys.indexes AS i
    ON i.object_id = t.object_id
   AND i.is_primary_key = 1
INNER JOIN sys.index_columns AS ic
    ON ic.object_id = i.object_id
   AND ic.index_id = i.index_id
   AND ic.key_ordinal = 1
INNER JOIN sys.columns AS c
    ON c.object_id = ic.object_id
   AND c.column_id = ic.column_id
WHERE t.name COLLATE DATABASE_DEFAULT = @p_tablename COLLATE DATABASE_DEFAULT
  AND s.name COLLATE DATABASE_DEFAULT = @p_schemaname COLLATE DATABASE_DEFAULT;

IF @p_keyname IS NULL
BEGIN
    RAISERROR('Primary key column (key_ordinal = 1) not found for %s.%s.', 16, 1, @p_schemaname, @p_tablename);
    RETURN;
END;


-- Dataset table for optional record count filtering

DROP TABLE IF EXISTS #dataset;
CREATE TABLE #dataset (dataset_ky INT NOT NULL);

-- INSERT INTO #dataset (dataset_ky)
-- SELECT <your key values here>;


-- Build all FK relationships from sys catalog views (replaces sp_fkeys)
-- This single query replaces all iterative sp_fkeys calls

DROP TABLE IF EXISTS #AllFKRelationships;

CREATE TABLE #AllFKRelationships
(
    pk_schema_name     sysname COLLATE DATABASE_DEFAULT NOT NULL,
    pk_table_name      sysname COLLATE DATABASE_DEFAULT NOT NULL,
    pk_column_name     sysname COLLATE DATABASE_DEFAULT NOT NULL,
    fk_schema_name     sysname COLLATE DATABASE_DEFAULT NOT NULL,
    fk_table_name      sysname COLLATE DATABASE_DEFAULT NOT NULL,
    fk_column_name     sysname COLLATE DATABASE_DEFAULT NOT NULL,
    fk_name            sysname COLLATE DATABASE_DEFAULT NOT NULL,
    pk_constraint_name sysname COLLATE DATABASE_DEFAULT NULL,
    is_self_join       AS (CASE WHEN pk_schema_name = fk_schema_name
                                AND pk_table_name = fk_table_name
                                THEN 1 ELSE 0 END)
);

INSERT INTO #AllFKRelationships
(
    pk_schema_name,
    pk_table_name,
    pk_column_name,
    fk_schema_name,
    fk_table_name,
    fk_column_name,
    fk_name,
    pk_constraint_name
)
SELECT s_pk.name    AS pk_schema_name,
       t_pk.name     AS pk_table_name,
       c_pk.name     AS pk_column_name,
       s_fk.name     AS fk_schema_name,
       t_fk.name     AS fk_table_name,
       c_fk.name     AS fk_column_name,
       fk.name       AS fk_name,
       i_pk.name     AS pk_constraint_name
FROM sys.foreign_keys AS fk
INNER JOIN sys.foreign_key_columns AS fkc
    ON fkc.constraint_object_id = fk.object_id
INNER JOIN sys.tables AS t_fk
    ON t_fk.object_id = fk.parent_object_id
INNER JOIN sys.schemas AS s_fk
    ON s_fk.schema_id = t_fk.schema_id
INNER JOIN sys.columns AS c_fk
    ON c_fk.object_id = fkc.parent_object_id
   AND c_fk.column_id = fkc.parent_column_id
INNER JOIN sys.tables AS t_pk
    ON t_pk.object_id = fk.referenced_object_id
INNER JOIN sys.schemas AS s_pk
    ON s_pk.schema_id = t_pk.schema_id
INNER JOIN sys.columns AS c_pk
    ON c_pk.object_id = fkc.referenced_object_id
   AND c_pk.column_id = fkc.referenced_column_id
LEFT JOIN sys.indexes AS i_pk
    ON i_pk.object_id = t_pk.object_id
   AND i_pk.is_primary_key = 1;


-- Build FK tree using recursive CTE with circular reference protection

DROP TABLE IF EXISTS #FKTree;

CREATE TABLE #FKTree
(
    FKTree_ky        INT IDENTITY(1, 1) PRIMARY KEY NOT NULL,
    ParentFKTree_ky  INT NULL,
    PKTABLE_OWNER    sysname COLLATE DATABASE_DEFAULT NULL,
    PKTABLE_NAME     sysname COLLATE DATABASE_DEFAULT NULL,
    PKCOLUMN_NAME    sysname COLLATE DATABASE_DEFAULT NULL,
    FKTABLE_OWNER    sysname COLLATE DATABASE_DEFAULT NOT NULL,
    FKTABLE_NAME     sysname COLLATE DATABASE_DEFAULT NOT NULL,
    FKCOLUMN_NAME    sysname COLLATE DATABASE_DEFAULT NOT NULL,
    FK_LEVEL         SMALLINT NOT NULL,
    FK_NAME          sysname COLLATE DATABASE_DEFAULT NULL,
    PK_NAME          sysname COLLATE DATABASE_DEFAULT NULL,
    FKTABLE_PKCOLUMN sysname COLLATE DATABASE_DEFAULT NULL,
    CntStatement     VARCHAR(MAX) NULL,
    RecordsAffected  BIGINT NULL
);


-- Insert root node (Level 0)
INSERT INTO #FKTree
(
    FKTABLE_OWNER,
    FKTABLE_NAME,
    FKCOLUMN_NAME,
    FK_LEVEL
)
VALUES
(
    @p_schemaname,
    @p_tablename,
    @p_keyname,
    0
);


-- Iterative BFS traversal with visited-set to prevent infinite loops

DROP TABLE IF EXISTS #Visited;

CREATE TABLE #Visited
(
    schema_name sysname COLLATE DATABASE_DEFAULT NOT NULL,
    table_name  sysname COLLATE DATABASE_DEFAULT NOT NULL,
    fk_name     sysname COLLATE DATABASE_DEFAULT NOT NULL,
    PRIMARY KEY (schema_name, table_name, fk_name)
);

DECLARE @FKLevel SMALLINT = 1;
DECLARE @RowsInserted INT = 1;

WHILE @RowsInserted > 0 AND @FKLevel <= 50 -- safety limit to prevent runaway
BEGIN
    -- Insert children of current level's parents (exclude self-joins and already visited)
    INSERT INTO #FKTree
    (
        ParentFKTree_ky,
        PKTABLE_OWNER,
        PKTABLE_NAME,
        PKCOLUMN_NAME,
        FKTABLE_OWNER,
        FKTABLE_NAME,
        FKCOLUMN_NAME,
        FK_LEVEL,
        FK_NAME,
        PK_NAME
    )
    SELECT p.FKTree_ky          AS ParentFKTree_ky,
           r.pk_schema_name     AS PKTABLE_OWNER,
           r.pk_table_name      AS PKTABLE_NAME,
           r.pk_column_name     AS PKCOLUMN_NAME,
           r.fk_schema_name     AS FKTABLE_OWNER,
           r.fk_table_name      AS FKTABLE_NAME,
           r.fk_column_name     AS FKCOLUMN_NAME,
           @FKLevel             AS FK_LEVEL,
           r.fk_name            AS FK_NAME,
           r.pk_constraint_name AS PK_NAME
    FROM #AllFKRelationships AS r
    INNER JOIN #FKTree AS p
        ON p.FKTABLE_OWNER COLLATE DATABASE_DEFAULT = r.pk_schema_name COLLATE DATABASE_DEFAULT
       AND p.FKTABLE_NAME  COLLATE DATABASE_DEFAULT = r.pk_table_name  COLLATE DATABASE_DEFAULT
       AND p.FK_LEVEL      = @FKLevel - 1
    WHERE r.is_self_join = 0 -- exclude self-referencing FKs
      AND NOT EXISTS (
          SELECT 1
          FROM #Visited AS v
          WHERE v.schema_name COLLATE DATABASE_DEFAULT = r.fk_schema_name COLLATE DATABASE_DEFAULT
            AND v.table_name  COLLATE DATABASE_DEFAULT = r.fk_table_name  COLLATE DATABASE_DEFAULT
            AND v.fk_name     COLLATE DATABASE_DEFAULT = r.fk_name        COLLATE DATABASE_DEFAULT
      );

    SET @RowsInserted = @@ROWCOUNT;

    -- Mark newly inserted relationships as visited
    INSERT INTO #Visited (schema_name, table_name, fk_name)
    SELECT DISTINCT
           r.fk_schema_name,
           r.fk_table_name,
           r.fk_name
    FROM #AllFKRelationships AS r
    INNER JOIN #FKTree AS p
        ON p.FKTABLE_OWNER COLLATE DATABASE_DEFAULT = r.pk_schema_name COLLATE DATABASE_DEFAULT
       AND p.FKTABLE_NAME  COLLATE DATABASE_DEFAULT = r.pk_table_name  COLLATE DATABASE_DEFAULT
       AND p.FK_LEVEL      = @FKLevel - 1
    WHERE r.is_self_join = 0
      AND NOT EXISTS (
          SELECT 1
          FROM #Visited AS v
          WHERE v.schema_name COLLATE DATABASE_DEFAULT = r.fk_schema_name COLLATE DATABASE_DEFAULT
            AND v.table_name  COLLATE DATABASE_DEFAULT = r.fk_table_name  COLLATE DATABASE_DEFAULT
            AND v.fk_name     COLLATE DATABASE_DEFAULT = r.fk_name        COLLATE DATABASE_DEFAULT
      );

    SET @FKLevel = @FKLevel + 1;
END;


-- Update FK tree with PK column for all FK tables

UPDATE fkt
SET fkt.FKTABLE_PKCOLUMN = c.name
FROM #FKTree AS fkt
INNER JOIN sys.tables AS t
    ON t.name COLLATE DATABASE_DEFAULT = fkt.FKTABLE_NAME COLLATE DATABASE_DEFAULT
INNER JOIN sys.schemas AS s
    ON s.schema_id = t.schema_id
   AND s.name COLLATE DATABASE_DEFAULT = fkt.FKTABLE_OWNER COLLATE DATABASE_DEFAULT
INNER JOIN sys.indexes AS i
    ON i.object_id = t.object_id
   AND i.is_primary_key = 1
INNER JOIN sys.index_columns AS ic
    ON ic.object_id = i.object_id
   AND ic.index_id = i.index_id
   AND ic.key_ordinal = 1
INNER JOIN sys.columns AS c
    ON c.object_id = ic.object_id
   AND c.column_id = ic.column_id;


-- Collect self-referencing FKs for reporting
-- Only includes self-joins on tables within the discovered FK tree
-- that belong to the target schema

DROP TABLE IF EXISTS #FKSelfJoins;

SELECT r.pk_schema_name AS PKTABLE_OWNER,
       r.pk_table_name  AS PKTABLE_NAME,
       r.pk_column_name AS PARENT_COL_NAME,
       r.fk_column_name AS CHILD_COL_NAME,
       r.fk_name        AS FK_NAME
INTO #FKSelfJoins
FROM #AllFKRelationships AS r
WHERE r.is_self_join = 1
  AND r.pk_schema_name COLLATE DATABASE_DEFAULT = @p_schemaname COLLATE DATABASE_DEFAULT
  AND EXISTS (
      SELECT 1
      FROM #FKTree AS ft
      WHERE ft.FKTABLE_OWNER COLLATE DATABASE_DEFAULT = r.pk_schema_name COLLATE DATABASE_DEFAULT
        AND ft.FKTABLE_NAME  COLLATE DATABASE_DEFAULT = r.pk_table_name  COLLATE DATABASE_DEFAULT
  );

/*****************************************************************************/
/*                      Get all Logical FK's                                 */
/*****************************************************************************/
DROP TABLE IF EXISTS #databases2check;
DROP TABLE IF EXISTS #lfk_table;

CREATE TABLE #databases2check
(
    dbname sysname COLLATE DATABASE_DEFAULT NOT NULL PRIMARY KEY
);

CREATE TABLE #lfk_table
(
    ext_prp_name sysname COLLATE DATABASE_DEFAULT NOT NULL,
    schema_name  sysname COLLATE DATABASE_DEFAULT NOT NULL,
    table_name   sysname COLLATE DATABASE_DEFAULT NOT NULL,
    key_name     sysname COLLATE DATABASE_DEFAULT NOT NULL,
    ref_db       sysname COLLATE DATABASE_DEFAULT NOT NULL,
    ref_schema   sysname COLLATE DATABASE_DEFAULT NOT NULL,
    ref_table    sysname COLLATE DATABASE_DEFAULT NOT NULL,
    ref_key      sysname COLLATE DATABASE_DEFAULT NOT NULL,
    PRIMARY KEY (ext_prp_name, schema_name, table_name, key_name)
);


-- Get all databases to check for logical FKs
INSERT INTO #databases2check (dbname)
SELECT d.name
FROM sys.databases AS d
WHERE d.name LIKE 'DPAS%'
  AND d.name <> 'DPAS_Admin';

DECLARE @databasename sysname;
DECLARE @sql NVARCHAR(MAX);

WHILE EXISTS (SELECT 1 FROM #databases2check)
BEGIN
    SET @databasename = (SELECT TOP (1) dbname FROM #databases2check);

    -- Reconstructed XML shredding for comma-delimited extended property value
    -- (clipped on the right in IMG_4741.jpg; verify exact format if needed)
    SET @sql = N'
WITH lfk_parsed AS
(
    SELECT p.name AS ext_prp_name,
           sch.name AS SchemaName,
           tbl.name AS TableName,
           clns.name AS ColumnName,
           CAST(''<x>'' + REPLACE(CAST(p.value AS NVARCHAR(MAX)), '','', ''</x><x>'') + ''</x>'' AS XML) AS xml_val
    FROM ' + QUOTENAME(@databasename) + N'.sys.tables AS tbl
    INNER JOIN ' + QUOTENAME(@databasename) + N'.sys.schemas AS sch
        ON sch.schema_id = tbl.schema_id
    INNER JOIN ' + QUOTENAME(@databasename) + N'.sys.columns AS clns
        ON clns.object_id = tbl.object_id
    INNER JOIN ' + QUOTENAME(@databasename) + N'.sys.extended_properties AS p
        ON p.major_id = clns.object_id
       AND p.minor_id = clns.column_id
    WHERE p.name LIKE ''lfk%''
),
lfk_data AS
(
    SELECT ext_prp_name,
           SchemaName,
           TableName,
           ColumnName,
           xml_val.value(''(/x)[1]'', ''sysname'') AS ref_db,
           xml_val.value(''(/x)[2]'', ''sysname'') AS ref_schema,
           xml_val.value(''(/x)[3]'', ''sysname'') AS ref_table,
           xml_val.value(''(/x)[4]'', ''sysname'') AS ref_key
    FROM lfk_parsed
)
SELECT lfkd.ext_prp_name,
       lfkd.SchemaName,
       lfkd.TableName,
       lfkd.ColumnName,
       lfkd.ref_db,
       lfkd.ref_schema,
       lfkd.ref_table,
       lfkd.ref_key
FROM lfk_data AS lfkd
WHERE lfkd.ref_table COLLATE DATABASE_DEFAULT = @ref_table COLLATE DATABASE_DEFAULT
  AND lfkd.ref_key   COLLATE DATABASE_DEFAULT = @ref_key   COLLATE DATABASE_DEFAULT;';

    INSERT INTO #lfk_table
    (
        ext_prp_name,
        schema_name,
        table_name,
        key_name,
        ref_db,
        ref_schema,
        ref_table,
        ref_key
    )
    EXEC sp_executesql @sql,
        N'@ref_table sysname, @ref_key sysname',
        @ref_table = @p_tablename,
        @ref_key   = @p_keyname;

    DELETE FROM #databases2check WHERE dbname = @databasename;
END;

/*****************************************************************************/
/* Record Count Section (optional)                                           */
/*****************************************************************************/
IF @GetRecordCounts = 1
BEGIN
    DROP TABLE IF EXISTS #SmallTree;
    DROP TABLE IF EXISTS #Counts;

    CREATE TABLE #SmallTree
    (
        FKTree_ky       INT NOT NULL PRIMARY KEY,
        ParentFKTree_ky INT NULL
    );

    CREATE TABLE #Counts
    (
        FKTree_ky       INT NOT NULL PRIMARY KEY,
        RecordsAffected BIGINT NULL
    );

    DECLARE @FKTree_ky INT;
    DECLARE @FKOwner sysname;
    DECLARE @FKTable sysname;
    DECLARE @FKColumn sysname;
    DECLARE @PKColumn sysname;

    DECLARE curCntQry CURSOR LOCAL FAST_FORWARD FOR
        SELECT FKTree_ky,
               FKTABLE_OWNER,
               FKTABLE_NAME,
               FKCOLUMN_NAME,
               FKTABLE_PKCOLUMN
        FROM #FKTree
        ORDER BY FKTree_ky DESC;

    OPEN curCntQry;
    FETCH NEXT FROM curCntQry
    INTO @FKTree_ky, @FKOwner, @FKTable, @FKColumn, @PKColumn;

    WHILE @@FETCH_STATUS = 0
    BEGIN
        -- Build path from this node to root using recursive CTE
        ;WITH CTE AS
        (
            SELECT a.ParentFKTree_ky,
                   a.FKTree_ky
            FROM #FKTree AS a
            WHERE a.FKTree_ky = @FKTree_ky
            UNION ALL
            SELECT b.ParentFKTree_ky,
                   b.FKTree_ky
            FROM #FKTree AS b
            INNER JOIN CTE AS c
                ON c.ParentFKTree_ky = b.FKTree_ky
            WHERE b.FKTree_ky <> c.FKTree_ky -- prevent infinite recursion
        )
        INSERT INTO #SmallTree (FKTree_ky, ParentFKTree_ky)
        SELECT CTE.FKTree_ky,
               CTE.ParentFKTree_ky
        FROM CTE
        ORDER BY CTE.FKTree_ky;

        -- Build the dynamic SQL join chain
        DECLARE @ssSQL NVARCHAR(MAX) = N'';
        DECLARE @Where VARCHAR(MAX) = N'';
        DECLARE @SMFKTree_ky INT;
        DECLARE @SMParentFKTree_ky INT;

        DECLARE curSmallTree CURSOR LOCAL FAST_FORWARD FOR
            SELECT FKTree_ky, ParentFKTree_ky
            FROM #SmallTree
            ORDER BY FKTree_ky;

        OPEN curSmallTree;
        FETCH NEXT FROM curSmallTree
        INTO @SMFKTree_ky, @SMParentFKTree_ky;

        WHILE @@FETCH_STATUS = 0
        BEGIN
            DECLARE @sOwnername sysname;
            DECLARE @sTablename sysname;
            DECLARE @sColumnname sysname;
            DECLARE @sPKColname sysname;
            DECLARE @sLevel INT;

            SELECT @sOwnername  = FKTABLE_OWNER,
                   @sTablename  = FKTABLE_NAME,
                   @sColumnname = FKCOLUMN_NAME,
                   @sPKColname  = FKTABLE_PKCOLUMN,
                   @sLevel      = FK_LEVEL
            FROM #FKTree
            WHERE FKTree_ky = @SMFKTree_ky;

            IF @sLevel = 0
            BEGIN
                SET @ssSQL = N'FROM ' + QUOTENAME(@sOwnername) + N'.' + QUOTENAME(@sTablename)
                           + N' AS a' + CAST(@sLevel AS VARCHAR(3)) + N' ';
                SET @Where = N' WHERE a0.' + QUOTENAME(@sColumnname)
                           + N' IN (SELECT dataset_ky FROM #dataset)';
            END
            ELSE
            BEGIN
                SELECT @sPKColname = FKTABLE_PKCOLUMN
                FROM #FKTree
                WHERE FKTree_ky = @SMParentFKTree_ky;

                SET @ssSQL = @ssSQL
                           + N'INNER JOIN ' + QUOTENAME(@sOwnername) + N'.' + QUOTENAME(@sTablename)
                           + N' AS a' + CAST(@sLevel AS VARCHAR(3))
                           + N' ON a' + CAST(@sLevel AS VARCHAR(3)) + N'.' + QUOTENAME(@sColumnname)
                           + N' = a' + CAST((@sLevel - 1) AS VARCHAR(3)) + N'.' + QUOTENAME(@sPKColname);
            END;

            FETCH NEXT FROM curSmallTree
            INTO @SMFKTree_ky, @SMParentFKTree_ky;
        END;

        CLOSE curSmallTree;
        DEALLOCATE curSmallTree;
        TRUNCATE TABLE #SmallTree;

        -- Execute count query
        IF LEN(@ssSQL) > 0
        BEGIN
            DECLARE @ssSQLwParam NVARCHAR(MAX) = N'SELECT ' + CAST(@FKTree_ky AS NVARCHAR(10))
                                               + N' AS FKTree_ky, COUNT(1) ' + @ssSQL + @Where;
            PRINT @ssSQLwParam;

            INSERT INTO #Counts (FKTree_ky, RecordsAffected)
            EXEC (@ssSQLwParam);

            UPDATE fkt
            SET fkt.CntStatement    = N'SELECT COUNT(1) ' + @ssSQL + @Where,
                fkt.RecordsAffected = c.RecordsAffected
            FROM #FKTree AS fkt
            INNER JOIN #Counts AS c
                ON c.FKTree_ky = fkt.FKTree_ky;

            TRUNCATE TABLE #Counts;
        END;

        FETCH NEXT FROM curCntQry
        INTO @FKTree_ky, @FKOwner, @FKTable, @FKColumn, @PKColumn;
    END;

    CLOSE curCntQry;
    DEALLOCATE curCntQry;
END;

/*****************************************************************************/
/* Output Results                                                            */
/*****************************************************************************/

-- Main FK Tree
SELECT 'FKTree' AS qryname,
       FKTree_ky,
       ParentFKTree_ky,
       PKTABLE_OWNER,
       PKTABLE_NAME,
       PKCOLUMN_NAME,
       FKTABLE_OWNER,
       FKTABLE_NAME,
       FKCOLUMN_NAME,
       FK_NAME,
       PK_NAME,
       FK_LEVEL,
       FKTABLE_PKCOLUMN,
       CntStatement,
       RecordsAffected,
       N'SELECT COUNT(*) AS ' + QUOTENAME(FKTABLE_NAME + N'_rows')
       + N' FROM ' + QUOTENAME(FKTABLE_OWNER) + N'.' + QUOTENAME(FKTABLE_NAME)
       + N' AS a INNER JOIN ' + QUOTENAME(FKTABLE_OWNER) + N'.' + QUOTENAME(FKTABLE_NAME)
       + N' AS b ON a.' + QUOTENAME(FKCOLUMN_NAME)
       + N' = b.' + QUOTENAME(ISNULL(PKCOLUMN_NAME, @p_keyname))
       + N';' AS SQLRowCnt
FROM #FKTree
ORDER BY FKTree_ky;

-- Self-referencing FKs
SELECT 'FKSelfJoins' AS qryname,
       PKTABLE_OWNER,
       PKTABLE_NAME,
       PARENT_COL_NAME,
       CHILD_COL_NAME,
       FK_NAME
FROM #FKSelfJoins
ORDER BY PKTABLE_OWNER,
         PKTABLE_NAME;

-- Logical FKs
SELECT 'logical FK' AS qryname,
       lfk.ext_prp_name,
       lfk.schema_name,
       lfk.table_name,
       lfk.key_name,
       lfk.ref_db,
       lfk.ref_schema,
       lfk.ref_table,
       lfk.ref_key
FROM #lfk_table AS lfk;

/*****************************************************************************/
/* Self-join nested level counts (optional)                                  */
/*****************************************************************************/
IF @GetRecordCounts = 1
BEGIN
    DROP TABLE IF EXISTS #FKSJrecordCnts;

    CREATE TABLE #FKSJrecordCnts
    (
        FKName         sysname COLLATE DATABASE_DEFAULT,
        TableName      sysname COLLATE DATABASE_DEFAULT,
        maxNestedLevel INT,
        cntNestedLevel INT
    );

    --DECLARE @ssSQL VARCHAR(MAX);
    DECLARE @SJ_OWNER sysname;
    DECLARE @SJ_TABLE sysname;
    DECLARE @SJ_PKCOL sysname;
    DECLARE @SJ_FKCOL sysname;
    DECLARE @SJ_FKNAME sysname;

    DECLARE curSJCnts CURSOR LOCAL FAST_FORWARD FOR
        SELECT PKTABLE_OWNER,
               PKTABLE_NAME,
               PARENT_COL_NAME,
               CHILD_COL_NAME,
               FK_NAME
        FROM #FKSelfJoins;

    OPEN curSJCnts;
    FETCH NEXT FROM curSJCnts
    INTO @SJ_OWNER, @SJ_TABLE, @SJ_PKCOL, @SJ_FKCOL, @SJ_FKNAME;

    WHILE @@FETCH_STATUS = 0
    BEGIN
        SET @ssSQL = '
        ;WITH CTE AS
        (
            -- Anchor: root nodes with no parent
            SELECT t1.' + QUOTENAME(@SJ_PKCOL) + ' AS pk_val,
                   t1.' + QUOTENAME(@SJ_FKCOL) + ' AS fk_val,
                   1 AS nestedlevel
            FROM ' + QUOTENAME(@SJ_OWNER) + '.' + QUOTENAME(@SJ_TABLE) + ' AS t1
            WHERE t1.' + QUOTENAME(@SJ_FKCOL) + ' IS NULL
            UNION ALL
            -- Recursive: children
            SELECT t2.' + QUOTENAME(@SJ_PKCOL) + ',
                   t2.' + QUOTENAME(@SJ_FKCOL) + ',
                   M.nestedlevel + 1
            FROM ' + QUOTENAME(@SJ_OWNER) + '.' + QUOTENAME(@SJ_TABLE) + ' AS t2
            INNER JOIN CTE AS M
                ON t2.' + QUOTENAME(@SJ_FKCOL) + ' = M.pk_val
        )
        SELECT ''' + @SJ_FKNAME + ''',
               ''' + @SJ_OWNER + '.' + @SJ_TABLE + ''',
               MAX(CTE.nestedlevel) AS maxNestedLevel,
               COUNT(*) AS cntNestedLevel
        FROM CTE
        WHERE CTE.nestedlevel > 1
        GROUP BY CTE.nestedlevel
        OPTION (MAXRECURSION 200);';

        INSERT INTO #FKSJrecordCnts (FKName, TableName, maxNestedLevel, cntNestedLevel)
        EXEC (@ssSQL);

        FETCH NEXT FROM curSJCnts
        INTO @SJ_OWNER, @SJ_TABLE, @SJ_PKCOL, @SJ_FKCOL, @SJ_FKNAME;
    END;

    CLOSE curSJCnts;
    DEALLOCATE curSJCnts;

    SELECT FKName,
           TableName,
           MAX(maxNestedLevel) AS maxNestedLevel,
           SUM(cntNestedLevel) AS cntNestedLevel
    FROM #FKSJrecordCnts
    GROUP BY FKName,
             TableName;
END;

/*****************************************************************************/
/* Cleanup                                                                   */
/*****************************************************************************/
DROP TABLE IF EXISTS #AllFKRelationships;
DROP TABLE IF EXISTS #FKSelfJoins;
DROP TABLE IF EXISTS #FKTree;
DROP TABLE IF EXISTS #Visited;
DROP TABLE IF EXISTS #databases2check;
DROP TABLE IF EXISTS #lfk_table;
DROP TABLE IF EXISTS #dataset;
DROP TABLE IF EXISTS #SmallTree;
DROP TABLE IF EXISTS #Counts;
DROP TABLE IF EXISTS #FKSJrecordCnts;