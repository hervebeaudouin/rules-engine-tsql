/***********************************************************************
    TESTS EXHAUSTIFS V6.9.2 - VERSION SPEC V1.7.1
    Conformité: SPEC V1.7.1 | ~90 tests + benchmarks
    Nouveauté: Agrégateur par défaut contextuel (SUM/FIRST)
************************************************************************/
SET NOCOUNT ON;
GO

PRINT '======================================================================';
PRINT '    TESTS EXHAUSTIFS V6.9.2 - SPEC V1.7.1                            ';
PRINT '======================================================================';
PRINT 'Date: ' + CONVERT(VARCHAR, GETDATE(), 120);
PRINT '';
GO

-- =========================================================================
-- TABLES RÉSULTATS
-- =========================================================================
IF OBJECT_ID('dbo.TestResults','U') IS NOT NULL DROP TABLE dbo.TestResults;
CREATE TABLE dbo.TestResults (
    TestId INT IDENTITY(1,1) PRIMARY KEY,
    Category NVARCHAR(50),
    TestName NVARCHAR(200),
    Expected NVARCHAR(MAX),
    Actual NVARCHAR(MAX),
    Passed BIT,
    ErrorMsg NVARCHAR(MAX),
    DurationMs INT,
    ExecutedAt DATETIME2 DEFAULT SYSDATETIME()
);

IF OBJECT_ID('dbo.PerfResults','U') IS NOT NULL DROP TABLE dbo.PerfResults;
CREATE TABLE dbo.PerfResults (
    PerfId INT IDENTITY(1,1) PRIMARY KEY,
    TestName NVARCHAR(200),
    Iterations INT,
    TotalMs INT,
    AvgMs DECIMAL(10,3),
    MinMs INT,
    MaxMs INT,
    OpsPerSec DECIMAL(10,2),
    ExecutedAt DATETIME2 DEFAULT SYSDATETIME()
);
GO

-- =========================================================================
-- PROCÉDURE TEST
-- =========================================================================
IF OBJECT_ID('dbo.sp_Test','P') IS NOT NULL DROP PROCEDURE dbo.sp_Test;
GO

CREATE PROCEDURE dbo.sp_Test
    @Category NVARCHAR(50),
    @TestName NVARCHAR(200),
    @InputJson NVARCHAR(MAX),
    @RuleCode NVARCHAR(200),
    @Expected NVARCHAR(MAX),
    @ExpectNull BIT = 0,
    @ExpectError BIT = 0
AS
BEGIN
    SET NOCOUNT ON;
    
    DECLARE @Output NVARCHAR(MAX), @Actual NVARCHAR(MAX), @State NVARCHAR(50);
    DECLARE @Start DATETIME2 = SYSDATETIME();
    DECLARE @Passed BIT = 0, @Err NVARCHAR(MAX) = NULL;
    
    BEGIN TRY
        EXEC dbo.sp_RunRulesEngine @InputJson, @Output OUTPUT;
        
        SELECT @Actual = JSON_VALUE(r.value, '$.value'),
               @State = JSON_VALUE(r.value, '$.state')
        FROM OPENJSON(@Output, '$.results') r
        WHERE JSON_VALUE(r.value, '$.ruleCode') = @RuleCode;
        
        IF @ExpectError = 1
            SET @Passed = CASE WHEN @State = 'ERROR' THEN 1 ELSE 0 END;
        ELSE IF @ExpectNull = 1
            SET @Passed = CASE WHEN @Actual IS NULL AND @State = 'EVALUATED' THEN 1 ELSE 0 END;
        ELSE
            SET @Passed = CASE WHEN @Actual = @Expected THEN 1 ELSE 0 END;
        
        IF @Passed = 0
            SET @Err = 'Attendu: [' + ISNULL(CASE WHEN @ExpectError=1 THEN 'ERROR' WHEN @ExpectNull=1 THEN 'NULL' ELSE @Expected END, 'NULL') 
                     + '] / Obtenu: [' + ISNULL(@Actual, 'NULL') + '] (State=' + ISNULL(@State,'?') + ')';
    END TRY
    BEGIN CATCH
        SET @Err = 'EXCEPTION: ' + ERROR_MESSAGE();
    END CATCH
    
    INSERT INTO dbo.TestResults (Category, TestName, Expected, Actual, Passed, ErrorMsg, DurationMs)
    VALUES (@Category, @TestName, 
            CASE WHEN @ExpectError=1 THEN 'ERROR' WHEN @ExpectNull=1 THEN 'NULL' ELSE @Expected END,
            @Actual, @Passed, @Err, DATEDIFF(MICROSECOND, @Start, SYSDATETIME())/1000);
    
    PRINT CASE WHEN @Passed=1 THEN '  [PASS] ' ELSE '  [FAIL] ' END + @TestName 
          + CASE WHEN @Passed=0 THEN ' -> ' + ISNULL(@Err,'') ELSE '' END;
END;
GO

-- =========================================================================
-- PROCÉDURE BENCHMARK
-- =========================================================================
IF OBJECT_ID('dbo.sp_Benchmark','P') IS NOT NULL DROP PROCEDURE dbo.sp_Benchmark;
GO

CREATE PROCEDURE dbo.sp_Benchmark
    @TestName NVARCHAR(200),
    @InputJson NVARCHAR(MAX),
    @Iterations INT = 100
AS
BEGIN
    SET NOCOUNT ON;
    
    DECLARE @i INT = 0, @Output NVARCHAR(MAX);
    DECLARE @Start DATETIME2, @End DATETIME2;
    DECLARE @TotalMs INT = 0, @MinMs INT = 999999, @MaxMs INT = 0, @Ms INT;
    
    WHILE @i < 5 BEGIN EXEC dbo.sp_RunRulesEngine @InputJson, @Output OUTPUT; SET @i += 1; END
    SET @i = 0;
    
    WHILE @i < @Iterations
    BEGIN
        SET @Start = SYSDATETIME();
        EXEC dbo.sp_RunRulesEngine @InputJson, @Output OUTPUT;
        SET @End = SYSDATETIME();
        SET @Ms = DATEDIFF(MICROSECOND, @Start, @End) / 1000;
        SET @TotalMs += @Ms;
        IF @Ms < @MinMs SET @MinMs = @Ms;
        IF @Ms > @MaxMs SET @MaxMs = @Ms;
        SET @i += 1;
    END
    
    INSERT INTO dbo.PerfResults (TestName, Iterations, TotalMs, AvgMs, MinMs, MaxMs, OpsPerSec)
    VALUES (@TestName, @Iterations, @TotalMs, 
            CAST(@TotalMs AS DECIMAL(10,3)) / @Iterations,
            @MinMs, @MaxMs,
            CASE WHEN @TotalMs > 0 THEN CAST(@Iterations AS DECIMAL(10,2)) * 1000 / @TotalMs ELSE 0 END);
    
    PRINT '  [PERF] ' + @TestName + ': ' + CAST(CAST(@TotalMs AS DECIMAL(10,3)) / @Iterations AS VARCHAR) + ' ms/op';
