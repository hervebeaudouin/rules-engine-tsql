/***********************************************************************
    TESTS COMPLETS V6.9.5 - SUITE EXHAUSTIVE V3
    =========================================================================
    Conformité: SPEC V1.7.2
    
    CORRECTIONS V3:
    ---------------
    ✅ Distinction claire: référence directe vs pattern
       - Référence directe: {rule:DEEPR_01} (PAS d'échappement)
       - Pattern wildcard: {SUM(rule:RULEARN\_%)} (échappement du _)
    ✅ Self-cycle corrigé (pas d'échappement pour référence directe)
    ✅ Chaîne profonde corrigée
    
    RÈGLE FONDAMENTALE:
    - Si le nom contient % ou * ou ? → c'est un pattern → échapper les _
    - Si le nom est exact → référence directe → PAS d'échappement
************************************************************************/
SET NOCOUNT ON;
GO

PRINT '======================================================================';
PRINT '    TESTS COMPLETS V6.9.5 - SPEC V1.7.2 (V3)';
PRINT '======================================================================';
PRINT 'Date: ' + CONVERT(VARCHAR, GETDATE(), 120);
PRINT '';
GO

-- =========================================================================
-- INFRASTRUCTURE
-- =========================================================================
IF OBJECT_ID('dbo.TestResults','U') IS NOT NULL DROP TABLE dbo.TestResults;
CREATE TABLE dbo.TestResults (
    TestId INT IDENTITY(1,1) PRIMARY KEY,
    Section NVARCHAR(50),
    Category NVARCHAR(50),
    TestName NVARCHAR(200),
    Expected NVARCHAR(MAX),
    Actual NVARCHAR(MAX),
    Passed BIT,
    ErrorMsg NVARCHAR(MAX),
    DurationMs DECIMAL(10,3)
);

IF OBJECT_ID('dbo.BenchmarkResults','U') IS NOT NULL DROP TABLE dbo.BenchmarkResults;
CREATE TABLE dbo.BenchmarkResults (
    BenchId INT IDENTITY(1,1) PRIMARY KEY,
    BenchName NVARCHAR(200),
    Category NVARCHAR(50),
    Complexity NVARCHAR(20),
    AvgMs DECIMAL(10,4),
    MinMs DECIMAL(10,4),
    MaxMs DECIMAL(10,4),
    P50Ms DECIMAL(10,4),
    OpsPerSec DECIMAL(10,2)
);

IF OBJECT_ID('dbo.BenchmarkRuns','U') IS NOT NULL DROP TABLE dbo.BenchmarkRuns;
CREATE TABLE dbo.BenchmarkRuns (RunId INT IDENTITY PRIMARY KEY, BenchName NVARCHAR(200), DurationMs DECIMAL(10,4));
GO

IF OBJECT_ID('dbo.sp_Test','P') IS NOT NULL DROP PROCEDURE dbo.sp_Test;
GO
CREATE PROCEDURE dbo.sp_Test
    @Section NVARCHAR(50), @Category NVARCHAR(50), @TestName NVARCHAR(200),
    @InputJson NVARCHAR(MAX), @RuleCode NVARCHAR(200), @Expected NVARCHAR(MAX),
    @ExpectNull BIT = 0, @ExpectError BIT = 0
AS
BEGIN
    SET NOCOUNT ON;
    DECLARE @Output NVARCHAR(MAX), @Actual NVARCHAR(MAX), @State NVARCHAR(50);
    DECLARE @Start DATETIME2 = SYSDATETIME(), @Passed BIT = 0, @Err NVARCHAR(MAX);
    
    BEGIN TRY
        EXEC dbo.sp_RunRulesEngine @InputJson, @Output OUTPUT;
        SELECT @Actual = JSON_VALUE(r.value, '$.value'), @State = JSON_VALUE(r.value, '$.state')
        FROM OPENJSON(@Output, '$.results') r WHERE JSON_VALUE(r.value, '$.ruleCode') = @RuleCode;
        
        IF @ExpectError = 1 SET @Passed = CASE WHEN @State = 'ERROR' THEN 1 ELSE 0 END;
        ELSE IF @ExpectNull = 1 SET @Passed = CASE WHEN @Actual IS NULL AND @State = 'EVALUATED' THEN 1 ELSE 0 END;
        ELSE SET @Passed = CASE WHEN @Actual = @Expected THEN 1 ELSE 0 END;
        
        IF @Passed = 0 SET @Err = 'Attendu: [' + ISNULL(CASE WHEN @ExpectError=1 THEN 'ERROR' WHEN @ExpectNull=1 THEN 'NULL' ELSE @Expected END, 'NULL') 
                                + '] / Obtenu: [' + ISNULL(@Actual, 'NULL') + '] (State=' + ISNULL(@State,'?') + ')';
    END TRY
    BEGIN CATCH SET @Err = 'EXCEPTION: ' + ERROR_MESSAGE(); END CATCH
    
    INSERT INTO dbo.TestResults (Section, Category, TestName, Expected, Actual, Passed, ErrorMsg, DurationMs)
    VALUES (@Section, @Category, @TestName, CASE WHEN @ExpectError=1 THEN 'ERROR' WHEN @ExpectNull=1 THEN 'NULL' ELSE @Expected END,
            @Actual, @Passed, @Err, DATEDIFF(MICROSECOND, @Start, SYSDATETIME()) / 1000.0);
    
    PRINT CASE WHEN @Passed=1 THEN '  [PASS] ' ELSE '  [FAIL] ' END + @TestName + CASE WHEN @Passed=0 THEN ' -> ' + ISNULL(@Err,'') ELSE '' END;
END;
GO

IF OBJECT_ID('dbo.sp_Benchmark','P') IS NOT NULL DROP PROCEDURE dbo.sp_Benchmark;
GO
CREATE PROCEDURE dbo.sp_Benchmark @BenchName NVARCHAR(200), @Category NVARCHAR(50), @Complexity NVARCHAR(20), @InputJson NVARCHAR(MAX), @Iterations INT = 50
AS
BEGIN
    SET NOCOUNT ON;
    DECLARE @i INT = 1, @Output NVARCHAR(MAX), @Start DATETIME2, @Duration DECIMAL(10,4);
    DECLARE @TotalMs DECIMAL(18,4) = 0, @MinMs DECIMAL(10,4) = 999999, @MaxMs DECIMAL(10,4) = 0;
    
    DELETE FROM dbo.BenchmarkRuns WHERE BenchName = @BenchName;
    WHILE @i <= 5 BEGIN EXEC dbo.sp_RunRulesEngine @InputJson, @Output OUTPUT; SET @i = @i + 1; END -- Warmup
    
    SET @i = 1;
    WHILE @i <= @Iterations
    BEGIN
        SET @Start = SYSDATETIME();
        EXEC dbo.sp_RunRulesEngine @InputJson, @Output OUTPUT;
        SET @Duration = DATEDIFF(MICROSECOND, @Start, SYSDATETIME()) / 1000.0;
        SET @TotalMs = @TotalMs + @Duration;
        IF @Duration < @MinMs SET @MinMs = @Duration;
        IF @Duration > @MaxMs SET @MaxMs = @Duration;
        INSERT INTO dbo.BenchmarkRuns (BenchName, DurationMs) VALUES (@BenchName, @Duration);
        SET @i = @i + 1;
    END
    
    DECLARE @P50 DECIMAL(10,4);
    SELECT @P50 = AVG(DurationMs) FROM (SELECT DurationMs, ROW_NUMBER() OVER (ORDER BY DurationMs) rn, COUNT(*) OVER () cnt FROM dbo.BenchmarkRuns WHERE BenchName = @BenchName) t WHERE rn IN (cnt/2, cnt/2+1);
    
    INSERT INTO dbo.BenchmarkResults (BenchName, Category, Complexity, AvgMs, MinMs, MaxMs, P50Ms, OpsPerSec)
    VALUES (@BenchName, @Category, @Complexity, @TotalMs/@Iterations, @MinMs, @MaxMs, ISNULL(@P50, @TotalMs/@Iterations), CASE WHEN @TotalMs > 0 THEN @Iterations * 1000.0 / @TotalMs ELSE 0 END);
    
    PRINT '  [BENCH] ' + @BenchName + ': ' + CAST(CAST(@TotalMs/@Iterations AS DECIMAL(10,1)) AS VARCHAR) + ' ms';
