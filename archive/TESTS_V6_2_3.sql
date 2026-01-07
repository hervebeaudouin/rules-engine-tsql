/***********************************************************************
    TESTS NORMATIFS - MOTEUR DE REGLES V6.2.3
    Conforme Spec V1.5.5
************************************************************************/

SET NOCOUNT ON;
GO

PRINT '== TESTS NORMATIFS V6.2.3 ==';
GO

-- Preparation
DELETE FROM dbo.RuleDefinitions WHERE RuleCode LIKE 'TEST[_]%';
GO

IF OBJECT_ID('tempdb..#TestResults') IS NOT NULL DROP TABLE #TestResults;
CREATE TABLE #TestResults (
    TestId INT IDENTITY(1,1),
    Category NVARCHAR(50),
    TestName NVARCHAR(100),
    Expected NVARCHAR(500),
    Actual NVARCHAR(500),
    Status VARCHAR(10)
);
GO

-- =========================================================================
-- PARTIE 1 : TESTS fn_ExtractTokens
-- =========================================================================
PRINT '-- Tests fn_ExtractTokens --';

-- Test 1.1: Token simple
DECLARE @T1 NVARCHAR(MAX);
SELECT @T1 = Token FROM dbo.fn_ExtractTokens('{VAR_A}');
INSERT INTO #TestResults (Category, TestName, Expected, Actual, Status)
VALUES ('TOKENS', 'Token simple', '{VAR_A}', @T1, CASE WHEN @T1 = '{VAR_A}' THEN 'PASS' ELSE 'FAIL' END);

-- Test 1.2: Tokens multiples
DECLARE @T2 NVARCHAR(MAX);
SELECT @T2 = STRING_AGG(Token, ',') WITHIN GROUP (ORDER BY Token) FROM dbo.fn_ExtractTokens('{A} + {B}');
INSERT INTO #TestResults (Category, TestName, Expected, Actual, Status)
VALUES ('TOKENS', 'Tokens multiples', '{A},{B}', @T2, CASE WHEN @T2 = '{A},{B}' THEN 'PASS' ELSE 'FAIL' END);

-- Test 1.3: Token avec agregateur
DECLARE @T3 NVARCHAR(MAX);
SELECT @T3 = Token FROM dbo.fn_ExtractTokens('{SUM(AMOUNT_%)}');
INSERT INTO #TestResults (Category, TestName, Expected, Actual, Status)
VALUES ('TOKENS', 'Agregateur', '{SUM(AMOUNT_%)}', @T3, CASE WHEN @T3 = '{SUM(AMOUNT_%)}' THEN 'PASS' ELSE 'FAIL' END);

GO

-- =========================================================================
-- PARTIE 2 : TESTS fn_ParseToken (correction bug LIKE)
-- =========================================================================
PRINT '-- Tests fn_ParseToken --';

-- Test 2.1: Variable directe
DECLARE @A1 VARCHAR(20), @R1 BIT, @P1 NVARCHAR(500);
SELECT @A1 = Aggregator, @R1 = IsRuleRef, @P1 = Pattern FROM dbo.fn_ParseToken('{VAR_A}');
INSERT INTO #TestResults (Category, TestName, Expected, Actual, Status)
VALUES ('PARSE', 'Variable directe', 'FIRST/0/VAR_A', CONCAT(@A1,'/',@R1,'/',@P1),
    CASE WHEN @A1='FIRST' AND @R1=0 AND @P1='VAR_A' THEN 'PASS' ELSE 'FAIL' END);

-- Test 2.2: SUM avec pattern
DECLARE @A2 VARCHAR(20), @P2 NVARCHAR(500);
SELECT @A2 = Aggregator, @P2 = Pattern FROM dbo.fn_ParseToken('{SUM(AMOUNT_%)}');
INSERT INTO #TestResults (Category, TestName, Expected, Actual, Status)
VALUES ('PARSE', 'SUM pattern', 'SUM/AMOUNT_%', CONCAT(@A2,'/',@P2),
    CASE WHEN @A2='SUM' AND @P2='AMOUNT_%' THEN 'PASS' ELSE 'FAIL' END);

