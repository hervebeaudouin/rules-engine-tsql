/***********************************************************************
    BENCHMARK - COMPARAISON PERFORMANCES MOTEUR DE REGLES
    
    Compare V6.2 (curseurs) vs V6.3 (sans curseurs) vs V6.4 (set-based)
    
    TESTS:
    1. Regles simples (constantes) x100
    2. Regles avec variables x100  
    3. Regles avec dependances (chaine 5 niveaux) x20
    4. Mix realiste x50
************************************************************************/

SET NOCOUNT ON;
GO

PRINT '======================================================================';
PRINT '                    BENCHMARK MOTEUR DE REGLES                       ';
PRINT '======================================================================';
PRINT '';

-- =========================================================================
-- PREPARATION DES DONNEES DE TEST
-- =========================================================================

-- Nettoyer
DELETE FROM dbo.RuleDefinitions WHERE RuleCode LIKE 'BENCH[_]%';
GO

-- Creer 100 regles constantes (niveau 0)
DECLARE @i INT = 1;
WHILE @i <= 100
BEGIN
    INSERT INTO dbo.RuleDefinitions (RuleCode, Expression)
    VALUES ('BENCH_CONST_' + RIGHT('000' + CAST(@i AS VARCHAR), 3), 
            CAST(@i AS VARCHAR) + ' + ' + CAST(@i * 2 AS VARCHAR));
    SET @i += 1;
END
GO

-- Creer 100 regles avec variables (niveau 1)
DECLARE @i INT = 1;
WHILE @i <= 100
BEGIN
    INSERT INTO dbo.RuleDefinitions (RuleCode, Expression)
    VALUES ('BENCH_VAR_' + RIGHT('000' + CAST(@i AS VARCHAR), 3), 
            '{VAR_A} + ' + CAST(@i AS VARCHAR) + ' * {VAR_B}');
    SET @i += 1;
END
GO

-- Creer 20 chaines de 5 niveaux (niveau N)
DECLARE @i INT = 1;
WHILE @i <= 20
BEGIN
    DECLARE @prefix VARCHAR(20) = 'BENCH_CHAIN_' + RIGHT('00' + CAST(@i AS VARCHAR), 2);
    INSERT INTO dbo.RuleDefinitions (RuleCode, Expression) VALUES
        (@prefix + '_L1', '10'),
        (@prefix + '_L2', '{Rule:' + @prefix + '_L1} * 2'),
        (@prefix + '_L3', '{Rule:' + @prefix + '_L2} + 5'),
        (@prefix + '_L4', '{Rule:' + @prefix + '_L3} * 3'),
        (@prefix + '_L5', '{Rule:' + @prefix + '_L4} - 10');
    SET @i += 1;
END
GO

-- Creer 50 regles mixtes
DECLARE @i INT = 1;
WHILE @i <= 50
BEGIN
    INSERT INTO dbo.RuleDefinitions (RuleCode, Expression)
    VALUES ('BENCH_MIX_' + RIGHT('00' + CAST(@i AS VARCHAR), 2), 
            'IIF({VAR_X} > 50, {VAR_A} * 2, {VAR_B} + ' + CAST(@i AS VARCHAR) + ')');
    SET @i += 1;
END
GO

PRINT 'Donnees de test creees:';
PRINT '  - 100 regles constantes (BENCH_CONST_xxx)';
PRINT '  - 100 regles avec variables (BENCH_VAR_xxx)';
PRINT '  - 20 chaines x 5 niveaux (BENCH_CHAIN_xx_Lx)';
PRINT '  - 50 regles mixtes (BENCH_MIX_xx)';
PRINT '';

-- =========================================================================
-- TABLE DES RESULTATS
-- =========================================================================

IF OBJECT_ID('tempdb..#BenchResults') IS NOT NULL DROP TABLE #BenchResults;
CREATE TABLE #BenchResults (
    TestId INT IDENTITY(1,1),
    TestName NVARCHAR(100),
    RuleCount INT,
    DurationMs INT,
    RulesPerSecond DECIMAL(10,2)
);
GO

-- =========================================================================
-- TEST 1: REGLES CONSTANTES (100 regles)
-- =========================================================================
PRINT '-- Test 1: 100 regles constantes --';