END;
GO

PRINT 'Infrastructure créée';
PRINT '';
GO

-- =========================================================================
-- NETTOYAGE
-- =========================================================================
DELETE FROM dbo.RuleDefinitions;
GO

-- =========================================================================
-- RÈGLES DE BASE
-- =========================================================================
INSERT INTO dbo.RuleDefinitions (RuleCode, Expression) VALUES 
('CONST_INT_POS', '42'), ('CONST_INT_NEG', '-42'), ('CONST_INT_ZERO', '0'),
('CONST_DEC_POS', '3.14159265359'), ('CONST_DEC_NEG', '-2.71828'), ('CONST_DEC_SMALL', '0.000001'),
('CONST_STR', '''Hello'''), ('CONST_STR_EMPTY', ''''''), ('CONST_STR_SPACE', '''   '''),
('CONST_STR_QUOTE', '''It''''s a test'''), ('CONST_NULL', 'NULL');
GO

INSERT INTO dbo.RuleDefinitions (RuleCode, Expression) VALUES 
('CALC_ADD', '10+5'), ('CALC_SUB', '100-37'), ('CALC_MUL', '7*8'),
('CALC_DIV', '100.0/8'), ('CALC_MOD', '17%5'), ('CALC_NEG', '-(-42)'),
('CALC_COMPLEX1', '(10+5)*2-30/6'), ('CALC_COMPLEX2', '((2+3)*(4+1))/5'),
('CALC_COMPLEX3', '1+2*3-4/2+5%3'), ('CALC_FLOAT', '1.5*2.5+0.25'),
('CALC_CHAIN', '1+2+3+4+5+6+7+8+9+10'), ('CALC_PAREN', '((((1+2)+3)+4)+5)');
GO

INSERT INTO dbo.RuleDefinitions (RuleCode, Expression) VALUES 
('FUNC_ABS', 'ABS(-42)'), ('FUNC_ROUND', 'ROUND(3.14159, 2)'),
('FUNC_CEIL', 'CEILING(3.14)'), ('FUNC_FLOOR', 'FLOOR(3.99)'),
('FUNC_POWER', 'POWER(2, 10)'), ('FUNC_SQRT', 'SQRT(144)'),
('FUNC_LEN', 'LEN(''Hello'')'), ('FUNC_UPPER', 'UPPER(''hello'')'),
('FUNC_LOWER', 'LOWER(''HELLO'')'), ('FUNC_SUBSTR', 'SUBSTRING(''Hello'', 1, 3)'),
('FUNC_REPLACE', 'REPLACE(''Hello'', ''l'', ''L'')'),
('FUNC_COAL', 'COALESCE(NULL, NULL, ''default'')'),
('FUNC_IIF', 'IIF(1>0, ''yes'', ''no'')'),
('FUNC_CASE', 'CASE WHEN 1=1 THEN ''A'' ELSE ''B'' END');
GO

INSERT INTO dbo.RuleDefinitions (RuleCode, Expression) VALUES 
('VAR_SIMPLE', '{XVAR}'), ('VAR_ADD', '{AVAR}+{BVAR}'),
('VAR_MUL', '{AVAR}*{BVAR}'), ('VAR_DIV', '{AVAR}/{BVAR}'),
('VAR_COMPLEX', '({AVAR}+{BVAR})*{CVAR}-{DVAR}/{EVAR}'),
('VAR_MISSING', '{UNKNOWN}'),
('VAR_CASE', 'CASE WHEN {XVAR}>50 THEN ''HIGH'' ELSE ''LOW'' END'),
('VAR_IIF', 'IIF({XVAR}>0, {XVAR}*2, 0)');
GO

INSERT INTO dbo.RuleDefinitions (RuleCode, Expression) VALUES 
('NORM_FR1', '2,5+3,5'), ('NORM_FR2', '10,25*2'),
('NORM_FR3', '{XVAR}+1,5'), ('NORM_FR4', '(2,5+3,5)*2,0');
GO

-- =========================================================================
-- AGRÉGATS (patterns avec \_ pour échapper le underscore)
-- =========================================================================
INSERT INTO dbo.RuleDefinitions (RuleCode, Expression) VALUES 
('TEST_AGG_SUM', '{SUM(AGGNUM\_%)}'), ('TEST_AGG_AVG', '{AVG(AGGNUM\_%)}'),
('TEST_AGG_MIN', '{MIN(AGGNUM\_%)}'), ('TEST_AGG_MAX', '{MAX(AGGNUM\_%)}'),
('TEST_AGG_COUNT', '{COUNT(AGGNUM\_%)}');
GO

INSERT INTO dbo.RuleDefinitions (RuleCode, Expression) VALUES 
('TEST_AGG_FIRST_S', '{FIRST(AGGSTR\_%)}'), ('TEST_AGG_LAST_S', '{LAST(AGGSTR\_%)}'),
('TEST_AGG_FIRST_N', '{FIRST(AGGORD\_%)}'), ('TEST_AGG_LAST_N', '{LAST(AGGORD\_%)}');
GO

INSERT INTO dbo.RuleDefinitions (RuleCode, Expression) VALUES 
('TEST_AGG_SUM_POS', '{SUM_POS(AGGPN\_%)}'), ('TEST_AGG_COUNT_POS', '{COUNT_POS(AGGPN\_%)}'),
('TEST_AGG_FIRST_POS', '{FIRST_POS(AGGPN\_%)}'), ('TEST_AGG_LAST_POS', '{LAST_POS(AGGPN\_%)}'),
('TEST_AGG_SUM_NEG', '{SUM_NEG(AGGPN\_%)}'), ('TEST_AGG_COUNT_NEG', '{COUNT_NEG(AGGPN\_%)}'),
('TEST_AGG_FIRST_NEG', '{FIRST_NEG(AGGPN\_%)}'), ('TEST_AGG_LAST_NEG', '{LAST_NEG(AGGPN\_%)}');
GO

