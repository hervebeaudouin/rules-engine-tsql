/***********************************************************************
    TESTS COMPLETS V6.9.2 - SUITE EXHAUSTIVE
    =========================================================================
    Conformité: SPEC V1.7.1
    Objectifs:
      - Couverture complète de tous les cas d'usage
      - Edge cases et cas limites
      - Tests de régression
      - Benchmarks pour optimisation par paliers
    
    Structure:
      PARTIE 1: Tests fonctionnels (~150 tests)
      PARTIE 2: Tests de robustesse (~30 tests)
      PARTIE 3: Tests de performance (benchmarks gradués)
************************************************************************/
SET NOCOUNT ON;
GO

PRINT '======================================================================';
PRINT '    TESTS COMPLETS V6.9.2 - SPEC V1.7.1';
PRINT '======================================================================';
PRINT 'Date: ' + CONVERT(VARCHAR, GETDATE(), 120);
PRINT '';
GO

-- =========================================================================
-- INFRASTRUCTURE DE TEST
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
    DurationMs DECIMAL(10,3),
    ExecutedAt DATETIME2 DEFAULT SYSDATETIME()
);

IF OBJECT_ID('dbo.BenchmarkResults','U') IS NOT NULL DROP TABLE dbo.BenchmarkResults;
CREATE TABLE dbo.BenchmarkResults (
    BenchId INT IDENTITY(1,1) PRIMARY KEY,
    BenchName NVARCHAR(200),
    Category NVARCHAR(50),
    Complexity NVARCHAR(20),  -- SIMPLE, MEDIUM, COMPLEX, EXTREME
    Iterations INT,
    TotalMs INT,
    AvgMs DECIMAL(10,4),
    MinMs DECIMAL(10,4),
    MaxMs DECIMAL(10,4),
    P50Ms DECIMAL(10,4),
    P95Ms DECIMAL(10,4),
    P99Ms DECIMAL(10,4),
    OpsPerSec DECIMAL(10,2),
    MemoryKB INT,
    ExecutedAt DATETIME2 DEFAULT SYSDATETIME()
);

IF OBJECT_ID('dbo.BenchmarkRuns','U') IS NOT NULL DROP TABLE dbo.BenchmarkRuns;
CREATE TABLE dbo.BenchmarkRuns (
    RunId INT IDENTITY(1,1) PRIMARY KEY,
    BenchName NVARCHAR(200),
    Iteration INT,
    DurationMs DECIMAL(10,4)
);
GO

-- =========================================================================
-- PROCÉDURE DE TEST STANDARD
-- =========================================================================
IF OBJECT_ID('dbo.sp_Test','P') IS NOT NULL DROP PROCEDURE dbo.sp_Test;
GO

CREATE PROCEDURE dbo.sp_Test
    @Section NVARCHAR(50),
    @Category NVARCHAR(50),
    @TestName NVARCHAR(200),
    @InputJson NVARCHAR(MAX),
    @RuleCode NVARCHAR(200),
    @Expected NVARCHAR(MAX),
    @ExpectNull BIT = 0,
    @ExpectError BIT = 0,
    @Tolerance DECIMAL(10,6) = NULL  -- Pour comparaisons numériques avec tolérance
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
        ELSE IF @Tolerance IS NOT NULL
        BEGIN
            -- Comparaison numérique avec tolérance
            DECLARE @ExpNum DECIMAL(38,18), @ActNum DECIMAL(38,18);
            SET @ExpNum = TRY_CAST(@Expected AS DECIMAL(38,18));
            SET @ActNum = TRY_CAST(@Actual AS DECIMAL(38,18));
            SET @Passed = CASE WHEN ABS(@ExpNum - @ActNum) <= @Tolerance THEN 1 ELSE 0 END;
        END
        ELSE
            SET @Passed = CASE WHEN @Actual = @Expected THEN 1 ELSE 0 END;
        
        IF @Passed = 0
            SET @Err = 'Attendu: [' + ISNULL(CASE WHEN @ExpectError=1 THEN 'ERROR' WHEN @ExpectNull=1 THEN 'NULL' ELSE @Expected END, 'NULL') 
                     + '] / Obtenu: [' + ISNULL(@Actual, 'NULL') + '] (State=' + ISNULL(@State,'?') + ')';
    END TRY
    BEGIN CATCH
        SET @Err = 'EXCEPTION: ' + ERROR_MESSAGE();
    END CATCH
    
    DECLARE @Duration DECIMAL(10,3) = DATEDIFF(MICROSECOND, @Start, SYSDATETIME()) / 1000.0;
    
    INSERT INTO dbo.TestResults (Section, Category, TestName, Expected, Actual, Passed, ErrorMsg, DurationMs)
    VALUES (@Section, @Category, @TestName, 
            CASE WHEN @ExpectError=1 THEN 'ERROR' WHEN @ExpectNull=1 THEN 'NULL' ELSE @Expected END,
            @Actual, @Passed, @Err, @Duration);
    
    PRINT CASE WHEN @Passed=1 THEN '  [PASS] ' ELSE '  [FAIL] ' END + @TestName 
          + CASE WHEN @Passed=0 THEN ' -> ' + ISNULL(@Err,'') ELSE '' END;
END;
GO

-- =========================================================================
-- PROCÉDURE DE BENCHMARK AVANCÉ
-- =========================================================================
IF OBJECT_ID('dbo.sp_Benchmark','P') IS NOT NULL DROP PROCEDURE dbo.sp_Benchmark;
GO

CREATE PROCEDURE dbo.sp_Benchmark
    @BenchName NVARCHAR(200),
    @Category NVARCHAR(50),
    @Complexity NVARCHAR(20),
    @InputJson NVARCHAR(MAX),
    @Iterations INT = 50,
    @WarmupIterations INT = 5
AS
BEGIN
    SET NOCOUNT ON;
    
    DECLARE @i INT = 1, @Output NVARCHAR(MAX);
    DECLARE @Start DATETIME2, @End DATETIME2, @Duration DECIMAL(10,4);
    DECLARE @TotalMs DECIMAL(18,4) = 0;
    DECLARE @MinMs DECIMAL(10,4) = 999999, @MaxMs DECIMAL(10,4) = 0;
    
    -- Nettoyage runs précédents
    DELETE FROM dbo.BenchmarkRuns WHERE BenchName = @BenchName;
    
    -- Warmup (non comptabilisé)
    WHILE @i <= @WarmupIterations
    BEGIN
        EXEC dbo.sp_RunRulesEngine @InputJson, @Output OUTPUT;
        SET @i = @i + 1;
    END
    
    -- Exécutions mesurées
    SET @i = 1;
    WHILE @i <= @Iterations
    BEGIN
        SET @Start = SYSDATETIME();
        EXEC dbo.sp_RunRulesEngine @InputJson, @Output OUTPUT;
        SET @End = SYSDATETIME();
        
        SET @Duration = DATEDIFF(MICROSECOND, @Start, @End) / 1000.0;
        SET @TotalMs = @TotalMs + @Duration;
        IF @Duration < @MinMs SET @MinMs = @Duration;
        IF @Duration > @MaxMs SET @MaxMs = @Duration;
        
        INSERT INTO dbo.BenchmarkRuns (BenchName, Iteration, DurationMs)
        VALUES (@BenchName, @i, @Duration);
        
        SET @i = @i + 1;
    END
    
    -- Calcul des percentiles
    DECLARE @P50 DECIMAL(10,4), @P95 DECIMAL(10,4), @P99 DECIMAL(10,4);
    
    SELECT @P50 = AVG(DurationMs)
    FROM (
        SELECT DurationMs, ROW_NUMBER() OVER (ORDER BY DurationMs) AS rn,
               COUNT(*) OVER () AS cnt
        FROM dbo.BenchmarkRuns WHERE BenchName = @BenchName
    ) t WHERE rn IN (cnt/2, cnt/2+1);
    
    SELECT @P95 = MIN(DurationMs)
    FROM (
        SELECT DurationMs, NTILE(100) OVER (ORDER BY DurationMs) AS pct
        FROM dbo.BenchmarkRuns WHERE BenchName = @BenchName
    ) t WHERE pct >= 95;
    
    SELECT @P99 = MIN(DurationMs)
    FROM (
        SELECT DurationMs, NTILE(100) OVER (ORDER BY DurationMs) AS pct
        FROM dbo.BenchmarkRuns WHERE BenchName = @BenchName
    ) t WHERE pct >= 99;
    
    -- Insertion résultat
    INSERT INTO dbo.BenchmarkResults (BenchName, Category, Complexity, Iterations, TotalMs, 
                                       AvgMs, MinMs, MaxMs, P50Ms, P95Ms, P99Ms, OpsPerSec)
    VALUES (@BenchName, @Category, @Complexity, @Iterations, @TotalMs,
            @TotalMs / @Iterations, @MinMs, @MaxMs, 
            ISNULL(@P50, @TotalMs/@Iterations), 
            ISNULL(@P95, @MaxMs), 
            ISNULL(@P99, @MaxMs),
            CASE WHEN @TotalMs > 0 THEN @Iterations * 1000.0 / @TotalMs ELSE 0 END);
    
    PRINT '  [BENCH] ' + @BenchName + ': ' 
          + CAST(CAST(@TotalMs/@Iterations AS DECIMAL(10,2)) AS VARCHAR) + ' ms/op'
          + ' (P50=' + CAST(CAST(ISNULL(@P50,0) AS DECIMAL(10,2)) AS VARCHAR) 
          + ', P95=' + CAST(CAST(ISNULL(@P95,0) AS DECIMAL(10,2)) AS VARCHAR) 
          + ', P99=' + CAST(CAST(ISNULL(@P99,0) AS DECIMAL(10,2)) AS VARCHAR) + ')';