-- Test 2.3: Reference regle
DECLARE @A3 VARCHAR(20), @R3 BIT, @P3 NVARCHAR(500);
SELECT @A3 = Aggregator, @R3 = IsRuleRef, @P3 = Pattern FROM dbo.fn_ParseToken('{Rule:CALC_TOTAL}');
INSERT INTO #TestResults (Category, TestName, Expected, Actual, Status)
VALUES ('PARSE', 'Rule reference', 'FIRST/1/CALC_TOTAL', CONCAT(@A3,'/',@R3,'/',@P3),
    CASE WHEN @A3='FIRST' AND @R3=1 AND @P3='CALC_TOTAL' THEN 'PASS' ELSE 'FAIL' END);

-- Test 2.4: SUM_POS
DECLARE @A4 VARCHAR(20), @P4 NVARCHAR(500);
SELECT @A4 = Aggregator, @P4 = Pattern FROM dbo.fn_ParseToken('{SUM_POS(AMOUNT_%)}');
INSERT INTO #TestResults (Category, TestName, Expected, Actual, Status)
VALUES ('PARSE', 'SUM_POS', 'SUM_POS/AMOUNT_%', CONCAT(@A4,'/',@P4),
    CASE WHEN @A4='SUM_POS' AND @P4='AMOUNT_%' THEN 'PASS' ELSE 'FAIL' END);

-- Test 2.5: Fonction inconnue = FIRST par defaut
DECLARE @A5 VARCHAR(20), @P5 NVARCHAR(500);
SELECT @A5 = Aggregator, @P5 = Pattern FROM dbo.fn_ParseToken('{UNKNOWN(TEST)}');
INSERT INTO #TestResults (Category, TestName, Expected, Actual, Status)
VALUES ('PARSE', 'Fonction inconnue', 'FIRST', @A5,
    CASE WHEN @A5='FIRST' THEN 'PASS' ELSE 'FAIL' END);

GO

-- =========================================================================
-- PARTIE 3 : TESTS EXECUTION
-- =========================================================================
PRINT '-- Tests execution --';

-- Creer regles de test
INSERT INTO dbo.RuleDefinitions (RuleCode, Expression) VALUES
    ('TEST_SIMPLE', '100 + 50'),
    ('TEST_VAR', '{VAR_X} * 2'),
    ('TEST_MULTI', '{VAR_X} + {VAR_Y}'),
    ('TEST_NESTED', '{Rule:TEST_SIMPLE} / 2'),
    ('TEST_CHAIN_A', '10'),
    ('TEST_CHAIN_B', '{Rule:TEST_CHAIN_A} * 2'),
    ('TEST_CHAIN_C', '{Rule:TEST_CHAIN_B} + 5'),
    ('TEST_DIV_ZERO', '{VAR_X} / 0'),
    ('TEST_CYCLE_A', '{Rule:TEST_CYCLE_B}'),
    ('TEST_CYCLE_B', '{Rule:TEST_CYCLE_A}'),
    ('TEST_IIF', 'IIF({VAR_X} > 50, "GRAND", "PETIT")');
GO

-- Test 3.1: Regle simple
DECLARE @In1 NVARCHAR(MAX) = N'{"rules": ["TEST_SIMPLE"]}';
DECLARE @Out1 NVARCHAR(MAX);
EXEC dbo.sp_RunRulesEngine @In1, @Out1 OUTPUT;
DECLARE @V1 NVARCHAR(100) = JSON_VALUE(@Out1, '$.results[0].value');
INSERT INTO #TestResults (Category, TestName, Expected, Actual, Status)
VALUES ('EXEC', 'Regle simple', '150', @V1, CASE WHEN TRY_CAST(@V1 AS INT) = 150 THEN 'PASS' ELSE 'FAIL' END);