INSERT INTO dbo.RuleDefinitions (RuleCode, Expression) VALUES 
('TEST_AGG_CONCAT', '{CONCAT(AGGCAT\_%)}'), ('TEST_AGG_JSON', '{JSONIFY(AGGJSON\_%)}');
GO

INSERT INTO dbo.RuleDefinitions (RuleCode, Expression) VALUES 
('TEST_EMPTY_SUM', '{SUM(EMPTYVAR\_%)}'), ('TEST_EMPTY_COUNT', '{COUNT(EMPTYVAR\_%)}'),
('TEST_EMPTY_FIRST', '{FIRST(EMPTYVAR\_%)}'), ('TEST_EMPTY_CONCAT', '{CONCAT(EMPTYVAR\_%)}'),
('TEST_EMPTY_JSON', '{JSONIFY(EMPTYVAR\_%)}');
GO

INSERT INTO dbo.RuleDefinitions (RuleCode, Expression) VALUES 
('TEST_NULL_SUM', '{SUM(NULLVAR\_%)}'), ('TEST_NULL_COUNT', '{COUNT(NULLVAR\_%)}'),
('TEST_NULL_AVG', '{AVG(NULLVAR\_%)}'), ('TEST_NULL_FIRST', '{FIRST(NULLVAR\_%)}'),
('TEST_NULL_LAST', '{LAST(NULLVAR\_%)}');
GO

-- =========================================================================
-- SCOPES (patterns avec \_ pour les wildcards)
-- =========================================================================
INSERT INTO dbo.RuleDefinitions (RuleCode, Expression) VALUES 
('SCOPERULE1', '100'), ('SCOPERULE2', '200'), ('SCOPERULE3', '300');
GO

INSERT INTO dbo.RuleDefinitions (RuleCode, Expression) VALUES 
('TEST_SCOPE_VAR', '{SUM(var:SCOPEVAR\_%)}'),
('TEST_SCOPE_RULE', '{SUM(rule:SCOPERULE%)}'),  -- Pattern avec % (pas de _ à échapper)
('TEST_SCOPE_ALL', '{SUM(all:SCOPEVAR\_%)}');
GO

-- =========================================================================
-- WILDCARDS
-- =========================================================================
INSERT INTO dbo.RuleDefinitions (RuleCode, Expression) VALUES 
('TEST_WILD_PCT', '{SUM(WILDVAR\_%)}'),
('TEST_WILD_UNDER', '{COUNT(WILDVAR\_?)}'),
('TEST_WILD_STAR', '{SUM(WILDVAR\_*)}'),
('TEST_WILD_MIX', '{SUM(MIXVAR\_%\_END)}');
GO

-- =========================================================================
-- DÉPENDANCES (références DIRECTES sans échappement)
-- IMPORTANT: {rule:DEP_A} est une référence directe, pas un pattern!
-- =========================================================================
INSERT INTO dbo.RuleDefinitions (RuleCode, Expression) VALUES 
('DEP_A', '10'),
('DEP_B', '{rule:DEP_A}+5'),      -- Référence directe, PAS d'échappement
('DEP_C', '{rule:DEP_B}*2'),
('DEP_D', '{rule:DEP_C}-10'),
('DEP_E', '{rule:DEP_D}/2');
GO

INSERT INTO dbo.RuleDefinitions (RuleCode, Expression) VALUES 
('TREE_L1', '1'), ('TREE_L2', '2'), ('TREE_R1', '3'), ('TREE_R2', '4'),
('TREE_ML', '{rule:TREE_L1}+{rule:TREE_L2}'),   -- Références directes
('TREE_MR', '{rule:TREE_R1}+{rule:TREE_R2}'),
('TREE_ROOT', '{rule:TREE_ML}*{rule:TREE_MR}');
GO

-- Agrégat sur règles: pattern avec \_ car wildcard %
INSERT INTO dbo.RuleDefinitions (RuleCode, Expression) VALUES 
('RULEARN1', '10'), ('RULEARN2', '20'), ('RULEARN3', '30'),
('TEST_RULEAGG_SUM', '{SUM(rule:RULEARN%)}'),      -- Pattern, mais pas de _ à échapper
('TEST_RULEAGG_AVG', '{AVG(rule:RULEARN%)}'),
('TEST_RULEAGG_FIRST', '{FIRST(rule:RULEARN%)}');
GO

-- Self-match: pattern avec wildcard
INSERT INTO dbo.RuleDefinitions (RuleCode, Expression) VALUES 
('SELFM1', '1'), ('SELFM2', '2'), ('SELFM3', '3'),
('SELFMSUM', '{SUM(rule:SELFM%)}');  -- Pattern, SELFMSUM s'exclut lui-même
GO

-- =========================================================================
-- CYCLES (références DIRECTES sans échappement)
-- =========================================================================
INSERT INTO dbo.RuleDefinitions (RuleCode, Expression) VALUES 
('CYCLE_A', '{rule:CYCLE_B}+1'),       -- Référence directe
('CYCLE_B', '{rule:CYCLE_A}+1'),       -- Cycle A↔B
('CYCLESELF', '{rule:CYCLESELF}+1'),   -- Self-cycle (référence directe à soi-même)
('CYCLE3_A', '{rule:CYCLE3_B}'),       -- Cycle triangulaire
('CYCLE3_B', '{rule:CYCLE3_C}'),
('CYCLE3_C', '{rule:CYCLE3_A}');
GO

INSERT INTO dbo.RuleDefinitions (RuleCode, Expression) VALUES 
('ERR_DIV0', '1/0'), ('ERR_CAST', 'CAST(''abc'' AS INT)'), ('ERR_SYNTAX', 'SELECT * FROM');
GO

-- =========================================================================
-- AGRÉGATEUR PAR DÉFAUT V1.7.1 (patterns avec \_ car wildcard)
-- =========================================================================
INSERT INTO dbo.RuleDefinitions (RuleCode, Expression) VALUES 
('TEST_DEF_NUM', '{DEFNUM\_%}'), ('TEST_DEF_TXT', '{DEFTXT\_%}'),
('TEST_DEF_MIX', '{DEFMIX\_%}'), ('TEST_DEF_SINGLE', '{DEFSINGLE}'),
('TEST_DEF_RULE', '{rule:DEFRULE%}'),
('DEFRULE1', '10'), ('DEFRULE2', '20'), ('DEFRULE3', '30');
GO

-- =========================================================================
-- CAS LIMITES
-- =========================================================================
INSERT INTO dbo.RuleDefinitions (RuleCode, Expression) VALUES 
('EDGE_NEST', '((((((1+2)+3)+4)+5)+6)+7)'),
('EDGE_MULTI', '{SUM(EDGENUM\_%)}+{AVG(EDGENUM\_%)}+{COUNT(EDGENUM\_%)}'),
('EDGE_SPACE1', '{ SUM( EDGENUM\_% ) }'),
('EDGE_SPACE2', '{  FIRST  (  EDGESTR\_%  )  }');
GO