END;
GO

PRINT 'Infrastructure de test créée';
PRINT '';
GO

-- =========================================================================
-- NETTOYAGE ET PRÉPARATION DES RÈGLES
-- =========================================================================
PRINT '-- Préparation des règles de test --';

DELETE FROM dbo.RuleDefinitions;
GO

-- =========================================================================
-- SECTION 1: RÈGLES DE BASE
-- =========================================================================

-- 1.1 Constantes de tous types
INSERT INTO dbo.RuleDefinitions (RuleCode, Expression) VALUES 
('C_INT_POS', '42'),
('C_INT_NEG', '-42'),
('C_INT_ZERO', '0'),
('C_DEC_POS', '3.14159265359'),
('C_DEC_NEG', '-2.71828'),
('C_DEC_SMALL', '0.000001'),
('C_DEC_LARGE', '999999999.999999'),
('C_STR_SIMPLE', '''Hello'''),
('C_STR_EMPTY', ''''''),
('C_STR_SPACE', '''   '''),
('C_STR_UNICODE', N'''Héllo Wörld 日本語'''),
('C_STR_QUOTES', '''It''''s a test'''),
('C_STR_SPECIAL', '''<>&"test"'''),
('C_BOOL_TRUE', '1'),
('C_BOOL_FALSE', '0'),
('C_NULL', 'NULL');
GO

-- 1.2 Opérations arithmétiques
INSERT INTO dbo.RuleDefinitions (RuleCode, Expression) VALUES 
('A_ADD', '10+5'),
('A_SUB', '100-37'),
('A_MUL', '7*8'),
('A_DIV', '100.0/8'),
('A_MOD', '17%5'),
('A_NEG', '-(-42)'),
('A_COMPLEX1', '(10+5)*2-30/6'),
('A_COMPLEX2', '((2+3)*(4+1))/5'),
('A_COMPLEX3', '1+2*3-4/2+5%3'),
('A_FLOAT', '1.5*2.5+0.25'),
('A_PREC', '1.0/3.0*3.0'),
('A_CHAIN', '1+2+3+4+5+6+7+8+9+10'),
('A_PAREN_DEEP', '((((1+2)+3)+4)+5)');
GO

-- 1.3 Fonctions SQL
INSERT INTO dbo.RuleDefinitions (RuleCode, Expression) VALUES 
('F_ABS', 'ABS(-42)'),
('F_ROUND', 'ROUND(3.14159, 2)'),
('F_CEILING', 'CEILING(3.14)'),
('F_FLOOR', 'FLOOR(3.99)'),
('F_POWER', 'POWER(2, 10)'),
('F_SQRT', 'SQRT(144)'),
('F_LEN', 'LEN(''Hello'')'),
('F_UPPER', 'UPPER(''hello'')'),
('F_LOWER', 'LOWER(''HELLO'')'),
('F_LTRIM', 'LTRIM(''  test'')'),
('F_RTRIM', 'RTRIM(''test  '')'),
('F_SUBSTRING', 'SUBSTRING(''Hello'', 1, 3)'),
('F_REPLACE', 'REPLACE(''Hello'', ''l'', ''L'')'),
('F_COALESCE', 'COALESCE(NULL, NULL, ''default'')'),
('F_IIF', 'IIF(1>0, ''yes'', ''no'')'),
('F_CASE', 'CASE WHEN 1=1 THEN ''A'' ELSE ''B'' END'),
('F_CAST', 'CAST(42 AS VARCHAR)'),
('F_CONVERT', 'CONVERT(VARCHAR, 42)');
GO

-- 1.4 Variables simples
INSERT INTO dbo.RuleDefinitions (RuleCode, Expression) VALUES 
('V_SIMPLE', '{X}'),
('V_ADD', '{A}+{B}'),
('V_MUL', '{A}*{B}'),
('V_DIV', '{A}/{B}'),
('V_COMPLEX', '({A}+{B})*{C}-{D}/{E}'),
('V_MISSING', '{UNKNOWN}'),
('V_CASE', 'CASE WHEN {X}>50 THEN ''HIGH'' ELSE ''LOW'' END'),
('V_IIF', 'IIF({X}>0, {X}*2, 0)'),
('V_COALESCE', 'COALESCE({X}, {Y}, 0)'),
('V_MIXED', '{A}+10*{B}-5');
GO

-- 1.5 Normalisation FR (virgule décimale)
INSERT INTO dbo.RuleDefinitions (RuleCode, Expression) VALUES 
('N_FR1', '2,5+3,5'),
('N_FR2', '10,25*2'),
('N_FR3', '{X}+1,5'),
('N_FR4', '(2,5+3,5)*2,0'),
('N_FR5', '100,0/3,0');
GO

-- =========================================================================
-- SECTION 2: AGRÉGATS
-- =========================================================================

-- 2.1 Agrégats de base
INSERT INTO dbo.RuleDefinitions (RuleCode, Expression) VALUES 
('AG_SUM', '{SUM(N[_]%)}'),
('AG_AVG', '{AVG(N[_]%)}'),
('AG_MIN', '{MIN(N[_]%)}'),
('AG_MAX', '{MAX(N[_]%)}'),
('AG_COUNT', '{COUNT(N[_]%)}');
GO

-- 2.2 Agrégats positionnels
INSERT INTO dbo.RuleDefinitions (RuleCode, Expression) VALUES 
('AG_FIRST', '{FIRST(S[_]%)}'),
('AG_LAST', '{LAST(S[_]%)}'),
('AG_FIRST_N', '{FIRST(N[_]%)}'),
('AG_LAST_N', '{LAST(N[_]%)}');
GO

-- 2.3 Agrégats filtrés POS
INSERT INTO dbo.RuleDefinitions (RuleCode, Expression) VALUES 
('AG_SUM_POS', '{SUM_POS(V[_]%)}'),
('AG_COUNT_POS', '{COUNT_POS(V[_]%)}'),
('AG_FIRST_POS', '{FIRST_POS(V[_]%)}'),
('AG_LAST_POS', '{LAST_POS(V[_]%)}'),
('AG_AVG_POS', '{AVG_POS(V[_]%)}'),
('AG_MIN_POS', '{MIN_POS(V[_]%)}'),
('AG_MAX_POS', '{MAX_POS(V[_]%)}');
GO

-- 2.4 Agrégats filtrés NEG
INSERT INTO dbo.RuleDefinitions (RuleCode, Expression) VALUES 
('AG_SUM_NEG', '{SUM_NEG(V[_]%)}'),
('AG_COUNT_NEG', '{COUNT_NEG(V[_]%)}'),
('AG_FIRST_NEG', '{FIRST_NEG(V[_]%)}'),
('AG_LAST_NEG', '{LAST_NEG(V[_]%)}'),
('AG_AVG_NEG', '{AVG_NEG(V[_]%)}'),
('AG_MIN_NEG', '{MIN_NEG(V[_]%)}'),
('AG_MAX_NEG', '{MAX_NEG(V[_]%)}');
GO