END;
GO

PRINT 'Procédures de test créées';
PRINT '';
GO

-- =========================================================================
-- INSERTION DES RÈGLES DE TEST
-- =========================================================================
PRINT '-- Insertion des règles de test --';

DELETE FROM dbo.RuleDefinitions;
GO

-- Constantes
INSERT INTO dbo.RuleDefinitions (RuleCode, Expression) VALUES ('R_INT', '42');
INSERT INTO dbo.RuleDefinitions (RuleCode, Expression) VALUES ('R_DEC', '3.14159');
INSERT INTO dbo.RuleDefinitions (RuleCode, Expression) VALUES ('R_NEG', '-100');
INSERT INTO dbo.RuleDefinitions (RuleCode, Expression) VALUES ('R_ZERO', '0');
INSERT INTO dbo.RuleDefinitions (RuleCode, Expression) VALUES ('R_STR', '''Hello''');
GO

-- Calculs
INSERT INTO dbo.RuleDefinitions (RuleCode, Expression) VALUES ('R_ADD', '10+5');
INSERT INTO dbo.RuleDefinitions (RuleCode, Expression) VALUES ('R_SUB', '100-37');
INSERT INTO dbo.RuleDefinitions (RuleCode, Expression) VALUES ('R_MUL', '7*8');
INSERT INTO dbo.RuleDefinitions (RuleCode, Expression) VALUES ('R_DIV', '100.0/8');
INSERT INTO dbo.RuleDefinitions (RuleCode, Expression) VALUES ('R_MOD', '17%5');
INSERT INTO dbo.RuleDefinitions (RuleCode, Expression) VALUES ('R_COMPLEX', '(10+5)*2-30/6');
INSERT INTO dbo.RuleDefinitions (RuleCode, Expression) VALUES ('R_PAREN', '((2+3)*(4+1))');
INSERT INTO dbo.RuleDefinitions (RuleCode, Expression) VALUES ('R_FLOAT', '1.5*2.5');
GO

-- Variables
INSERT INTO dbo.RuleDefinitions (RuleCode, Expression) VALUES ('R_VAR', '{X}');
INSERT INTO dbo.RuleDefinitions (RuleCode, Expression) VALUES ('R_VAR2', '{A}+{B}');
INSERT INTO dbo.RuleDefinitions (RuleCode, Expression) VALUES ('R_VARMUL', '{A}*{B}');
INSERT INTO dbo.RuleDefinitions (RuleCode, Expression) VALUES ('R_MISSING', '{UNKNOWN}');
INSERT INTO dbo.RuleDefinitions (RuleCode, Expression) VALUES ('R_COND', 'CASE WHEN {X}>50 THEN ''HIGH'' ELSE ''LOW'' END');
INSERT INTO dbo.RuleDefinitions (RuleCode, Expression) VALUES ('R_MULTI', '({A}+{B})*{C}');
GO

-- Normalisation FR
INSERT INTO dbo.RuleDefinitions (RuleCode, Expression) VALUES ('R_FR1', '2,5+3,5');
INSERT INTO dbo.RuleDefinitions (RuleCode, Expression) VALUES ('R_FR2', '10,25*2');
INSERT INTO dbo.RuleDefinitions (RuleCode, Expression) VALUES ('R_FR3', '{X}+1,5');
GO

-- Agrégats base
INSERT INTO dbo.RuleDefinitions (RuleCode, Expression) VALUES ('R_SUM', '{SUM(N_%)}');
INSERT INTO dbo.RuleDefinitions (RuleCode, Expression) VALUES ('R_AVG', '{AVG(N_%)}');
INSERT INTO dbo.RuleDefinitions (RuleCode, Expression) VALUES ('R_MIN', '{MIN(N_%)}');
INSERT INTO dbo.RuleDefinitions (RuleCode, Expression) VALUES ('R_MAX', '{MAX(N_%)}');
INSERT INTO dbo.RuleDefinitions (RuleCode, Expression) VALUES ('R_COUNT', '{COUNT(N_%)}');
GO

-- Agrégats POS
INSERT INTO dbo.RuleDefinitions (RuleCode, Expression) VALUES ('R_SUMP', '{SUM_POS(V_%)}');
INSERT INTO dbo.RuleDefinitions (RuleCode, Expression) VALUES ('R_AVGP', '{AVG_POS(V_%)}');
INSERT INTO dbo.RuleDefinitions (RuleCode, Expression) VALUES ('R_MINP', '{MIN_POS(V_%)}');
INSERT INTO dbo.RuleDefinitions (RuleCode, Expression) VALUES ('R_MAXP', '{MAX_POS(V_%)}');
INSERT INTO dbo.RuleDefinitions (RuleCode, Expression) VALUES ('R_CNTP', '{COUNT_POS(V_%)}');
INSERT INTO dbo.RuleDefinitions (RuleCode, Expression) VALUES ('R_FIRSTP', '{FIRST_POS(V_%)}');
INSERT INTO dbo.RuleDefinitions (RuleCode, Expression) VALUES ('R_LASTP', '{LAST_POS(V_%)}');
GO

