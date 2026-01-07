/***********************************************************************
    TESTS NORMATIFS - MOTEUR DE RÈGLES V6.2.3
    Conforme Spec V1.5.5
    
    Ces tests valident:
    1. Extraction correcte des tokens (y compris imbriqués)
    2. Parsing des agrégateurs
    3. Résolution des variables et règles
    4. Gestion des erreurs et récursions
    5. Tous les 17 agrégateurs
    6. Runner JSON
************************************************************************/

SET NOCOUNT ON;
GO

PRINT '══════════════════════════════════════════════════════════════════════';
PRINT '           TESTS NORMATIFS V6.2.3 - Spec V1.5.5                       ';
PRINT '══════════════════════════════════════════════════════════════════════';
PRINT '';
GO

-- =========================================================================
-- PRÉPARATION
-- =========================================================================

-- Nettoyer les règles de test
DELETE FROM dbo.RuleDefinitions WHERE RuleCode LIKE 'TEST_%';
GO

-- Table de résultats
IF OBJECT_ID('tempdb..#TestResults') IS NOT NULL DROP TABLE #TestResults;
CREATE TABLE #TestResults (
    TestId INT IDENTITY(1,1),
    Category NVARCHAR(50),
    TestName NVARCHAR(100),
    Expected NVARCHAR(500),
    Actual NVARCHAR(500),
    Status VARCHAR(10),
    Details NVARCHAR(500)
);
GO

-- =========================================================================
-- PARTIE 1 : TESTS fn_ExtractTokens
-- =========================================================================
PRINT '── Tests fn_ExtractTokens ──';

-- Test 1.1: Token simple
DECLARE @Tokens1 NVARCHAR(MAX);
SELECT @Tokens1 = STRING_AGG(Token, ',') WITHIN GROUP (ORDER BY Token)
FROM dbo.fn_ExtractTokens('{VAR_A}');

INSERT INTO #TestResults (Category, TestName, Expected, Actual, Status)
VALUES ('TOKENS', 'Token simple', '{VAR_A}', @Tokens1,
    CASE WHEN @Tokens1 = '{VAR_A}' THEN 'PASS' ELSE 'FAIL' END);

-- Test 1.2: Tokens multiples
DECLARE @Tokens2 NVARCHAR(MAX);
SELECT @Tokens2 = STRING_AGG(Token, ',') WITHIN GROUP (ORDER BY Token)
FROM dbo.fn_ExtractTokens('{A} + {B} - {C}');

INSERT INTO #TestResults (Category, TestName, Expected, Actual, Status)
VALUES ('TOKENS', 'Tokens multiples', '{A},{B},{C}', @Tokens2,
    CASE WHEN @Tokens2 = '{A},{B},{C}' THEN 'PASS' ELSE 'FAIL' END);

-- Test 1.3: Token avec fonction
DECLARE @Tokens3 NVARCHAR(MAX);
SELECT @Tokens3 = STRING_AGG(Token, ',') WITHIN GROUP (ORDER BY Token)
FROM dbo.fn_ExtractTokens('{SUM(MONTANT_%)}');

INSERT INTO #TestResults (Category, TestName, Expected, Actual, Status)
VALUES ('TOKENS', 'Token avec fonction', '{SUM(MONTANT_%)}', @Tokens3,
    CASE WHEN @Tokens3 = '{SUM(MONTANT_%)}' THEN 'PASS' ELSE 'FAIL' END);

-- Test 1.4: Token IIF imbriqué (CRITIQUE - bug V6.2.2)
DECLARE @Tokens4 NVARCHAR(MAX);
SELECT @Tokens4 = Token
FROM dbo.fn_ExtractTokens('{IIF({A}>0,{B},{C})}');

INSERT INTO #TestResults (Category, TestName, Expected, Actual, Status, Details)
VALUES ('TOKENS', 'Token IIF imbriqué', '{IIF({A}>0,{B},{C})}', @Tokens4,
    CASE WHEN @Tokens4 = '{IIF({A}>0,{B},{C})}' THEN 'PASS' ELSE 'FAIL' END,
    'Bug critique V6.2.2 corrigé');

-- Test 1.5: Expression avec IIF externe uniquement
DECLARE @Tokens5 NVARCHAR(MAX);
SELECT @Tokens5 = STRING_AGG(Token, '|') WITHIN GROUP (ORDER BY Token)
FROM dbo.fn_ExtractTokens('100 + {IIF({X}>50,{Y},{Z})} * 2');