-- 2.5 Agrégats textuels
INSERT INTO dbo.RuleDefinitions (RuleCode, Expression) VALUES 
('AG_CONCAT', '{CONCAT(S[_]%)}'),
('AG_CONCAT_N', '{CONCAT(N[_]%)}'),
('AG_JSON', '{JSONIFY(J[_]%)}'),
('AG_JSON_MIX', '{JSONIFY(M[_]%)}');
GO

-- 2.6 Agrégats sur ensemble vide
INSERT INTO dbo.RuleDefinitions (RuleCode, Expression) VALUES 
('AG_E_SUM', '{SUM(EMPTY[_]%)}'),
('AG_E_COUNT', '{COUNT(EMPTY[_]%)}'),
('AG_E_FIRST', '{FIRST(EMPTY[_]%)}'),
('AG_E_CONCAT', '{CONCAT(EMPTY[_]%)}'),
('AG_E_JSON', '{JSONIFY(EMPTY[_]%)}');
GO

-- 2.7 Agrégats avec NULL
INSERT INTO dbo.RuleDefinitions (RuleCode, Expression) VALUES 
('AG_N_SUM', '{SUM(NL[_]%)}'),
('AG_N_COUNT', '{COUNT(NL[_]%)}'),
('AG_N_AVG', '{AVG(NL[_]%)}'),
('AG_N_FIRST', '{FIRST(NL[_]%)}'),
('AG_N_LAST', '{LAST(NL[_]%)}'),
('AG_N_CONCAT', '{CONCAT(NL[_]%)}');
GO

-- =========================================================================
-- SECTION 3: SCOPES
-- =========================================================================

-- 3.1 Scope explicite
INSERT INTO dbo.RuleDefinitions (RuleCode, Expression) VALUES 
('SC_VAR', '{SUM(var:SC[_]%)}'),
('SC_RULE', '{SUM(rule:SC[_]%)}'),
('SC_ALL', '{SUM(all:SC[_]%)}'),
('SC_VAR_F', '{FIRST(var:SC[_]%)}'),
('SC_RULE_F', '{FIRST(rule:SC[_]%)}');
GO

-- 3.2 Règles pour scope rule:
INSERT INTO dbo.RuleDefinitions (RuleCode, Expression) VALUES 
('SC_R1', '100'),
('SC_R2', '200'),
('SC_R3', '300');
GO

-- =========================================================================
-- SECTION 4: WILDCARDS ET PATTERNS
-- =========================================================================

-- 4.1 Wildcards SQL
INSERT INTO dbo.RuleDefinitions (RuleCode, Expression) VALUES 
('W_PERCENT', '{SUM(W[_]%)}'),
('W_UNDER', '{COUNT(W[_]?)}'),
('W_MIX', '{SUM(X[_]%[_]Y)}'),
('W_MULTI', '{COUNT(W[_]%%)}');
GO

-- 4.2 Wildcards utilisateur
INSERT INTO dbo.RuleDefinitions (RuleCode, Expression) VALUES 
('W_STAR', '{SUM(W[_]*)}'),
('W_QUEST', '{COUNT(W[_]?)}'),
('W_STAR_MID', '{SUM(X[_]*[_]Y)}');
GO

-- =========================================================================
-- SECTION 5: DÉPENDANCES ET RÉFÉRENCES
-- =========================================================================

-- 5.1 Chaîne simple
INSERT INTO dbo.RuleDefinitions (RuleCode, Expression) VALUES 
('D_A', '10'),
('D_B', '{rule:D_A}+5'),
('D_C', '{rule:D_B}*2'),
('D_D', '{rule:D_C}-10'),
('D_E', '{rule:D_D}/2');
GO

-- 5.2 Arbre de dépendances
INSERT INTO dbo.RuleDefinitions (RuleCode, Expression) VALUES 
('T_L1', '1'),
('T_L2', '2'),
('T_R1', '3'),
('T_R2', '4'),
('T_ML', '{rule:T_L1}+{rule:T_L2}'),
('T_MR', '{rule:T_R1}+{rule:T_R2}'),
('T_ROOT', '{rule:T_ML}*{rule:T_MR}');
GO

-- 5.3 Agrégat sur règles
INSERT INTO dbo.RuleDefinitions (RuleCode, Expression) VALUES 
('RA_1', '10'),
('RA_2', '20'),
('RA_3', '30'),
('RA_SUM', '{SUM(rule:RA[_]%)}'),
('RA_AVG', '{AVG(rule:RA[_]%)}'),
('RA_FIRST', '{FIRST(rule:RA[_]%)}');
GO