-- Test 3.2: Regle avec variable
DECLARE @In2 NVARCHAR(MAX) = N'{"variables": [{"key": "VAR_X", "value": "25"}], "rules": ["TEST_VAR"]}';
DECLARE @Out2 NVARCHAR(MAX);
EXEC dbo.sp_RunRulesEngine @In2, @Out2 OUTPUT;
DECLARE @V2 NVARCHAR(100) = JSON_VALUE(@Out2, '$.results[0].value');
INSERT INTO #TestResults (Category, TestName, Expected, Actual, Status)
VALUES ('EXEC', 'Avec variable', '50', @V2, CASE WHEN TRY_CAST(@V2 AS INT) = 50 THEN 'PASS' ELSE 'FAIL' END);

-- Test 3.3: Chaine 3 niveaux
DECLARE @In3 NVARCHAR(MAX) = N'{"rules": ["TEST_CHAIN_C"]}';
DECLARE @Out3 NVARCHAR(MAX);
EXEC dbo.sp_RunRulesEngine @In3, @Out3 OUTPUT;
DECLARE @V3 NVARCHAR(100) = JSON_VALUE(@Out3, '$.results[0].value');
INSERT INTO #TestResults (Category, TestName, Expected, Actual, Status)
VALUES ('EXEC', 'Chaine 3 niveaux', '25', @V3, CASE WHEN TRY_CAST(@V3 AS INT) = 25 THEN 'PASS' ELSE 'FAIL' END);

-- Test 3.4: Division par zero
DECLARE @In4 NVARCHAR(MAX) = N'{"variables": [{"key": "VAR_X", "value": "100"}], "rules": ["TEST_DIV_ZERO"]}';
DECLARE @Out4 NVARCHAR(MAX);
EXEC dbo.sp_RunRulesEngine @In4, @Out4 OUTPUT;
DECLARE @S4 NVARCHAR(50) = JSON_VALUE(@Out4, '$.results[0].state');
DECLARE @E4 NVARCHAR(50) = JSON_VALUE(@Out4, '$.results[0].errorCategory');
INSERT INTO #TestResults (Category, TestName, Expected, Actual, Status)
VALUES ('EXEC', 'Division zero', 'ERROR/NUMERIC', CONCAT(@S4,'/',@E4),
    CASE WHEN @S4='ERROR' AND @E4='NUMERIC' THEN 'PASS' ELSE 'FAIL' END);

-- Test 3.5: Cycle detecte
DECLARE @In5 NVARCHAR(MAX) = N'{"rules": ["TEST_CYCLE_A"]}';
DECLARE @Out5 NVARCHAR(MAX);
EXEC dbo.sp_RunRulesEngine @In5, @Out5 OUTPUT;
DECLARE @S5 NVARCHAR(50) = JSON_VALUE(@Out5, '$.results[0].state');
DECLARE @E5 NVARCHAR(50) = JSON_VALUE(@Out5, '$.results[0].errorCategory');
INSERT INTO #TestResults (Category, TestName, Expected, Actual, Status)
VALUES ('EXEC', 'Cycle detecte', 'ERROR/RECURSION', CONCAT(@S5,'/',@E5),
    CASE WHEN @S5='ERROR' AND @E5='RECURSION' THEN 'PASS' ELSE 'FAIL' END);

-- Test 3.6: IIF
DECLARE @In6 NVARCHAR(MAX) = N'{"variables": [{"key": "VAR_X", "value": "100"}], "rules": ["TEST_IIF"]}';
DECLARE @Out6 NVARCHAR(MAX);
EXEC dbo.sp_RunRulesEngine @In6, @Out6 OUTPUT;
DECLARE @V6 NVARCHAR(100) = JSON_VALUE(@Out6, '$.results[0].value');
INSERT INTO #TestResults (Category, TestName, Expected, Actual, Status)
VALUES ('EXEC', 'IIF vrai', 'GRAND', @V6, CASE WHEN @V6 = 'GRAND' THEN 'PASS' ELSE 'FAIL' END);

GO

-- =========================================================================
-- PARTIE 4 : TESTS AGREGATEURS
-- =========================================================================
PRINT '-- Tests agregateurs --';