-- Agrégats NEG
INSERT INTO dbo.RuleDefinitions (RuleCode, Expression) VALUES ('R_SUMN', '{SUM_NEG(V_%)}');
INSERT INTO dbo.RuleDefinitions (RuleCode, Expression) VALUES ('R_AVGN', '{AVG_NEG(V_%)}');
INSERT INTO dbo.RuleDefinitions (RuleCode, Expression) VALUES ('R_MINN', '{MIN_NEG(V_%)}');
INSERT INTO dbo.RuleDefinitions (RuleCode, Expression) VALUES ('R_MAXN', '{MAX_NEG(V_%)}');
INSERT INTO dbo.RuleDefinitions (RuleCode, Expression) VALUES ('R_CNTN', '{COUNT_NEG(V_%)}');
INSERT INTO dbo.RuleDefinitions (RuleCode, Expression) VALUES ('R_FIRSTN', '{FIRST_NEG(V_%)}');
INSERT INTO dbo.RuleDefinitions (RuleCode, Expression) VALUES ('R_LASTN', '{LAST_NEG(V_%)}');
GO

-- FIRST/LAST
INSERT INTO dbo.RuleDefinitions (RuleCode, Expression) VALUES ('R_FIRST', '{FIRST(S_%)}');
INSERT INTO dbo.RuleDefinitions (RuleCode, Expression) VALUES ('R_LAST', '{LAST(S_%)}');
INSERT INTO dbo.RuleDefinitions (RuleCode, Expression) VALUES ('R_FIRSTN2', '{FIRST(N_%)}');
INSERT INTO dbo.RuleDefinitions (RuleCode, Expression) VALUES ('R_LASTN2', '{LAST(N_%)}');
GO

-- CONCAT/JSONIFY
INSERT INTO dbo.RuleDefinitions (RuleCode, Expression) VALUES ('R_CONCAT', '{CONCAT(L_%)}');
INSERT INTO dbo.RuleDefinitions (RuleCode, Expression) VALUES ('R_CONC_E', '{CONCAT(NOMATCH_%)}');
INSERT INTO dbo.RuleDefinitions (RuleCode, Expression) VALUES ('R_JSON', '{JSONIFY(P_%)}');
INSERT INTO dbo.RuleDefinitions (RuleCode, Expression) VALUES ('R_JSON_E', '{JSONIFY(NOMATCH_%)}');
GO

-- NULL tests (V1.6.0)
INSERT INTO dbo.RuleDefinitions (RuleCode, Expression) VALUES ('R_NSUM', '{SUM(NL_%)}');
INSERT INTO dbo.RuleDefinitions (RuleCode, Expression) VALUES ('R_NAVG', '{AVG(NL_%)}');
INSERT INTO dbo.RuleDefinitions (RuleCode, Expression) VALUES ('R_NCOUNT', '{COUNT(NL_%)}');
INSERT INTO dbo.RuleDefinitions (RuleCode, Expression) VALUES ('R_NFIRST', '{FIRST(NL_%)}');
INSERT INTO dbo.RuleDefinitions (RuleCode, Expression) VALUES ('R_NLAST', '{LAST(NL_%)}');
INSERT INTO dbo.RuleDefinitions (RuleCode, Expression) VALUES ('R_NCONCAT', '{CONCAT(NL_%)}');
GO

-- Empty set
INSERT INTO dbo.RuleDefinitions (RuleCode, Expression) VALUES ('R_ESUM', '{SUM(EMPTY_%)}');
INSERT INTO dbo.RuleDefinitions (RuleCode, Expression) VALUES ('R_ECOUNT', '{COUNT(EMPTY_%)}');
INSERT INTO dbo.RuleDefinitions (RuleCode, Expression) VALUES ('R_EFIRST', '{FIRST(EMPTY_%)}');
INSERT INTO dbo.RuleDefinitions (RuleCode, Expression) VALUES ('R_ECONCAT', '{CONCAT(EMPTY_%)}');
INSERT INTO dbo.RuleDefinitions (RuleCode, Expression) VALUES ('R_EJSON', '{JSONIFY(EMPTY_%)}');
GO

-- SeqId order
INSERT INTO dbo.RuleDefinitions (RuleCode, Expression) VALUES ('R_OFIRST', '{FIRST(ORD_%)}');
INSERT INTO dbo.RuleDefinitions (RuleCode, Expression) VALUES ('R_OLAST', '{LAST(ORD_%)}');
INSERT INTO dbo.RuleDefinitions (RuleCode, Expression) VALUES ('R_OCONCAT', '{CONCAT(ORD_%)}');
GO

-- Wildcards
INSERT INTO dbo.RuleDefinitions (RuleCode, Expression) VALUES ('R_WSTAR', '{SUM(DATA_%)}');
INSERT INTO dbo.RuleDefinitions (RuleCode, Expression) VALUES ('R_WQUEST', '{SUM(ITEM_?)}');
INSERT INTO dbo.RuleDefinitions (RuleCode, Expression) VALUES ('R_WMIX', '{COUNT(X_%_Y)}');
GO

-- Scopes
INSERT INTO dbo.RuleDefinitions (RuleCode, Expression) VALUES ('R_SVAR', '{SUM(var:SC_%)}');
INSERT INTO dbo.RuleDefinitions (RuleCode, Expression) VALUES ('R_SRULE', '{SUM(rule:SCR_%)}');
INSERT INTO dbo.RuleDefinitions (RuleCode, Expression) VALUES ('R_SALL', '{COUNT(all:SC_%)}');
INSERT INTO dbo.RuleDefinitions (RuleCode, Expression) VALUES ('SCR_1', '100');
INSERT INTO dbo.RuleDefinitions (RuleCode, Expression) VALUES ('SCR_2', '200');
INSERT INTO dbo.RuleDefinitions (RuleCode, Expression) VALUES ('SCR_3', '300');
GO

-- RuleRef
INSERT INTO dbo.RuleDefinitions (RuleCode, Expression) VALUES ('RD_A', '10');
INSERT INTO dbo.RuleDefinitions (RuleCode, Expression) VALUES ('RD_B', '{rule:RD_A}+5');
INSERT INTO dbo.RuleDefinitions (RuleCode, Expression) VALUES ('RD_C', '{rule:RD_B}*2');
INSERT INTO dbo.RuleDefinitions (RuleCode, Expression) VALUES ('RD_D', '{rule:RD_C}-10');
INSERT INTO dbo.RuleDefinitions (RuleCode, Expression) VALUES ('RC_1', '1');
INSERT INTO dbo.RuleDefinitions (RuleCode, Expression) VALUES ('RC_2', '2');
INSERT INTO dbo.RuleDefinitions (RuleCode, Expression) VALUES ('RC_3', '3');
INSERT INTO dbo.RuleDefinitions (RuleCode, Expression) VALUES ('RC_SUM', '{SUM(rule:RC_%)}');
GO

