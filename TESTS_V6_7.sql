/***********************************************************************
    TESTS COMPLETS - MOTEUR DE RÈGLES V6.7
    =====================================================================
    
    Conformité: SPEC V1.6.0
    Couverture: 49 tests fonctionnels + 6 benchmarks performance
    
    CATÉGORIES DE TESTS:
    --------------------
    01. Règles constantes (4 tests)
    02. Calculs simples (6 tests)
    03. Variables (5 tests)
    04. Agrégats mathématiques (5 tests)
    05. Agrégats positifs/négatifs (6 tests)
    06. Agrégats positionnels FIRST/LAST (4 tests)
    07. CONCAT (3 tests)
    08. JSONIFY (4 tests)
    09. Gestion NULL - Spec V1.6.0 (4 tests)
    10. Cas limites (4 tests)
    11. Fonctions SQL dans expressions (14 tests) <<< NOUVEAU
    12. Tests de performance (6 benchmarks)
************************************************************************/

SET NOCOUNT ON;
GO

PRINT '======================================================================';
PRINT '        TESTS COMPLETS - MOTEUR DE RÈGLES V6.7                       ';
PRINT '======================================================================';
PRINT '';
PRINT 'Date: ' + CONVERT(VARCHAR, GETDATE(), 120);
PRINT '';
GO

-- =========================================================================
-- PRÉPARATION
-- =========================================================================
PRINT '-- Préparation environnement de test --';
PRINT '';

-- Table des résultats
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
GO

-- Table des benchmarks
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

-- Procédure de test unitaire
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

-- Procédure de benchmark
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
    
    -- Warmup
    WHILE @i < 5
    BEGIN
        EXEC dbo.sp_RunRulesEngine @InputJson, @Output OUTPUT;
        SET @i += 1;
    END
    SET @i = 0;
    
    -- Test
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
    
    PRINT '  [PERF] ' + @TestName + ': ' 
          + CAST(CAST(@TotalMs AS DECIMAL(10,3)) / @Iterations AS VARCHAR) + ' ms/op, '
          + CAST(CASE WHEN @TotalMs > 0 THEN CAST(@Iterations AS DECIMAL(10,2)) * 1000 / @TotalMs ELSE 0 END AS VARCHAR) + ' ops/sec';
END;
GO

PRINT '        OK';
PRINT '';
GO

-- =========================================================================
-- INSERTION DES RÈGLES DE TEST
-- =========================================================================
PRINT '-- Insertion des règles de test --';

DELETE FROM dbo.RuleDefinitions;

-- Règles constantes
INSERT INTO dbo.RuleDefinitions (RuleCode, Expression) VALUES
    ('R_CONST_INT', '42'),
    ('R_CONST_DEC', '3.14159'),
    ('R_CONST_NEG', '-100'),
    ('R_CONST_STR', '''Hello World''');

-- Règles calculs
INSERT INTO dbo.RuleDefinitions (RuleCode, Expression) VALUES
    ('R_CALC_ADD', '10 + 5'),
    ('R_CALC_SUB', '100 - 37'),
    ('R_CALC_MUL', '7 * 8'),
    ('R_CALC_DIV', '100.0 / 8'),
    ('R_CALC_COMPLEX', '(10 + 5) * 2 - 30 / 6'),
    ('R_CALC_FR', '2,5 + 3,5'),
    ('R_CALC_ERR', '1/0');

-- Règles variables
INSERT INTO dbo.RuleDefinitions (RuleCode, Expression) VALUES
    ('R_VAR_SIMPLE', '{X}'),
    ('R_VAR_CALC', '{A} + {B}'),
    ('R_VAR_COND', 'CASE WHEN {X} > 50 THEN ''HIGH'' ELSE ''LOW'' END'),
    ('R_VAR_MULTI', '({A} + {B}) * {C}'),
    ('R_VAR_MISSING', '{UNKNOWN}');

-- Règles agrégats mathématiques
INSERT INTO dbo.RuleDefinitions (RuleCode, Expression) VALUES
    ('R_SUM', '{SUM(N_*)}'),
    ('R_AVG', '{AVG(N_*)}'),
    ('R_MIN', '{MIN(N_*)}'),
    ('R_MAX', '{MAX(N_*)}'),
    ('R_COUNT', '{COUNT(N_*)}');