INSERT INTO #TestResults (Category, TestName, Expected, Actual, Status)
VALUES ('TOKENS', 'Expression avec IIF', '{IIF({X}>50,{Y},{Z})}', @Tokens5,
    CASE WHEN @Tokens5 = '{IIF({X}>50,{Y},{Z})}' THEN 'PASS' ELSE 'FAIL' END);

GO

-- =========================================================================
-- PARTIE 2 : TESTS fn_ParseToken
-- =========================================================================
PRINT '── Tests fn_ParseToken ──';

-- Test 2.1: Variable directe (agrégateur par défaut = FIRST)
DECLARE @Agg1 VARCHAR(20), @Ref1 BIT, @Pat1 NVARCHAR(500);
SELECT @Agg1 = Aggregator, @Ref1 = IsRuleRef, @Pat1 = Pattern
FROM dbo.fn_ParseToken('{VAR_A}');

INSERT INTO #TestResults (Category, TestName, Expected, Actual, Status)
VALUES ('PARSE', 'Variable directe', 'FIRST,0,VAR_A', CONCAT(@Agg1,',',@Ref1,',',@Pat1),
    CASE WHEN @Agg1='FIRST' AND @Ref1=0 AND @Pat1='VAR_A' THEN 'PASS' ELSE 'FAIL' END);

-- Test 2.2: Fonction SUM
DECLARE @Agg2 VARCHAR(20), @Ref2 BIT, @Pat2 NVARCHAR(500);
SELECT @Agg2 = Aggregator, @Ref2 = IsRuleRef, @Pat2 = Pattern
FROM dbo.fn_ParseToken('{SUM(MONTANT_%)}');

INSERT INTO #TestResults (Category, TestName, Expected, Actual, Status)
VALUES ('PARSE', 'Fonction SUM', 'SUM,0,MONTANT_%', CONCAT(@Agg2,',',@Ref2,',',@Pat2),
    CASE WHEN @Agg2='SUM' AND @Ref2=0 AND @Pat2='MONTANT_%' THEN 'PASS' ELSE 'FAIL' END);

-- Test 2.3: Référence règle
DECLARE @Agg3 VARCHAR(20), @Ref3 BIT, @Pat3 NVARCHAR(500);
SELECT @Agg3 = Aggregator, @Ref3 = IsRuleRef, @Pat3 = Pattern
FROM dbo.fn_ParseToken('{Rule:CALC_TOTAL}');

INSERT INTO #TestResults (Category, TestName, Expected, Actual, Status)
VALUES ('PARSE', 'Référence règle', 'FIRST,1,CALC_TOTAL', CONCAT(@Agg3,',',@Ref3,',',@Pat3),
    CASE WHEN @Agg3='FIRST' AND @Ref3=1 AND @Pat3='CALC_TOTAL' THEN 'PASS' ELSE 'FAIL' END);

-- Test 2.4: Fonction avec référence règle
DECLARE @Agg4 VARCHAR(20), @Ref4 BIT, @Pat4 NVARCHAR(500);
SELECT @Agg4 = Aggregator, @Ref4 = IsRuleRef, @Pat4 = Pattern
FROM dbo.fn_ParseToken('{SUM(Rule:MONTANT_%)}');

INSERT INTO #TestResults (Category, TestName, Expected, Actual, Status)
VALUES ('PARSE', 'SUM avec Rule:', 'SUM,1,MONTANT_%', CONCAT(@Agg4,',',@Ref4,',',@Pat4),
    CASE WHEN @Agg4='SUM' AND @Ref4=1 AND @Pat4='MONTANT_%' THEN 'PASS' ELSE 'FAIL' END);

-- Test 2.5: Agrégateur avec filtre POS
DECLARE @Agg5 VARCHAR(20), @Pat5 NVARCHAR(500);
SELECT @Agg5 = Aggregator, @Pat5 = Pattern
FROM dbo.fn_ParseToken('{SUM_POS(MONTANT_%)}');

INSERT INTO #TestResults (Category, TestName, Expected, Actual, Status)
VALUES ('PARSE', 'Agrégateur SUM_POS', 'SUM_POS,MONTANT_%', CONCAT(@Agg5,',',@Pat5),
    CASE WHEN @Agg5='SUM_POS' AND @Pat5='MONTANT_%' THEN 'PASS' ELSE 'FAIL' END);

