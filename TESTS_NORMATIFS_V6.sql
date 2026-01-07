/***********************************************************************
    TESTS NORMATIFS V6.1 - Spec V1.5.5
    
    Utilise le Runner JSON (sp_RunRulesEngine)
    
    Prérequis: Exécuter MOTEUR_REGLES_V6.1.sql d'abord
    
    Tests selon REFERENCE_v1.5.5.md:
    - T: Parsing/Tokens
    - C: Collation/Unicité
    - O: Ordre canonique
    - A: Agrégateurs
    - L: Lazy/Cache
    - E: Erreurs
    - P: Performance/Modes
************************************************************************/

SET NOCOUNT ON;
GO

PRINT '══════════════════════════════════════════════════════════════════════';
PRINT '         TESTS NORMATIFS V6.1 - Spec V1.5.5                           ';
PRINT '══════════════════════════════════════════════════════════════════════';
PRINT '';
GO

-- =========================================================================
-- PRÉPARATION
-- =========================================================================
PRINT '── Préparation ──';

-- Table des résultats de tests
IF OBJECT_ID('tempdb..#TestResults') IS NOT NULL DROP TABLE #TestResults;
CREATE TABLE #TestResults (
    TestId INT IDENTITY(1,1),
    Category VARCHAR(20),
    Name VARCHAR(50),
    InputExpression NVARCHAR(500),
    Expected NVARCHAR(500),
    Actual NVARCHAR(500),
    Pass BIT,
    Details NVARCHAR(500)
);

-- Nettoyer les règles de test précédentes
DELETE FROM dbo.RuleDefinitions WHERE RuleCode LIKE 'TEST_%' OR RuleCode LIKE 'BBB%';

-- Créer les règles de test (fixtures §11.3)
INSERT INTO dbo.RuleDefinitions (RuleCode, Expression) VALUES
    ('BBB1', '10'),
    ('BBB2', '-5'),
    ('BBB_NULL', 'NULL');

PRINT '   OK';
PRINT '';
GO

-- =========================================================================
-- T: TESTS PARSING/TOKENS
-- =========================================================================
PRINT '── T: Parsing/Tokens ──';

DECLARE @Input NVARCHAR(MAX), @Output NVARCHAR(MAX);
DECLARE @ResultValue NVARCHAR(500), @ResultState VARCHAR(20);

-- T01: Aucun token
DELETE FROM dbo.RuleDefinitions WHERE RuleCode = 'TEST_T01';
INSERT INTO dbo.RuleDefinitions (RuleCode, Expression) VALUES ('TEST_T01', '100 + 50');

SET @Input = N'{"mode":"NORMAL","variables":[],"rules":["TEST_T01"]}';
EXEC dbo.sp_RunRulesEngine @Input, @Output OUTPUT;
SELECT @ResultValue = JSON_VALUE(@Output, '$.results[0].value');
INSERT INTO #TestResults VALUES ('PARSING', 'T01_NoToken', '100 + 50', '150', @ResultValue, 
    CASE WHEN TRY_CAST(@ResultValue AS INT) = 150 THEN 1 ELSE 0 END, NULL);

-- T02: Multi tokens
DELETE FROM dbo.RuleDefinitions WHERE RuleCode = 'TEST_T02';
INSERT INTO dbo.RuleDefinitions (RuleCode, Expression) VALUES ('TEST_T02', '{VAL_A} + {VAL_B}');

SET @Input = N'{"mode":"NORMAL","variables":[{"key":"VAL_A","type":"DECIMAL","value":"100"},{"key":"VAL_B","type":"DECIMAL","value":"50"}],"rules":["TEST_T02"]}';
EXEC dbo.sp_RunRulesEngine @Input, @Output OUTPUT;
SELECT @ResultValue = JSON_VALUE(@Output, '$.results[0].value');
INSERT INTO #TestResults VALUES ('PARSING', 'T02_MultiToken', '{VAL_A} + {VAL_B}', '150', @ResultValue, 
    CASE WHEN TRY_CAST(@ResultValue AS INT) = 150 THEN 1 ELSE 0 END, NULL);

-- T06: rule: prefix
DELETE FROM dbo.RuleDefinitions WHERE RuleCode = 'TEST_T06';
INSERT INTO dbo.RuleDefinitions (RuleCode, Expression) VALUES ('TEST_T06', '{rule:BBB1} + 5');

SET @Input = N'{"mode":"NORMAL","variables":[],"rules":["BBB1","TEST_T06"]}';
EXEC dbo.sp_RunRulesEngine @Input, @Output OUTPUT;
SELECT @ResultValue = JSON_VALUE(@Output, '$.results[1].value');
INSERT INTO #TestResults VALUES ('PARSING', 'T06_RuleRef', '{rule:BBB1} + 5', '15', @ResultValue, 
    CASE WHEN TRY_CAST(@ResultValue AS INT) = 15 THEN 1 ELSE 0 END, NULL);