-- Cycles
INSERT INTO dbo.RuleDefinitions (RuleCode, Expression) VALUES ('CYC_A', '{rule:CYC_B}+1');
INSERT INTO dbo.RuleDefinitions (RuleCode, Expression) VALUES ('CYC_B', '{rule:CYC_A}+1');
INSERT INTO dbo.RuleDefinitions (RuleCode, Expression) VALUES ('SELF', '{rule:SELF}+1');
GO

-- V1.7.1: Agrégateur par défaut contextuel
INSERT INTO dbo.RuleDefinitions (RuleCode, Expression) VALUES ('R_DEFNUM', '{NUM_%}');          -- Numérique → SUM
INSERT INTO dbo.RuleDefinitions (RuleCode, Expression) VALUES ('R_DEFTXT', '{TXT_%}');          -- Texte → FIRST
INSERT INTO dbo.RuleDefinitions (RuleCode, Expression) VALUES ('R_DEFONE', '{SINGLE}');         -- Un seul numérique
INSERT INTO dbo.RuleDefinitions (RuleCode, Expression) VALUES ('R_DEFMIX', '{MIX_%}');          -- Mixte → FIRST
INSERT INTO dbo.RuleDefinitions (RuleCode, Expression) VALUES ('R_DEFRULE', '{rule:RN_%}');     -- Règles numériques → SUM
INSERT INTO dbo.RuleDefinitions (RuleCode, Expression) VALUES ('RN_1', '10');                   -- Pour test DEFRULE
INSERT INTO dbo.RuleDefinitions (RuleCode, Expression) VALUES ('RN_2', '20');                   -- Pour test DEFRULE
INSERT INTO dbo.RuleDefinitions (RuleCode, Expression) VALUES ('RN_3', '30');                   -- Pour test DEFRULE
GO

-- Errors
INSERT INTO dbo.RuleDefinitions (RuleCode, Expression) VALUES ('R_DIV0', '1/0');
INSERT INTO dbo.RuleDefinitions (RuleCode, Expression) VALUES ('R_SYNTAX', 'SELECT * FROM');
INSERT INTO dbo.RuleDefinitions (RuleCode, Expression) VALUES ('R_CAST', 'CAST(''abc'' AS INT)');
GO

-- Special chars
INSERT INTO dbo.RuleDefinitions (RuleCode, Expression) VALUES ('R_SPEC', '{X}');
INSERT INTO dbo.RuleDefinitions (RuleCode, Expression) VALUES ('R_UNI', '{X}');
GO

-- Afficher le nombre de règles
DECLARE @RuleCount INT;
SELECT @RuleCount = COUNT(*) FROM dbo.RuleDefinitions;
PRINT 'Règles insérées: ' + CAST(@RuleCount AS VARCHAR);
PRINT '';
GO

-- =========================================================================
-- SECTION A: FONDAMENTAUX
-- =========================================================================
PRINT '======================================================================';
PRINT '    SECTION A: FONDAMENTAUX';
PRINT '======================================================================';

-- 01. Constantes
PRINT '-- 01. Constantes --';
EXEC dbo.sp_Test 'CONST', '01.1 Entier', '{"rules":["R_INT"]}', 'R_INT', '42';
EXEC dbo.sp_Test 'CONST', '01.2 Décimal', '{"rules":["R_DEC"]}', 'R_DEC', '3.14159';
EXEC dbo.sp_Test 'CONST', '01.3 Négatif', '{"rules":["R_NEG"]}', 'R_NEG', '-100';
EXEC dbo.sp_Test 'CONST', '01.4 Zéro', '{"rules":["R_ZERO"]}', 'R_ZERO', '0';
EXEC dbo.sp_Test 'CONST', '01.5 Chaîne', '{"rules":["R_STR"]}', 'R_STR', 'Hello';
PRINT '';

-- 02. Calculs
PRINT '-- 02. Calculs --';
EXEC dbo.sp_Test 'CALC', '02.1 Addition', '{"rules":["R_ADD"]}', 'R_ADD', '15';
EXEC dbo.sp_Test 'CALC', '02.2 Soustraction', '{"rules":["R_SUB"]}', 'R_SUB', '63';
EXEC dbo.sp_Test 'CALC', '02.3 Multiplication', '{"rules":["R_MUL"]}', 'R_MUL', '56';
EXEC dbo.sp_Test 'CALC', '02.4 Division', '{"rules":["R_DIV"]}', 'R_DIV', '12.5';
EXEC dbo.sp_Test 'CALC', '02.5 Modulo', '{"rules":["R_MOD"]}', 'R_MOD', '2';
EXEC dbo.sp_Test 'CALC', '02.6 Complexe', '{"rules":["R_COMPLEX"]}', 'R_COMPLEX', '25';
EXEC dbo.sp_Test 'CALC', '02.7 Parenthèses', '{"rules":["R_PAREN"]}', 'R_PAREN', '25';
EXEC dbo.sp_Test 'CALC', '02.8 Float', '{"rules":["R_FLOAT"]}', 'R_FLOAT', '3.75';
PRINT '';

-- 03. Variables
PRINT '-- 03. Variables --';
EXEC dbo.sp_Test 'VAR', '03.1 Simple', '{"rules":["R_VAR"],"variables":[{"key":"X","value":"99"}]}', 'R_VAR', '99';
EXEC dbo.sp_Test 'VAR', '03.2 Addition', '{"rules":["R_VAR2"],"variables":[{"key":"A","value":"25"},{"key":"B","value":"17"}]}', 'R_VAR2', '42';
EXEC dbo.sp_Test 'VAR', '03.3 Multiplication', '{"rules":["R_VARMUL"],"variables":[{"key":"A","value":"6"},{"key":"B","value":"7"}]}', 'R_VARMUL', '42';
EXEC dbo.sp_Test 'VAR', '03.4 Condition HIGH', '{"rules":["R_COND"],"variables":[{"key":"X","value":"75"}]}', 'R_COND', 'HIGH';
EXEC dbo.sp_Test 'VAR', '03.5 Condition LOW', '{"rules":["R_COND"],"variables":[{"key":"X","value":"25"}]}', 'R_COND', 'LOW';
EXEC dbo.sp_Test 'VAR', '03.6 Multi', '{"rules":["R_MULTI"],"variables":[{"key":"A","value":"3"},{"key":"B","value":"7"},{"key":"C","value":"5"}]}', 'R_MULTI', '50';
EXEC dbo.sp_Test 'VAR', '03.7 Missing', '{"rules":["R_MISSING"]}', 'R_MISSING', NULL, 1;
PRINT '';