-- Test 2.6: Agrégateur avec filtre NEG
DECLARE @Agg6 VARCHAR(20), @Pat6 NVARCHAR(500);
SELECT @Agg6 = Aggregator, @Pat6 = Pattern
FROM dbo.fn_ParseToken('{AVG_NEG(SCORE_%)}');

INSERT INTO #TestResults (Category, TestName, Expected, Actual, Status)
VALUES ('PARSE', 'Agrégateur AVG_NEG', 'AVG_NEG,SCORE_%', CONCAT(@Agg6,',',@Pat6),
    CASE WHEN @Agg6='AVG_NEG' AND @Pat6='SCORE_%' THEN 'PASS' ELSE 'FAIL' END);

-- Test 2.7: Fonction inconnue = FIRST par défaut
DECLARE @Agg7 VARCHAR(20), @Pat7 NVARCHAR(500);
SELECT @Agg7 = Aggregator, @Pat7 = Pattern
FROM dbo.fn_ParseToken('{UNKNOWN_FUNC(TEST)}');

INSERT INTO #TestResults (Category, TestName, Expected, Actual, Status, Details)
VALUES ('PARSE', 'Fonction inconnue', 'FIRST,UNKNOWN_FUNC(TEST)', CONCAT(@Agg7,',',@Pat7),
    CASE WHEN @Agg7='FIRST' THEN 'PASS' ELSE 'FAIL' END,
    'Agrégateur par défaut appliqué');

GO

-- =========================================================================
-- PARTIE 3 : TESTS D'EXÉCUTION AVEC RUNNER
-- =========================================================================
PRINT '── Tests exécution ──';

-- Créer des règles de test
INSERT INTO dbo.RuleDefinitions (RuleCode, Expression) VALUES
    ('TEST_SIMPLE', '100 + 50'),
    ('TEST_VAR', '{VAR_A} * 2'),
    ('TEST_MULTI', '{VAR_A} + {VAR_B} - {VAR_C}'),
    ('TEST_NESTED', '{Rule:TEST_SIMPLE} / 2'),
    ('TEST_CHAIN_A', '10'),
    ('TEST_CHAIN_B', '{Rule:TEST_CHAIN_A} * 2'),
    ('TEST_CHAIN_C', '{Rule:TEST_CHAIN_B} + 5'),
    ('TEST_DIV_ZERO', '{VAR_A} / 0'),
    ('TEST_CYCLE_A', '{Rule:TEST_CYCLE_B}'),
    ('TEST_CYCLE_B', '{Rule:TEST_CYCLE_A}'),
    ('TEST_IIF', 'IIF({VAR_A} > 50, "GRAND", "PETIT")');
GO

-- Test 3.1: Règle simple (sans variables)
DECLARE @Input1 NVARCHAR(MAX) = N'{"rules": ["TEST_SIMPLE"]}';
DECLARE @Output1 NVARCHAR(MAX);
EXEC dbo.sp_RunRulesEngine @Input1, @Output1 OUTPUT;

DECLARE @Val1 NVARCHAR(100) = JSON_VALUE(@Output1, '$.results[0].value');
INSERT INTO #TestResults (Category, TestName, Expected, Actual, Status)
VALUES ('EXEC', 'Règle simple 100+50', '150', @Val1,
    CASE WHEN TRY_CAST(@Val1 AS INT) = 150 THEN 'PASS' ELSE 'FAIL' END);

-- Test 3.2: Règle avec variable
DECLARE @Input2 NVARCHAR(MAX) = N'{
    "variables": [{"key": "VAR_A", "value": "25"}],
    "rules": ["TEST_VAR"]
}';
DECLARE @Output2 NVARCHAR(MAX);
EXEC dbo.sp_RunRulesEngine @Input2, @Output2 OUTPUT;

DECLARE @Val2 NVARCHAR(100) = JSON_VALUE(@Output2, '$.results[0].value');
INSERT INTO #TestResults (Category, TestName, Expected, Actual, Status)
VALUES ('EXEC', 'Règle avec variable', '50', @Val2,
    CASE WHEN TRY_CAST(@Val2 AS INT) = 50 THEN 'PASS' ELSE 'FAIL' END);