-- T07: Case insensitive
DELETE FROM dbo.RuleDefinitions WHERE RuleCode = 'TEST_T07';
INSERT INTO dbo.RuleDefinitions (RuleCode, Expression) VALUES ('TEST_T07', '{TOTO_LOWER}');

SET @Input = N'{"mode":"NORMAL","variables":[{"key":"toto_lower","type":"DECIMAL","value":"99"}],"rules":["TEST_T07"]}';
EXEC dbo.sp_RunRulesEngine @Input, @Output OUTPUT;
SELECT @ResultValue = JSON_VALUE(@Output, '$.results[0].value');
INSERT INTO #TestResults VALUES ('PARSING', 'T07_CaseInsensitive', '{TOTO_LOWER}', '99', @ResultValue, 
    CASE WHEN TRY_CAST(@ResultValue AS INT) = 99 THEN 1 ELSE 0 END, 'CI collation');

PRINT '   OK';
GO

-- =========================================================================
-- O: TESTS ORDRE CANONIQUE
-- =========================================================================
PRINT '── O: Ordre canonique ──';

DECLARE @Input NVARCHAR(MAX), @Output NVARCHAR(MAX);
DECLARE @ResultValue NVARCHAR(500);

-- Fixtures MONTANT_% (§11.1 - ordre d'insertion = ordre canonique)
DECLARE @MontantVars NVARCHAR(MAX) = N'[
    {"key":"MONTANT_1","type":"DECIMAL","value":"100"},
    {"key":"MONTANT_2","type":"DECIMAL","value":"200"},
    {"key":"MONTANT_3","type":"DECIMAL","value":"-50"},
    {"key":"MONTANT_4","type":"DECIMAL","value":"150"},
    {"key":"MONTANT_5","type":"DECIMAL","value":"-25"},
    {"key":"MONTANT_6","type":"NULL","value":null}
]';

-- Fixtures LIBELLE_% (§11.2)
DECLARE @LibelleVars NVARCHAR(MAX) = N'[
    {"key":"LIBELLE_1","type":"STRING","value":"A"},
    {"key":"LIBELLE_2","type":"STRING","value":"B"},
    {"key":"LIBELLE_3","type":"NULL","value":null},
    {"key":"LIBELLE_4","type":"STRING","value":"C"}
]';

-- O01: FIRST retourne première valeur selon SeqId
DELETE FROM dbo.RuleDefinitions WHERE RuleCode = 'TEST_O01';
INSERT INTO dbo.RuleDefinitions (RuleCode, Expression) VALUES ('TEST_O01', '{FIRST(MONTANT_%)}');

SET @Input = N'{"mode":"NORMAL","variables":' + @MontantVars + N',"rules":["TEST_O01"]}';
EXEC dbo.sp_RunRulesEngine @Input, @Output OUTPUT;
SELECT @ResultValue = JSON_VALUE(@Output, '$.results[0].value');
INSERT INTO #TestResults VALUES ('ORDRE', 'O01_First', '{FIRST(MONTANT_%)}', '100', @ResultValue, 
    CASE WHEN TRY_CAST(@ResultValue AS INT) = 100 THEN 1 ELSE 0 END, 'Premier SeqId');

-- O02: FIRST_NEG retourne premier négatif selon SeqId
DELETE FROM dbo.RuleDefinitions WHERE RuleCode = 'TEST_O02';
INSERT INTO dbo.RuleDefinitions (RuleCode, Expression) VALUES ('TEST_O02', '{FIRST_NEG(MONTANT_%)}');

SET @Input = N'{"mode":"NORMAL","variables":' + @MontantVars + N',"rules":["TEST_O02"]}';
EXEC dbo.sp_RunRulesEngine @Input, @Output OUTPUT;
SELECT @ResultValue = JSON_VALUE(@Output, '$.results[0].value');
INSERT INTO #TestResults VALUES ('ORDRE', 'O02_FirstNeg', '{FIRST_NEG(MONTANT_%)}', '-50', @ResultValue, 
    CASE WHEN TRY_CAST(@ResultValue AS INT) = -50 THEN 1 ELSE 0 END, 'Premier négatif');

-- O03: CONCAT respecte ordre SeqId, ignore NULL
DELETE FROM dbo.RuleDefinitions WHERE RuleCode = 'TEST_O03';
INSERT INTO dbo.RuleDefinitions (RuleCode, Expression) VALUES ('TEST_O03', '{CONCAT(LIBELLE_%)}');

SET @Input = N'{"mode":"NORMAL","variables":' + @LibelleVars + N',"rules":["TEST_O03"]}';
EXEC dbo.sp_RunRulesEngine @Input, @Output OUTPUT;
SELECT @ResultValue = JSON_VALUE(@Output, '$.results[0].value');
INSERT INTO #TestResults VALUES ('ORDRE', 'O03_Concat', '{CONCAT(LIBELLE_%)}', 'A,B,C', @ResultValue, 
    CASE WHEN @ResultValue = 'A,B,C' THEN 1 ELSE 0 END, 'NULL ignoré');