-- Règles agrégats positifs/négatifs
INSERT INTO dbo.RuleDefinitions (RuleCode, Expression) VALUES
    ('R_SUM_POS', '{SUM_POS(V_*)}'),
    ('R_SUM_NEG', '{SUM_NEG(V_*)}'),
    ('R_COUNT_POS', '{COUNT_POS(V_*)}'),
    ('R_COUNT_NEG', '{COUNT_NEG(V_*)}'),
    ('R_FIRST_POS', '{FIRST_POS(V_*)}'),
    ('R_FIRST_NEG', '{FIRST_NEG(V_*)}');

-- Règles agrégats positionnels
INSERT INTO dbo.RuleDefinitions (RuleCode, Expression) VALUES
    ('R_FIRST', '{FIRST(S_*)}'),
    ('R_LAST', '{LAST(S_*)}'),
    ('R_FIRST_NULL', '{FIRST(NV_*)}'),
    ('R_LAST_NULL', '{LAST(NV_*)}');

-- Règles CONCAT
INSERT INTO dbo.RuleDefinitions (RuleCode, Expression) VALUES
    ('R_CONCAT', '{CONCAT(L_*)}'),
    ('R_CONCAT_EMPTY', '{CONCAT(NONE_*)}'),
    ('R_CONCAT_NULL', '{CONCAT(CN_*)}');

-- Règles JSONIFY
INSERT INTO dbo.RuleDefinitions (RuleCode, Expression) VALUES
    ('R_JSON', '{JSONIFY(P_*)}'),
    ('R_JSON_EMPTY', '{JSONIFY(NONE_*)}'),
    ('R_JSON_NULL', '{JSONIFY(JN_*)}'),
    ('R_JSON_TYPES', '{JSONIFY(T_*)}');

-- Règles NULL spec V1.6.0
INSERT INTO dbo.RuleDefinitions (RuleCode, Expression) VALUES
    ('R_NULL_SUM', '{SUM(NL_*)}'),
    ('R_NULL_AVG', '{AVG(NL_*)}'),
    ('R_NULL_COUNT', '{COUNT(NL_*)}'),
    ('R_NULL_FIRST', '{FIRST(NL_*)}');

-- Règles cas limites
INSERT INTO dbo.RuleDefinitions (RuleCode, Expression) VALUES
    ('R_EMPTY_SUM', '{SUM(EMPTY_*)}'),
    ('R_EMPTY_COUNT', '{COUNT(EMPTY_*)}'),
    ('R_SINGLE', '{FIRST(SINGLE_*)}'),
    ('R_BIG_NUM', '{X}');

-- Règles avec fonctions SQL
INSERT INTO dbo.RuleDefinitions (RuleCode, Expression) VALUES
    ('R_FN_UPPER', 'UPPER({txt})'),
    ('R_FN_LOWER', 'LOWER({txt})'),
    ('R_FN_LEN', 'LEN({txt})'),
    ('R_FN_LEFT', 'LEFT({txt}, 3)'),
    ('R_FN_REPLACE', 'REPLACE({txt}, ''o'', ''0'')'),
    ('R_FN_CONCAT_WS', 'CONCAT({a}, ''-'', {b})'),
    ('R_FN_ABS', 'ABS({num})'),
    ('R_FN_ROUND', 'ROUND({num}, 2)'),
    ('R_FN_CEILING', 'CEILING({num})'),
    ('R_FN_COALESCE', 'COALESCE({maybe_null}, ''default'')'),
    ('R_FN_IIF', 'IIF({num} > 50, ''BIG'', ''SMALL'')'),
    ('R_FN_NESTED', 'UPPER(LEFT({txt}, 3))'),
    ('R_FN_MATH', 'POWER({num}, 2) + SQRT({num})');

PRINT '        ' + CAST(@@ROWCOUNT AS VARCHAR) + ' règles insérées';
PRINT '';
GO

-- =========================================================================
-- EXÉCUTION DES TESTS FONCTIONNELS
-- =========================================================================
PRINT '======================================================================';
PRINT '    TESTS FONCTIONNELS';
PRINT '======================================================================';
PRINT '';