INSERT INTO dbo.RuleDefinitions (RuleCode, Expression) VALUES
    ('TEST_AGG_SUM', '{SUM(AMT_%)}'),
    ('TEST_AGG_AVG', '{AVG(AMT_%)}'),
    ('TEST_AGG_MIN', '{MIN(AMT_%)}'),
    ('TEST_AGG_MAX', '{MAX(AMT_%)}'),
    ('TEST_AGG_COUNT', '{COUNT(AMT_%)}'),
    ('TEST_AGG_SUM_POS', '{SUM_POS(AMT_%)}'),
    ('TEST_AGG_SUM_NEG', '{SUM_NEG(AMT_%)}'),
    ('TEST_AGG_CONCAT', '{CONCAT(TXT_%)}');
GO

-- Test 4.1: SUM
DECLARE @InA1 NVARCHAR(MAX) = N'{"variables": [{"key": "AMT_01", "value": "100"},{"key": "AMT_02", "value": "200"},{"key": "AMT_03", "value": "-50"}], "rules": ["TEST_AGG_SUM"]}';
DECLARE @OutA1 NVARCHAR(MAX);
EXEC dbo.sp_RunRulesEngine @InA1, @OutA1 OUTPUT;
DECLARE @VA1 NVARCHAR(100) = JSON_VALUE(@OutA1, '$.results[0].value');
INSERT INTO #TestResults (Category, TestName, Expected, Actual, Status)
VALUES ('AGG', 'SUM', '250', @VA1, CASE WHEN TRY_CAST(@VA1 AS DECIMAL(18,2)) = 250 THEN 'PASS' ELSE 'FAIL' END);

-- Test 4.2: MIN
DECLARE @InA2 NVARCHAR(MAX) = N'{"variables": [{"key": "AMT_01", "value": "100"},{"key": "AMT_02", "value": "200"},{"key": "AMT_03", "value": "-50"}], "rules": ["TEST_AGG_MIN"]}';
DECLARE @OutA2 NVARCHAR(MAX);
EXEC dbo.sp_RunRulesEngine @InA2, @OutA2 OUTPUT;
DECLARE @VA2 NVARCHAR(100) = JSON_VALUE(@OutA2, '$.results[0].value');
INSERT INTO #TestResults (Category, TestName, Expected, Actual, Status)
VALUES ('AGG', 'MIN', '-50', @VA2, CASE WHEN TRY_CAST(@VA2 AS DECIMAL(18,2)) = -50 THEN 'PASS' ELSE 'FAIL' END);

-- Test 4.3: MAX
DECLARE @InA3 NVARCHAR(MAX) = N'{"variables": [{"key": "AMT_01", "value": "100"},{"key": "AMT_02", "value": "200"},{"key": "AMT_03", "value": "-50"}], "rules": ["TEST_AGG_MAX"]}';
DECLARE @OutA3 NVARCHAR(MAX);
EXEC dbo.sp_RunRulesEngine @InA3, @OutA3 OUTPUT;
DECLARE @VA3 NVARCHAR(100) = JSON_VALUE(@OutA3, '$.results[0].value');
INSERT INTO #TestResults (Category, TestName, Expected, Actual, Status)
VALUES ('AGG', 'MAX', '200', @VA3, CASE WHEN TRY_CAST(@VA3 AS DECIMAL(18,2)) = 200 THEN 'PASS' ELSE 'FAIL' END);

-- Test 4.4: COUNT
DECLARE @InA4 NVARCHAR(MAX) = N'{"variables": [{"key": "AMT_01", "value": "100"},{"key": "AMT_02", "value": "200"},{"key": "AMT_03", "value": "-50"}], "rules": ["TEST_AGG_COUNT"]}';
DECLARE @OutA4 NVARCHAR(MAX);
EXEC dbo.sp_RunRulesEngine @InA4, @OutA4 OUTPUT;
DECLARE @VA4 NVARCHAR(100) = JSON_VALUE(@OutA4, '$.results[0].value');
INSERT INTO #TestResults (Category, TestName, Expected, Actual, Status)
VALUES ('AGG', 'COUNT', '3', @VA4, CASE WHEN TRY_CAST(@VA4 AS INT) = 3 THEN 'PASS' ELSE 'FAIL' END);