DECLARE @RuleCount INT;
SELECT @RuleCount = COUNT(*) FROM dbo.RuleDefinitions;
PRINT 'Règles insérées: ' + CAST(@RuleCount AS VARCHAR);
PRINT '';
GO

-- =========================================================================
-- PARTIE 1: TESTS FONCTIONNELS
-- =========================================================================
PRINT '======================================================================';
PRINT '    PARTIE 1: TESTS FONCTIONNELS';
PRINT '======================================================================';
PRINT '';

PRINT '-- 1.1 Constantes --';
EXEC dbo.sp_Test 'FONC', 'CONST', '1.1.01 Entier positif', '{"rules":["CONST_INT_POS"]}', 'CONST_INT_POS', '42';
EXEC dbo.sp_Test 'FONC', 'CONST', '1.1.02 Entier négatif', '{"rules":["CONST_INT_NEG"]}', 'CONST_INT_NEG', '-42';
EXEC dbo.sp_Test 'FONC', 'CONST', '1.1.03 Zéro', '{"rules":["CONST_INT_ZERO"]}', 'CONST_INT_ZERO', '0';
EXEC dbo.sp_Test 'FONC', 'CONST', '1.1.04 Décimal positif', '{"rules":["CONST_DEC_POS"]}', 'CONST_DEC_POS', '3.14159265359';
EXEC dbo.sp_Test 'FONC', 'CONST', '1.1.05 Décimal négatif', '{"rules":["CONST_DEC_NEG"]}', 'CONST_DEC_NEG', '-2.71828';
EXEC dbo.sp_Test 'FONC', 'CONST', '1.1.06 Décimal petit', '{"rules":["CONST_DEC_SMALL"]}', 'CONST_DEC_SMALL', '0.000001';
EXEC dbo.sp_Test 'FONC', 'CONST', '1.1.07 Chaîne simple', '{"rules":["CONST_STR"]}', 'CONST_STR', 'Hello';
EXEC dbo.sp_Test 'FONC', 'CONST', '1.1.08 Chaîne vide', '{"rules":["CONST_STR_EMPTY"]}', 'CONST_STR_EMPTY', '';
EXEC dbo.sp_Test 'FONC', 'CONST', '1.1.09 Chaîne espaces', '{"rules":["CONST_STR_SPACE"]}', 'CONST_STR_SPACE', '   ';
EXEC dbo.sp_Test 'FONC', 'CONST', '1.1.10 Chaîne quotes', '{"rules":["CONST_STR_QUOTE"]}', 'CONST_STR_QUOTE', 'It''s a test';
EXEC dbo.sp_Test 'FONC', 'CONST', '1.1.11 NULL explicite', '{"rules":["CONST_NULL"]}', 'CONST_NULL', NULL, 1;
PRINT '';

PRINT '-- 1.2 Arithmétique --';
EXEC dbo.sp_Test 'FONC', 'ARITH', '1.2.01 Addition', '{"rules":["CALC_ADD"]}', 'CALC_ADD', '15';
EXEC dbo.sp_Test 'FONC', 'ARITH', '1.2.02 Soustraction', '{"rules":["CALC_SUB"]}', 'CALC_SUB', '63';
EXEC dbo.sp_Test 'FONC', 'ARITH', '1.2.03 Multiplication', '{"rules":["CALC_MUL"]}', 'CALC_MUL', '56';
EXEC dbo.sp_Test 'FONC', 'ARITH', '1.2.04 Division', '{"rules":["CALC_DIV"]}', 'CALC_DIV', '12.5';
EXEC dbo.sp_Test 'FONC', 'ARITH', '1.2.05 Modulo', '{"rules":["CALC_MOD"]}', 'CALC_MOD', '2';
EXEC dbo.sp_Test 'FONC', 'ARITH', '1.2.06 Double négation', '{"rules":["CALC_NEG"]}', 'CALC_NEG', '42';
EXEC dbo.sp_Test 'FONC', 'ARITH', '1.2.07 Complexe 1', '{"rules":["CALC_COMPLEX1"]}', 'CALC_COMPLEX1', '25';
EXEC dbo.sp_Test 'FONC', 'ARITH', '1.2.08 Complexe 2', '{"rules":["CALC_COMPLEX2"]}', 'CALC_COMPLEX2', '5';
EXEC dbo.sp_Test 'FONC', 'ARITH', '1.2.09 Complexe 3', '{"rules":["CALC_COMPLEX3"]}', 'CALC_COMPLEX3', '7';
EXEC dbo.sp_Test 'FONC', 'ARITH', '1.2.10 Float', '{"rules":["CALC_FLOAT"]}', 'CALC_FLOAT', '4';
EXEC dbo.sp_Test 'FONC', 'ARITH', '1.2.11 Chaîne additions', '{"rules":["CALC_CHAIN"]}', 'CALC_CHAIN', '55';
EXEC dbo.sp_Test 'FONC', 'ARITH', '1.2.12 Parenthèses', '{"rules":["CALC_PAREN"]}', 'CALC_PAREN', '15';
PRINT '';

PRINT '-- 1.3 Fonctions SQL --';
EXEC dbo.sp_Test 'FONC', 'FUNC', '1.3.01 ABS', '{"rules":["FUNC_ABS"]}', 'FUNC_ABS', '42';
EXEC dbo.sp_Test 'FONC', 'FUNC', '1.3.02 ROUND', '{"rules":["FUNC_ROUND"]}', 'FUNC_ROUND', '3.14';
EXEC dbo.sp_Test 'FONC', 'FUNC', '1.3.03 CEILING', '{"rules":["FUNC_CEIL"]}', 'FUNC_CEIL', '4';
EXEC dbo.sp_Test 'FONC', 'FUNC', '1.3.04 FLOOR', '{"rules":["FUNC_FLOOR"]}', 'FUNC_FLOOR', '3';
EXEC dbo.sp_Test 'FONC', 'FUNC', '1.3.05 POWER', '{"rules":["FUNC_POWER"]}', 'FUNC_POWER', '1024';
EXEC dbo.sp_Test 'FONC', 'FUNC', '1.3.06 SQRT', '{"rules":["FUNC_SQRT"]}', 'FUNC_SQRT', '12';
EXEC dbo.sp_Test 'FONC', 'FUNC', '1.3.07 LEN', '{"rules":["FUNC_LEN"]}', 'FUNC_LEN', '5';
EXEC dbo.sp_Test 'FONC', 'FUNC', '1.3.08 UPPER', '{"rules":["FUNC_UPPER"]}', 'FUNC_UPPER', 'HELLO';
EXEC dbo.sp_Test 'FONC', 'FUNC', '1.3.09 LOWER', '{"rules":["FUNC_LOWER"]}', 'FUNC_LOWER', 'hello';
EXEC dbo.sp_Test 'FONC', 'FUNC', '1.3.10 SUBSTRING', '{"rules":["FUNC_SUBSTR"]}', 'FUNC_SUBSTR', 'Hel';
EXEC dbo.sp_Test 'FONC', 'FUNC', '1.3.11 REPLACE', '{"rules":["FUNC_REPLACE"]}', 'FUNC_REPLACE', 'HeLLo';
EXEC dbo.sp_Test 'FONC', 'FUNC', '1.3.12 COALESCE', '{"rules":["FUNC_COAL"]}', 'FUNC_COAL', 'default';
EXEC dbo.sp_Test 'FONC', 'FUNC', '1.3.13 IIF', '{"rules":["FUNC_IIF"]}', 'FUNC_IIF', 'yes';
EXEC dbo.sp_Test 'FONC', 'FUNC', '1.3.14 CASE', '{"rules":["FUNC_CASE"]}', 'FUNC_CASE', 'A';
PRINT '';