-- =========================================
-- 01. RÈGLES CONSTANTES
-- =========================================
PRINT '-- 01. Règles constantes --';

EXEC dbo.sp_Test 'CONST', '01.1 Entier', 
    '{"rules":["R_CONST_INT"]}', 'R_CONST_INT', '42';

EXEC dbo.sp_Test 'CONST', '01.2 Décimal', 
    '{"rules":["R_CONST_DEC"]}', 'R_CONST_DEC', '3.14159';

EXEC dbo.sp_Test 'CONST', '01.3 Négatif', 
    '{"rules":["R_CONST_NEG"]}', 'R_CONST_NEG', '-100';

EXEC dbo.sp_Test 'CONST', '01.4 Chaîne', 
    '{"rules":["R_CONST_STR"]}', 'R_CONST_STR', 'Hello World';

PRINT '';

-- =========================================
-- 02. CALCULS SIMPLES
-- =========================================
PRINT '-- 02. Calculs simples --';

EXEC dbo.sp_Test 'CALC', '02.1 Addition', 
    '{"rules":["R_CALC_ADD"]}', 'R_CALC_ADD', '15';

EXEC dbo.sp_Test 'CALC', '02.2 Soustraction', 
    '{"rules":["R_CALC_SUB"]}', 'R_CALC_SUB', '63';

EXEC dbo.sp_Test 'CALC', '02.3 Multiplication', 
    '{"rules":["R_CALC_MUL"]}', 'R_CALC_MUL', '56';

EXEC dbo.sp_Test 'CALC', '02.4 Division', 
    '{"rules":["R_CALC_DIV"]}', 'R_CALC_DIV', '12.5';

EXEC dbo.sp_Test 'CALC', '02.5 Expression complexe', 
    '{"rules":["R_CALC_COMPLEX"]}', 'R_CALC_COMPLEX', '25';

EXEC dbo.sp_Test 'CALC', '02.6 Décimaux français (2,5+3,5)', 
    '{"rules":["R_CALC_FR"]}', 'R_CALC_FR', '6';

PRINT '';

-- =========================================
-- 03. VARIABLES
-- =========================================
PRINT '-- 03. Variables --';

EXEC dbo.sp_Test 'VAR', '03.1 Variable simple', 
    '{"rules":["R_VAR_SIMPLE"],"variables":[{"key":"X","value":"99"}]}', 
    'R_VAR_SIMPLE', '99';

EXEC dbo.sp_Test 'VAR', '03.2 Calcul A+B', 
    '{"rules":["R_VAR_CALC"],"variables":[{"key":"A","value":"25"},{"key":"B","value":"17"}]}', 
    'R_VAR_CALC', '42';

EXEC dbo.sp_Test 'VAR', '03.3 Condition HIGH', 
    '{"rules":["R_VAR_COND"],"variables":[{"key":"X","value":"75"}]}', 
    'R_VAR_COND', 'HIGH';

EXEC dbo.sp_Test 'VAR', '03.4 Condition LOW', 
    '{"rules":["R_VAR_COND"],"variables":[{"key":"X","value":"25"}]}', 
    'R_VAR_COND', 'LOW';

EXEC dbo.sp_Test 'VAR', '03.5 Multi-variables (A+B)*C', 
    '{"rules":["R_VAR_MULTI"],"variables":[{"key":"A","value":"3"},{"key":"B","value":"7"},{"key":"C","value":"5"}]}', 
    'R_VAR_MULTI', '50';

PRINT '';

-- =========================================
-- 04. AGRÉGATS MATHÉMATIQUES
-- =========================================
PRINT '-- 04. Agrégats mathématiques --';

DECLARE @VarsN NVARCHAR(MAX) = '[{"key":"N_1","value":"10"},{"key":"N_2","value":"20"},{"key":"N_3","value":"30"},{"key":"N_4","value":"40"},{"key":"N_5","value":"50"}]';

EXEC dbo.sp_Test 'AGG', '04.1 SUM (10+20+30+40+50=150)', 
    '{"rules":["R_SUM"],"variables":[{"key":"N_1","value":"10"},{"key":"N_2","value":"20"},{"key":"N_3","value":"30"},{"key":"N_4","value":"40"},{"key":"N_5","value":"50"}]}', 
    'R_SUM', '150';