-- 04. Normalisation FR
PRINT '-- 04. Normalisation FR --';
EXEC dbo.sp_Test 'NORM', '04.1 Virgule 2,5+3,5', '{"rules":["R_FR1"]}', 'R_FR1', '6';
EXEC dbo.sp_Test 'NORM', '04.2 Virgule 10,25*2', '{"rules":["R_FR2"]}', 'R_FR2', '20.5';
EXEC dbo.sp_Test 'NORM', '04.3 Var+virgule', '{"rules":["R_FR3"],"variables":[{"key":"X","value":"10"}]}', 'R_FR3', '11.5';
PRINT '';
GO

-- =========================================================================
-- SECTION B: AGRÉGATS
-- =========================================================================
PRINT '======================================================================';
PRINT '    SECTION B: AGRÉGATS';
PRINT '======================================================================';

-- 05. Agrégats base
PRINT '-- 05. Agrégats base --';
EXEC dbo.sp_Test 'AGG', '05.1 SUM=150', '{"rules":["R_SUM"],"variables":[{"key":"N_1","value":"10"},{"key":"N_2","value":"20"},{"key":"N_3","value":"30"},{"key":"N_4","value":"40"},{"key":"N_5","value":"50"}]}', 'R_SUM', '150';
EXEC dbo.sp_Test 'AGG', '05.2 AVG=30', '{"rules":["R_AVG"],"variables":[{"key":"N_1","value":"10"},{"key":"N_2","value":"20"},{"key":"N_3","value":"30"},{"key":"N_4","value":"40"},{"key":"N_5","value":"50"}]}', 'R_AVG', '30';
EXEC dbo.sp_Test 'AGG', '05.3 MIN=10', '{"rules":["R_MIN"],"variables":[{"key":"N_1","value":"10"},{"key":"N_2","value":"20"},{"key":"N_3","value":"30"},{"key":"N_4","value":"40"},{"key":"N_5","value":"50"}]}', 'R_MIN', '10';
EXEC dbo.sp_Test 'AGG', '05.4 MAX=50', '{"rules":["R_MAX"],"variables":[{"key":"N_1","value":"10"},{"key":"N_2","value":"20"},{"key":"N_3","value":"30"},{"key":"N_4","value":"40"},{"key":"N_5","value":"50"}]}', 'R_MAX', '50';
EXEC dbo.sp_Test 'AGG', '05.5 COUNT=5', '{"rules":["R_COUNT"],"variables":[{"key":"N_1","value":"10"},{"key":"N_2","value":"20"},{"key":"N_3","value":"30"},{"key":"N_4","value":"40"},{"key":"N_5","value":"50"}]}', 'R_COUNT', '5';
PRINT '';

-- 06. Agrégats POS
PRINT '-- 06. Agrégats POS --';
EXEC dbo.sp_Test 'POS', '06.1 SUM_POS=70', '{"rules":["R_SUMP"],"variables":[{"key":"V_1","value":"15"},{"key":"V_2","value":"-10"},{"key":"V_3","value":"25"},{"key":"V_4","value":"-5"},{"key":"V_5","value":"30"}]}', 'R_SUMP', '70';
EXEC dbo.sp_Test 'POS', '06.2 MIN_POS=15', '{"rules":["R_MINP"],"variables":[{"key":"V_1","value":"15"},{"key":"V_2","value":"-10"},{"key":"V_3","value":"25"},{"key":"V_4","value":"-5"},{"key":"V_5","value":"30"}]}', 'R_MINP', '15';
EXEC dbo.sp_Test 'POS', '06.3 MAX_POS=30', '{"rules":["R_MAXP"],"variables":[{"key":"V_1","value":"15"},{"key":"V_2","value":"-10"},{"key":"V_3","value":"25"},{"key":"V_4","value":"-5"},{"key":"V_5","value":"30"}]}', 'R_MAXP', '30';
EXEC dbo.sp_Test 'POS', '06.4 COUNT_POS=3', '{"rules":["R_CNTP"],"variables":[{"key":"V_1","value":"15"},{"key":"V_2","value":"-10"},{"key":"V_3","value":"25"},{"key":"V_4","value":"-5"},{"key":"V_5","value":"30"}]}', 'R_CNTP', '3';
EXEC dbo.sp_Test 'POS', '06.5 FIRST_POS=15', '{"rules":["R_FIRSTP"],"variables":[{"key":"V_1","value":"15"},{"key":"V_2","value":"-10"},{"key":"V_3","value":"25"},{"key":"V_4","value":"-5"},{"key":"V_5","value":"30"}]}', 'R_FIRSTP', '15';
EXEC dbo.sp_Test 'POS', '06.6 LAST_POS=30', '{"rules":["R_LASTP"],"variables":[{"key":"V_1","value":"15"},{"key":"V_2","value":"-10"},{"key":"V_3","value":"25"},{"key":"V_4","value":"-5"},{"key":"V_5","value":"30"}]}', 'R_LASTP', '30';
PRINT '';