PRINT '   OK';
GO

-- =========================================================================
-- A: TESTS AGRÉGATEURS
-- =========================================================================
PRINT '── A: Agrégateurs ──';

DECLARE @Input NVARCHAR(MAX), @Output NVARCHAR(MAX);
DECLARE @ResultValue NVARCHAR(500);

DECLARE @MontantVars NVARCHAR(MAX) = N'[
    {"key":"MONTANT_1","type":"DECIMAL","value":"100"},
    {"key":"MONTANT_2","type":"DECIMAL","value":"200"},
    {"key":"MONTANT_3","type":"DECIMAL","value":"-50"},
    {"key":"MONTANT_4","type":"DECIMAL","value":"150"},
    {"key":"MONTANT_5","type":"DECIMAL","value":"-25"},
    {"key":"MONTANT_6","type":"NULL","value":null}
]';

-- A01: SUM
DELETE FROM dbo.RuleDefinitions WHERE RuleCode = 'TEST_A01';
INSERT INTO dbo.RuleDefinitions (RuleCode, Expression) VALUES ('TEST_A01', '{SUM(MONTANT_%)}');
SET @Input = N'{"mode":"NORMAL","variables":' + @MontantVars + N',"rules":["TEST_A01"]}';
EXEC dbo.sp_RunRulesEngine @Input, @Output OUTPUT;
SELECT @ResultValue = JSON_VALUE(@Output, '$.results[0].value');
INSERT INTO #TestResults VALUES ('AGGREG', 'A01_Sum', '{SUM(MONTANT_%)}', '375', @ResultValue, 
    CASE WHEN ABS(TRY_CAST(@ResultValue AS DECIMAL(18,2)) - 375) < 0.01 THEN 1 ELSE 0 END, NULL);

-- A02: SUM_POS
DELETE FROM dbo.RuleDefinitions WHERE RuleCode = 'TEST_A02';
INSERT INTO dbo.RuleDefinitions (RuleCode, Expression) VALUES ('TEST_A02', '{SUM_POS(MONTANT_%)}');
SET @Input = N'{"mode":"NORMAL","variables":' + @MontantVars + N',"rules":["TEST_A02"]}';
EXEC dbo.sp_RunRulesEngine @Input, @Output OUTPUT;
SELECT @ResultValue = JSON_VALUE(@Output, '$.results[0].value');
INSERT INTO #TestResults VALUES ('AGGREG', 'A02_SumPos', '{SUM_POS(MONTANT_%)}', '450', @ResultValue, 
    CASE WHEN ABS(TRY_CAST(@ResultValue AS DECIMAL(18,2)) - 450) < 0.01 THEN 1 ELSE 0 END, NULL);

-- A03: SUM_NEG
DELETE FROM dbo.RuleDefinitions WHERE RuleCode = 'TEST_A03';
INSERT INTO dbo.RuleDefinitions (RuleCode, Expression) VALUES ('TEST_A03', '{SUM_NEG(MONTANT_%)}');
SET @Input = N'{"mode":"NORMAL","variables":' + @MontantVars + N',"rules":["TEST_A03"]}';
EXEC dbo.sp_RunRulesEngine @Input, @Output OUTPUT;
SELECT @ResultValue = JSON_VALUE(@Output, '$.results[0].value');
INSERT INTO #TestResults VALUES ('AGGREG', 'A03_SumNeg', '{SUM_NEG(MONTANT_%)}', '-75', @ResultValue, 
    CASE WHEN ABS(TRY_CAST(@ResultValue AS DECIMAL(18,2)) - (-75)) < 0.01 THEN 1 ELSE 0 END, NULL);

-- A04: AVG
DELETE FROM dbo.RuleDefinitions WHERE RuleCode = 'TEST_A04';
INSERT INTO dbo.RuleDefinitions (RuleCode, Expression) VALUES ('TEST_A04', '{AVG(MONTANT_%)}');
SET @Input = N'{"mode":"NORMAL","variables":' + @MontantVars + N',"rules":["TEST_A04"]}';
EXEC dbo.sp_RunRulesEngine @Input, @Output OUTPUT;
SELECT @ResultValue = JSON_VALUE(@Output, '$.results[0].value');
INSERT INTO #TestResults VALUES ('AGGREG', 'A04_Avg', '{AVG(MONTANT_%)}', '75', @ResultValue, 
    CASE WHEN ABS(TRY_CAST(@ResultValue AS DECIMAL(18,2)) - 75) < 0.01 THEN 1 ELSE 0 END, NULL);