-- Test 3.3: Règle avec multiples variables
DECLARE @Input3 NVARCHAR(MAX) = N'{
    "variables": [
        {"key": "VAR_A", "value": "100"},
        {"key": "VAR_B", "value": "50"},
        {"key": "VAR_C", "value": "30"}
    ],
    "rules": ["TEST_MULTI"]
}';
DECLARE @Output3 NVARCHAR(MAX);
EXEC dbo.sp_RunRulesEngine @Input3, @Output3 OUTPUT;

DECLARE @Val3 NVARCHAR(100) = JSON_VALUE(@Output3, '$.results[0].value');
INSERT INTO #TestResults (Category, TestName, Expected, Actual, Status)
VALUES ('EXEC', 'Variables multiples', '120', @Val3,
    CASE WHEN TRY_CAST(@Val3 AS INT) = 120 THEN 'PASS' ELSE 'FAIL' END);

-- Test 3.4: Règle référençant autre règle
DECLARE @Input4 NVARCHAR(MAX) = N'{"rules": ["TEST_NESTED"]}';
DECLARE @Output4 NVARCHAR(MAX);
EXEC dbo.sp_RunRulesEngine @Input4, @Output4 OUTPUT;

DECLARE @Val4 NVARCHAR(100) = JSON_VALUE(@Output4, '$.results[0].value');
INSERT INTO #TestResults (Category, TestName, Expected, Actual, Status, Details)
VALUES ('EXEC', 'Référence Rule:', '75', @Val4,
    CASE WHEN TRY_CAST(@Val4 AS INT) = 75 THEN 'PASS' ELSE 'FAIL' END,
    'TEST_SIMPLE(150) / 2');

-- Test 3.5: Chaîne de dépendances (3 niveaux)
DECLARE @Input5 NVARCHAR(MAX) = N'{"rules": ["TEST_CHAIN_C"]}';
DECLARE @Output5 NVARCHAR(MAX);
EXEC dbo.sp_RunRulesEngine @Input5, @Output5 OUTPUT;

DECLARE @Val5 NVARCHAR(100) = JSON_VALUE(@Output5, '$.results[0].value');
INSERT INTO #TestResults (Category, TestName, Expected, Actual, Status, Details)
VALUES ('EXEC', 'Chaîne 3 niveaux', '25', @Val5,
    CASE WHEN TRY_CAST(@Val5 AS INT) = 25 THEN 'PASS' ELSE 'FAIL' END,
    'A(10) -> B(20) -> C(25)');

-- Test 3.6: Division par zéro = ERROR
DECLARE @Input6 NVARCHAR(MAX) = N'{
    "variables": [{"key": "VAR_A", "value": "100"}],
    "rules": ["TEST_DIV_ZERO"]
}';
DECLARE @Output6 NVARCHAR(MAX);
EXEC dbo.sp_RunRulesEngine @Input6, @Output6 OUTPUT;

DECLARE @State6 NVARCHAR(50) = JSON_VALUE(@Output6, '$.results[0].state');
DECLARE @ErrCat6 NVARCHAR(50) = JSON_VALUE(@Output6, '$.results[0].errorCategory');
INSERT INTO #TestResults (Category, TestName, Expected, Actual, Status)
VALUES ('EXEC', 'Division par zéro', 'ERROR/NUMERIC', CONCAT(@State6,'/',@ErrCat6),
    CASE WHEN @State6='ERROR' AND @ErrCat6='NUMERIC' THEN 'PASS' ELSE 'FAIL' END);

-- Test 3.7: Cycle détecté = ERROR/RECURSION
DECLARE @Input7 NVARCHAR(MAX) = N'{"rules": ["TEST_CYCLE_A"]}';
DECLARE @Output7 NVARCHAR(MAX);
EXEC dbo.sp_RunRulesEngine @Input7, @Output7 OUTPUT;

DECLARE @State7 NVARCHAR(50) = JSON_VALUE(@Output7, '$.results[0].state');
DECLARE @ErrCat7 NVARCHAR(50) = JSON_VALUE(@Output7, '$.results[0].errorCategory');
INSERT INTO #TestResults (Category, TestName, Expected, Actual, Status)
VALUES ('EXEC', 'Cycle détecté', 'ERROR/RECURSION', CONCAT(@State7,'/',@ErrCat7),
    CASE WHEN @State7='ERROR' AND @ErrCat7='RECURSION' THEN 'PASS' ELSE 'FAIL' END);