-- 07. Agrégats NEG
PRINT '-- 07. Agrégats NEG --';
EXEC dbo.sp_Test 'NEG', '07.1 SUM_NEG=-15', '{"rules":["R_SUMN"],"variables":[{"key":"V_1","value":"15"},{"key":"V_2","value":"-10"},{"key":"V_3","value":"25"},{"key":"V_4","value":"-5"},{"key":"V_5","value":"30"}]}', 'R_SUMN', '-15';
EXEC dbo.sp_Test 'NEG', '07.2 MIN_NEG=-10', '{"rules":["R_MINN"],"variables":[{"key":"V_1","value":"15"},{"key":"V_2","value":"-10"},{"key":"V_3","value":"25"},{"key":"V_4","value":"-5"},{"key":"V_5","value":"30"}]}', 'R_MINN', '-10';
EXEC dbo.sp_Test 'NEG', '07.3 MAX_NEG=-5', '{"rules":["R_MAXN"],"variables":[{"key":"V_1","value":"15"},{"key":"V_2","value":"-10"},{"key":"V_3","value":"25"},{"key":"V_4","value":"-5"},{"key":"V_5","value":"30"}]}', 'R_MAXN', '-5';
EXEC dbo.sp_Test 'NEG', '07.4 COUNT_NEG=2', '{"rules":["R_CNTN"],"variables":[{"key":"V_1","value":"15"},{"key":"V_2","value":"-10"},{"key":"V_3","value":"25"},{"key":"V_4","value":"-5"},{"key":"V_5","value":"30"}]}', 'R_CNTN', '2';
EXEC dbo.sp_Test 'NEG', '07.5 FIRST_NEG=-10', '{"rules":["R_FIRSTN"],"variables":[{"key":"V_1","value":"15"},{"key":"V_2","value":"-10"},{"key":"V_3","value":"25"},{"key":"V_4","value":"-5"},{"key":"V_5","value":"30"}]}', 'R_FIRSTN', '-10';
EXEC dbo.sp_Test 'NEG', '07.6 LAST_NEG=-5', '{"rules":["R_LASTN"],"variables":[{"key":"V_1","value":"15"},{"key":"V_2","value":"-10"},{"key":"V_3","value":"25"},{"key":"V_4","value":"-5"},{"key":"V_5","value":"30"}]}', 'R_LASTN', '-5';
PRINT '';

-- 08. FIRST/LAST
PRINT '-- 08. FIRST/LAST --';
EXEC dbo.sp_Test 'POS', '08.1 FIRST=A', '{"rules":["R_FIRST"],"variables":[{"key":"S_1","value":"A"},{"key":"S_2","value":"B"},{"key":"S_3","value":"C"}]}', 'R_FIRST', 'A';
EXEC dbo.sp_Test 'POS', '08.2 LAST=C', '{"rules":["R_LAST"],"variables":[{"key":"S_1","value":"A"},{"key":"S_2","value":"B"},{"key":"S_3","value":"C"}]}', 'R_LAST', 'C';
EXEC dbo.sp_Test 'POS', '08.3 FIRST num', '{"rules":["R_FIRSTN2"],"variables":[{"key":"N_1","value":"10"},{"key":"N_2","value":"20"}]}', 'R_FIRSTN2', '10';
EXEC dbo.sp_Test 'POS', '08.4 LAST num', '{"rules":["R_LASTN2"],"variables":[{"key":"N_1","value":"10"},{"key":"N_2","value":"20"}]}', 'R_LASTN2', '20';
PRINT '';

-- 09. CONCAT
PRINT '-- 09. CONCAT --';
EXEC dbo.sp_Test 'CONCAT', '09.1 ABC', '{"rules":["R_CONCAT"],"variables":[{"key":"L_1","value":"A"},{"key":"L_2","value":"B"},{"key":"L_3","value":"C"}]}', 'R_CONCAT', 'ABC';
EXEC dbo.sp_Test 'CONCAT', '09.2 Empty set', '{"rules":["R_CONC_E"]}', 'R_CONC_E', '';
PRINT '';

-- 10. JSONIFY
PRINT '-- 10. JSONIFY --';
EXEC dbo.sp_Test 'JSON', '10.1 Object', '{"rules":["R_JSON"],"variables":[{"key":"P_a","value":"1"},{"key":"P_b","value":"2"}]}', 'R_JSON', '{"P_a":1,"P_b":2}';
EXEC dbo.sp_Test 'JSON', '10.2 Empty set', '{"rules":["R_JSON_E"]}', 'R_JSON_E', '{}';
PRINT '';
GO

-- =========================================================================
-- SECTION C: SÉMANTIQUE V1.6.0
-- =========================================================================
PRINT '======================================================================';
PRINT '    SECTION C: SÉMANTIQUE V1.6.0';
PRINT '======================================================================';

-- 11. Gestion NULL
PRINT '-- 11. NULL V1.6.0 --';
EXEC dbo.sp_Test 'NULL', '11.1 SUM ignore NULL=90', '{"rules":["R_NSUM"],"variables":[{"key":"NL_1","value":"10"},{"key":"NL_2","value":null},{"key":"NL_3","value":"30"},{"key":"NL_4","value":null},{"key":"NL_5","value":"50"}]}', 'R_NSUM', '90';
EXEC dbo.sp_Test 'NULL', '11.2 AVG ignore NULL=30', '{"rules":["R_NAVG"],"variables":[{"key":"NL_1","value":"10"},{"key":"NL_2","value":null},{"key":"NL_3","value":"30"},{"key":"NL_4","value":null},{"key":"NL_5","value":"50"}]}', 'R_NAVG', '30';
EXEC dbo.sp_Test 'NULL', '11.3 COUNT ignore NULL=3', '{"rules":["R_NCOUNT"],"variables":[{"key":"NL_1","value":"10"},{"key":"NL_2","value":null},{"key":"NL_3","value":"30"},{"key":"NL_4","value":null},{"key":"NL_5","value":"50"}]}', 'R_NCOUNT', '3';
EXEC dbo.sp_Test 'NULL', '11.4 FIRST ignore NULL=10', '{"rules":["R_NFIRST"],"variables":[{"key":"NL_1","value":"10"},{"key":"NL_2","value":null},{"key":"NL_3","value":"30"}]}', 'R_NFIRST', '10';
EXEC dbo.sp_Test 'NULL', '11.5 LAST ignore NULL=50', '{"rules":["R_NLAST"],"variables":[{"key":"NL_1","value":"10"},{"key":"NL_2","value":null},{"key":"NL_3","value":"50"}]}', 'R_NLAST', '50';
EXEC dbo.sp_Test 'NULL', '11.6 FIRST skip leading NULL', '{"rules":["R_NFIRST"],"variables":[{"key":"NL_1","value":null},{"key":"NL_2","value":"X"},{"key":"NL_3","value":"Y"}]}', 'R_NFIRST', 'X';
PRINT '';

-- 12. Ensemble vide
PRINT '-- 12. Ensemble vide --';
EXEC dbo.sp_Test 'EMPTY', '12.1 SUM empty=NULL', '{"rules":["R_ESUM"]}', 'R_ESUM', NULL, 1;
EXEC dbo.sp_Test 'EMPTY', '12.2 COUNT empty=0', '{"rules":["R_ECOUNT"]}', 'R_ECOUNT', '0';
EXEC dbo.sp_Test 'EMPTY', '12.3 FIRST empty=NULL', '{"rules":["R_EFIRST"]}', 'R_EFIRST', NULL, 1;
EXEC dbo.sp_Test 'EMPTY', '12.4 CONCAT empty', '{"rules":["R_ECONCAT"]}', 'R_ECONCAT', '';
EXEC dbo.sp_Test 'EMPTY', '12.5 JSONIFY empty={}', '{"rules":["R_EJSON"]}', 'R_EJSON', '{}';
PRINT '';