EXEC dbo.sp_Test 'AGG', '04.2 AVG (150/5=30)', 
    '{"rules":["R_AVG"],"variables":[{"key":"N_1","value":"10"},{"key":"N_2","value":"20"},{"key":"N_3","value":"30"},{"key":"N_4","value":"40"},{"key":"N_5","value":"50"}]}', 
    'R_AVG', '30';

EXEC dbo.sp_Test 'AGG', '04.3 MIN', 
    '{"rules":["R_MIN"],"variables":[{"key":"N_1","value":"10"},{"key":"N_2","value":"20"},{"key":"N_3","value":"30"},{"key":"N_4","value":"40"},{"key":"N_5","value":"50"}]}', 
    'R_MIN', '10';

EXEC dbo.sp_Test 'AGG', '04.4 MAX', 
    '{"rules":["R_MAX"],"variables":[{"key":"N_1","value":"10"},{"key":"N_2","value":"20"},{"key":"N_3","value":"30"},{"key":"N_4","value":"40"},{"key":"N_5","value":"50"}]}', 
    'R_MAX', '50';

EXEC dbo.sp_Test 'AGG', '04.5 COUNT', 
    '{"rules":["R_COUNT"],"variables":[{"key":"N_1","value":"10"},{"key":"N_2","value":"20"},{"key":"N_3","value":"30"},{"key":"N_4","value":"40"},{"key":"N_5","value":"50"}]}', 
    'R_COUNT', '5';

PRINT '';

-- =========================================
-- 05. AGRÉGATS POSITIFS/NÉGATIFS
-- =========================================
PRINT '-- 05. Agrégats positifs/négatifs --';

-- V_1=15, V_2=-10, V_3=25, V_4=-5, V_5=30
DECLARE @VarsV NVARCHAR(MAX) = '[{"key":"V_1","value":"15"},{"key":"V_2","value":"-10"},{"key":"V_3","value":"25"},{"key":"V_4","value":"-5"},{"key":"V_5","value":"30"}]';

EXEC dbo.sp_Test 'SIGN', '05.1 SUM_POS (15+25+30=70)', 
    '{"rules":["R_SUM_POS"],"variables":[{"key":"V_1","value":"15"},{"key":"V_2","value":"-10"},{"key":"V_3","value":"25"},{"key":"V_4","value":"-5"},{"key":"V_5","value":"30"}]}', 
    'R_SUM_POS', '70';

EXEC dbo.sp_Test 'SIGN', '05.2 SUM_NEG (-10-5=-15)', 
    '{"rules":["R_SUM_NEG"],"variables":[{"key":"V_1","value":"15"},{"key":"V_2","value":"-10"},{"key":"V_3","value":"25"},{"key":"V_4","value":"-5"},{"key":"V_5","value":"30"}]}', 
    'R_SUM_NEG', '-15';

EXEC dbo.sp_Test 'SIGN', '05.3 COUNT_POS (3)', 
    '{"rules":["R_COUNT_POS"],"variables":[{"key":"V_1","value":"15"},{"key":"V_2","value":"-10"},{"key":"V_3","value":"25"},{"key":"V_4","value":"-5"},{"key":"V_5","value":"30"}]}', 
    'R_COUNT_POS', '3';

EXEC dbo.sp_Test 'SIGN', '05.4 COUNT_NEG (2)', 
    '{"rules":["R_COUNT_NEG"],"variables":[{"key":"V_1","value":"15"},{"key":"V_2","value":"-10"},{"key":"V_3","value":"25"},{"key":"V_4","value":"-5"},{"key":"V_5","value":"30"}]}', 
    'R_COUNT_NEG', '2';

-- FIX-BUG-2: FIRST_POS doit retourner première valeur positive par SeqId (15, pas 30)
EXEC dbo.sp_Test 'SIGN', '05.5 FIRST_POS (premier positif par SeqId = 15)', 
    '{"rules":["R_FIRST_POS"],"variables":[{"key":"V_1","value":"15"},{"key":"V_2","value":"-10"},{"key":"V_3","value":"25"},{"key":"V_4","value":"-5"},{"key":"V_5","value":"30"}]}', 
    'R_FIRST_POS', '15';