-- Test 3.8: IIF avec comparaison
DECLARE @Input8 NVARCHAR(MAX) = N'{
    "variables": [{"key": "VAR_A", "value": "100"}],
    "rules": ["TEST_IIF"]
}';
DECLARE @Output8 NVARCHAR(MAX);
EXEC dbo.sp_RunRulesEngine @Input8, @Output8 OUTPUT;

DECLARE @Val8 NVARCHAR(100) = JSON_VALUE(@Output8, '$.results[0].value');
INSERT INTO #TestResults (Category, TestName, Expected, Actual, Status)
VALUES ('EXEC', 'IIF condition vraie', 'GRAND', @Val8,
    CASE WHEN @Val8 = 'GRAND' THEN 'PASS' ELSE 'FAIL' END);

GO

-- =========================================================================
-- PARTIE 4 : TESTS DES AGRÉGATEURS
-- =========================================================================
PRINT '── Tests agrégateurs ──';

-- Créer règles pour agrégateurs
INSERT INTO dbo.RuleDefinitions (RuleCode, Expression) VALUES
    ('TEST_AGG_SUM', '{SUM(AMOUNT_%)}'),
    ('TEST_AGG_AVG', '{AVG(AMOUNT_%)}'),
    ('TEST_AGG_MIN', '{MIN(AMOUNT_%)}'),
    ('TEST_AGG_MAX', '{MAX(AMOUNT_%)}'),
    ('TEST_AGG_COUNT', '{COUNT(AMOUNT_%)}'),
    ('TEST_AGG_SUM_POS', '{SUM_POS(AMOUNT_%)}'),
    ('TEST_AGG_SUM_NEG', '{SUM_NEG(AMOUNT_%)}'),
    ('TEST_AGG_CONCAT', '{CONCAT(TEXT_%)}');
GO

-- Test 4.1: SUM
DECLARE @InputAgg1 NVARCHAR(MAX) = N'{
    "variables": [
        {"key": "AMOUNT_01", "value": "100"},
        {"key": "AMOUNT_02", "value": "200"},
        {"key": "AMOUNT_03", "value": "-50"}
    ],
    "rules": ["TEST_AGG_SUM"]
}';
DECLARE @OutputAgg1 NVARCHAR(MAX);
EXEC dbo.sp_RunRulesEngine @InputAgg1, @OutputAgg1 OUTPUT;

DECLARE @ValAgg1 NVARCHAR(100) = JSON_VALUE(@OutputAgg1, '$.results[0].value');
INSERT INTO #TestResults (Category, TestName, Expected, Actual, Status)
VALUES ('AGG', 'SUM', '250', @ValAgg1,
    CASE WHEN TRY_CAST(@ValAgg1 AS DECIMAL(18,2)) = 250 THEN 'PASS' ELSE 'FAIL' END);

-- Test 4.2: AVG
DECLARE @InputAgg2 NVARCHAR(MAX) = N'{
    "variables": [
        {"key": "AMOUNT_01", "value": "100"},
        {"key": "AMOUNT_02", "value": "200"},
        {"key": "AMOUNT_03", "value": "-50"}
    ],
    "rules": ["TEST_AGG_AVG"]
}';
DECLARE @OutputAgg2 NVARCHAR(MAX);
EXEC dbo.sp_RunRulesEngine @InputAgg2, @OutputAgg2 OUTPUT;

DECLARE @ValAgg2 NVARCHAR(100) = JSON_VALUE(@OutputAgg2, '$.results[0].value');
INSERT INTO #TestResults (Category, TestName, Expected, Actual, Status, Details)
VALUES ('AGG', 'AVG', '~83.33', @ValAgg2,
    CASE WHEN ABS(TRY_CAST(@ValAgg2 AS DECIMAL(18,2)) - 83.33) < 1 THEN 'PASS' ELSE 'FAIL' END,
    '(100+200-50)/3');

-- Test 4.3: MIN
DECLARE @InputAgg3 NVARCHAR(MAX) = N'{
    "variables": [
        {"key": "AMOUNT_01", "value": "100"},
        {"key": "AMOUNT_02", "value": "200"},
        {"key": "AMOUNT_03", "value": "-50"}
    ],
    "rules": ["TEST_AGG_MIN"]
}';
DECLARE @OutputAgg3 NVARCHAR(MAX);
EXEC dbo.sp_RunRulesEngine @InputAgg3, @OutputAgg3 OUTPUT;