-- 13. Ordre SeqId
PRINT '-- 13. Ordre SeqId --';
EXEC dbo.sp_Test 'ORDER', '13.1 FIRST=C (premier inséré)', '{"rules":["R_OFIRST"],"variables":[{"key":"ORD_3","value":"C"},{"key":"ORD_1","value":"A"},{"key":"ORD_2","value":"B"}]}', 'R_OFIRST', 'C';
EXEC dbo.sp_Test 'ORDER', '13.2 LAST=B (dernier inséré)', '{"rules":["R_OLAST"],"variables":[{"key":"ORD_3","value":"C"},{"key":"ORD_1","value":"A"},{"key":"ORD_2","value":"B"}]}', 'R_OLAST', 'B';
EXEC dbo.sp_Test 'ORDER', '13.3 CONCAT=CAB (ordre SeqId)', '{"rules":["R_OCONCAT"],"variables":[{"key":"ORD_3","value":"C"},{"key":"ORD_1","value":"A"},{"key":"ORD_2","value":"B"}]}', 'R_OCONCAT', 'CAB';
PRINT '';

-- 14. Case-insensitivity
PRINT '-- 14. Case-insensitivity --';
EXEC dbo.sp_Test 'CASE', '14.1 Key CI lowercase', '{"rules":["R_VAR"],"variables":[{"key":"x","value":"OK"}]}', 'R_VAR', 'OK';
EXEC dbo.sp_Test 'CASE', '14.2 Key CI uppercase', '{"rules":["R_VAR"],"variables":[{"key":"X","value":"OK2"}]}', 'R_VAR', 'OK2';
PRINT '';
GO

-- =========================================================================
-- SECTION D: TOKENS ET PATTERNS
-- =========================================================================
PRINT '======================================================================';
PRINT '    SECTION D: TOKENS ET PATTERNS';
PRINT '======================================================================';

-- 15. Wildcards
PRINT '-- 15. Wildcards --';
EXEC dbo.sp_Test 'WILD', '15.1 Star %', '{"rules":["R_WSTAR"],"variables":[{"key":"DATA_A","value":"10"},{"key":"DATA_B","value":"20"},{"key":"DATA_123","value":"30"}]}', 'R_WSTAR', '60';
EXEC dbo.sp_Test 'WILD', '15.2 Question _', '{"rules":["R_WQUEST"],"variables":[{"key":"ITEM_A","value":"5"},{"key":"ITEM_B","value":"10"},{"key":"ITEM_AB","value":"100"}]}', 'R_WQUEST', '15';
EXEC dbo.sp_Test 'WILD', '15.3 Star middle', '{"rules":["R_WMIX"],"variables":[{"key":"X_1_Y","value":"1"},{"key":"X_ABC_Y","value":"1"}]}', 'R_WMIX', '2';
PRINT '';

-- 16. Scopes
PRINT '-- 16. Scopes --';
EXEC dbo.sp_Test 'SCOPE', '16.1 var: only', '{"rules":["R_SVAR"],"variables":[{"key":"SC_1","value":"10"},{"key":"SC_2","value":"20"}]}', 'R_SVAR', '30';
EXEC dbo.sp_Test 'SCOPE', '16.2 rule: only', '{"rules":["R_SRULE"]}', 'R_SRULE', '600';
EXEC dbo.sp_Test 'SCOPE', '16.3 all: both', '{"rules":["R_SALL","SCR_1"],"variables":[{"key":"SC_X","value":"1"}]}', 'R_SALL', '2';
PRINT '';
GO

-- =========================================================================
-- SECTION E: RÈGLES ET DÉPENDANCES
-- =========================================================================
PRINT '======================================================================';
PRINT '    SECTION E: RÈGLES ET DÉPENDANCES';
PRINT '======================================================================';

-- 17. RuleRef
PRINT '-- 17. RuleRef --';
EXEC dbo.sp_Test 'REF', '17.1 Direct A=10', '{"rules":["RD_A"]}', 'RD_A', '10';
EXEC dbo.sp_Test 'REF', '17.2 B=A+5=15', '{"rules":["RD_B"]}', 'RD_B', '15';
EXEC dbo.sp_Test 'REF', '17.3 C=B*2=30', '{"rules":["RD_C"]}', 'RD_C', '30';
EXEC dbo.sp_Test 'REF', '17.4 D=C-10=20', '{"rules":["RD_D"]}', 'RD_D', '20';
PRINT '';

-- 18. RuleRef pattern
PRINT '-- 18. RuleRef pattern --';
EXEC dbo.sp_Test 'REF', '18.1 SUM chain 1+2+3=6', '{"rules":["RC_SUM"]}', 'RC_SUM', '6';
PRINT '';

-- 19. Cycles
PRINT '-- 19. Cycles --';
EXEC dbo.sp_Test 'CYCLE', '19.1 Mutual cycle', '{"rules":["CYC_A"]}', 'CYC_A', NULL, 0, 1;
EXEC dbo.sp_Test 'CYCLE', '19.2 Self cycle', '{"rules":["SELF"]}', 'SELF', NULL, 0, 1;
PRINT '';

-- 20. Agrégateur par défaut contextuel (V1.7.1)
PRINT '-- 20. Agrégateur par défaut V1.7.1 --';
-- NUM_1=10, NUM_2=20, NUM_3=30 → SUM par défaut = 60
EXEC dbo.sp_Test 'DEFAULT', '20.1 Numérique → SUM', 
    '{"rules":["R_DEFNUM"],"variables":[{"key":"NUM_1","value":"10"},{"key":"NUM_2","value":"20"},{"key":"NUM_3","value":"30"}]}', 
    'R_DEFNUM', '60';