-- 5.4 Self-match (doit s'ignorer)
INSERT INTO dbo.RuleDefinitions (RuleCode, Expression) VALUES 
('SM_1', '1'),
('SM_2', '2'),
('SM_3', '3'),
('SM_SUM', '{SUM(rule:SM[_]%)}');  -- Doit ignorer SM_SUM lui-même
GO

-- =========================================================================
-- SECTION 6: CYCLES ET ERREURS
-- =========================================================================

-- 6.1 Cycles
INSERT INTO dbo.RuleDefinitions (RuleCode, Expression) VALUES 
('CYC_A', '{rule:CYC_B}+1'),
('CYC_B', '{rule:CYC_A}+1'),
('SELF', '{rule:SELF}+1'),
('CYC3_A', '{rule:CYC3_B}'),
('CYC3_B', '{rule:CYC3_C}'),
('CYC3_C', '{rule:CYC3_A}');
GO

-- 6.2 Erreurs SQL
INSERT INTO dbo.RuleDefinitions (RuleCode, Expression) VALUES 
('E_DIV0', '1/0'),
('E_OVERFLOW', 'POWER(10.0, 400)'),
('E_CAST', 'CAST(''abc'' AS INT)'),
('E_SYNTAX', 'SELECT * FROM'),
('E_FUNC', 'SQRT(-1)');
GO

-- =========================================================================
-- SECTION 7: AGRÉGATEUR PAR DÉFAUT V1.7.1
-- =========================================================================

INSERT INTO dbo.RuleDefinitions (RuleCode, Expression) VALUES 
('DEF_NUM', '{NUM[_]%}'),           -- Numérique → SUM
('DEF_TXT', '{TXT[_]%}'),           -- Texte → FIRST
('DEF_MIX', '{MIX[_]%}'),           -- Mixte (1er=txt) → FIRST
('DEF_ONE', '{SINGLE}'),          -- Un seul
('DEF_RULE', '{rule:RN[_]%}'),      -- Règles numériques → SUM
('RN_1', '10'),
('RN_2', '20'),
('RN_3', '30');
GO

-- =========================================================================
-- SECTION 8: CAS LIMITES (EDGE CASES)
-- =========================================================================

-- 8.1 Valeurs extrêmes
INSERT INTO dbo.RuleDefinitions (RuleCode, Expression) VALUES 
('EX_LARGE', '99999999999999999999.999999'),
('EX_SMALL', '0.000000000000000001'),
('EX_NEG_LARGE', '-99999999999999999999.999999'),
('EX_PREC', '1.123456789012345678');
GO

-- 8.2 Chaînes longues
INSERT INTO dbo.RuleDefinitions (RuleCode, Expression) VALUES 
('EX_STR_LONG', ''''+REPLICATE('A',1000)+'''');
GO

-- 8.3 Expressions complexes
INSERT INTO dbo.RuleDefinitions (RuleCode, Expression) VALUES 
('EX_NEST', '((((((1+2)+3)+4)+5)+6)+7)'),
('EX_MULTI_AGG', '{SUM(N[_]%)}+{AVG(N[_]%)}+{COUNT(N[_]%)}'),
('EX_COND_NEST', 'CASE WHEN {X}>0 THEN CASE WHEN {X}>50 THEN ''HIGH'' ELSE ''MED'' END ELSE ''LOW'' END');
GO

-- 8.4 Espaces et formatage
INSERT INTO dbo.RuleDefinitions (RuleCode, Expression) VALUES 
('EX_SPACE1', '{ SUM( N[_]% ) }'),
('EX_SPACE2', '{  FIRST  (  S[_]%  )  }'),
('EX_SPACE3', '{ SUM ( var : N[_]% ) }');
GO

-- Compter les règles
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

-- -------------------------------------------------------------------------
-- 1.1 CONSTANTES
-- -------------------------------------------------------------------------
PRINT '-- 1.1 Constantes --';
EXEC dbo.sp_Test 'FONC', 'CONST', '1.1.01 Entier positif', '{"rules":["C_INT_POS"]}', 'C_INT_POS', '42';
EXEC dbo.sp_Test 'FONC', 'CONST', '1.1.02 Entier négatif', '{"rules":["C_INT_NEG"]}', 'C_INT_NEG', '-42';
EXEC dbo.sp_Test 'FONC', 'CONST', '1.1.03 Zéro', '{"rules":["C_INT_ZERO"]}', 'C_INT_ZERO', '0';
EXEC dbo.sp_Test 'FONC', 'CONST', '1.1.04 Décimal positif', '{"rules":["C_DEC_POS"]}', 'C_DEC_POS', '3.14159265359';
EXEC dbo.sp_Test 'FONC', 'CONST', '1.1.05 Décimal négatif', '{"rules":["C_DEC_NEG"]}', 'C_DEC_NEG', '-2.71828';
EXEC dbo.sp_Test 'FONC', 'CONST', '1.1.06 Décimal petit', '{"rules":["C_DEC_SMALL"]}', 'C_DEC_SMALL', '0.000001';
EXEC dbo.sp_Test 'FONC', 'CONST', '1.1.07 Chaîne simple', '{"rules":["C_STR_SIMPLE"]}', 'C_STR_SIMPLE', 'Hello';
EXEC dbo.sp_Test 'FONC', 'CONST', '1.1.08 Chaîne vide', '{"rules":["C_STR_EMPTY"]}', 'C_STR_EMPTY', '';
EXEC dbo.sp_Test 'FONC', 'CONST', '1.1.09 Chaîne espaces', '{"rules":["C_STR_SPACE"]}', 'C_STR_SPACE', '   ';
EXEC dbo.sp_Test 'FONC', 'CONST', '1.1.10 Chaîne quotes', '{"rules":["C_STR_QUOTES"]}', 'C_STR_QUOTES', 'It''s a test';
EXEC dbo.sp_Test 'FONC', 'CONST', '1.1.11 NULL explicite', '{"rules":["C_NULL"]}', 'C_NULL', NULL, 1;
PRINT '';

-- -------------------------------------------------------------------------
-- 1.2 ARITHMÉTIQUE
-- -------------------------------------------------------------------------
PRINT '-- 1.2 Arithmétique --';
EXEC dbo.sp_Test 'FONC', 'ARITH', '1.2.01 Addition', '{"rules":["A_ADD"]}', 'A_ADD', '15';
EXEC dbo.sp_Test 'FONC', 'ARITH', '1.2.02 Soustraction', '{"rules":["A_SUB"]}', 'A_SUB', '63';
EXEC dbo.sp_Test 'FONC', 'ARITH', '1.2.03 Multiplication', '{"rules":["A_MUL"]}', 'A_MUL', '56';
EXEC dbo.sp_Test 'FONC', 'ARITH', '1.2.04 Division', '{"rules":["A_DIV"]}', 'A_DIV', '12.5';
EXEC dbo.sp_Test 'FONC', 'ARITH', '1.2.05 Modulo', '{"rules":["A_MOD"]}', 'A_MOD', '2';
EXEC dbo.sp_Test 'FONC', 'ARITH', '1.2.06 Double négation', '{"rules":["A_NEG"]}', 'A_NEG', '42';
EXEC dbo.sp_Test 'FONC', 'ARITH', '1.2.07 Complexe 1', '{"rules":["A_COMPLEX1"]}', 'A_COMPLEX1', '25';
EXEC dbo.sp_Test 'FONC', 'ARITH', '1.2.08 Complexe 2', '{"rules":["A_COMPLEX2"]}', 'A_COMPLEX2', '5';
EXEC dbo.sp_Test 'FONC', 'ARITH', '1.2.09 Complexe 3', '{"rules":["A_COMPLEX3"]}', 'A_COMPLEX3', '7';
EXEC dbo.sp_Test 'FONC', 'ARITH', '1.2.10 Float', '{"rules":["A_FLOAT"]}', 'A_FLOAT', '4';
EXEC dbo.sp_Test 'FONC', 'ARITH', '1.2.11 Chaîne additions', '{"rules":["A_CHAIN"]}', 'A_CHAIN', '55';
EXEC dbo.sp_Test 'FONC', 'ARITH', '1.2.12 Parenthèses profondes', '{"rules":["A_PAREN_DEEP"]}', 'A_PAREN_DEEP', '15';
PRINT '';

-- -------------------------------------------------------------------------
-- 1.3 FONCTIONS SQL
-- -------------------------------------------------------------------------
PRINT '-- 1.3 Fonctions SQL --';
EXEC dbo.sp_Test 'FONC', 'FUNC', '1.3.01 ABS', '{"rules":["F_ABS"]}', 'F_ABS', '42';
EXEC dbo.sp_Test 'FONC', 'FUNC', '1.3.02 ROUND', '{"rules":["F_ROUND"]}', 'F_ROUND', '3.14';
EXEC dbo.sp_Test 'FONC', 'FUNC', '1.3.03 CEILING', '{"rules":["F_CEILING"]}', 'F_CEILING', '4';
EXEC dbo.sp_Test 'FONC', 'FUNC', '1.3.04 FLOOR', '{"rules":["F_FLOOR"]}', 'F_FLOOR', '3';
EXEC dbo.sp_Test 'FONC', 'FUNC', '1.3.05 POWER', '{"rules":["F_POWER"]}', 'F_POWER', '1024';
EXEC dbo.sp_Test 'FONC', 'FUNC', '1.3.06 SQRT', '{"rules":["F_SQRT"]}', 'F_SQRT', '12';
EXEC dbo.sp_Test 'FONC', 'FUNC', '1.3.07 LEN', '{"rules":["F_LEN"]}', 'F_LEN', '5';
EXEC dbo.sp_Test 'FONC', 'FUNC', '1.3.08 UPPER', '{"rules":["F_UPPER"]}', 'F_UPPER', 'HELLO';
EXEC dbo.sp_Test 'FONC', 'FUNC', '1.3.09 LOWER', '{"rules":["F_LOWER"]}', 'F_LOWER', 'hello';
EXEC dbo.sp_Test 'FONC', 'FUNC', '1.3.10 SUBSTRING', '{"rules":["F_SUBSTRING"]}', 'F_SUBSTRING', 'Hel';
EXEC dbo.sp_Test 'FONC', 'FUNC', '1.3.11 REPLACE', '{"rules":["F_REPLACE"]}', 'F_REPLACE', 'HeLLo';
EXEC dbo.sp_Test 'FONC', 'FUNC', '1.3.12 COALESCE', '{"rules":["F_COALESCE"]}', 'F_COALESCE', 'default';
EXEC dbo.sp_Test 'FONC', 'FUNC', '1.3.13 IIF', '{"rules":["F_IIF"]}', 'F_IIF', 'yes';
EXEC dbo.sp_Test 'FONC', 'FUNC', '1.3.14 CASE', '{"rules":["F_CASE"]}', 'F_CASE', 'A';
PRINT '';

-- -------------------------------------------------------------------------
-- 1.4 VARIABLES
-- -------------------------------------------------------------------------
PRINT '-- 1.4 Variables --';
EXEC dbo.sp_Test 'FONC', 'VAR', '1.4.01 Simple', 
    '{"rules":["V_SIMPLE"],"variables":[{"key":"X","value":"42"}]}', 'V_SIMPLE', '42';
EXEC dbo.sp_Test 'FONC', 'VAR', '1.4.02 Addition', 
    '{"rules":["V_ADD"],"variables":[{"key":"A","value":"10"},{"key":"B","value":"5"}]}', 'V_ADD', '15';
EXEC dbo.sp_Test 'FONC', 'VAR', '1.4.03 Multiplication', 
    '{"rules":["V_MUL"],"variables":[{"key":"A","value":"7"},{"key":"B","value":"6"}]}', 'V_MUL', '42';
EXEC dbo.sp_Test 'FONC', 'VAR', '1.4.04 Division', 
    '{"rules":["V_DIV"],"variables":[{"key":"A","value":"100"},{"key":"B","value":"4"}]}', 'V_DIV', '25';
EXEC dbo.sp_Test 'FONC', 'VAR', '1.4.05 Complexe', 
    '{"rules":["V_COMPLEX"],"variables":[{"key":"A","value":"10"},{"key":"B","value":"5"},{"key":"C","value":"3"},{"key":"D","value":"30"},{"key":"E","value":"2"}]}', 
    'V_COMPLEX', '30';
EXEC dbo.sp_Test 'FONC', 'VAR', '1.4.06 Manquante', 
    '{"rules":["V_MISSING"]}', 'V_MISSING', NULL, 1;
EXEC dbo.sp_Test 'FONC', 'VAR', '1.4.07 CASE HIGH', 
    '{"rules":["V_CASE"],"variables":[{"key":"X","value":"100"}]}', 'V_CASE', 'HIGH';
EXEC dbo.sp_Test 'FONC', 'VAR', '1.4.08 CASE LOW', 
    '{"rules":["V_CASE"],"variables":[{"key":"X","value":"25"}]}', 'V_CASE', 'LOW';
EXEC dbo.sp_Test 'FONC', 'VAR', '1.4.09 IIF positif', 
    '{"rules":["V_IIF"],"variables":[{"key":"X","value":"10"}]}', 'V_IIF', '20';
EXEC dbo.sp_Test 'FONC', 'VAR', '1.4.10 IIF négatif', 
    '{"rules":["V_IIF"],"variables":[{"key":"X","value":"-5"}]}', 'V_IIF', '0';
EXEC dbo.sp_Test 'FONC', 'VAR', '1.4.11 COALESCE premier', 
    '{"rules":["V_COALESCE"],"variables":[{"key":"X","value":"42"}]}', 'V_COALESCE', '42';
PRINT '';

-- -------------------------------------------------------------------------
-- 1.5 NORMALISATION FR
-- -------------------------------------------------------------------------
PRINT '-- 1.5 Normalisation FR --';
EXEC dbo.sp_Test 'FONC', 'NORM', '1.5.01 Virgule addition', '{"rules":["N_FR1"]}', 'N_FR1', '6';
EXEC dbo.sp_Test 'FONC', 'NORM', '1.5.02 Virgule multiplication', '{"rules":["N_FR2"]}', 'N_FR2', '20.5';
EXEC dbo.sp_Test 'FONC', 'NORM', '1.5.03 Virgule + variable', 
    '{"rules":["N_FR3"],"variables":[{"key":"X","value":"10"}]}', 'N_FR3', '11.5';
EXEC dbo.sp_Test 'FONC', 'NORM', '1.5.04 Virgule complexe', '{"rules":["N_FR4"]}', 'N_FR4', '12';
PRINT '';

-- -------------------------------------------------------------------------
-- 2.1 AGRÉGATS DE BASE
-- -------------------------------------------------------------------------
PRINT '-- 2.1 Agrégats de base --';
DECLARE @VarsN NVARCHAR(MAX) = '{"rules":["AG_SUM","AG_AVG","AG_MIN","AG_MAX","AG_COUNT"],"variables":[{"key":"N_1","value":"10"},{"key":"N_2","value":"20"},{"key":"N_3","value":"30"},{"key":"N_4","value":"40"},{"key":"N_5","value":"50"}]}';
EXEC dbo.sp_Test 'FONC', 'AGG', '2.1.01 SUM', @VarsN, 'AG_SUM', '150';
EXEC dbo.sp_Test 'FONC', 'AGG', '2.1.02 AVG', @VarsN, 'AG_AVG', '30';
EXEC dbo.sp_Test 'FONC', 'AGG', '2.1.03 MIN', @VarsN, 'AG_MIN', '10';
EXEC dbo.sp_Test 'FONC', 'AGG', '2.1.04 MAX', @VarsN, 'AG_MAX', '50';
EXEC dbo.sp_Test 'FONC', 'AGG', '2.1.05 COUNT', @VarsN, 'AG_COUNT', '5';
PRINT '';

-- -------------------------------------------------------------------------
-- 2.2 AGRÉGATS POSITIONNELS
-- -------------------------------------------------------------------------
PRINT '-- 2.2 Agrégats positionnels --';
DECLARE @VarsS NVARCHAR(MAX) = '{"rules":["AG_FIRST","AG_LAST"],"variables":[{"key":"S_1","value":"Alpha"},{"key":"S_2","value":"Beta"},{"key":"S_3","value":"Gamma"}]}';
EXEC dbo.sp_Test 'FONC', 'AGG', '2.2.01 FIRST texte', @VarsS, 'AG_FIRST', 'Alpha';
EXEC dbo.sp_Test 'FONC', 'AGG', '2.2.02 LAST texte', @VarsS, 'AG_LAST', 'Gamma';
SET @VarsS = '{"rules":["AG_FIRST_N","AG_LAST_N"],"variables":[{"key":"N_1","value":"10"},{"key":"N_2","value":"20"},{"key":"N_3","value":"30"}]}';
EXEC dbo.sp_Test 'FONC', 'AGG', '2.2.03 FIRST num', @VarsS, 'AG_FIRST_N', '10';
EXEC dbo.sp_Test 'FONC', 'AGG', '2.2.04 LAST num', @VarsS, 'AG_LAST_N', '30';
PRINT '';

-- -------------------------------------------------------------------------
-- 2.3 AGRÉGATS POS/NEG
-- -------------------------------------------------------------------------
PRINT '-- 2.3 Agrégats POS/NEG --';
DECLARE @VarsV NVARCHAR(MAX) = '{"rules":["AG_SUM_POS","AG_COUNT_POS","AG_FIRST_POS","AG_LAST_POS","AG_SUM_NEG","AG_COUNT_NEG","AG_FIRST_NEG","AG_LAST_NEG"],"variables":[{"key":"V_1","value":"-10"},{"key":"V_2","value":"15"},{"key":"V_3","value":"-5"},{"key":"V_4","value":"25"},{"key":"V_5","value":"30"}]}';
EXEC dbo.sp_Test 'FONC', 'AGG', '2.3.01 SUM_POS', @VarsV, 'AG_SUM_POS', '70';
EXEC dbo.sp_Test 'FONC', 'AGG', '2.3.02 COUNT_POS', @VarsV, 'AG_COUNT_POS', '3';
EXEC dbo.sp_Test 'FONC', 'AGG', '2.3.03 FIRST_POS', @VarsV, 'AG_FIRST_POS', '15';
EXEC dbo.sp_Test 'FONC', 'AGG', '2.3.04 LAST_POS', @VarsV, 'AG_LAST_POS', '30';
EXEC dbo.sp_Test 'FONC', 'AGG', '2.3.05 SUM_NEG', @VarsV, 'AG_SUM_NEG', '-15';
EXEC dbo.sp_Test 'FONC', 'AGG', '2.3.06 COUNT_NEG', @VarsV, 'AG_COUNT_NEG', '2';
EXEC dbo.sp_Test 'FONC', 'AGG', '2.3.07 FIRST_NEG', @VarsV, 'AG_FIRST_NEG', '-10';
EXEC dbo.sp_Test 'FONC', 'AGG', '2.3.08 LAST_NEG', @VarsV, 'AG_LAST_NEG', '-5';
PRINT '';

-- -------------------------------------------------------------------------
-- 2.4 CONCAT ET JSONIFY
-- -------------------------------------------------------------------------
PRINT '-- 2.4 CONCAT et JSONIFY --';
DECLARE @VarsTxt NVARCHAR(MAX) = '{"rules":["AG_CONCAT"],"variables":[{"key":"S_1","value":"A"},{"key":"S_2","value":"B"},{"key":"S_3","value":"C"}]}';
EXEC dbo.sp_Test 'FONC', 'AGG', '2.4.01 CONCAT', @VarsTxt, 'AG_CONCAT', 'ABC';

SET @VarsTxt = '{"rules":["AG_JSON"],"variables":[{"key":"J_A","value":"1"},{"key":"J_B","value":"hello"},{"key":"J_C","value":"true"}]}';
EXEC dbo.sp_Test 'FONC', 'AGG', '2.4.02 JSONIFY simple', @VarsTxt, 'AG_JSON', '{"J_A":1,"J_B":"hello","J_C":true}';
PRINT '';

-- -------------------------------------------------------------------------
-- 2.5 ENSEMBLE VIDE
-- -------------------------------------------------------------------------
PRINT '-- 2.5 Ensemble vide --';
DECLARE @VarsEmpty NVARCHAR(MAX) = '{"rules":["AG_E_SUM","AG_E_COUNT","AG_E_FIRST","AG_E_CONCAT","AG_E_JSON"]}';
EXEC dbo.sp_Test 'FONC', 'AGG', '2.5.01 SUM vide', @VarsEmpty, 'AG_E_SUM', NULL, 1;
EXEC dbo.sp_Test 'FONC', 'AGG', '2.5.02 COUNT vide', @VarsEmpty, 'AG_E_COUNT', '0';
EXEC dbo.sp_Test 'FONC', 'AGG', '2.5.03 FIRST vide', @VarsEmpty, 'AG_E_FIRST', NULL, 1;
EXEC dbo.sp_Test 'FONC', 'AGG', '2.5.04 CONCAT vide', @VarsEmpty, 'AG_E_CONCAT', '';
EXEC dbo.sp_Test 'FONC', 'AGG', '2.5.05 JSONIFY vide', @VarsEmpty, 'AG_E_JSON', '{}';
PRINT '';

-- -------------------------------------------------------------------------
-- 2.6 GESTION NULL
-- -------------------------------------------------------------------------
PRINT '-- 2.6 Gestion NULL --';
DECLARE @VarsNL NVARCHAR(MAX) = '{"rules":["AG_N_SUM","AG_N_COUNT","AG_N_AVG","AG_N_FIRST","AG_N_LAST","AG_N_CONCAT"],"variables":[{"key":"NL_1","value":"10"},{"key":"NL_2","value":null},{"key":"NL_3","value":"30"},{"key":"NL_4","value":null},{"key":"NL_5","value":"50"}]}';
EXEC dbo.sp_Test 'FONC', 'NULL', '2.6.01 SUM ignore NULL', @VarsNL, 'AG_N_SUM', '90';
EXEC dbo.sp_Test 'FONC', 'NULL', '2.6.02 COUNT ignore NULL', @VarsNL, 'AG_N_COUNT', '3';
EXEC dbo.sp_Test 'FONC', 'NULL', '2.6.03 AVG ignore NULL', @VarsNL, 'AG_N_AVG', '30';
EXEC dbo.sp_Test 'FONC', 'NULL', '2.6.04 FIRST ignore NULL', @VarsNL, 'AG_N_FIRST', '10';
EXEC dbo.sp_Test 'FONC', 'NULL', '2.6.05 LAST ignore NULL', @VarsNL, 'AG_N_LAST', '50';
PRINT '';

-- -------------------------------------------------------------------------
-- 3. SCOPES
-- -------------------------------------------------------------------------
PRINT '-- 3. Scopes --';
DECLARE @VarsSC NVARCHAR(MAX) = '{"rules":["SC_VAR","SC_RULE","SC_ALL","SC_R1","SC_R2","SC_R3"],"variables":[{"key":"SC_1","value":"10"},{"key":"SC_2","value":"20"}]}';
EXEC dbo.sp_Test 'FONC', 'SCOPE', '3.01 var: only', @VarsSC, 'SC_VAR', '30';
EXEC dbo.sp_Test 'FONC', 'SCOPE', '3.02 rule: only', @VarsSC, 'SC_RULE', '600';
EXEC dbo.sp_Test 'FONC', 'SCOPE', '3.03 all: both', @VarsSC, 'SC_ALL', '630';
PRINT '';

-- -------------------------------------------------------------------------
-- 4. WILDCARDS
-- -------------------------------------------------------------------------
PRINT '-- 4. Wildcards --';
DECLARE @VarsW NVARCHAR(MAX) = '{"rules":["W_PERCENT","W_UNDER","W_STAR"],"variables":[{"key":"W_1","value":"10"},{"key":"W_2","value":"20"},{"key":"W_3","value":"30"},{"key":"W_A","value":"5"}]}';
EXEC dbo.sp_Test 'FONC', 'WILD', '4.01 Percent %', @VarsW, 'W_PERCENT', '65';
EXEC dbo.sp_Test 'FONC', 'WILD', '4.02 Underscore _', @VarsW, 'W_UNDER', '4';
EXEC dbo.sp_Test 'FONC', 'WILD', '4.03 Star *', @VarsW, 'W_STAR', '65';

SET @VarsW = '{"rules":["W_MIX"],"variables":[{"key":"X_1_Y","value":"10"},{"key":"X_2_Y","value":"20"},{"key":"X_ABC_Y","value":"30"}]}';
EXEC dbo.sp_Test 'FONC', 'WILD', '4.04 Pattern X_%_Y', @VarsW, 'W_MIX', '60';
PRINT '';

-- -------------------------------------------------------------------------
-- 5. DÉPENDANCES
-- -------------------------------------------------------------------------
PRINT '-- 5. Dépendances --';
EXEC dbo.sp_Test 'FONC', 'DEP', '5.01 Chaîne A=10', '{"rules":["D_A"]}', 'D_A', '10';
EXEC dbo.sp_Test 'FONC', 'DEP', '5.02 Chaîne B=A+5=15', '{"rules":["D_B"]}', 'D_B', '15';
EXEC dbo.sp_Test 'FONC', 'DEP', '5.03 Chaîne C=B*2=30', '{"rules":["D_C"]}', 'D_C', '30';
EXEC dbo.sp_Test 'FONC', 'DEP', '5.04 Chaîne D=C-10=20', '{"rules":["D_D"]}', 'D_D', '20';
EXEC dbo.sp_Test 'FONC', 'DEP', '5.05 Chaîne E=D/2=10', '{"rules":["D_E"]}', 'D_E', '10';
EXEC dbo.sp_Test 'FONC', 'DEP', '5.06 Arbre ROOT=(1+2)*(3+4)=21', '{"rules":["T_ROOT"]}', 'T_ROOT', '21';
EXEC dbo.sp_Test 'FONC', 'DEP', '5.07 Agrégat règles SUM=60', '{"rules":["RA_SUM"]}', 'RA_SUM', '60';
EXEC dbo.sp_Test 'FONC', 'DEP', '5.08 Agrégat règles AVG=20', '{"rules":["RA_AVG"]}', 'RA_AVG', '20';
EXEC dbo.sp_Test 'FONC', 'DEP', '5.09 Agrégat règles FIRST=10', '{"rules":["RA_FIRST"]}', 'RA_FIRST', '10';
PRINT '';

-- -------------------------------------------------------------------------
-- 5.1 SELF-MATCH
-- -------------------------------------------------------------------------
PRINT '-- 5.1 Self-match --';
EXEC dbo.sp_Test 'FONC', 'SELF', '5.1.01 Self-match ignoré (1+2+3=6)', '{"rules":["SM_SUM"]}', 'SM_SUM', '6';
PRINT '';

-- -------------------------------------------------------------------------
-- 6. CYCLES
-- -------------------------------------------------------------------------
PRINT '-- 6. Cycles --';
EXEC dbo.sp_Test 'FONC', 'CYCLE', '6.01 Cycle mutuel A↔B', '{"rules":["CYC_A"]}', 'CYC_A', NULL, 0, 1;
EXEC dbo.sp_Test 'FONC', 'CYCLE', '6.02 Self-cycle', '{"rules":["SELF"]}', 'SELF', NULL, 0, 1;
EXEC dbo.sp_Test 'FONC', 'CYCLE', '6.03 Cycle triangulaire A→B→C→A', '{"rules":["CYC3_A"]}', 'CYC3_A', NULL, 0, 1;
PRINT '';

-- -------------------------------------------------------------------------
-- 7. ERREURS SQL
-- -------------------------------------------------------------------------
PRINT '-- 7. Erreurs SQL --';
EXEC dbo.sp_Test 'FONC', 'ERROR', '7.01 Division par zéro', '{"rules":["E_DIV0"]}', 'E_DIV0', NULL, 0, 1;
EXEC dbo.sp_Test 'FONC', 'ERROR', '7.02 Cast invalide', '{"rules":["E_CAST"]}', 'E_CAST', NULL, 0, 1;
EXEC dbo.sp_Test 'FONC', 'ERROR', '7.03 Syntaxe invalide', '{"rules":["E_SYNTAX"]}', 'E_SYNTAX', NULL, 0, 1;
PRINT '';

-- -------------------------------------------------------------------------
-- 8. AGRÉGATEUR PAR DÉFAUT V1.7.1
-- -------------------------------------------------------------------------
PRINT '-- 8. Agrégateur par défaut V1.7.1 --';
EXEC dbo.sp_Test 'FONC', 'DEF', '8.01 Numérique → SUM', 
    '{"rules":["DEF_NUM"],"variables":[{"key":"NUM_1","value":"10"},{"key":"NUM_2","value":"20"},{"key":"NUM_3","value":"30"}]}', 
    'DEF_NUM', '60';
EXEC dbo.sp_Test 'FONC', 'DEF', '8.02 Texte → FIRST', 
    '{"rules":["DEF_TXT"],"variables":[{"key":"TXT_1","value":"Alpha"},{"key":"TXT_2","value":"Beta"}]}', 
    'DEF_TXT', 'Alpha';
EXEC dbo.sp_Test 'FONC', 'DEF', '8.03 Mixte (1er=txt) → FIRST', 
    '{"rules":["DEF_MIX"],"variables":[{"key":"MIX_1","value":"text"},{"key":"MIX_2","value":"123"}]}', 
    'DEF_MIX', 'text';
EXEC dbo.sp_Test 'FONC', 'DEF', '8.04 Un seul numérique → SUM', 
    '{"rules":["DEF_ONE"],"variables":[{"key":"SINGLE","value":"42"}]}', 
    'DEF_ONE', '42';
EXEC dbo.sp_Test 'FONC', 'DEF', '8.05 Règles numériques → SUM', 
    '{"rules":["DEF_RULE"]}', 
    'DEF_RULE', '60';
PRINT '';

-- -------------------------------------------------------------------------
-- 9. CAS LIMITES
-- -------------------------------------------------------------------------
PRINT '-- 9. Cas limites --';
EXEC dbo.sp_Test 'FONC', 'EDGE', '9.01 Espaces token 1', 
    '{"rules":["EX_SPACE1"],"variables":[{"key":"N_1","value":"10"},{"key":"N_2","value":"20"}]}', 
    'EX_SPACE1', '30';
EXEC dbo.sp_Test 'FONC', 'EDGE', '9.02 Espaces token 2', 
    '{"rules":["EX_SPACE2"],"variables":[{"key":"S_1","value":"A"},{"key":"S_2","value":"B"}]}', 
    'EX_SPACE2', 'A';
EXEC dbo.sp_Test 'FONC', 'EDGE', '9.03 Multi-agrégats', 
    '{"rules":["EX_MULTI_AGG"],"variables":[{"key":"N_1","value":"10"},{"key":"N_2","value":"20"},{"key":"N_3","value":"30"}]}', 
    'EX_MULTI_AGG', '83';
EXEC dbo.sp_Test 'FONC', 'EDGE', '9.04 Parenthèses profondes', 
    '{"rules":["EX_NEST"]}', 
    'EX_NEST', '28';
PRINT '';
GO

-- =========================================================================
-- PARTIE 2: TESTS DE ROBUSTESSE
-- =========================================================================
PRINT '';
PRINT '======================================================================';
PRINT '    PARTIE 2: TESTS DE ROBUSTESSE';
PRINT '======================================================================';
PRINT '';

-- Tests de volume
PRINT '-- Tests de volume --';

-- Créer règles pour tests de volume
DECLARE @i INT = 1;
WHILE @i <= 100
BEGIN
    DECLARE @Code NVARCHAR(50) = 'VOL_' + RIGHT('000' + CAST(@i AS VARCHAR), 3);
    DECLARE @Expr NVARCHAR(100) = CAST(@i AS VARCHAR);
    
    IF NOT EXISTS (SELECT 1 FROM dbo.RuleDefinitions WHERE RuleCode = @Code)
        INSERT INTO dbo.RuleDefinitions (RuleCode, Expression) VALUES (@Code, @Expr);
    
    SET @i = @i + 1;
END

-- Test agrégat sur 100 éléments
INSERT INTO dbo.RuleDefinitions (RuleCode, Expression) 
SELECT 'VOL_SUM', '{SUM(rule:VOL[_]%)}' 
WHERE NOT EXISTS (SELECT 1 FROM dbo.RuleDefinitions WHERE RuleCode = 'VOL_SUM');
GO

EXEC dbo.sp_Test 'ROBUST', 'VOLUME', 'R.01 SUM 100 règles (5050)', '{"rules":["VOL_SUM"]}', 'VOL_SUM', '5050';
PRINT '';

-- Tests de récursion profonde
PRINT '-- Récursion profonde --';
DECLARE @j INT = 1;
DECLARE @PrevCode NVARCHAR(50) = NULL;

WHILE @j <= 20
BEGIN
    DECLARE @Code2 NVARCHAR(50) = 'DEEP_' + RIGHT('00' + CAST(@j AS VARCHAR), 2);
    DECLARE @Expr2 NVARCHAR(100);
    
    IF @j = 1
        SET @Expr2 = '1';
    ELSE
        SET @Expr2 = '{rule:' + @PrevCode + '}+1';
    
    IF NOT EXISTS (SELECT 1 FROM dbo.RuleDefinitions WHERE RuleCode = @Code2)
        INSERT INTO dbo.RuleDefinitions (RuleCode, Expression) VALUES (@Code2, @Expr2);
    
    SET @PrevCode = @Code2;
    SET @j = @j + 1;
END
GO

EXEC dbo.sp_Test 'ROBUST', 'DEEP', 'R.02 Chaîne 20 niveaux', '{"rules":["DEEP_20"]}', 'DEEP_20', '20';
PRINT '';

-- Tests de variables volumineuses
PRINT '-- Variables volumineuses --';
DECLARE @BigVars NVARCHAR(MAX) = '{"rules":["AG_SUM"],"variables":[';
DECLARE @k INT = 1;
WHILE @k <= 50
BEGIN
    IF @k > 1 SET @BigVars = @BigVars + ',';
    SET @BigVars = @BigVars + '{"key":"N_' + CAST(@k AS VARCHAR) + '","value":"' + CAST(@k AS VARCHAR) + '"}';
    SET @k = @k + 1;
END
SET @BigVars = @BigVars + ']}';

-- SUM(1..50) = 1275
EXEC dbo.sp_Test 'ROBUST', 'BIGVAR', 'R.03 50 variables', @BigVars, 'AG_SUM', '1275';
PRINT '';
GO

-- =========================================================================
-- PARTIE 3: BENCHMARKS
-- =========================================================================
PRINT '';
PRINT '======================================================================';
PRINT '    PARTIE 3: BENCHMARKS';
PRINT '======================================================================';
PRINT '';

-- -------------------------------------------------------------------------
-- NIVEAU 1: SIMPLE (baseline)
-- -------------------------------------------------------------------------
PRINT '-- Niveau SIMPLE (baseline) --';

EXEC dbo.sp_Benchmark 'B01 Constante entière', 'BASELINE', 'SIMPLE',
    '{"rules":["C_INT_POS"]}', 50, 5;

EXEC dbo.sp_Benchmark 'B02 Calcul simple', 'BASELINE', 'SIMPLE',
    '{"rules":["A_ADD"]}', 50, 5;

EXEC dbo.sp_Benchmark 'B03 Variable simple', 'BASELINE', 'SIMPLE',
    '{"rules":["V_SIMPLE"],"variables":[{"key":"X","value":"42"}]}', 50, 5;

PRINT '';

-- -------------------------------------------------------------------------
-- NIVEAU 2: MEDIUM
-- -------------------------------------------------------------------------
PRINT '-- Niveau MEDIUM --';

EXEC dbo.sp_Benchmark 'B04 Calcul complexe', 'COMPUTE', 'MEDIUM',
    '{"rules":["A_COMPLEX1"]}', 50, 5;

EXEC dbo.sp_Benchmark 'B05 Multi-variables', 'COMPUTE', 'MEDIUM',
    '{"rules":["V_COMPLEX"],"variables":[{"key":"A","value":"10"},{"key":"B","value":"5"},{"key":"C","value":"3"},{"key":"D","value":"30"},{"key":"E","value":"2"}]}', 50, 5;

EXEC dbo.sp_Benchmark 'B06 Agrégat 5 elem', 'AGGREGATE', 'MEDIUM',
    '{"rules":["AG_SUM"],"variables":[{"key":"N_1","value":"10"},{"key":"N_2","value":"20"},{"key":"N_3","value":"30"},{"key":"N_4","value":"40"},{"key":"N_5","value":"50"}]}', 50, 5;

EXEC dbo.sp_Benchmark 'B07 FIRST/LAST', 'AGGREGATE', 'MEDIUM',
    '{"rules":["AG_FIRST","AG_LAST"],"variables":[{"key":"S_1","value":"A"},{"key":"S_2","value":"B"},{"key":"S_3","value":"C"}]}', 50, 5;

PRINT '';

-- -------------------------------------------------------------------------
-- NIVEAU 3: COMPLEX
-- -------------------------------------------------------------------------
PRINT '-- Niveau COMPLEX --';

EXEC dbo.sp_Benchmark 'B08 Agrégat 10 elem', 'AGGREGATE', 'COMPLEX',
    '{"rules":["AG_SUM"],"variables":[{"key":"N_1","value":"1"},{"key":"N_2","value":"2"},{"key":"N_3","value":"3"},{"key":"N_4","value":"4"},{"key":"N_5","value":"5"},{"key":"N_6","value":"6"},{"key":"N_7","value":"7"},{"key":"N_8","value":"8"},{"key":"N_9","value":"9"},{"key":"N_10","value":"10"}]}', 50, 5;

EXEC dbo.sp_Benchmark 'B09 CONCAT', 'AGGREGATE', 'COMPLEX',
    '{"rules":["AG_CONCAT"],"variables":[{"key":"S_1","value":"A"},{"key":"S_2","value":"B"},{"key":"S_3","value":"C"},{"key":"S_4","value":"D"},{"key":"S_5","value":"E"}]}', 50, 5;

EXEC dbo.sp_Benchmark 'B10 JSONIFY', 'AGGREGATE', 'COMPLEX',
    '{"rules":["AG_JSON"],"variables":[{"key":"J_A","value":"1"},{"key":"J_B","value":"hello"},{"key":"J_C","value":"true"},{"key":"J_D","value":"3.14"},{"key":"J_E","value":"test"}]}', 50, 5;

EXEC dbo.sp_Benchmark 'B11 Dépendance chaîne 5', 'DEPENDENCY', 'COMPLEX',
    '{"rules":["D_E"]}', 50, 5;

EXEC dbo.sp_Benchmark 'B12 Dépendance arbre', 'DEPENDENCY', 'COMPLEX',
    '{"rules":["T_ROOT"]}', 50, 5;

PRINT '';

-- -------------------------------------------------------------------------
-- NIVEAU 4: EXTREME
-- -------------------------------------------------------------------------
PRINT '-- Niveau EXTREME --';

EXEC dbo.sp_Benchmark 'B13 Agrégat 50 variables', 'AGGREGATE', 'EXTREME',
    '{"rules":["AG_SUM"],"variables":[{"key":"N_1","value":"1"},{"key":"N_2","value":"2"},{"key":"N_3","value":"3"},{"key":"N_4","value":"4"},{"key":"N_5","value":"5"},{"key":"N_6","value":"6"},{"key":"N_7","value":"7"},{"key":"N_8","value":"8"},{"key":"N_9","value":"9"},{"key":"N_10","value":"10"},{"key":"N_11","value":"11"},{"key":"N_12","value":"12"},{"key":"N_13","value":"13"},{"key":"N_14","value":"14"},{"key":"N_15","value":"15"},{"key":"N_16","value":"16"},{"key":"N_17","value":"17"},{"key":"N_18","value":"18"},{"key":"N_19","value":"19"},{"key":"N_20","value":"20"},{"key":"N_21","value":"21"},{"key":"N_22","value":"22"},{"key":"N_23","value":"23"},{"key":"N_24","value":"24"},{"key":"N_25","value":"25"},{"key":"N_26","value":"26"},{"key":"N_27","value":"27"},{"key":"N_28","value":"28"},{"key":"N_29","value":"29"},{"key":"N_30","value":"30"},{"key":"N_31","value":"31"},{"key":"N_32","value":"32"},{"key":"N_33","value":"33"},{"key":"N_34","value":"34"},{"key":"N_35","value":"35"},{"key":"N_36","value":"36"},{"key":"N_37","value":"37"},{"key":"N_38","value":"38"},{"key":"N_39","value":"39"},{"key":"N_40","value":"40"},{"key":"N_41","value":"41"},{"key":"N_42","value":"42"},{"key":"N_43","value":"43"},{"key":"N_44","value":"44"},{"key":"N_45","value":"45"},{"key":"N_46","value":"46"},{"key":"N_47","value":"47"},{"key":"N_48","value":"48"},{"key":"N_49","value":"49"},{"key":"N_50","value":"50"}]}', 30, 5;

EXEC dbo.sp_Benchmark 'B14 100 règles agrégées', 'AGGREGATE', 'EXTREME',
    '{"rules":["VOL_SUM"]}', 30, 5;

EXEC dbo.sp_Benchmark 'B15 Chaîne 20 niveaux', 'DEPENDENCY', 'EXTREME',
    '{"rules":["DEEP_20"]}', 30, 5;

PRINT '';
GO

-- =========================================================================
-- RAPPORT FINAL
-- =========================================================================
PRINT '======================================================================';
PRINT '    RAPPORT FINAL';
PRINT '======================================================================';
PRINT '';

DECLARE @TotTests INT, @PassTests INT, @FailTests INT;
SELECT @TotTests = COUNT(*), 
       @PassTests = SUM(CAST(Passed AS INT)), 
       @FailTests = SUM(CASE WHEN Passed = 0 THEN 1 ELSE 0 END)
FROM dbo.TestResults;

PRINT '  TESTS FONCTIONNELS';
PRINT '  ------------------';
PRINT '  Total:  ' + CAST(@TotTests AS VARCHAR);
PRINT '  Pass:   ' + CAST(@PassTests AS VARCHAR) + ' (' + CAST(CAST(@PassTests * 100.0 / @TotTests AS INT) AS VARCHAR) + '%)';
PRINT '  Fail:   ' + CAST(@FailTests AS VARCHAR);
PRINT '';

IF @FailTests > 0
BEGIN
    PRINT '  Tests échoués:';
    SELECT '    - ' + Section + '/' + Category + ': ' + TestName AS FailedTest
    FROM dbo.TestResults WHERE Passed = 0;
    PRINT '';
END

IF @PassTests = @TotTests
    PRINT '  ✓ MOTEUR V6.9.2 CONFORME SPEC V1.7.1';
PRINT '';

-- Résumé benchmarks
PRINT '  BENCHMARKS';
PRINT '  ----------';
SELECT 
    Complexity,
    COUNT(*) AS Tests,
    CAST(AVG(AvgMs) AS DECIMAL(10,2)) AS AvgMs,
    CAST(MIN(AvgMs) AS DECIMAL(10,2)) AS MinMs,
    CAST(MAX(AvgMs) AS DECIMAL(10,2)) AS MaxMs
FROM dbo.BenchmarkResults
GROUP BY Complexity
ORDER BY 
    CASE Complexity 
        WHEN 'SIMPLE' THEN 1 
        WHEN 'MEDIUM' THEN 2 
        WHEN 'COMPLEX' THEN 3 
        WHEN 'EXTREME' THEN 4 
    END;

PRINT '';
PRINT '  Détail des benchmarks:';
SELECT 
    '  ' + BenchName AS Benchmark,
    CAST(AvgMs AS VARCHAR) + ' ms' AS Avg,
    'P50=' + CAST(P50Ms AS VARCHAR) + ' P95=' + CAST(P95Ms AS VARCHAR) + ' P99=' + CAST(P99Ms AS VARCHAR) AS Percentiles,
    CAST(OpsPerSec AS VARCHAR) + ' ops/s' AS Throughput
FROM dbo.BenchmarkResults
ORDER BY 
    CASE Complexity 
        WHEN 'SIMPLE' THEN 1 
        WHEN 'MEDIUM' THEN 2 
        WHEN 'COMPLEX' THEN 3 
        WHEN 'EXTREME' THEN 4 
    END,
    BenchName;

PRINT '';
PRINT '======================================================================';
PRINT '    FIN DES TESTS - ' + CONVERT(VARCHAR, GETDATE(), 120);
PRINT '======================================================================';
GO