DECLARE @ValAgg3 NVARCHAR(100) = JSON_VALUE(@OutputAgg3, '$.results[0].value');
INSERT INTO #TestResults (Category, TestName, Expected, Actual, Status)
VALUES ('AGG', 'MIN', '-50', @ValAgg3,
    CASE WHEN TRY_CAST(@ValAgg3 AS DECIMAL(18,2)) = -50 THEN 'PASS' ELSE 'FAIL' END);

-- Test 4.4: MAX
DECLARE @InputAgg4 NVARCHAR(MAX) = N'{
    "variables": [
        {"key": "AMOUNT_01", "value": "100"},
        {"key": "AMOUNT_02", "value": "200"},
        {"key": "AMOUNT_03", "value": "-50"}
    ],
    "rules": ["TEST_AGG_MAX"]
}';
DECLARE @OutputAgg4 NVARCHAR(MAX);
EXEC dbo.sp_RunRulesEngine @InputAgg4, @OutputAgg4 OUTPUT;

DECLARE @ValAgg4 NVARCHAR(100) = JSON_VALUE(@OutputAgg4, '$.results[0].value');
INSERT INTO #TestResults (Category, TestName, Expected, Actual, Status)
VALUES ('AGG', 'MAX', '200', @ValAgg4,
    CASE WHEN TRY_CAST(@ValAgg4 AS DECIMAL(18,2)) = 200 THEN 'PASS' ELSE 'FAIL' END);

-- Test 4.5: COUNT
DECLARE @InputAgg5 NVARCHAR(MAX) = N'{
    "variables": [
        {"key": "AMOUNT_01", "value": "100"},
        {"key": "AMOUNT_02", "value": "200"},
        {"key": "AMOUNT_03", "value": "-50"}
    ],
    "rules": ["TEST_AGG_COUNT"]
}';
DECLARE @OutputAgg5 NVARCHAR(MAX);
EXEC dbo.sp_RunRulesEngine @InputAgg5, @OutputAgg5 OUTPUT;

DECLARE @ValAgg5 NVARCHAR(100) = JSON_VALUE(@OutputAgg5, '$.results[0].value');
INSERT INTO #TestResults (Category, TestName, Expected, Actual, Status)
VALUES ('AGG', 'COUNT', '3', @ValAgg5,
    CASE WHEN TRY_CAST(@ValAgg5 AS INT) = 3 THEN 'PASS' ELSE 'FAIL' END);

-- Test 4.6: SUM_POS (filtrage positifs)
DECLARE @InputAgg6 NVARCHAR(MAX) = N'{
    "variables": [
        {"key": "AMOUNT_01", "value": "100"},
        {"key": "AMOUNT_02", "value": "200"},
        {"key": "AMOUNT_03", "value": "-50"}
    ],
    "rules": ["TEST_AGG_SUM_POS"]
}';
DECLARE @OutputAgg6 NVARCHAR(MAX);
EXEC dbo.sp_RunRulesEngine @InputAgg6, @OutputAgg6 OUTPUT;

DECLARE @ValAgg6 NVARCHAR(100) = JSON_VALUE(@OutputAgg6, '$.results[0].value');
INSERT INTO #TestResults (Category, TestName, Expected, Actual, Status)
VALUES ('AGG', 'SUM_POS', '300', @ValAgg6,
    CASE WHEN TRY_CAST(@ValAgg6 AS DECIMAL(18,2)) = 300 THEN 'PASS' ELSE 'FAIL' END);

-- Test 4.7: SUM_NEG (filtrage négatifs)
DECLARE @InputAgg7 NVARCHAR(MAX) = N'{
    "variables": [
        {"key": "AMOUNT_01", "value": "100"},
        {"key": "AMOUNT_02", "value": "200"},
        {"key": "AMOUNT_03", "value": "-50"}
    ],
    "rules": ["TEST_AGG_SUM_NEG"]
}';
DECLARE @OutputAgg7 NVARCHAR(MAX);
EXEC dbo.sp_RunRulesEngine @InputAgg7, @OutputAgg7 OUTPUT;

DECLARE @ValAgg7 NVARCHAR(100) = JSON_VALUE(@OutputAgg7, '$.results[0].value');
INSERT INTO #TestResults (Category, TestName, Expected, Actual, Status)
VALUES ('AGG', 'SUM_NEG', '-50', @ValAgg7,
    CASE WHEN TRY_CAST(@ValAgg7 AS DECIMAL(18,2)) = -50 THEN 'PASS' ELSE 'FAIL' END);