-- FIX-BUG-2: FIRST_NEG doit retourner première valeur négative par SeqId (-10, pas -5)
EXEC dbo.sp_Test 'SIGN', '05.6 FIRST_NEG (premier négatif par SeqId = -10)', 
    '{"rules":["R_FIRST_NEG"],"variables":[{"key":"V_1","value":"15"},{"key":"V_2","value":"-10"},{"key":"V_3","value":"25"},{"key":"V_4","value":"-5"},{"key":"V_5","value":"30"}]}', 
    'R_FIRST_NEG', '-10';

PRINT '';

-- =========================================
-- 06. AGRÉGATS POSITIONNELS FIRST/LAST
-- =========================================
PRINT '-- 06. Agrégats positionnels --';

EXEC dbo.sp_Test 'POS', '06.1 FIRST (ordre insertion)', 
    '{"rules":["R_FIRST"],"variables":[{"key":"S_1","value":"Alpha"},{"key":"S_2","value":"Beta"},{"key":"S_3","value":"Gamma"}]}', 
    'R_FIRST', 'Alpha';

EXEC dbo.sp_Test 'POS', '06.2 LAST (ordre insertion)', 
    '{"rules":["R_LAST"],"variables":[{"key":"S_1","value":"Alpha"},{"key":"S_2","value":"Beta"},{"key":"S_3","value":"Gamma"}]}', 
    'R_LAST', 'Gamma';

-- FIRST ignore NULL (spec V1.6.0)
EXEC dbo.sp_Test 'POS', '06.3 FIRST ignore NULL', 
    '{"rules":["R_FIRST_NULL"],"variables":[{"key":"NV_1","value":null},{"key":"NV_2","value":"Valid"},{"key":"NV_3","value":"Also"}]}', 
    'R_FIRST_NULL', 'Valid';

-- LAST ignore NULL (spec V1.6.0)
EXEC dbo.sp_Test 'POS', '06.4 LAST ignore NULL', 
    '{"rules":["R_LAST_NULL"],"variables":[{"key":"NV_1","value":"First"},{"key":"NV_2","value":null},{"key":"NV_3","value":"Last"}]}', 
    'R_LAST_NULL', 'Last';

PRINT '';

-- =========================================
-- 07. CONCAT
-- =========================================
PRINT '-- 07. CONCAT --';

EXEC dbo.sp_Test 'CONCAT', '07.1 Concaténation ABC', 
    '{"rules":["R_CONCAT"],"variables":[{"key":"L_1","value":"A"},{"key":"L_2","value":"B"},{"key":"L_3","value":"C"}]}', 
    'R_CONCAT', 'ABC';

EXEC dbo.sp_Test 'CONCAT', '07.2 Ensemble vide -> chaîne vide', 
    '{"rules":["R_CONCAT_EMPTY"],"variables":[]}', 
    'R_CONCAT_EMPTY', '';

EXEC dbo.sp_Test 'CONCAT', '07.3 CONCAT ignore NULL (XZ pas XnullZ)', 
    '{"rules":["R_CONCAT_NULL"],"variables":[{"key":"CN_1","value":"X"},{"key":"CN_2","value":null},{"key":"CN_3","value":"Z"}]}', 
    'R_CONCAT_NULL', 'XZ';

PRINT '';

-- =========================================
-- 08. JSONIFY
-- =========================================
PRINT '-- 08. JSONIFY --';

EXEC dbo.sp_Test 'JSON', '08.1 Objet simple', 
    '{"rules":["R_JSON"],"variables":[{"key":"P_name","value":"John"},{"key":"P_age","value":"30"}]}', 
    'R_JSON', '{"P_name":"John","P_age":30}';

EXEC dbo.sp_Test 'JSON', '08.2 Ensemble vide -> {}', 
    '{"rules":["R_JSON_EMPTY"],"variables":[]}', 
    'R_JSON_EMPTY', '{}';

EXEC dbo.sp_Test 'JSON', '08.3 JSONIFY ignore NULL', 
    '{"rules":["R_JSON_NULL"],"variables":[{"key":"JN_a","value":"ok"},{"key":"JN_b","value":null},{"key":"JN_c","value":"42"}]}', 
    'R_JSON_NULL', '{"JN_a":"ok","JN_c":42}';