-- TXT_1='A', TXT_2='B', TXT_3='C' → FIRST par défaut = 'A'
EXEC dbo.sp_Test 'DEFAULT', '20.2 Texte → FIRST', 
    '{"rules":["R_DEFTXT"],"variables":[{"key":"TXT_1","value":"Alpha"},{"key":"TXT_2","value":"Beta"},{"key":"TXT_3","value":"Gamma"}]}', 
    'R_DEFTXT', 'Alpha';
-- SINGLE=42 → SUM d'un seul = 42
EXEC dbo.sp_Test 'DEFAULT', '20.3 Un seul num → SUM', 
    '{"rules":["R_DEFONE"],"variables":[{"key":"SINGLE","value":"42"}]}', 
    'R_DEFONE', '42';
-- MIX_1='text', MIX_2=123 → Premier est texte → FIRST
EXEC dbo.sp_Test 'DEFAULT', '20.4 Mixte (1er=txt) → FIRST', 
    '{"rules":["R_DEFMIX"],"variables":[{"key":"MIX_1","value":"text"},{"key":"MIX_2","value":"123"}]}', 
    'R_DEFMIX', 'text';
-- Règles RN_1=10, RN_2=20, RN_3=30 → SUM par défaut = 60
EXEC dbo.sp_Test 'DEFAULT', '20.5 Règles num → SUM', 
    '{"rules":["R_DEFRULE"]}', 
    'R_DEFRULE', '60';
PRINT '';
GO

-- =========================================================================
-- SECTION F: ROBUSTESSE
-- =========================================================================
PRINT '======================================================================';
PRINT '    SECTION F: ROBUSTESSE';
PRINT '======================================================================';

-- 21. Erreurs SQL
PRINT '-- 21. Erreurs SQL --';
EXEC dbo.sp_Test 'ERROR', '21.1 Division by 0', '{"rules":["R_DIV0"]}', 'R_DIV0', NULL, 0, 1;
EXEC dbo.sp_Test 'ERROR', '21.2 Syntax error', '{"rules":["R_SYNTAX"]}', 'R_SYNTAX', NULL, 0, 1;
EXEC dbo.sp_Test 'ERROR', '21.3 Invalid cast', '{"rules":["R_CAST"]}', 'R_CAST', NULL, 0, 1;
PRINT '';

-- 22. Caractères spéciaux
PRINT '-- 22. Caractères spéciaux --';
EXEC dbo.sp_Test 'SPEC', '22.1 Quote', '{"rules":["R_SPEC"],"variables":[{"key":"X","value":"It''s OK"}]}', 'R_SPEC', 'It''s OK';
EXEC dbo.sp_Test 'SPEC', '22.2 Unicode', '{"rules":["R_UNI"],"variables":[{"key":"X","value":"Test123"}]}', 'R_UNI', 'Test123';
PRINT '';
GO

-- =========================================================================
-- SECTION G: BENCHMARKS
-- =========================================================================
PRINT '======================================================================';
PRINT '    SECTION G: BENCHMARKS';
PRINT '======================================================================';
PRINT '';

EXEC dbo.sp_Benchmark 'BENCH-01 Constante', '{"rules":["R_INT"]}', 50;
EXEC dbo.sp_Benchmark 'BENCH-02 Calcul', '{"rules":["R_COMPLEX"]}', 50;
EXEC dbo.sp_Benchmark 'BENCH-03 Variable', '{"rules":["R_VAR2"],"variables":[{"key":"A","value":"100"},{"key":"B","value":"200"}]}', 50;
EXEC dbo.sp_Benchmark 'BENCH-04 Agrégat 5 elem', '{"rules":["R_SUM"],"variables":[{"key":"N_1","value":"10"},{"key":"N_2","value":"20"},{"key":"N_3","value":"30"},{"key":"N_4","value":"40"},{"key":"N_5","value":"50"}]}', 50;
EXEC dbo.sp_Benchmark 'BENCH-05 JSONIFY', '{"rules":["R_JSON"],"variables":[{"key":"P_1","value":"1"},{"key":"P_2","value":"2"},{"key":"P_3","value":"3"}]}', 50;
EXEC dbo.sp_Benchmark 'BENCH-06 RuleRef chain', '{"rules":["RD_D"]}', 50;
PRINT '';
GO

-- =========================================================================
-- RAPPORT FINAL
-- =========================================================================
PRINT '======================================================================';
PRINT '    RAPPORT FINAL';
PRINT '======================================================================';
PRINT '';

SELECT Category, 
       COUNT(*) AS Total,
       SUM(CASE WHEN Passed=1 THEN 1 ELSE 0 END) AS Pass,
       SUM(CASE WHEN Passed=0 THEN 1 ELSE 0 END) AS Fail
FROM dbo.TestResults 
GROUP BY Category 
ORDER BY Category;

DECLARE @Tot INT, @Pass INT, @Fail INT;
SELECT @Tot = COUNT(*), 
       @Pass = SUM(CASE WHEN Passed=1 THEN 1 ELSE 0 END), 
       @Fail = SUM(CASE WHEN Passed=0 THEN 1 ELSE 0 END)
FROM dbo.TestResults;

PRINT '';
PRINT '  TOTAL: ' + CAST(@Tot AS VARCHAR) + ' tests';
PRINT '  PASS:  ' + CAST(@Pass AS VARCHAR) + ' (' + CAST(CASE WHEN @Tot > 0 THEN 100*@Pass/@Tot ELSE 0 END AS VARCHAR) + '%)';
PRINT '  FAIL:  ' + CAST(@Fail AS VARCHAR);
PRINT '';

IF @Fail > 0
BEGIN
    PRINT '-- Tests échoués --';
    SELECT Category, TestName, Expected, Actual, ErrorMsg 
    FROM dbo.TestResults 
    WHERE Passed = 0;
END

IF @Pass = @Tot AND @Tot > 0
    PRINT '  MOTEUR V6.9.2 CONFORME SPEC V1.7.1';
ELSE IF @Fail > 0
    PRINT '  ' + CAST(@Fail AS VARCHAR) + ' TEST(S) EN ECHEC';

PRINT '';
PRINT '======================================================================';
PRINT '    BENCHMARKS';
PRINT '======================================================================';

SELECT TestName, 
       CAST(AvgMs AS VARCHAR) + ' ms' AS AvgTime, 
       CAST(OpsPerSec AS VARCHAR) + ' /s' AS OpsPerSec
FROM dbo.PerfResults 
ORDER BY AvgMs;

PRINT '';
PRINT '======================================================================';
GO