PRINT '-- 1.4 Variables --';
EXEC dbo.sp_Test 'FONC', 'VAR', '1.4.01 Simple', '{"rules":["VAR_SIMPLE"],"variables":[{"key":"XVAR","value":"42"}]}', 'VAR_SIMPLE', '42';
EXEC dbo.sp_Test 'FONC', 'VAR', '1.4.02 Addition', '{"rules":["VAR_ADD"],"variables":[{"key":"AVAR","value":"10"},{"key":"BVAR","value":"5"}]}', 'VAR_ADD', '15';
EXEC dbo.sp_Test 'FONC', 'VAR', '1.4.03 Multiplication', '{"rules":["VAR_MUL"],"variables":[{"key":"AVAR","value":"7"},{"key":"BVAR","value":"6"}]}', 'VAR_MUL', '42';
EXEC dbo.sp_Test 'FONC', 'VAR', '1.4.04 Division', '{"rules":["VAR_DIV"],"variables":[{"key":"AVAR","value":"100"},{"key":"BVAR","value":"4"}]}', 'VAR_DIV', '25';
EXEC dbo.sp_Test 'FONC', 'VAR', '1.4.05 Complexe', '{"rules":["VAR_COMPLEX"],"variables":[{"key":"AVAR","value":"10"},{"key":"BVAR","value":"5"},{"key":"CVAR","value":"3"},{"key":"DVAR","value":"30"},{"key":"EVAR","value":"2"}]}', 'VAR_COMPLEX', '30';
EXEC dbo.sp_Test 'FONC', 'VAR', '1.4.06 Manquante', '{"rules":["VAR_MISSING"]}', 'VAR_MISSING', NULL, 1;
EXEC dbo.sp_Test 'FONC', 'VAR', '1.4.07 CASE HIGH', '{"rules":["VAR_CASE"],"variables":[{"key":"XVAR","value":"100"}]}', 'VAR_CASE', 'HIGH';
EXEC dbo.sp_Test 'FONC', 'VAR', '1.4.08 CASE LOW', '{"rules":["VAR_CASE"],"variables":[{"key":"XVAR","value":"25"}]}', 'VAR_CASE', 'LOW';
EXEC dbo.sp_Test 'FONC', 'VAR', '1.4.09 IIF positif', '{"rules":["VAR_IIF"],"variables":[{"key":"XVAR","value":"10"}]}', 'VAR_IIF', '20';
EXEC dbo.sp_Test 'FONC', 'VAR', '1.4.10 IIF négatif', '{"rules":["VAR_IIF"],"variables":[{"key":"XVAR","value":"-5"}]}', 'VAR_IIF', '0';
PRINT '';

PRINT '-- 1.5 Normalisation FR --';
EXEC dbo.sp_Test 'FONC', 'NORM', '1.5.01 Virgule add', '{"rules":["NORM_FR1"]}', 'NORM_FR1', '6';
EXEC dbo.sp_Test 'FONC', 'NORM', '1.5.02 Virgule mul', '{"rules":["NORM_FR2"]}', 'NORM_FR2', '20.5';
EXEC dbo.sp_Test 'FONC', 'NORM', '1.5.03 Virgule+var', '{"rules":["NORM_FR3"],"variables":[{"key":"XVAR","value":"10"}]}', 'NORM_FR3', '11.5';
EXEC dbo.sp_Test 'FONC', 'NORM', '1.5.04 Virgule complexe', '{"rules":["NORM_FR4"]}', 'NORM_FR4', '12';
PRINT '';

PRINT '-- 2.1 Agrégats base --';
DECLARE @VA NVARCHAR(MAX) = '{"rules":["TEST_AGG_SUM","TEST_AGG_AVG","TEST_AGG_MIN","TEST_AGG_MAX","TEST_AGG_COUNT"],"variables":[{"key":"AGGNUM_1","value":"10"},{"key":"AGGNUM_2","value":"20"},{"key":"AGGNUM_3","value":"30"},{"key":"AGGNUM_4","value":"40"},{"key":"AGGNUM_5","value":"50"}]}';
EXEC dbo.sp_Test 'FONC', 'AGG', '2.1.01 SUM', @VA, 'TEST_AGG_SUM', '150';
EXEC dbo.sp_Test 'FONC', 'AGG', '2.1.02 AVG', @VA, 'TEST_AGG_AVG', '30';
EXEC dbo.sp_Test 'FONC', 'AGG', '2.1.03 MIN', @VA, 'TEST_AGG_MIN', '10';
EXEC dbo.sp_Test 'FONC', 'AGG', '2.1.04 MAX', @VA, 'TEST_AGG_MAX', '50';
EXEC dbo.sp_Test 'FONC', 'AGG', '2.1.05 COUNT', @VA, 'TEST_AGG_COUNT', '5';
PRINT '';

PRINT '-- 2.2 Agrégats positionnels --';
EXEC dbo.sp_Test 'FONC', 'AGG', '2.2.01 FIRST txt', '{"rules":["TEST_AGG_FIRST_S"],"variables":[{"key":"AGGSTR_1","value":"Alpha"},{"key":"AGGSTR_2","value":"Beta"},{"key":"AGGSTR_3","value":"Gamma"}]}', 'TEST_AGG_FIRST_S', 'Alpha';
EXEC dbo.sp_Test 'FONC', 'AGG', '2.2.02 LAST txt', '{"rules":["TEST_AGG_LAST_S"],"variables":[{"key":"AGGSTR_1","value":"Alpha"},{"key":"AGGSTR_2","value":"Beta"},{"key":"AGGSTR_3","value":"Gamma"}]}', 'TEST_AGG_LAST_S', 'Gamma';
EXEC dbo.sp_Test 'FONC', 'AGG', '2.2.03 FIRST num', '{"rules":["TEST_AGG_FIRST_N"],"variables":[{"key":"AGGORD_1","value":"10"},{"key":"AGGORD_2","value":"20"},{"key":"AGGORD_3","value":"30"}]}', 'TEST_AGG_FIRST_N', '10';
EXEC dbo.sp_Test 'FONC', 'AGG', '2.2.04 LAST num', '{"rules":["TEST_AGG_LAST_N"],"variables":[{"key":"AGGORD_1","value":"10"},{"key":"AGGORD_2","value":"20"},{"key":"AGGORD_3","value":"30"}]}', 'TEST_AGG_LAST_N', '30';
PRINT '';