EXEC dbo.sp_Test 'JSON', '08.4 Types mixtes (str, num, bool, json)', 
    '{"rules":["R_JSON_TYPES"],"variables":[{"key":"T_str","value":"text"},{"key":"T_num","value":"123"},{"key":"T_bool","value":"true"},{"key":"T_obj","value":"{\"x\":1}"}]}', 
    'R_JSON_TYPES', '{"T_str":"text","T_num":123,"T_bool":true,"T_obj":{"x":1}}';

PRINT '';

-- =========================================
-- 09. GESTION NULL (SPEC V1.6.0)
-- =========================================
PRINT '-- 09. Gestion NULL (Spec V1.6.0) --';

-- Tous les agrégats ignorent NULL
EXEC dbo.sp_Test 'NULL', '09.1 SUM ignore NULL (10+30=40)', 
    '{"rules":["R_NULL_SUM"],"variables":[{"key":"NL_1","value":"10"},{"key":"NL_2","value":null},{"key":"NL_3","value":"30"}]}', 
    'R_NULL_SUM', '40';

EXEC dbo.sp_Test 'NULL', '09.2 AVG ignore NULL (40/2=20)', 
    '{"rules":["R_NULL_AVG"],"variables":[{"key":"NL_1","value":"10"},{"key":"NL_2","value":null},{"key":"NL_3","value":"30"}]}', 
    'R_NULL_AVG', '20';

EXEC dbo.sp_Test 'NULL', '09.3 COUNT ignore NULL (2)', 
    '{"rules":["R_NULL_COUNT"],"variables":[{"key":"NL_1","value":"10"},{"key":"NL_2","value":null},{"key":"NL_3","value":"30"}]}', 
    'R_NULL_COUNT', '2';

EXEC dbo.sp_Test 'NULL', '09.4 FIRST ignore NULL', 
    '{"rules":["R_NULL_FIRST"],"variables":[{"key":"NL_1","value":null},{"key":"NL_2","value":"Found"},{"key":"NL_3","value":"Also"}]}', 
    'R_NULL_FIRST', 'Found';

PRINT '';

-- =========================================
-- 10. CAS LIMITES
-- =========================================
PRINT '-- 10. Cas limites --';

EXEC dbo.sp_Test 'EDGE', '10.1 SUM ensemble vide -> NULL', 
    '{"rules":["R_EMPTY_SUM"],"variables":[]}', 
    'R_EMPTY_SUM', NULL, 1, 0;

EXEC dbo.sp_Test 'EDGE', '10.2 COUNT ensemble vide -> 0', 
    '{"rules":["R_EMPTY_COUNT"],"variables":[]}', 
    'R_EMPTY_COUNT', '0';

EXEC dbo.sp_Test 'EDGE', '10.3 Un seul élément', 
    '{"rules":["R_SINGLE"],"variables":[{"key":"SINGLE_1","value":"Unique"}]}', 
    'R_SINGLE', 'Unique';

EXEC dbo.sp_Test 'EDGE', '10.4 Grand nombre', 
    '{"rules":["R_BIG_NUM"],"variables":[{"key":"X","value":"12345678901234567890"}]}', 
    'R_BIG_NUM', '12345678901234567890';

PRINT '';

-- =========================================
-- 11. FONCTIONS SQL DANS EXPRESSIONS
-- =========================================
PRINT '-- 11. Fonctions SQL dans expressions --';

EXEC dbo.sp_Test 'SQLFN', '11.01 UPPER(text)', 
    '{"rules":["R_FN_UPPER"],"variables":[{"key":"txt","value":"hello"}]}', 
    'R_FN_UPPER', 'HELLO';

EXEC dbo.sp_Test 'SQLFN', '11.02 LOWER(text)', 
    '{"rules":["R_FN_LOWER"],"variables":[{"key":"txt","value":"WORLD"}]}', 
    'R_FN_LOWER', 'world';

EXEC dbo.sp_Test 'SQLFN', '11.03 LEN(text)', 
    '{"rules":["R_FN_LEN"],"variables":[{"key":"txt","value":"hello"}]}', 
    'R_FN_LEN', '5';

EXEC dbo.sp_Test 'SQLFN', '11.04 LEFT(text, n)', 
    '{"rules":["R_FN_LEFT"],"variables":[{"key":"txt","value":"hello"}]}', 
    'R_FN_LEFT', 'hel';