-- A05: AVG_NEG
DELETE FROM dbo.RuleDefinitions WHERE RuleCode = 'TEST_A05';
INSERT INTO dbo.RuleDefinitions (RuleCode, Expression) VALUES ('TEST_A05', '{AVG_NEG(MONTANT_%)}');
SET @Input = N'{"mode":"NORMAL","variables":' + @MontantVars + N',"rules":["TEST_A05"]}';
EXEC dbo.sp_RunRulesEngine @Input, @Output OUTPUT;
SELECT @ResultValue = JSON_VALUE(@Output, '$.results[0].value');
INSERT INTO #TestResults VALUES ('AGGREG', 'A05_AvgNeg', '{AVG_NEG(MONTANT_%)}', '-37.5', @ResultValue, 
    CASE WHEN ABS(TRY_CAST(@ResultValue AS DECIMAL(18,2)) - (-37.5)) < 0.01 THEN 1 ELSE 0 END, NULL);

-- A06: MIN
DELETE FROM dbo.RuleDefinitions WHERE RuleCode = 'TEST_A06';
INSERT INTO dbo.RuleDefinitions (RuleCode, Expression) VALUES ('TEST_A06', '{MIN(MONTANT_%)}');
SET @Input = N'{"mode":"NORMAL","variables":' + @MontantVars + N',"rules":["TEST_A06"]}';
EXEC dbo.sp_RunRulesEngine @Input, @Output OUTPUT;
SELECT @ResultValue = JSON_VALUE(@Output, '$.results[0].value');
INSERT INTO #TestResults VALUES ('AGGREG', 'A06_Min', '{MIN(MONTANT_%)}', '-50', @ResultValue, 
    CASE WHEN ABS(TRY_CAST(@ResultValue AS DECIMAL(18,2)) - (-50)) < 0.01 THEN 1 ELSE 0 END, NULL);

-- A07: MAX
DELETE FROM dbo.RuleDefinitions WHERE RuleCode = 'TEST_A07';
INSERT INTO dbo.RuleDefinitions (RuleCode, Expression) VALUES ('TEST_A07', '{MAX(MONTANT_%)}');
SET @Input = N'{"mode":"NORMAL","variables":' + @MontantVars + N',"rules":["TEST_A07"]}';
EXEC dbo.sp_RunRulesEngine @Input, @Output OUTPUT;
SELECT @ResultValue = JSON_VALUE(@Output, '$.results[0].value');
INSERT INTO #TestResults VALUES ('AGGREG', 'A07_Max', '{MAX(MONTANT_%)}', '200', @ResultValue, 
    CASE WHEN ABS(TRY_CAST(@ResultValue AS DECIMAL(18,2)) - 200) < 0.01 THEN 1 ELSE 0 END, NULL);

-- A08: COUNT (ignore NULL)
DELETE FROM dbo.RuleDefinitions WHERE RuleCode = 'TEST_A08';
INSERT INTO dbo.RuleDefinitions (RuleCode, Expression) VALUES ('TEST_A08', '{COUNT(MONTANT_%)}');
SET @Input = N'{"mode":"NORMAL","variables":' + @MontantVars + N',"rules":["TEST_A08"]}';
EXEC dbo.sp_RunRulesEngine @Input, @Output OUTPUT;
SELECT @ResultValue = JSON_VALUE(@Output, '$.results[0].value');
INSERT INTO #TestResults VALUES ('AGGREG', 'A08_Count', '{COUNT(MONTANT_%)}', '5', @ResultValue, 
    CASE WHEN TRY_CAST(@ResultValue AS INT) = 5 THEN 1 ELSE 0 END, 'NULL ignoré');

-- A09: COUNT_POS
DELETE FROM dbo.RuleDefinitions WHERE RuleCode = 'TEST_A09';
INSERT INTO dbo.RuleDefinitions (RuleCode, Expression) VALUES ('TEST_A09', '{COUNT_POS(MONTANT_%)}');
SET @Input = N'{"mode":"NORMAL","variables":' + @MontantVars + N',"rules":["TEST_A09"]}';
EXEC dbo.sp_RunRulesEngine @Input, @Output OUTPUT;
SELECT @ResultValue = JSON_VALUE(@Output, '$.results[0].value');
INSERT INTO #TestResults VALUES ('AGGREG', 'A09_CountPos', '{COUNT_POS(MONTANT_%)}', '3', @ResultValue, 
    CASE WHEN TRY_CAST(@ResultValue AS INT) = 3 THEN 1 ELSE 0 END, NULL);

-- A10: COUNT_NEG
DELETE FROM dbo.RuleDefinitions WHERE RuleCode = 'TEST_A10';
INSERT INTO dbo.RuleDefinitions (RuleCode, Expression) VALUES ('TEST_A10', '{COUNT_NEG(MONTANT_%)}');
SET @Input = N'{"mode":"NORMAL","variables":' + @MontantVars + N',"rules":["TEST_A10"]}';
EXEC dbo.sp_RunRulesEngine @Input, @Output OUTPUT;
SELECT @ResultValue = JSON_VALUE(@Output, '$.results[0].value');
INSERT INTO #TestResults VALUES ('AGGREG', 'A10_CountNeg', '{COUNT_NEG(MONTANT_%)}', '2', @ResultValue, 
    CASE WHEN TRY_CAST(@ResultValue AS INT) = 2 THEN 1 ELSE 0 END, NULL);