DECLARE @Input1 NVARCHAR(MAX);
DECLARE @Output1 NVARCHAR(MAX);
DECLARE @Start1 DATETIME2;

-- Construire JSON avec 100 regles
SET @Input1 = N'{"rules": [' + (
    SELECT STRING_AGG('"BENCH_CONST_' + RIGHT('000' + CAST(n AS VARCHAR), 3) + '"', ',')
    FROM (SELECT TOP 100 ROW_NUMBER() OVER (ORDER BY (SELECT NULL)) AS n FROM sys.objects) x
) + N']}';

SET @Start1 = SYSDATETIME();
EXEC dbo.sp_RunRulesEngine @Input1, @Output1 OUTPUT;

INSERT INTO #BenchResults (TestName, RuleCount, DurationMs, RulesPerSecond)
VALUES ('Constantes x100', 100, JSON_VALUE(@Output1, '$.durationMs'),
        100.0 * 1000 / NULLIF(JSON_VALUE(@Output1, '$.durationMs'), 0));

PRINT '   Duree: ' + JSON_VALUE(@Output1, '$.durationMs') + ' ms';
GO

-- =========================================================================
-- TEST 2: REGLES AVEC VARIABLES (100 regles)
-- =========================================================================
PRINT '-- Test 2: 100 regles avec variables --';

DECLARE @Input2 NVARCHAR(MAX);
DECLARE @Output2 NVARCHAR(MAX);

SET @Input2 = N'{
    "variables": [
        {"key": "VAR_A", "value": "10"},
        {"key": "VAR_B", "value": "5"}
    ],
    "rules": [' + (
    SELECT STRING_AGG('"BENCH_VAR_' + RIGHT('000' + CAST(n AS VARCHAR), 3) + '"', ',')
    FROM (SELECT TOP 100 ROW_NUMBER() OVER (ORDER BY (SELECT NULL)) AS n FROM sys.objects) x
) + N']}';

EXEC dbo.sp_RunRulesEngine @Input2, @Output2 OUTPUT;

INSERT INTO #BenchResults (TestName, RuleCount, DurationMs, RulesPerSecond)
VALUES ('Variables x100', 100, JSON_VALUE(@Output2, '$.durationMs'),
        100.0 * 1000 / NULLIF(JSON_VALUE(@Output2, '$.durationMs'), 0));

PRINT '   Duree: ' + JSON_VALUE(@Output2, '$.durationMs') + ' ms';
GO

-- =========================================================================
-- TEST 3: CHAINES DE DEPENDANCES (20 x 5 niveaux = 100 regles)
-- =========================================================================
PRINT '-- Test 3: 20 chaines de 5 niveaux --';

DECLARE @Input3 NVARCHAR(MAX);
DECLARE @Output3 NVARCHAR(MAX);

-- Demander uniquement les regles de niveau 5 (qui declenchent toute la chaine)
SET @Input3 = N'{"rules": [' + (
    SELECT STRING_AGG('"BENCH_CHAIN_' + RIGHT('00' + CAST(n AS VARCHAR), 2) + '_L5"', ',')
    FROM (SELECT TOP 20 ROW_NUMBER() OVER (ORDER BY (SELECT NULL)) AS n FROM sys.objects) x
) + N']}';

EXEC dbo.sp_RunRulesEngine @Input3, @Output3 OUTPUT;

INSERT INTO #BenchResults (TestName, RuleCount, DurationMs, RulesPerSecond)
VALUES ('Chaines 5 niveaux x20', 20, JSON_VALUE(@Output3, '$.durationMs'),
        20.0 * 1000 / NULLIF(JSON_VALUE(@Output3, '$.durationMs'), 0));

PRINT '   Duree: ' + JSON_VALUE(@Output3, '$.durationMs') + ' ms';
PRINT '   (100 regles evaluees au total via dependances)';
GO

-- =========================================================================
-- TEST 4: MIX REALISTE (50 regles)
-- =========================================================================
PRINT '-- Test 4: 50 regles mixtes --';

DECLARE @Input4 NVARCHAR(MAX);
DECLARE @Output4 NVARCHAR(MAX);