EXEC dbo.sp_Test 'SQLFN', '11.05 REPLACE(text)', 
    '{"rules":["R_FN_REPLACE"],"variables":[{"key":"txt","value":"hello"}]}', 
    'R_FN_REPLACE', 'hell0';

EXEC dbo.sp_Test 'SQLFN', '11.06 CONCAT(a, sep, b)', 
    '{"rules":["R_FN_CONCAT_WS"],"variables":[{"key":"a","value":"foo"},{"key":"b","value":"bar"}]}', 
    'R_FN_CONCAT_WS', 'foo-bar';

EXEC dbo.sp_Test 'SQLFN', '11.07 ABS(negative)', 
    '{"rules":["R_FN_ABS"],"variables":[{"key":"num","value":"-42"}]}', 
    'R_FN_ABS', '42';

EXEC dbo.sp_Test 'SQLFN', '11.08 ROUND(decimal, 2)', 
    '{"rules":["R_FN_ROUND"],"variables":[{"key":"num","value":"3.14159"}]}', 
    'R_FN_ROUND', '3.14';

EXEC dbo.sp_Test 'SQLFN', '11.09 CEILING(decimal)', 
    '{"rules":["R_FN_CEILING"],"variables":[{"key":"num","value":"3.2"}]}', 
    'R_FN_CEILING', '4';

EXEC dbo.sp_Test 'SQLFN', '11.10 COALESCE avec valeur', 
    '{"rules":["R_FN_COALESCE"],"variables":[{"key":"maybe_null","value":"present"}]}', 
    'R_FN_COALESCE', 'present';

EXEC dbo.sp_Test 'SQLFN', '11.11 IIF condition true', 
    '{"rules":["R_FN_IIF"],"variables":[{"key":"num","value":"100"}]}', 
    'R_FN_IIF', 'BIG';

EXEC dbo.sp_Test 'SQLFN', '11.12 IIF condition false', 
    '{"rules":["R_FN_IIF"],"variables":[{"key":"num","value":"25"}]}', 
    'R_FN_IIF', 'SMALL';

EXEC dbo.sp_Test 'SQLFN', '11.13 Fonctions imbriquées UPPER(LEFT())', 
    '{"rules":["R_FN_NESTED"],"variables":[{"key":"txt","value":"hello"}]}', 
    'R_FN_NESTED', 'HEL';

EXEC dbo.sp_Test 'SQLFN', '11.14 Fonctions math POWER + SQRT', 
    '{"rules":["R_FN_MATH"],"variables":[{"key":"num","value":"4"}]}', 
    'R_FN_MATH', '18';

PRINT '';
GO

-- =========================================================================
-- RAPPORT TESTS FONCTIONNELS
-- =========================================================================
PRINT '======================================================================';
PRINT '    RAPPORT TESTS FONCTIONNELS';
PRINT '======================================================================';
PRINT '';

SELECT 
    Category,
    COUNT(*) AS Total,
    SUM(CASE WHEN Passed = 1 THEN 1 ELSE 0 END) AS [Pass],
    SUM(CASE WHEN Passed = 0 THEN 1 ELSE 0 END) AS [Fail]
FROM dbo.TestResults
GROUP BY Category
ORDER BY Category;

DECLARE @Total INT, @Pass INT, @Fail INT;
SELECT @Total = COUNT(*), 
       @Pass = SUM(CASE WHEN Passed = 1 THEN 1 ELSE 0 END),
       @Fail = SUM(CASE WHEN Passed = 0 THEN 1 ELSE 0 END)
FROM dbo.TestResults;

PRINT '';
PRINT '  TOTAL: ' + CAST(@Total AS VARCHAR) + ' tests';
PRINT '  PASS:  ' + CAST(@Pass AS VARCHAR) + ' (' + CAST(100*@Pass/@Total AS VARCHAR) + '%)';
PRINT '  FAIL:  ' + CAST(@Fail AS VARCHAR);
PRINT '';

IF @Fail > 0
BEGIN
    PRINT '-- Tests échoués --';
    SELECT Category, TestName, Expected, Actual, ErrorMsg
    FROM dbo.TestResults WHERE Passed = 0;