-- A11a: Ensemble vide -> NULL pour SUM
DELETE FROM dbo.RuleDefinitions WHERE RuleCode = 'TEST_A11a';
INSERT INTO dbo.RuleDefinitions (RuleCode, Expression) VALUES ('TEST_A11a', 'ISNULL({SUM(INEXISTANT_%)},-999)');
SET @Input = N'{"mode":"NORMAL","variables":[],"rules":["TEST_A11a"]}';
EXEC dbo.sp_RunRulesEngine @Input, @Output OUTPUT;
SELECT @ResultValue = JSON_VALUE(@Output, '$.results[0].value');
INSERT INTO #TestResults VALUES ('AGGREG', 'A11a_EmptySum', '{SUM(INEXISTANT_%)}', '-999', @ResultValue, 
    CASE WHEN TRY_CAST(@ResultValue AS INT) = -999 THEN 1 ELSE 0 END, 'Vide=>NULL');

-- A11b: Ensemble vide -> 0 pour COUNT
DELETE FROM dbo.RuleDefinitions WHERE RuleCode = 'TEST_A11b';
INSERT INTO dbo.RuleDefinitions (RuleCode, Expression) VALUES ('TEST_A11b', '{COUNT(INEXISTANT_%)}');
SET @Input = N'{"mode":"NORMAL","variables":[],"rules":["TEST_A11b"]}';
EXEC dbo.sp_RunRulesEngine @Input, @Output OUTPUT;
SELECT @ResultValue = JSON_VALUE(@Output, '$.results[0].value');
INSERT INTO #TestResults VALUES ('AGGREG', 'A11b_EmptyCount', '{COUNT(INEXISTANT_%)}', '0', @ResultValue, 
    CASE WHEN TRY_CAST(@ResultValue AS INT) = 0 THEN 1 ELSE 0 END, 'Vide=>0');

PRINT '   OK';
GO

-- =========================================================================
-- L: TESTS LAZY/CACHE
-- =========================================================================
PRINT '── L: Lazy/Cache ──';

DECLARE @Input NVARCHAR(MAX), @Output NVARCHAR(MAX);
DECLARE @ResultValue NVARCHAR(500), @ResultState VARCHAR(50);

-- L01/L02: Règle évaluée une seule fois (vérifié via état)
SET @Input = N'{"mode":"NORMAL","variables":[],"rules":["BBB1"],"options":{"returnStateTable":true}}';
EXEC dbo.sp_RunRulesEngine @Input, @Output OUTPUT;
SELECT @ResultValue = JSON_VALUE(@Output, '$.results[0].value');
SELECT @ResultState = JSON_VALUE(@Output, '$.results[0].state');
INSERT INTO #TestResults VALUES ('LAZY', 'L01_Evaluated', 'BBB1', 'EVALUATED', @ResultState, 
    CASE WHEN @ResultState = 'EVALUATED' THEN 1 ELSE 0 END, NULL);
INSERT INTO #TestResults VALUES ('LAZY', 'L02_Value', 'BBB1 value', '10', @ResultValue, 
    CASE WHEN @ResultValue = '10' THEN 1 ELSE 0 END, 'Valeur correcte');

PRINT '   OK';
GO

-- =========================================================================
-- E: TESTS ERREURS
-- =========================================================================
PRINT '── E: Erreurs ──';

DECLARE @Input NVARCHAR(MAX), @Output NVARCHAR(MAX);
DECLARE @ResultState VARCHAR(50), @ErrorCat VARCHAR(50);

-- E01: Division par zéro
DELETE FROM dbo.RuleDefinitions WHERE RuleCode = 'TEST_E01';
INSERT INTO dbo.RuleDefinitions (RuleCode, Expression) VALUES ('TEST_E01', '100 / 0');
SET @Input = N'{"mode":"NORMAL","variables":[],"rules":["TEST_E01"]}';
EXEC dbo.sp_RunRulesEngine @Input, @Output OUTPUT;
SELECT @ResultState = JSON_VALUE(@Output, '$.results[0].state');
SELECT @ErrorCat = JSON_VALUE(@Output, '$.results[0].errorCategory');
INSERT INTO #TestResults VALUES ('ERREURS', 'E01_DivZero', '100 / 0', 'ERROR+NUMERIC', 
    CONCAT(@ResultState, '+', @ErrorCat), 
    CASE WHEN @ResultState = 'ERROR' AND @ErrorCat = 'NUMERIC' THEN 1 ELSE 0 END, NULL);