PRINT '-- 2.3 Agrégats POS/NEG --';
DECLARE @VPN NVARCHAR(MAX) = '{"rules":["TEST_AGG_SUM_POS","TEST_AGG_COUNT_POS","TEST_AGG_FIRST_POS","TEST_AGG_LAST_POS","TEST_AGG_SUM_NEG","TEST_AGG_COUNT_NEG","TEST_AGG_FIRST_NEG","TEST_AGG_LAST_NEG"],"variables":[{"key":"AGGPN_1","value":"-10"},{"key":"AGGPN_2","value":"15"},{"key":"AGGPN_3","value":"-5"},{"key":"AGGPN_4","value":"25"},{"key":"AGGPN_5","value":"30"}]}';
EXEC dbo.sp_Test 'FONC', 'AGG', '2.3.01 SUM_POS', @VPN, 'TEST_AGG_SUM_POS', '70';
EXEC dbo.sp_Test 'FONC', 'AGG', '2.3.02 COUNT_POS', @VPN, 'TEST_AGG_COUNT_POS', '3';
EXEC dbo.sp_Test 'FONC', 'AGG', '2.3.03 FIRST_POS', @VPN, 'TEST_AGG_FIRST_POS', '15';
EXEC dbo.sp_Test 'FONC', 'AGG', '2.3.04 LAST_POS', @VPN, 'TEST_AGG_LAST_POS', '30';
EXEC dbo.sp_Test 'FONC', 'AGG', '2.3.05 SUM_NEG', @VPN, 'TEST_AGG_SUM_NEG', '-15';
EXEC dbo.sp_Test 'FONC', 'AGG', '2.3.06 COUNT_NEG', @VPN, 'TEST_AGG_COUNT_NEG', '2';
EXEC dbo.sp_Test 'FONC', 'AGG', '2.3.07 FIRST_NEG', @VPN, 'TEST_AGG_FIRST_NEG', '-10';
EXEC dbo.sp_Test 'FONC', 'AGG', '2.3.08 LAST_NEG', @VPN, 'TEST_AGG_LAST_NEG', '-5';
PRINT '';

PRINT '-- 2.4 CONCAT/JSONIFY --';
EXEC dbo.sp_Test 'FONC', 'AGG', '2.4.01 CONCAT', '{"rules":["TEST_AGG_CONCAT"],"variables":[{"key":"AGGCAT_1","value":"A"},{"key":"AGGCAT_2","value":"B"},{"key":"AGGCAT_3","value":"C"}]}', 'TEST_AGG_CONCAT', 'ABC';
EXEC dbo.sp_Test 'FONC', 'AGG', '2.4.02 JSONIFY', '{"rules":["TEST_AGG_JSON"],"variables":[{"key":"AGGJSON_A","value":"1"},{"key":"AGGJSON_B","value":"hello"},{"key":"AGGJSON_C","value":"true"}]}', 'TEST_AGG_JSON', '{"AGGJSON_A":1,"AGGJSON_B":"hello","AGGJSON_C":true}';
PRINT '';

PRINT '-- 2.5 Ensemble vide --';
DECLARE @VE NVARCHAR(MAX) = '{"rules":["TEST_EMPTY_SUM","TEST_EMPTY_COUNT","TEST_EMPTY_FIRST","TEST_EMPTY_CONCAT","TEST_EMPTY_JSON"]}';
EXEC dbo.sp_Test 'FONC', 'AGG', '2.5.01 SUM vide', @VE, 'TEST_EMPTY_SUM', NULL, 1;
EXEC dbo.sp_Test 'FONC', 'AGG', '2.5.02 COUNT vide', @VE, 'TEST_EMPTY_COUNT', '0';
EXEC dbo.sp_Test 'FONC', 'AGG', '2.5.03 FIRST vide', @VE, 'TEST_EMPTY_FIRST', NULL, 1;
EXEC dbo.sp_Test 'FONC', 'AGG', '2.5.04 CONCAT vide', @VE, 'TEST_EMPTY_CONCAT', '';
EXEC dbo.sp_Test 'FONC', 'AGG', '2.5.05 JSONIFY vide', @VE, 'TEST_EMPTY_JSON', '{}';
PRINT '';

PRINT '-- 2.6 Gestion NULL --';
DECLARE @VN NVARCHAR(MAX) = '{"rules":["TEST_NULL_SUM","TEST_NULL_COUNT","TEST_NULL_AVG","TEST_NULL_FIRST","TEST_NULL_LAST"],"variables":[{"key":"NULLVAR_1","value":"10"},{"key":"NULLVAR_2","value":null},{"key":"NULLVAR_3","value":"30"},{"key":"NULLVAR_4","value":null},{"key":"NULLVAR_5","value":"50"}]}';
EXEC dbo.sp_Test 'FONC', 'NULL', '2.6.01 SUM ignore NULL', @VN, 'TEST_NULL_SUM', '90';
EXEC dbo.sp_Test 'FONC', 'NULL', '2.6.02 COUNT ignore NULL', @VN, 'TEST_NULL_COUNT', '3';
EXEC dbo.sp_Test 'FONC', 'NULL', '2.6.03 AVG ignore NULL', @VN, 'TEST_NULL_AVG', '30';
EXEC dbo.sp_Test 'FONC', 'NULL', '2.6.04 FIRST ignore NULL', @VN, 'TEST_NULL_FIRST', '10';
EXEC dbo.sp_Test 'FONC', 'NULL', '2.6.05 LAST ignore NULL', @VN, 'TEST_NULL_LAST', '50';
PRINT '';

PRINT '-- 3. Scopes --';
DECLARE @VS NVARCHAR(MAX) = '{"rules":["TEST_SCOPE_VAR","TEST_SCOPE_RULE","TEST_SCOPE_ALL","SCOPERULE1","SCOPERULE2","SCOPERULE3"],"variables":[{"key":"SCOPEVAR_1","value":"10"},{"key":"SCOPEVAR_2","value":"20"}]}';
EXEC dbo.sp_Test 'FONC', 'SCOPE', '3.01 var: only', @VS, 'TEST_SCOPE_VAR', '30';
EXEC dbo.sp_Test 'FONC', 'SCOPE', '3.02 rule: only', @VS, 'TEST_SCOPE_RULE', '600';
EXEC dbo.sp_Test 'FONC', 'SCOPE', '3.03 all: (vars)', @VS, 'TEST_SCOPE_ALL', '30';
PRINT '';

PRINT '-- 4. Wildcards --';
DECLARE @VW NVARCHAR(MAX) = '{"rules":["TEST_WILD_PCT","TEST_WILD_UNDER","TEST_WILD_STAR"],"variables":[{"key":"WILDVAR_1","value":"10"},{"key":"WILDVAR_2","value":"20"},{"key":"WILDVAR_3","value":"30"},{"key":"WILDVAR_A","value":"5"}]}';
EXEC dbo.sp_Test 'FONC', 'WILD', '4.01 Percent %', @VW, 'TEST_WILD_PCT', '65';
EXEC dbo.sp_Test 'FONC', 'WILD', '4.02 Underscore _', @VW, 'TEST_WILD_UNDER', '4';
EXEC dbo.sp_Test 'FONC', 'WILD', '4.03 Star *', @VW, 'TEST_WILD_STAR', '65';
EXEC dbo.sp_Test 'FONC', 'WILD', '4.04 Mix', '{"rules":["TEST_WILD_MIX"],"variables":[{"key":"MIXVAR_1_END","value":"10"},{"key":"MIXVAR_2_END","value":"20"},{"key":"MIXVAR_ABC_END","value":"30"}]}', 'TEST_WILD_MIX', '60';
PRINT '';