END
PRINT '';
GO

-- =========================================================================
-- TESTS DE PERFORMANCE
-- =========================================================================
PRINT '======================================================================';
PRINT '    TESTS DE PERFORMANCE';
PRINT '======================================================================';
PRINT '';

EXEC dbo.sp_Benchmark 'PERF-01 Constante', 
    '{"rules":["R_CONST_INT"]}', 100;

EXEC dbo.sp_Benchmark 'PERF-02 Calcul simple', 
    '{"rules":["R_CALC_COMPLEX"]}', 100;

EXEC dbo.sp_Benchmark 'PERF-03 Variable', 
    '{"rules":["R_VAR_CALC"],"variables":[{"key":"A","value":"100"},{"key":"B","value":"200"}]}', 100;

EXEC dbo.sp_Benchmark 'PERF-04 Agrégat 5 éléments', 
    '{"rules":["R_SUM","R_AVG","R_COUNT"],"variables":[{"key":"N_1","value":"10"},{"key":"N_2","value":"20"},{"key":"N_3","value":"30"},{"key":"N_4","value":"40"},{"key":"N_5","value":"50"}]}', 100;

EXEC dbo.sp_Benchmark 'PERF-05 JSONIFY', 
    '{"rules":["R_JSON"],"variables":[{"key":"P_a","value":"1"},{"key":"P_b","value":"2"},{"key":"P_c","value":"3"},{"key":"P_d","value":"4"},{"key":"P_e","value":"5"}]}', 100;

EXEC dbo.sp_Benchmark 'PERF-06 CONCAT', 
    '{"rules":["R_CONCAT"],"variables":[{"key":"L_1","value":"A"},{"key":"L_2","value":"B"},{"key":"L_3","value":"C"},{"key":"L_4","value":"D"},{"key":"L_5","value":"E"}]}', 100;

PRINT '';
GO

-- =========================================================================
-- RAPPORT PERFORMANCE
-- =========================================================================
PRINT '======================================================================';
PRINT '    RAPPORT PERFORMANCE';
PRINT '======================================================================';
PRINT '';

SELECT 
    TestName,
    Iterations AS [Iter],
    CAST(AvgMs AS VARCHAR) + ' ms' AS [Avg],
    CAST(MinMs AS VARCHAR) + ' ms' AS [Min],
    CAST(MaxMs AS VARCHAR) + ' ms' AS [Max],
    CAST(OpsPerSec AS VARCHAR) + ' /s' AS [Ops/Sec]
FROM dbo.PerfResults
ORDER BY AvgMs;

PRINT '';

SELECT 
    'GLOBAL' AS Summary,
    SUM(Iterations) AS TotalIterations,
    CAST(AVG(AvgMs) AS VARCHAR) + ' ms' AS AvgMs,
    CAST(AVG(OpsPerSec) AS VARCHAR) + ' ops/s' AS AvgOpsPerSec
FROM dbo.PerfResults;

PRINT '';
GO

-- =========================================================================
-- RÉSUMÉ FINAL
-- =========================================================================
PRINT '======================================================================';
PRINT '    RÉSUMÉ FINAL';
PRINT '======================================================================';
PRINT '';

DECLARE @TotalTests INT, @PassedTests INT, @TotalBenchmarks INT;
SELECT @TotalTests = COUNT(*), @PassedTests = SUM(CASE WHEN Passed=1 THEN 1 ELSE 0 END) FROM dbo.TestResults;
SELECT @TotalBenchmarks = COUNT(*) FROM dbo.PerfResults;

PRINT '  Tests fonctionnels: ' + CAST(@PassedTests AS VARCHAR) + '/' + CAST(@TotalTests AS VARCHAR);
PRINT '  Benchmarks:         ' + CAST(@TotalBenchmarks AS VARCHAR) + ' exécutés';
PRINT '';

IF @PassedTests = @TotalTests
    PRINT '  ✅ TOUS LES TESTS PASSENT - MOTEUR V6.7 CONFORME SPEC V1.6.0';
ELSE
    PRINT '  ❌ ' + CAST(@TotalTests - @PassedTests AS VARCHAR) + ' TEST(S) EN ÉCHEC';

PRINT '';
PRINT '======================================================================';
GO