-- Test 4.5: SUM_POS
DECLARE @InA5 NVARCHAR(MAX) = N'{"variables": [{"key": "AMT_01", "value": "100"},{"key": "AMT_02", "value": "200"},{"key": "AMT_03", "value": "-50"}], "rules": ["TEST_AGG_SUM_POS"]}';
DECLARE @OutA5 NVARCHAR(MAX);
EXEC dbo.sp_RunRulesEngine @InA5, @OutA5 OUTPUT;
DECLARE @VA5 NVARCHAR(100) = JSON_VALUE(@OutA5, '$.results[0].value');
INSERT INTO #TestResults (Category, TestName, Expected, Actual, Status)
VALUES ('AGG', 'SUM_POS', '300', @VA5, CASE WHEN TRY_CAST(@VA5 AS DECIMAL(18,2)) = 300 THEN 'PASS' ELSE 'FAIL' END);

-- Test 4.6: SUM_NEG
DECLARE @InA6 NVARCHAR(MAX) = N'{"variables": [{"key": "AMT_01", "value": "100"},{"key": "AMT_02", "value": "200"},{"key": "AMT_03", "value": "-50"}], "rules": ["TEST_AGG_SUM_NEG"]}';
DECLARE @OutA6 NVARCHAR(MAX);
EXEC dbo.sp_RunRulesEngine @InA6, @OutA6 OUTPUT;
DECLARE @VA6 NVARCHAR(100) = JSON_VALUE(@OutA6, '$.results[0].value');
INSERT INTO #TestResults (Category, TestName, Expected, Actual, Status)
VALUES ('AGG', 'SUM_NEG', '-50', @VA6, CASE WHEN TRY_CAST(@VA6 AS DECIMAL(18,2)) = -50 THEN 'PASS' ELSE 'FAIL' END);

-- Test 4.7: CONCAT
DECLARE @InA7 NVARCHAR(MAX) = N'{"variables": [{"key": "TXT_A", "value": "Hello"},{"key": "TXT_B", "value": "World"}], "rules": ["TEST_AGG_CONCAT"]}';
DECLARE @OutA7 NVARCHAR(MAX);
EXEC dbo.sp_RunRulesEngine @InA7, @OutA7 OUTPUT;
DECLARE @VA7 NVARCHAR(100) = JSON_VALUE(@OutA7, '$.results[0].value');
INSERT INTO #TestResults (Category, TestName, Expected, Actual, Status)
VALUES ('AGG', 'CONCAT', 'Hello,World', @VA7, CASE WHEN @VA7 LIKE '%Hello%World%' THEN 'PASS' ELSE 'FAIL' END);

GO

-- =========================================================================
-- RAPPORT
-- =========================================================================
PRINT '';
PRINT '== RAPPORT ==';

SELECT Category, TestName, Expected, Actual, Status FROM #TestResults ORDER BY TestId;

DECLARE @Total INT, @Pass INT, @Fail INT;
SELECT @Total = COUNT(*), 
       @Pass = SUM(CASE WHEN Status = 'PASS' THEN 1 ELSE 0 END),
       @Fail = SUM(CASE WHEN Status = 'FAIL' THEN 1 ELSE 0 END)
FROM #TestResults;

PRINT '';
PRINT CONCAT('TOTAL: ', @Total, ' | PASS: ', @Pass, ' | FAIL: ', @Fail);
PRINT CONCAT('Taux: ', CAST(100.0 * @Pass / @Total AS DECIMAL(5,1)), '%');

IF @Fail > 0
BEGIN
    PRINT '';
    PRINT 'ECHECS:';
    SELECT Category, TestName, Expected, Actual FROM #TestResults WHERE Status = 'FAIL';
END

-- Nettoyage
DELETE FROM dbo.RuleDefinitions WHERE RuleCode LIKE 'TEST[_]%';
DROP TABLE #TestResults;
GO