-- E05: Récursivité directe
DELETE FROM dbo.RuleDefinitions WHERE RuleCode = 'TEST_E05';
INSERT INTO dbo.RuleDefinitions (RuleCode, Expression) VALUES ('TEST_E05', '{rule:TEST_E05} + 1');
SET @Input = N'{"mode":"NORMAL","variables":[],"rules":["TEST_E05"]}';
EXEC dbo.sp_RunRulesEngine @Input, @Output OUTPUT;
SELECT @ResultState = JSON_VALUE(@Output, '$.results[0].state');
SELECT @ErrorCat = JSON_VALUE(@Output, '$.results[0].errorCategory');
INSERT INTO #TestResults VALUES ('ERREURS', 'E05_RecursionDirect', '{rule:TEST_E05}', 'ERROR+RECURSION', 
    CONCAT(@ResultState, '+', @ErrorCat), 
    CASE WHEN @ResultState = 'ERROR' AND @ErrorCat = 'RECURSION' THEN 1 ELSE 0 END, NULL);

-- E06: Récursivité indirecte A->B->A
-- Selon §8.4: A est ERROR (récursion détectée), B reçoit NULL et s'évalue normalement
DELETE FROM dbo.RuleDefinitions WHERE RuleCode IN ('TEST_E06A', 'TEST_E06B');
INSERT INTO dbo.RuleDefinitions (RuleCode, Expression) VALUES 
    ('TEST_E06A', '{rule:TEST_E06B} + 1'),
    ('TEST_E06B', '{rule:TEST_E06A} + 1');
SET @Input = N'{"mode":"NORMAL","variables":[],"rules":["TEST_E06A","TEST_E06B"]}';
EXEC dbo.sp_RunRulesEngine @Input, @Output OUTPUT;
DECLARE @StateA VARCHAR(20) = JSON_VALUE(@Output, '$.results[0].state');
DECLARE @StateB VARCHAR(20) = JSON_VALUE(@Output, '$.results[1].state');
DECLARE @ValueB NVARCHAR(50) = JSON_VALUE(@Output, '$.results[1].value');
-- A doit être ERROR (récursion), B doit être EVALUATED avec NULL (thread continue)
INSERT INTO #TestResults VALUES ('ERREURS', 'E06_RecursionIndirect', 'A->B->A', 'A=ERROR,B=EVALUATED', 
    CONCAT('A=', @StateA, ',B=', @StateB), 
    CASE WHEN @StateA = 'ERROR' AND @StateB = 'EVALUATED' THEN 1 ELSE 0 END, 'B gets NULL, thread continues');

-- E07: Agrégation tolérante (ignore NULL des erreurs)
DELETE FROM dbo.RuleDefinitions WHERE RuleCode = 'TEST_E07';
INSERT INTO dbo.RuleDefinitions (RuleCode, Expression) VALUES ('TEST_E07', '{SUM(rule:BBB%)}');
SET @Input = N'{"mode":"NORMAL","variables":[],"rules":["BBB1","BBB2","BBB_NULL","TEST_E07"]}';
EXEC dbo.sp_RunRulesEngine @Input, @Output OUTPUT;
DECLARE @SumValue NVARCHAR(50) = JSON_VALUE(@Output, '$.results[3].value');
INSERT INTO #TestResults VALUES ('ERREURS', 'E07_AggTolerant', '{SUM(rule:BBB%)}', '5', @SumValue, 
    CASE WHEN ABS(TRY_CAST(@SumValue AS DECIMAL(18,2)) - 5) < 0.01 THEN 1 ELSE 0 END, '10+(-5), NULL ignored');

PRINT '   OK';
GO

-- =========================================================================
-- P: TESTS PERFORMANCE/MODES
-- =========================================================================
PRINT '── P: Performance/Modes ──';

DECLARE @Input NVARCHAR(MAX), @Output NVARCHAR(MAX);
DECLARE @Mode VARCHAR(20), @HasDebug BIT;

-- P01: Mode NORMAL - pas de debug dans output
SET @Input = N'{"mode":"NORMAL","variables":[],"rules":["BBB1"],"options":{"returnDebug":true}}';
EXEC dbo.sp_RunRulesEngine @Input, @Output OUTPUT;
SELECT @Mode = JSON_VALUE(@Output, '$.mode');
SET @HasDebug = CASE WHEN JSON_VALUE(@Output, '$.debugLog') IS NOT NULL THEN 1 ELSE 0 END;
INSERT INTO #TestResults VALUES ('PERF', 'P01_NormalNoDebug', 'Mode NORMAL', 'No debug', 
    CONCAT('Mode=', @Mode, ',Debug=', @HasDebug), 
    CASE WHEN @Mode = 'NORMAL' AND @HasDebug = 0 THEN 1 ELSE 0 END, NULL);