SET @Input4 = N'{
    "variables": [
        {"key": "VAR_X", "value": "75"},
        {"key": "VAR_A", "value": "100"},
        {"key": "VAR_B", "value": "50"}
    ],
    "rules": [' + (
    SELECT STRING_AGG('"BENCH_MIX_' + RIGHT('00' + CAST(n AS VARCHAR), 2) + '"', ',')
    FROM (SELECT TOP 50 ROW_NUMBER() OVER (ORDER BY (SELECT NULL)) AS n FROM sys.objects) x
) + N']}';

EXEC dbo.sp_RunRulesEngine @Input4, @Output4 OUTPUT;

INSERT INTO #BenchResults (TestName, RuleCount, DurationMs, RulesPerSecond)
VALUES ('Mix realiste x50', 50, JSON_VALUE(@Output4, '$.durationMs'),
        50.0 * 1000 / NULLIF(JSON_VALUE(@Output4, '$.durationMs'), 0));

PRINT '   Duree: ' + JSON_VALUE(@Output4, '$.durationMs') + ' ms';
GO

-- =========================================================================
-- TEST 5: CHARGE - 250 regles en un appel
-- =========================================================================
PRINT '-- Test 5: Charge 250 regles --';

DECLARE @Input5 NVARCHAR(MAX);
DECLARE @Output5 NVARCHAR(MAX);

SET @Input5 = N'{
    "variables": [
        {"key": "VAR_A", "value": "10"},
        {"key": "VAR_B", "value": "5"},
        {"key": "VAR_X", "value": "75"}
    ],
    "rules": [' + 
    (SELECT STRING_AGG('"BENCH_CONST_' + RIGHT('000' + CAST(n AS VARCHAR), 3) + '"', ',')
     FROM (SELECT TOP 100 ROW_NUMBER() OVER (ORDER BY (SELECT NULL)) AS n FROM sys.objects) x) + ',' +
    (SELECT STRING_AGG('"BENCH_VAR_' + RIGHT('000' + CAST(n AS VARCHAR), 3) + '"', ',')
     FROM (SELECT TOP 100 ROW_NUMBER() OVER (ORDER BY (SELECT NULL)) AS n FROM sys.objects) x) + ',' +
    (SELECT STRING_AGG('"BENCH_MIX_' + RIGHT('00' + CAST(n AS VARCHAR), 2) + '"', ',')
     FROM (SELECT TOP 50 ROW_NUMBER() OVER (ORDER BY (SELECT NULL)) AS n FROM sys.objects) x) +
N']}';

EXEC dbo.sp_RunRulesEngine @Input5, @Output5 OUTPUT;

INSERT INTO #BenchResults (TestName, RuleCount, DurationMs, RulesPerSecond)
VALUES ('Charge x250', 250, JSON_VALUE(@Output5, '$.durationMs'),
        250.0 * 1000 / NULLIF(JSON_VALUE(@Output5, '$.durationMs'), 0));

PRINT '   Duree: ' + JSON_VALUE(@Output5, '$.durationMs') + ' ms';
GO

-- =========================================================================
-- RAPPORT
-- =========================================================================
PRINT '';
PRINT '======================================================================';
PRINT '                         RESULTATS BENCHMARK                         ';
PRINT '======================================================================';

SELECT 
    TestName AS [Test],
    RuleCount AS [Regles],
    DurationMs AS [Duree (ms)],
    CAST(RulesPerSecond AS INT) AS [Regles/sec]
FROM #BenchResults
ORDER BY TestId;

PRINT '';
PRINT 'TOTAL:';
SELECT 
    SUM(RuleCount) AS [Total Regles],
    SUM(DurationMs) AS [Total ms],
    CAST(SUM(RuleCount) * 1000.0 / NULLIF(SUM(DurationMs), 0) AS INT) AS [Moyenne Regles/sec]
FROM #BenchResults;

-- Nettoyage
DELETE FROM dbo.RuleDefinitions WHERE RuleCode LIKE 'BENCH[_]%';
DROP TABLE #BenchResults;
GO

PRINT '';
PRINT '======================================================================';
PRINT '  Pour comparer, executez ce script apres chaque version du moteur   ';
PRINT '======================================================================';
GO