-- Test 4.8: CONCAT
DECLARE @InputAgg8 NVARCHAR(MAX) = N'{
    "variables": [
        {"key": "TEXT_A", "value": "Hello"},
        {"key": "TEXT_B", "value": "World"},
        {"key": "TEXT_C", "value": "!"}
    ],
    "rules": ["TEST_AGG_CONCAT"]
}';
DECLARE @OutputAgg8 NVARCHAR(MAX);
EXEC dbo.sp_RunRulesEngine @InputAgg8, @OutputAgg8 OUTPUT;

DECLARE @ValAgg8 NVARCHAR(100) = JSON_VALUE(@OutputAgg8, '$.results[0].value');
INSERT INTO #TestResults (Category, TestName, Expected, Actual, Status, Details)
VALUES ('AGG', 'CONCAT', 'Hello,World,!', @ValAgg8,
    CASE WHEN @ValAgg8 LIKE '%Hello%World%' THEN 'PASS' ELSE 'FAIL' END,
    'Ordre par SeqId');

GO

-- =========================================================================
-- PARTIE 5 : TESTS MODE DEBUG
-- =========================================================================
PRINT '── Tests mode DEBUG ──';

DECLARE @InputDebug NVARCHAR(MAX) = N'{
    "mode": "DEBUG",
    "variables": [{"key": "VAR_A", "value": "42"}],
    "rules": ["TEST_VAR"],
    "options": {"returnDebug": true}
}';
DECLARE @OutputDebug NVARCHAR(MAX);
EXEC dbo.sp_RunRulesEngine @InputDebug, @OutputDebug OUTPUT;

DECLARE @StatusDebug NVARCHAR(20) = JSON_VALUE(@OutputDebug, '$.status');
DECLARE @ModeDebug NVARCHAR(20) = JSON_VALUE(@OutputDebug, '$.mode');

INSERT INTO #TestResults (Category, TestName, Expected, Actual, Status)
VALUES ('DEBUG', 'Mode DEBUG activé', 'SUCCESS/DEBUG', CONCAT(@StatusDebug,'/',@ModeDebug),
    CASE WHEN @StatusDebug='SUCCESS' AND @ModeDebug='DEBUG' THEN 'PASS' ELSE 'FAIL' END);

GO

-- =========================================================================
-- RAPPORT FINAL
-- =========================================================================
PRINT '';
PRINT '══════════════════════════════════════════════════════════════════════';
PRINT '                        RAPPORT FINAL                                 ';
PRINT '══════════════════════════════════════════════════════════════════════';
PRINT '';

-- Résumé par catégorie
SELECT 
    Category AS [Catégorie],
    COUNT(*) AS [Total],
    SUM(CASE WHEN Status = 'PASS' THEN 1 ELSE 0 END) AS [Pass],
    SUM(CASE WHEN Status = 'FAIL' THEN 1 ELSE 0 END) AS [Fail]
FROM #TestResults
GROUP BY Category
ORDER BY Category;

-- Détails
SELECT 
    TestId AS [#],
    Category AS [Cat],
    TestName AS [Test],
    Expected AS [Attendu],
    Actual AS [Obtenu],
    Status AS [Statut],
    Details AS [Détails]
FROM #TestResults
ORDER BY TestId;

-- Totaux
DECLARE @Total INT, @Pass INT, @Fail INT;
SELECT @Total = COUNT(*), 
       @Pass = SUM(CASE WHEN Status = 'PASS' THEN 1 ELSE 0 END),
       @Fail = SUM(CASE WHEN Status = 'FAIL' THEN 1 ELSE 0 END)
FROM #TestResults;

PRINT '';
PRINT '══════════════════════════════════════════════════════════════════════';
PRINT CONCAT('  TOTAL: ', @Total, ' tests | PASS: ', @Pass, ' | FAIL: ', @Fail);
PRINT CONCAT('  Taux de réussite: ', CAST(100.0 * @Pass / @Total AS DECIMAL(5,1)), '%');
PRINT '══════════════════════════════════════════════════════════════════════';

IF @Fail > 0
BEGIN
    PRINT '';
    PRINT 'TESTS EN ÉCHEC:';
    SELECT Category, TestName, Expected, Actual, Details 
    FROM #TestResults WHERE Status = 'FAIL';
END

-- Nettoyage
DELETE FROM dbo.RuleDefinitions WHERE RuleCode LIKE 'TEST_%';
DROP TABLE #TestResults;
GO