-- P02: Mode DEBUG - debug présent
SET @Input = N'{"mode":"DEBUG","variables":[],"rules":["BBB1"],"options":{"returnDebug":true}}';
EXEC dbo.sp_RunRulesEngine @Input, @Output OUTPUT;
SELECT @Mode = JSON_VALUE(@Output, '$.mode');
SET @HasDebug = CASE WHEN JSON_QUERY(@Output, '$.debugLog') IS NOT NULL THEN 1 ELSE 0 END;
INSERT INTO #TestResults VALUES ('PERF', 'P02_DebugPresent', 'Mode DEBUG', 'Has debug', 
    CONCAT('Mode=', @Mode, ',Debug=', @HasDebug), 
    CASE WHEN @Mode = 'DEBUG' AND @HasDebug = 1 THEN 1 ELSE 0 END, NULL);

PRINT '   OK';
PRINT '';
GO

-- =========================================================================

-- =========================================================================
-- VERROUILLAGES ANTI-AMBIGUÏTÉ (Spec v1.5.5) — tests additionnels
-- =========================================================================
PRINT '── X: Verrouillages (anti-ambiguïté) ──';

DECLARE @Input NVARCHAR(MAX), @Output NVARCHAR(MAX);
DECLARE @ResultValue NVARCHAR(500), @ResultState VARCHAR(20);


-- X01: FIRST doit pouvoir retourner NULL (ordre canonique / 1ère valeur NULL)
DELETE FROM dbo.RuleDefinitions WHERE RuleCode IN ('TEST_X01');
INSERT INTO dbo.RuleDefinitions (RuleCode, Expression) VALUES ('TEST_X01', '{FIRST(MONTANT_%)}');

DECLARE @VarsFirstNull NVARCHAR(MAX) = N'[
    {"key":"MONTANT_1","type":"NULL","value":null},
    {"key":"MONTANT_2","type":"DECIMAL","value":"10"}
]';

SET @Input = N'{"mode":"NORMAL","variables":' + @VarsFirstNull + N',"rules":["TEST_X01"]}';
EXEC dbo.sp_RunRulesEngine @Input, @Output OUTPUT;
SELECT @ResultValue = JSON_VALUE(@Output, '$.results[0].value');

INSERT INTO #TestResults VALUES ('LOCK', 'X01_FirstNull', '{FIRST(MONTANT_%)}', NULL, @ResultValue,
    CASE WHEN @ResultValue IS NULL THEN 1 ELSE 0 END, 'FIRST doit retourner NULL si 1ère valeur (SeqId) est NULL');

-- X02: JSONIFY doit inclure les règles en ERROR avec valeur null, même si non listées dans rules[]
DELETE FROM dbo.RuleDefinitions WHERE RuleCode IN ('ERR_X02','TEST_X02');
INSERT INTO dbo.RuleDefinitions (RuleCode, Expression) VALUES ('ERR_X02', '10/0');
INSERT INTO dbo.RuleDefinitions (RuleCode, Expression) VALUES ('TEST_X02', '{JSONIFY(rule:ERR_%)}');

SET @Input = N'{"mode":"NORMAL","variables":[],"rules":["TEST_X02"]}';
EXEC dbo.sp_RunRulesEngine @Input, @Output OUTPUT;
SELECT @ResultValue = JSON_VALUE(@Output, '$.results[0].value');

INSERT INTO #TestResults VALUES ('LOCK', 'X02_JsonifyError', '{JSONIFY(rule:ERR_%)}', '{"ERR_X02":null}', @ResultValue,
    CASE WHEN @ResultValue LIKE '%"ERR_X02":null%' THEN 1 ELSE 0 END,
    'JSONIFY doit inclure la clé ERR_X02 avec null (ERROR => NULL)');

-- X03: {rule:BBB%} doit être indépendant de rules[] (lazy insert + lazy eval)
DELETE FROM dbo.RuleDefinitions WHERE RuleCode IN ('BBB1','BBB2','TEST_X03');
INSERT INTO dbo.RuleDefinitions (RuleCode, Expression) VALUES ('BBB1', '10');
INSERT INTO dbo.RuleDefinitions (RuleCode, Expression) VALUES ('BBB2', '20');
INSERT INTO dbo.RuleDefinitions (RuleCode, Expression) VALUES ('TEST_X03', '{MAX(rule:BBB%)}');

SET @Input = N'{"mode":"NORMAL","variables":[],"rules":["TEST_X03"]}';
EXEC dbo.sp_RunRulesEngine @Input, @Output OUTPUT;
SELECT @ResultValue = JSON_VALUE(@Output, '$.results[0].value');

INSERT INTO #TestResults VALUES ('LOCK', 'X03_RuleLikeLazy', '{MAX(rule:BBB%)}', '20', @ResultValue,
    CASE WHEN TRY_CAST(@ResultValue AS INT) = 20 THEN 1 ELSE 0 END,
    'Le token rule:BBB% doit découvrir/insérer/évaluer BBB1,BBB2 même si non listées dans rules[]');