PRINT '-- 5. Dépendances --';
EXEC dbo.sp_Test 'FONC', 'DEP', '5.01 A=10', '{"rules":["DEP_A"]}', 'DEP_A', '10';
EXEC dbo.sp_Test 'FONC', 'DEP', '5.02 B=A+5=15', '{"rules":["DEP_B"]}', 'DEP_B', '15';
EXEC dbo.sp_Test 'FONC', 'DEP', '5.03 C=B*2=30', '{"rules":["DEP_C"]}', 'DEP_C', '30';
EXEC dbo.sp_Test 'FONC', 'DEP', '5.04 D=C-10=20', '{"rules":["DEP_D"]}', 'DEP_D', '20';
EXEC dbo.sp_Test 'FONC', 'DEP', '5.05 E=D/2=10', '{"rules":["DEP_E"]}', 'DEP_E', '10';
EXEC dbo.sp_Test 'FONC', 'DEP', '5.06 Arbre=21', '{"rules":["TREE_ROOT"]}', 'TREE_ROOT', '21';
EXEC dbo.sp_Test 'FONC', 'DEP', '5.07 RuleAgg SUM=60', '{"rules":["TEST_RULEAGG_SUM"]}', 'TEST_RULEAGG_SUM', '60';
EXEC dbo.sp_Test 'FONC', 'DEP', '5.08 RuleAgg AVG=20', '{"rules":["TEST_RULEAGG_AVG"]}', 'TEST_RULEAGG_AVG', '20';
EXEC dbo.sp_Test 'FONC', 'DEP', '5.09 RuleAgg FIRST=10', '{"rules":["TEST_RULEAGG_FIRST"]}', 'TEST_RULEAGG_FIRST', '10';
PRINT '';

PRINT '-- 5.1 Self-match --';
EXEC dbo.sp_Test 'FONC', 'SELF', '5.1.01 Self-match=6', '{"rules":["SELFMSUM"]}', 'SELFMSUM', '6';
PRINT '';

PRINT '-- 6. Cycles --';
EXEC dbo.sp_Test 'FONC', 'CYCLE', '6.01 Mutuel A↔B', '{"rules":["CYCLE_A"]}', 'CYCLE_A', NULL, 0, 1;
EXEC dbo.sp_Test 'FONC', 'CYCLE', '6.02 Self-cycle', '{"rules":["CYCLESELF"]}', 'CYCLESELF', NULL, 0, 1;
EXEC dbo.sp_Test 'FONC', 'CYCLE', '6.03 Triangulaire', '{"rules":["CYCLE3_A"]}', 'CYCLE3_A', NULL, 0, 1;
PRINT '';

PRINT '-- 7. Erreurs SQL --';
EXEC dbo.sp_Test 'FONC', 'ERROR', '7.01 Div/0', '{"rules":["ERR_DIV0"]}', 'ERR_DIV0', NULL, 0, 1;
EXEC dbo.sp_Test 'FONC', 'ERROR', '7.02 Cast', '{"rules":["ERR_CAST"]}', 'ERR_CAST', NULL, 0, 1;
EXEC dbo.sp_Test 'FONC', 'ERROR', '7.03 Syntax', '{"rules":["ERR_SYNTAX"]}', 'ERR_SYNTAX', NULL, 0, 1;
PRINT '';

PRINT '-- 8. Agrégateur défaut V1.7.1 --';
EXEC dbo.sp_Test 'FONC', 'DEF', '8.01 Num→SUM', '{"rules":["TEST_DEF_NUM"],"variables":[{"key":"DEFNUM_1","value":"10"},{"key":"DEFNUM_2","value":"20"},{"key":"DEFNUM_3","value":"30"}]}', 'TEST_DEF_NUM', '60';
EXEC dbo.sp_Test 'FONC', 'DEF', '8.02 Txt→FIRST', '{"rules":["TEST_DEF_TXT"],"variables":[{"key":"DEFTXT_1","value":"Alpha"},{"key":"DEFTXT_2","value":"Beta"}]}', 'TEST_DEF_TXT', 'Alpha';
EXEC dbo.sp_Test 'FONC', 'DEF', '8.03 Mix→FIRST', '{"rules":["TEST_DEF_MIX"],"variables":[{"key":"DEFMIX_1","value":"text"},{"key":"DEFMIX_2","value":"123"}]}', 'TEST_DEF_MIX', 'text';
EXEC dbo.sp_Test 'FONC', 'DEF', '8.04 Single→SUM', '{"rules":["TEST_DEF_SINGLE"],"variables":[{"key":"DEFSINGLE","value":"42"}]}', 'TEST_DEF_SINGLE', '42';
EXEC dbo.sp_Test 'FONC', 'DEF', '8.05 Rule→SUM', '{"rules":["TEST_DEF_RULE"]}', 'TEST_DEF_RULE', '60';
PRINT '';

PRINT '-- 9. Cas limites --';
EXEC dbo.sp_Test 'FONC', 'EDGE', '9.01 Nest=28', '{"rules":["EDGE_NEST"]}', 'EDGE_NEST', '28';
EXEC dbo.sp_Test 'FONC', 'EDGE', '9.02 Multi=83', '{"rules":["EDGE_MULTI"],"variables":[{"key":"EDGENUM_1","value":"10"},{"key":"EDGENUM_2","value":"20"},{"key":"EDGENUM_3","value":"30"}]}', 'EDGE_MULTI', '83';
EXEC dbo.sp_Test 'FONC', 'EDGE', '9.03 Space1=30', '{"rules":["EDGE_SPACE1"],"variables":[{"key":"EDGENUM_1","value":"10"},{"key":"EDGENUM_2","value":"20"}]}', 'EDGE_SPACE1', '30';
EXEC dbo.sp_Test 'FONC', 'EDGE', '9.04 Space2=A', '{"rules":["EDGE_SPACE2"],"variables":[{"key":"EDGESTR_1","value":"A"},{"key":"EDGESTR_2","value":"B"}]}', 'EDGE_SPACE2', 'A';
PRINT '';
GO

-- =========================================================================
-- PARTIE 2: ROBUSTESSE
-- =========================================================================
PRINT '======================================================================';
PRINT '    PARTIE 2: TESTS DE ROBUSTESSE';
PRINT '======================================================================';
PRINT '';