-- X04: Normalisation des littéraux — décimal français 2,5 -> 2.5
DELETE FROM dbo.RuleDefinitions WHERE RuleCode IN ('TEST_X04');
INSERT INTO dbo.RuleDefinitions (RuleCode, Expression) VALUES ('TEST_X04', '2,5 + 1');

SET @Input = N'{"mode":"NORMAL","variables":[],"rules":["TEST_X04"]}';
EXEC dbo.sp_RunRulesEngine @Input, @Output OUTPUT;
SELECT @ResultValue = JSON_VALUE(@Output, '$.results[0].value');

INSERT INTO #TestResults VALUES ('LOCK', 'X04_DecimalComma', '2,5+1', '3.5', @ResultValue,
    CASE WHEN ABS(TRY_CAST(@ResultValue AS DECIMAL(18,2)) - 3.5) < 0.01 THEN 1 ELSE 0 END,
    'Les décimaux français doivent être compilés en notation SQL (.)');

-- X05: Normalisation des littéraux — "ABC" -> ''ABC''
DELETE FROM dbo.RuleDefinitions WHERE RuleCode IN ('TEST_X05');
INSERT INTO dbo.RuleDefinitions (RuleCode, Expression) VALUES ('TEST_X05', '"ABC"');

SET @Input = N'{"mode":"NORMAL","variables":[],"rules":["TEST_X05"]}';
EXEC dbo.sp_RunRulesEngine @Input, @Output OUTPUT;
SELECT @ResultValue = JSON_VALUE(@Output, '$.results[0].value');

INSERT INTO #TestResults VALUES ('LOCK', 'X05_DoubleQuotes', '"ABC"', 'ABC', @ResultValue,
    CASE WHEN @ResultValue = 'ABC' THEN 1 ELSE 0 END,
    'Les littéraux double-quote doivent être compilés en single-quote (SQL)');

-- X06: Runner — ScalarValue doit supporter NVARCHAR(MAX) (anti-troncature JSON_VALUE)
DELETE FROM dbo.RuleDefinitions WHERE RuleCode IN ('TEST_X06');
INSERT INTO dbo.RuleDefinitions (RuleCode, Expression) VALUES ('TEST_X06', '{CONFIG}');

DECLARE @Big NVARCHAR(MAX) = REPLICATE('x', 5000);
DECLARE @VarsBig NVARCHAR(MAX) = N'[{"key":"CONFIG","type":"JSON","value":"' + @Big + N'"}]';

SET @Input = N'{"mode":"NORMAL","variables":' + @VarsBig + N',"rules":["TEST_X06"]}';
EXEC dbo.sp_RunRulesEngine @Input, @Output OUTPUT;
SELECT @ResultValue = JSON_VALUE(@Output, '$.results[0].value');

INSERT INTO #TestResults VALUES ('LOCK', 'X06_NVarMax', '{CONFIG}', CAST(LEN(@Big) AS VARCHAR(20)), CAST(LEN(@ResultValue) AS VARCHAR(20)),
    CASE WHEN LEN(@ResultValue) = LEN(@Big) THEN 1 ELSE 0 END,
    'La valeur JSON/texte longue ne doit pas être tronquée à 4000 caractères');


-- RAPPORT FINAL
-- =========================================================================
PRINT '══════════════════════════════════════════════════════════════════════';
PRINT '                        RAPPORT CONFORMITÉ                            ';
PRINT '══════════════════════════════════════════════════════════════════════';
PRINT '';

SELECT Category, COUNT(*) AS Total, SUM(CAST(Pass AS INT)) AS Pass, COUNT(*) - SUM(CAST(Pass AS INT)) AS Fail
FROM #TestResults GROUP BY Category ORDER BY Category;

PRINT '';

SELECT TestId AS [#], Category AS Cat, Name, Expected, Actual, 
    CASE WHEN Pass = 1 THEN 'PASS' ELSE 'FAIL' END AS Status, Details
FROM #TestResults ORDER BY TestId;

DECLARE @Total INT, @Pass INT, @Fail INT;
SELECT @Total = COUNT(*), @Pass = SUM(CAST(Pass AS INT)), @Fail = COUNT(*) - SUM(CAST(Pass AS INT)) FROM #TestResults;

PRINT '';
PRINT '══════════════════════════════════════════════════════════════════════';
PRINT CONCAT('  TOTAL: ', @Total, ' tests | PASS: ', @Pass, ' | FAIL: ', @Fail);
PRINT CONCAT('  Conformité: ', CAST(100.0 * @Pass / NULLIF(@Total, 0) AS DECIMAL(5,1)), '%');
PRINT '══════════════════════════════════════════════════════════════════════';

IF @Fail > 0
BEGIN
    PRINT '';
    PRINT 'TESTS EN ÉCHEC:';
    SELECT Category, Name, Expected, Actual, Details FROM #TestResults WHERE Pass = 0;
END
GO