PRINT '-- Volume --';
DECLARE @i INT = 1;
WHILE @i <= 100
BEGIN
    DECLARE @Code NVARCHAR(50) = 'VOLRULE' + CAST(@i AS VARCHAR);
    IF NOT EXISTS (SELECT 1 FROM dbo.RuleDefinitions WHERE RuleCode = @Code)
        INSERT INTO dbo.RuleDefinitions (RuleCode, Expression) VALUES (@Code, CAST(@i AS VARCHAR));
    SET @i = @i + 1;
END

IF NOT EXISTS (SELECT 1 FROM dbo.RuleDefinitions WHERE RuleCode = 'TEST_VOL_SUM')
    INSERT INTO dbo.RuleDefinitions (RuleCode, Expression) VALUES ('TEST_VOL_SUM', '{SUM(rule:VOLRULE%)}');
GO

EXEC dbo.sp_Test 'ROBUST', 'VOLUME', 'R.01 100 règles=5050', '{"rules":["TEST_VOL_SUM"]}', 'TEST_VOL_SUM', '5050';
PRINT '';

PRINT '-- Récursion profonde --';
DECLARE @j INT = 1, @Prev NVARCHAR(50) = NULL;
WHILE @j <= 20
BEGIN
    DECLARE @C NVARCHAR(50) = 'DEEPR' + CAST(@j AS VARCHAR);
    DECLARE @E NVARCHAR(100);
    IF @j = 1 SET @E = '1';
    ELSE SET @E = '{rule:' + @Prev + '}+1';  -- Référence DIRECTE, pas d'échappement
    
    IF NOT EXISTS (SELECT 1 FROM dbo.RuleDefinitions WHERE RuleCode = @C)
        INSERT INTO dbo.RuleDefinitions (RuleCode, Expression) VALUES (@C, @E);
    SET @Prev = @C;
    SET @j = @j + 1;
END
GO

EXEC dbo.sp_Test 'ROBUST', 'DEEP', 'R.02 Chaîne 20=20', '{"rules":["DEEPR20"]}', 'DEEPR20', '20';
PRINT '';

PRINT '-- 50 variables --';
DECLARE @BigV NVARCHAR(MAX) = '{"rules":["TEST_AGG_SUM"],"variables":[';
DECLARE @k INT = 1;
WHILE @k <= 50
BEGIN
    IF @k > 1 SET @BigV = @BigV + ',';
    SET @BigV = @BigV + '{"key":"AGGNUM_' + CAST(@k AS VARCHAR) + '","value":"' + CAST(@k AS VARCHAR) + '"}';
    SET @k = @k + 1;
END
SET @BigV = @BigV + ']}';
EXEC dbo.sp_Test 'ROBUST', 'BIGVAR', 'R.03 50 vars=1275', @BigV, 'TEST_AGG_SUM', '1275';
PRINT '';
GO

-- =========================================================================
-- PARTIE 3: BENCHMARKS
-- =========================================================================
PRINT '======================================================================';
PRINT '    PARTIE 3: BENCHMARKS';
PRINT '======================================================================';
PRINT '';

PRINT '-- SIMPLE --';
EXEC dbo.sp_Benchmark 'B01 Constante', 'BASE', 'SIMPLE', '{"rules":["CONST_INT_POS"]}', 50;
EXEC dbo.sp_Benchmark 'B02 Calcul', 'BASE', 'SIMPLE', '{"rules":["CALC_ADD"]}', 50;
EXEC dbo.sp_Benchmark 'B03 Variable', 'BASE', 'SIMPLE', '{"rules":["VAR_SIMPLE"],"variables":[{"key":"XVAR","value":"42"}]}', 50;
PRINT '';

PRINT '-- MEDIUM --';
EXEC dbo.sp_Benchmark 'B04 Complexe', 'COMP', 'MEDIUM', '{"rules":["CALC_COMPLEX1"]}', 50;
EXEC dbo.sp_Benchmark 'B05 Multi-vars', 'COMP', 'MEDIUM', '{"rules":["VAR_COMPLEX"],"variables":[{"key":"AVAR","value":"10"},{"key":"BVAR","value":"5"},{"key":"CVAR","value":"3"},{"key":"DVAR","value":"30"},{"key":"EVAR","value":"2"}]}', 50;
EXEC dbo.sp_Benchmark 'B06 Agrégat 5', 'AGG', 'MEDIUM', '{"rules":["TEST_AGG_SUM"],"variables":[{"key":"AGGNUM_1","value":"10"},{"key":"AGGNUM_2","value":"20"},{"key":"AGGNUM_3","value":"30"},{"key":"AGGNUM_4","value":"40"},{"key":"AGGNUM_5","value":"50"}]}', 50;
PRINT '';

PRINT '-- COMPLEX --';
EXEC dbo.sp_Benchmark 'B07 CONCAT', 'AGG', 'COMPLEX', '{"rules":["TEST_AGG_CONCAT"],"variables":[{"key":"AGGCAT_1","value":"A"},{"key":"AGGCAT_2","value":"B"},{"key":"AGGCAT_3","value":"C"}]}', 50;
EXEC dbo.sp_Benchmark 'B08 Chaîne 5', 'DEP', 'COMPLEX', '{"rules":["DEP_E"]}', 50;
EXEC dbo.sp_Benchmark 'B09 Arbre', 'DEP', 'COMPLEX', '{"rules":["TREE_ROOT"]}', 50;
PRINT '';

PRINT '-- EXTREME --';
EXEC dbo.sp_Benchmark 'B10 100 règles', 'AGG', 'EXTREME', '{"rules":["TEST_VOL_SUM"]}', 30;
EXEC dbo.sp_Benchmark 'B11 Chaîne 20', 'DEP', 'EXTREME', '{"rules":["DEEPR20"]}', 30;
PRINT '';
GO

-- =========================================================================
-- RAPPORT FINAL
-- =========================================================================
PRINT '======================================================================';
PRINT '    RAPPORT FINAL';
PRINT '======================================================================';
PRINT '';

DECLARE @Tot INT, @Pass INT, @Fail INT;
SELECT @Tot = COUNT(*), @Pass = SUM(CAST(Passed AS INT)), @Fail = SUM(CASE WHEN Passed=0 THEN 1 ELSE 0 END) FROM dbo.TestResults;

PRINT '  TESTS: ' + CAST(@Pass AS VARCHAR) + '/' + CAST(@Tot AS VARCHAR) + ' (' + CAST(CAST(@Pass*100.0/NULLIF(@Tot,0) AS INT) AS VARCHAR) + '%)';
PRINT '';

IF @Fail > 0
BEGIN
    PRINT '  Échecs:';
    SELECT '    - ' + TestName + ': ' + ISNULL(ErrorMsg,'') FROM dbo.TestResults WHERE Passed = 0;
END

IF @Pass = @Tot AND @Tot > 0 PRINT '  ✓ CONFORME SPEC V1.7.2';
PRINT '';

PRINT '  BENCHMARKS:';
SELECT '    ' + BenchName + ': ' + CAST(CAST(AvgMs AS DECIMAL(10,1)) AS VARCHAR) + ' ms' FROM dbo.BenchmarkResults ORDER BY BenchId;
PRINT '';
PRINT '======================================================================';
GO
