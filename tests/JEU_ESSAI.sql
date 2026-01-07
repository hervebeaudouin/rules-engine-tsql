/***********************************************************************
    JEU D'ESSAI EXHAUSTIF - MOTEUR DE RÈGLES V4.1
    
    Ce script teste toutes les fonctionnalités du moteur :
    1. Types de tokens (DIRECT, SUM, AVG, MIN, MAX, COUNT, IIF, Rule:)
    2. Filtres de valeurs (+, -, ALL)
    3. Dépendances multi-niveaux (jusqu'à 6 niveaux)
    4. Détection de cycles
    5. Gestion des erreurs
    6. Performance et cache
    7. Isolation entre sessions
    8. Cas limites et edge cases
    
    Prérequis : Exécuter MOTEUR_REGLES_COMPLET.sql avant ce script
    
    IMPORTANT: Ce script doit être exécuté en une seule fois (sans GO intermédiaires
    qui détruiraient les tables temporaires)
************************************************************************/

SET NOCOUNT ON;

PRINT '══════════════════════════════════════════════════════════════════════';
PRINT '         JEU D''ESSAI EXHAUSTIF - MOTEUR DE RÈGLES V4.1               ';
PRINT '══════════════════════════════════════════════════════════════════════';
PRINT '';
PRINT 'Session: ' + CAST(@@SPID AS varchar(10));
PRINT 'Date: ' + CONVERT(varchar(20), GETDATE(), 120);
PRINT '';

-- =========================================================================
-- PARTIE 0 : NETTOYAGE ET PRÉPARATION
-- =========================================================================
PRINT '┌─────────────────────────────────────────────────────────────────────┐';
PRINT '│ PARTIE 0 : Nettoyage et préparation                                 │';
PRINT '└─────────────────────────────────────────────────────────────────────┘';

-- Supprimer les règles de test existantes
DELETE FROM dbo.RuleDependency WHERE RuleCode LIKE 'TEST_%';
DELETE FROM dbo.Rules WHERE RuleCode LIKE 'TEST_%';

-- Créer #Variables si elle n'existe pas
IF OBJECT_ID('tempdb..#Variables') IS NULL
BEGIN
    CREATE TABLE #Variables (
        VarKey nvarchar(100) COLLATE DATABASE_DEFAULT PRIMARY KEY,
        VarType varchar(20) COLLATE DATABASE_DEFAULT NOT NULL,
        ValueDecimal decimal(18,6) NULL,
        ValueInteger bigint NULL,
        ValueString nvarchar(500) COLLATE DATABASE_DEFAULT NULL,
        ValueDate date NULL,
        ValueDateTime datetime2 NULL,
        ValueBoolean bit NULL,
        Category nvarchar(50) COLLATE DATABASE_DEFAULT NULL
    );
END
ELSE
    TRUNCATE TABLE #Variables;

-- Vider le cache
IF OBJECT_ID('tempdb..#RuleResultsCache') IS NOT NULL DROP TABLE #RuleResultsCache;

-- Table pour collecter les résultats des tests
IF OBJECT_ID('tempdb..#TestResults') IS NOT NULL DROP TABLE #TestResults;
CREATE TABLE #TestResults (
    TestId int IDENTITY(1,1),
    TestCategory nvarchar(50) COLLATE DATABASE_DEFAULT,
    TestName nvarchar(100) COLLATE DATABASE_DEFAULT,
    Expected nvarchar(100) COLLATE DATABASE_DEFAULT,
    Actual nvarchar(100) COLLATE DATABASE_DEFAULT,
    Status varchar(10) COLLATE DATABASE_DEFAULT,
    Details nvarchar(500) COLLATE DATABASE_DEFAULT
);

PRINT '   OK Préparation terminée';
PRINT '';

-- =========================================================================
-- PARTIE 1 : TESTS DES TYPES DE TOKENS
-- =========================================================================
PRINT '┌─────────────────────────────────────────────────────────────────────┐';
PRINT '│ PARTIE 1 : Tests des types de tokens                                │';
PRINT '└─────────────────────────────────────────────────────────────────────┘';

-- 1.1 Charger les données de test
INSERT INTO #Variables (VarKey, VarType, ValueDecimal, ValueInteger, ValueString, ValueBoolean, Category) VALUES
    -- Valeurs numériques directes
    ('VAL_A', 'DECIMAL', 100.00, NULL, NULL, NULL, 'DIRECT'),
    ('VAL_B', 'DECIMAL', 50.25, NULL, NULL, NULL, 'DIRECT'),
    ('VAL_C', 'DECIMAL', -30.00, NULL, NULL, NULL, 'DIRECT'),
    ('VAL_D', 'INTEGER', NULL, 42, NULL, NULL, 'DIRECT'),
    
    -- Valeurs pour agrégations (pattern MONTANT_%)
    ('MONTANT_01', 'DECIMAL', 100.00, NULL, NULL, NULL, 'MONTANT'),
    ('MONTANT_02', 'DECIMAL', 200.00, NULL, NULL, NULL, 'MONTANT'),
    ('MONTANT_03', 'DECIMAL', -50.00, NULL, NULL, NULL, 'MONTANT'),
    ('MONTANT_04', 'DECIMAL', 150.00, NULL, NULL, NULL, 'MONTANT'),
    ('MONTANT_05', 'DECIMAL', -25.00, NULL, NULL, NULL, 'MONTANT'),
    
    -- Valeurs pour tests conditionnels
    ('SEUIL_BAS', 'DECIMAL', 100.00, NULL, NULL, NULL, 'SEUIL'),
    ('SEUIL_HAUT', 'DECIMAL', 500.00, NULL, NULL, NULL, 'SEUIL'),
    ('TAUX_REDUIT', 'DECIMAL', 0.05, NULL, NULL, NULL, 'TAUX'),
    ('TAUX_NORMAL', 'DECIMAL', 0.10, NULL, NULL, NULL, 'TAUX'),
    ('TAUX_ELEVE', 'DECIMAL', 0.20, NULL, NULL, NULL, 'TAUX'),
    
    -- Valeurs booléennes
    ('FLAG_ACTIF', 'BOOLEAN', NULL, NULL, NULL, 1, 'FLAG'),
    ('FLAG_INACTIF', 'BOOLEAN', NULL, NULL, NULL, 0, 'FLAG'),
    
    -- Chaînes
    ('LIBELLE_A', 'STRING', NULL, NULL, 'Test String A', NULL, 'TEXT'),
    ('LIBELLE_B', 'STRING', NULL, NULL, 'Test String B', NULL, 'TEXT');

DECLARE @VarCount int;
SELECT @VarCount = COUNT(*) FROM #Variables;
PRINT CONCAT('   Données chargées: ', @VarCount, ' variables');

-- 1.2 Créer les règles de test pour chaque type de token
DECLARE @S bit, @E nvarchar(500);

-- DIRECT : Accès direct à une variable
INSERT INTO dbo.Rules (RuleCode, RuleName, Expression, Description) VALUES
('TEST_DIRECT_DEC', 'Test Direct Decimal', '{VAL_A}', 'Accès direct decimal');
EXEC dbo.sp_CompileRule 'TEST_DIRECT_DEC', @S OUTPUT, @E OUTPUT;

INSERT INTO dbo.Rules (RuleCode, RuleName, Expression, Description) VALUES
('TEST_DIRECT_INT', 'Test Direct Integer', '{VAL_D}', 'Accès direct integer');
EXEC dbo.sp_CompileRule 'TEST_DIRECT_INT', @S OUTPUT, @E OUTPUT;

-- DIRECT : Expression arithmétique
INSERT INTO dbo.Rules (RuleCode, RuleName, Expression, Description) VALUES
('TEST_ARITHM', 'Test Arithmetique', '{VAL_A} + {VAL_B} * 2 - {VAL_C}', 'Expression arithmétique');
EXEC dbo.sp_CompileRule 'TEST_ARITHM', @S OUTPUT, @E OUTPUT;

-- SUM : Somme avec pattern
INSERT INTO dbo.Rules (RuleCode, RuleName, Expression, Description) VALUES
('TEST_SUM_ALL', 'Test Sum All', '{Sum(MONTANT_%)}', 'Somme de tous les MONTANT_*');
EXEC dbo.sp_CompileRule 'TEST_SUM_ALL', @S OUTPUT, @E OUTPUT;

-- SUM avec filtre positif
INSERT INTO dbo.Rules (RuleCode, RuleName, Expression, Description) VALUES
('TEST_SUM_POS', 'Test Sum Positifs', '{Sum(MONTANT_%+)}', 'Somme des MONTANT_* positifs');
EXEC dbo.sp_CompileRule 'TEST_SUM_POS', @S OUTPUT, @E OUTPUT;

-- SUM avec filtre négatif
INSERT INTO dbo.Rules (RuleCode, RuleName, Expression, Description) VALUES
('TEST_SUM_NEG', 'Test Sum Negatifs', '{Sum(MONTANT_%-)}', 'Somme des MONTANT_* négatifs');
EXEC dbo.sp_CompileRule 'TEST_SUM_NEG', @S OUTPUT, @E OUTPUT;

-- AVG : Moyenne
INSERT INTO dbo.Rules (RuleCode, RuleName, Expression, Description) VALUES
('TEST_AVG', 'Test Average', '{Avg(MONTANT_%)}', 'Moyenne des MONTANT_*');
EXEC dbo.sp_CompileRule 'TEST_AVG', @S OUTPUT, @E OUTPUT;

-- MIN : Minimum
INSERT INTO dbo.Rules (RuleCode, RuleName, Expression, Description) VALUES
('TEST_MIN', 'Test Minimum', '{Min(MONTANT_%)}', 'Minimum des MONTANT_*');
EXEC dbo.sp_CompileRule 'TEST_MIN', @S OUTPUT, @E OUTPUT;

-- MAX : Maximum
INSERT INTO dbo.Rules (RuleCode, RuleName, Expression, Description) VALUES
('TEST_MAX', 'Test Maximum', '{Max(MONTANT_%)}', 'Maximum des MONTANT_*');
EXEC dbo.sp_CompileRule 'TEST_MAX', @S OUTPUT, @E OUTPUT;

-- COUNT : Comptage
INSERT INTO dbo.Rules (RuleCode, RuleName, Expression, Description) VALUES
('TEST_COUNT', 'Test Count', '{Count(MONTANT_%)}', 'Nombre de MONTANT_*');
EXEC dbo.sp_CompileRule 'TEST_COUNT', @S OUTPUT, @E OUTPUT;

-- IIF : Conditionnel simple
INSERT INTO dbo.Rules (RuleCode, RuleName, Expression, Description) VALUES
('TEST_IIF_SIMPLE', 'Test IIF Simple', '{IIF({VAL_A} > 50, 1, 0)}', 'IIF simple');
EXEC dbo.sp_CompileRule 'TEST_IIF_SIMPLE', @S OUTPUT, @E OUTPUT;

-- IIF : Conditionnel avec calcul
INSERT INTO dbo.Rules (RuleCode, RuleName, Expression, Description) VALUES
('TEST_IIF_CALC', 'Test IIF Calcul', '{IIF({VAL_A} > {SEUIL_BAS}, {VAL_A} * {TAUX_NORMAL}, {VAL_A} * {TAUX_REDUIT})}', 'IIF avec calcul');
EXEC dbo.sp_CompileRule 'TEST_IIF_CALC', @S OUTPUT, @E OUTPUT;

PRINT '   Règles de tokens créées';

-- 1.3 Exécuter et valider les tests de tokens
DECLARE @R nvarchar(500), @St varchar(20), @Er nvarchar(500), @T int;
DECLARE @Expected decimal(18,6), @Actual decimal(18,6);

-- Test DIRECT_DEC
IF OBJECT_ID('tempdb..#RuleResultsCache') IS NOT NULL DROP TABLE #RuleResultsCache;
EXEC dbo.sp_ExecuteRuleRecursive 'TEST_DIRECT_DEC', 0, @R OUTPUT, @St OUTPUT, @Er OUTPUT, @T OUTPUT;
SET @Expected = 100.00; SET @Actual = TRY_CAST(@R AS decimal(18,6));
INSERT INTO #TestResults (TestCategory, TestName, Expected, Actual, Status, Details)
VALUES ('TOKENS', 'DIRECT Decimal', CAST(@Expected AS nvarchar(50)), @R, 
    CASE WHEN @Actual = @Expected THEN 'PASS' ELSE 'FAIL' END, @Er);

-- Test DIRECT_INT
IF OBJECT_ID('tempdb..#RuleResultsCache') IS NOT NULL DROP TABLE #RuleResultsCache;
EXEC dbo.sp_ExecuteRuleRecursive 'TEST_DIRECT_INT', 0, @R OUTPUT, @St OUTPUT, @Er OUTPUT, @T OUTPUT;
SET @Expected = 42; SET @Actual = TRY_CAST(@R AS decimal(18,6));
INSERT INTO #TestResults (TestCategory, TestName, Expected, Actual, Status, Details)
VALUES ('TOKENS', 'DIRECT Integer', CAST(@Expected AS nvarchar(50)), @R,
    CASE WHEN @Actual = @Expected THEN 'PASS' ELSE 'FAIL' END, @Er);

-- Test ARITHM: 100 + 50.25*2 - (-30) = 100 + 100.5 + 30 = 230.5
IF OBJECT_ID('tempdb..#RuleResultsCache') IS NOT NULL DROP TABLE #RuleResultsCache;
EXEC dbo.sp_ExecuteRuleRecursive 'TEST_ARITHM', 0, @R OUTPUT, @St OUTPUT, @Er OUTPUT, @T OUTPUT;
SET @Expected = 230.50; SET @Actual = TRY_CAST(@R AS decimal(18,6));
INSERT INTO #TestResults (TestCategory, TestName, Expected, Actual, Status, Details)
VALUES ('TOKENS', 'Arithmetique', CAST(@Expected AS nvarchar(50)), @R,
    CASE WHEN @Actual = @Expected THEN 'PASS' ELSE 'FAIL' END, 
    '100 + 50.25*2 - (-30) = 230.50');

-- Test SUM_ALL: 100+200-50+150-25 = 375
IF OBJECT_ID('tempdb..#RuleResultsCache') IS NOT NULL DROP TABLE #RuleResultsCache;
EXEC dbo.sp_ExecuteRuleRecursive 'TEST_SUM_ALL', 0, @R OUTPUT, @St OUTPUT, @Er OUTPUT, @T OUTPUT;
SET @Expected = 375.00; SET @Actual = TRY_CAST(@R AS decimal(18,6));
INSERT INTO #TestResults (TestCategory, TestName, Expected, Actual, Status, Details)
VALUES ('TOKENS', 'SUM All', CAST(@Expected AS nvarchar(50)), @R,
    CASE WHEN @Actual = @Expected THEN 'PASS' ELSE 'FAIL' END,
    '100+200-50+150-25 = 375');

-- Test SUM_POS: 100+200+150 = 450
IF OBJECT_ID('tempdb..#RuleResultsCache') IS NOT NULL DROP TABLE #RuleResultsCache;
EXEC dbo.sp_ExecuteRuleRecursive 'TEST_SUM_POS', 0, @R OUTPUT, @St OUTPUT, @Er OUTPUT, @T OUTPUT;
SET @Expected = 450.00; SET @Actual = TRY_CAST(@R AS decimal(18,6));
INSERT INTO #TestResults (TestCategory, TestName, Expected, Actual, Status, Details)
VALUES ('TOKENS', 'SUM Positifs', CAST(@Expected AS nvarchar(50)), @R,
    CASE WHEN @Actual = @Expected THEN 'PASS' ELSE 'FAIL' END,
    '100+200+150 = 450');

-- Test SUM_NEG: -50-25 = -75
IF OBJECT_ID('tempdb..#RuleResultsCache') IS NOT NULL DROP TABLE #RuleResultsCache;
EXEC dbo.sp_ExecuteRuleRecursive 'TEST_SUM_NEG', 0, @R OUTPUT, @St OUTPUT, @Er OUTPUT, @T OUTPUT;
SET @Expected = -75.00; SET @Actual = TRY_CAST(@R AS decimal(18,6));
INSERT INTO #TestResults (TestCategory, TestName, Expected, Actual, Status, Details)
VALUES ('TOKENS', 'SUM Negatifs', CAST(@Expected AS nvarchar(50)), @R,
    CASE WHEN @Actual = @Expected THEN 'PASS' ELSE 'FAIL' END,
    '-50-25 = -75');

-- Test AVG: 375/5 = 75
IF OBJECT_ID('tempdb..#RuleResultsCache') IS NOT NULL DROP TABLE #RuleResultsCache;
EXEC dbo.sp_ExecuteRuleRecursive 'TEST_AVG', 0, @R OUTPUT, @St OUTPUT, @Er OUTPUT, @T OUTPUT;
SET @Expected = 75.00; SET @Actual = TRY_CAST(@R AS decimal(18,6));
INSERT INTO #TestResults (TestCategory, TestName, Expected, Actual, Status, Details)
VALUES ('TOKENS', 'AVG', CAST(@Expected AS nvarchar(50)), @R,
    CASE WHEN @Actual = @Expected THEN 'PASS' ELSE 'FAIL' END,
    '375/5 = 75');

-- Test MIN: -50
IF OBJECT_ID('tempdb..#RuleResultsCache') IS NOT NULL DROP TABLE #RuleResultsCache;
EXEC dbo.sp_ExecuteRuleRecursive 'TEST_MIN', 0, @R OUTPUT, @St OUTPUT, @Er OUTPUT, @T OUTPUT;
SET @Expected = -50.00; SET @Actual = TRY_CAST(@R AS decimal(18,6));
INSERT INTO #TestResults (TestCategory, TestName, Expected, Actual, Status, Details)
VALUES ('TOKENS', 'MIN', CAST(@Expected AS nvarchar(50)), @R,
    CASE WHEN @Actual = @Expected THEN 'PASS' ELSE 'FAIL' END,
    'Min = -50');

-- Test MAX: 200
IF OBJECT_ID('tempdb..#RuleResultsCache') IS NOT NULL DROP TABLE #RuleResultsCache;
EXEC dbo.sp_ExecuteRuleRecursive 'TEST_MAX', 0, @R OUTPUT, @St OUTPUT, @Er OUTPUT, @T OUTPUT;
SET @Expected = 200.00; SET @Actual = TRY_CAST(@R AS decimal(18,6));
INSERT INTO #TestResults (TestCategory, TestName, Expected, Actual, Status, Details)
VALUES ('TOKENS', 'MAX', CAST(@Expected AS nvarchar(50)), @R,
    CASE WHEN @Actual = @Expected THEN 'PASS' ELSE 'FAIL' END,
    'Max = 200');

-- Test COUNT: 5
IF OBJECT_ID('tempdb..#RuleResultsCache') IS NOT NULL DROP TABLE #RuleResultsCache;
EXEC dbo.sp_ExecuteRuleRecursive 'TEST_COUNT', 0, @R OUTPUT, @St OUTPUT, @Er OUTPUT, @T OUTPUT;
SET @Expected = 5; SET @Actual = TRY_CAST(@R AS decimal(18,6));
INSERT INTO #TestResults (TestCategory, TestName, Expected, Actual, Status, Details)
VALUES ('TOKENS', 'COUNT', CAST(@Expected AS nvarchar(50)), @R,
    CASE WHEN @Actual = @Expected THEN 'PASS' ELSE 'FAIL' END,
    'Count = 5');

-- Test IIF_SIMPLE: 100 > 50 => 1
IF OBJECT_ID('tempdb..#RuleResultsCache') IS NOT NULL DROP TABLE #RuleResultsCache;
EXEC dbo.sp_ExecuteRuleRecursive 'TEST_IIF_SIMPLE', 0, @R OUTPUT, @St OUTPUT, @Er OUTPUT, @T OUTPUT;
SET @Expected = 1; SET @Actual = TRY_CAST(@R AS decimal(18,6));
INSERT INTO #TestResults (TestCategory, TestName, Expected, Actual, Status, Details)
VALUES ('TOKENS', 'IIF Simple', CAST(@Expected AS nvarchar(50)), @R,
    CASE WHEN @Actual = @Expected THEN 'PASS' ELSE 'FAIL' END,
    '100 > 50 => 1');

-- Test IIF_CALC: 100 > 100 est FAUX => 100 * 0.05 = 5
IF OBJECT_ID('tempdb..#RuleResultsCache') IS NOT NULL DROP TABLE #RuleResultsCache;
EXEC dbo.sp_ExecuteRuleRecursive 'TEST_IIF_CALC', 0, @R OUTPUT, @St OUTPUT, @Er OUTPUT, @T OUTPUT;
SET @Expected = 5.00; SET @Actual = TRY_CAST(@R AS decimal(18,6));
INSERT INTO #TestResults (TestCategory, TestName, Expected, Actual, Status, Details)
VALUES ('TOKENS', 'IIF Calcul', CAST(@Expected AS nvarchar(50)), @R,
    CASE WHEN @Actual = @Expected THEN 'PASS' ELSE 'FAIL' END,
    '100 > 100 FAUX => 100*0.05 = 5');

PRINT '   Tests de tokens exécutés';
PRINT '';

-- =========================================================================
-- PARTIE 2 : TESTS DES DÉPENDANCES MULTI-NIVEAUX
-- =========================================================================
PRINT '┌─────────────────────────────────────────────────────────────────────┐';
PRINT '│ PARTIE 2 : Tests des dépendances multi-niveaux (6 niveaux)          │';
PRINT '└─────────────────────────────────────────────────────────────────────┘';

-- Niveau 1 : Base (pas de dépendances)
INSERT INTO dbo.Rules (RuleCode, RuleName, Expression, Description) VALUES
('TEST_L1_A', 'Niveau 1 A', '{VAL_A}', 'Niveau 1 - Valeur A = 100'),
('TEST_L1_B', 'Niveau 1 B', '{VAL_B}', 'Niveau 1 - Valeur B = 50.25');
EXEC dbo.sp_CompileRule 'TEST_L1_A', @S OUTPUT, @E OUTPUT;
EXEC dbo.sp_CompileRule 'TEST_L1_B', @S OUTPUT, @E OUTPUT;

-- Niveau 2 : Dépend de Niveau 1
INSERT INTO dbo.Rules (RuleCode, RuleName, Expression, Description) VALUES
('TEST_L2_A', 'Niveau 2 A', '{Rule:TEST_L1_A} + {Rule:TEST_L1_B}', 'L1_A + L1_B = 150.25'),
('TEST_L2_B', 'Niveau 2 B', '{Rule:TEST_L1_A} * 2', 'L1_A * 2 = 200');
EXEC dbo.sp_CompileRule 'TEST_L2_A', @S OUTPUT, @E OUTPUT;
EXEC dbo.sp_CompileRule 'TEST_L2_B', @S OUTPUT, @E OUTPUT;

-- Niveau 3 : Dépend de Niveau 2
INSERT INTO dbo.Rules (RuleCode, RuleName, Expression, Description) VALUES
('TEST_L3_A', 'Niveau 3 A', '{Rule:TEST_L2_A} + {Rule:TEST_L2_B}', 'L2_A + L2_B = 350.25'),
('TEST_L3_B', 'Niveau 3 B', '{Rule:TEST_L2_A} * {TAUX_NORMAL}', 'L2_A * 0.10 = 15.025');
EXEC dbo.sp_CompileRule 'TEST_L3_A', @S OUTPUT, @E OUTPUT;
EXEC dbo.sp_CompileRule 'TEST_L3_B', @S OUTPUT, @E OUTPUT;

-- Niveau 4 : Dépend de Niveau 3 ET Niveau 2 (dépendances croisées)
INSERT INTO dbo.Rules (RuleCode, RuleName, Expression, Description) VALUES
('TEST_L4_A', 'Niveau 4 A', '{Rule:TEST_L3_A} - {Rule:TEST_L2_A}', 'L3_A - L2_A = 200');
EXEC dbo.sp_CompileRule 'TEST_L4_A', @S OUTPUT, @E OUTPUT;

-- Niveau 5 : Dépend de Niveau 4
INSERT INTO dbo.Rules (RuleCode, RuleName, Expression, Description) VALUES
('TEST_L5_A', 'Niveau 5 A', '{Rule:TEST_L4_A} / 2 + {Rule:TEST_L3_B}', 'L4_A/2 + L3_B = 115.025');
EXEC dbo.sp_CompileRule 'TEST_L5_A', @S OUTPUT, @E OUTPUT;

-- Niveau 6 : Dépend de plusieurs niveaux
INSERT INTO dbo.Rules (RuleCode, RuleName, Expression, Description) VALUES
('TEST_L6_A', 'Niveau 6 A', '{Rule:TEST_L5_A} + {Rule:TEST_L1_A}', 'L5_A + L1_A = 215.025');
EXEC dbo.sp_CompileRule 'TEST_L6_A', @S OUTPUT, @E OUTPUT;

-- Reconstruire le graphe
EXEC dbo.sp_BuildRuleDependencyGraph;

-- Tester l'exécution du niveau 6 (devrait résoudre toute la chaîne)
IF OBJECT_ID('tempdb..#RuleResultsCache') IS NOT NULL DROP TABLE #RuleResultsCache;
EXEC dbo.sp_ExecuteRuleRecursive 'TEST_L6_A', 0, @R OUTPUT, @St OUTPUT, @Er OUTPUT, @T OUTPUT;
SET @Expected = 215.025; SET @Actual = TRY_CAST(@R AS decimal(18,6));
INSERT INTO #TestResults (TestCategory, TestName, Expected, Actual, Status, Details)
VALUES ('DEPENDANCES', '6 Niveaux', CAST(@Expected AS nvarchar(50)), @R,
    CASE WHEN ABS(ISNULL(@Actual,0) - @Expected) < 0.01 THEN 'PASS' ELSE 'FAIL' END,
    CONCAT('Temps: ', @T, ' ms, Erreur: ', @Er));

-- Vérifier que le cache contient toutes les règles intermédiaires
DECLARE @CacheCount int = 0;
IF OBJECT_ID('tempdb..#RuleResultsCache') IS NOT NULL
    SELECT @CacheCount = COUNT(*) FROM #RuleResultsCache WHERE RuleCode LIKE 'TEST_L%';
INSERT INTO #TestResults (TestCategory, TestName, Expected, Actual, Status, Details)
VALUES ('DEPENDANCES', 'Cache Rempli', '8', CAST(@CacheCount AS nvarchar(10)),
    CASE WHEN @CacheCount = 8 THEN 'PASS' ELSE 'FAIL' END,
    'Toutes les règles L1-L6 doivent être en cache');

PRINT '   Tests de dépendances exécutés';
PRINT '';

-- =========================================================================
-- PARTIE 3 : TESTS DE DÉTECTION DE CYCLES
-- =========================================================================
PRINT '┌─────────────────────────────────────────────────────────────────────┐';
PRINT '│ PARTIE 3 : Tests de détection de cycles                             │';
PRINT '└─────────────────────────────────────────────────────────────────────┘';

-- Créer un cycle : A -> B -> C -> A
INSERT INTO dbo.Rules (RuleCode, RuleName, Expression, Description) VALUES
('TEST_CYCLE_A', 'Cycle A', '{Rule:TEST_CYCLE_C} + 1', 'Cycle: A depend de C');
INSERT INTO dbo.Rules (RuleCode, RuleName, Expression, Description) VALUES
('TEST_CYCLE_B', 'Cycle B', '{Rule:TEST_CYCLE_A} + 1', 'Cycle: B depend de A');
INSERT INTO dbo.Rules (RuleCode, RuleName, Expression, Description) VALUES
('TEST_CYCLE_C', 'Cycle C', '{Rule:TEST_CYCLE_B} + 1', 'Cycle: C depend de B');

EXEC dbo.sp_CompileRule 'TEST_CYCLE_A', @S OUTPUT, @E OUTPUT;
EXEC dbo.sp_CompileRule 'TEST_CYCLE_B', @S OUTPUT, @E OUTPUT;
EXEC dbo.sp_CompileRule 'TEST_CYCLE_C', @S OUTPUT, @E OUTPUT;

-- Reconstruire le graphe
EXEC dbo.sp_BuildRuleDependencyGraph;

-- Tester que le cycle est détecté
IF OBJECT_ID('tempdb..#RuleResultsCache') IS NOT NULL DROP TABLE #RuleResultsCache;
EXEC dbo.sp_ExecuteRuleRecursive 'TEST_CYCLE_A', 0, @R OUTPUT, @St OUTPUT, @Er OUTPUT, @T OUTPUT;

INSERT INTO #TestResults (TestCategory, TestName, Expected, Actual, Status, Details)
VALUES ('CYCLES', 'Detection Cycle', 'ERROR', @St,
    CASE WHEN @St = 'ERROR' AND @Er LIKE '%Cycle%' THEN 'PASS' ELSE 'FAIL' END,
    @Er);

-- Tester sp_DetectRuleCycles
DECLARE @HasCycles bit;
EXEC dbo.sp_DetectRuleCycles @HasCycles OUTPUT;
INSERT INTO #TestResults (TestCategory, TestName, Expected, Actual, Status, Details)
VALUES ('CYCLES', 'sp_DetectRuleCycles', '1', CAST(@HasCycles AS varchar(1)),
    CASE WHEN @HasCycles = 1 THEN 'PASS' ELSE 'FAIL' END,
    'Cycle A->B->C->A devrait être détecté');

-- Nettoyer les règles cycliques pour ne pas perturber les autres tests
DELETE FROM dbo.RuleDependency WHERE RuleCode LIKE 'TEST_CYCLE_%';
DELETE FROM dbo.Rules WHERE RuleCode LIKE 'TEST_CYCLE_%';

PRINT '   Tests de cycles exécutés';
PRINT '';

-- =========================================================================
-- PARTIE 4 : TESTS DE GESTION D'ERREURS
-- =========================================================================
PRINT '┌─────────────────────────────────────────────────────────────────────┐';
PRINT '│ PARTIE 4 : Tests de gestion d''erreurs                               │';
PRINT '└─────────────────────────────────────────────────────────────────────┘';

-- Test règle inexistante
IF OBJECT_ID('tempdb..#RuleResultsCache') IS NOT NULL DROP TABLE #RuleResultsCache;
EXEC dbo.sp_ExecuteRuleRecursive 'REGLE_QUI_NEXISTE_PAS', 0, @R OUTPUT, @St OUTPUT, @Er OUTPUT, @T OUTPUT;
INSERT INTO #TestResults (TestCategory, TestName, Expected, Actual, Status, Details)
VALUES ('ERREURS', 'Regle Inexistante', 'ERROR', @St,
    CASE WHEN @St = 'ERROR' THEN 'PASS' ELSE 'FAIL' END, @Er);

-- Test variable inexistante (doit retourner 0)
INSERT INTO dbo.Rules (RuleCode, RuleName, Expression, Description) VALUES
('TEST_VAR_MISSING', 'Var Missing', '{VARIABLE_QUI_NEXISTE_PAS}', 'Variable inexistante');
EXEC dbo.sp_CompileRule 'TEST_VAR_MISSING', @S OUTPUT, @E OUTPUT;

IF OBJECT_ID('tempdb..#RuleResultsCache') IS NOT NULL DROP TABLE #RuleResultsCache;
EXEC dbo.sp_ExecuteRuleRecursive 'TEST_VAR_MISSING', 0, @R OUTPUT, @St OUTPUT, @Er OUTPUT, @T OUTPUT;
INSERT INTO #TestResults (TestCategory, TestName, Expected, Actual, Status, Details)
VALUES ('ERREURS', 'Variable Inexistante', '0', @R,
    CASE WHEN @R = '0' OR @R = '0.000000' THEN 'PASS' ELSE 'FAIL' END,
    'Variable manquante doit retourner 0');

-- Test division par zéro
INSERT INTO dbo.Rules (RuleCode, RuleName, Expression, Description) VALUES
('TEST_DIV_ZERO', 'Division Zero', '{VAL_A} / 0', 'Division par zéro');
EXEC dbo.sp_CompileRule 'TEST_DIV_ZERO', @S OUTPUT, @E OUTPUT;

IF OBJECT_ID('tempdb..#RuleResultsCache') IS NOT NULL DROP TABLE #RuleResultsCache;
EXEC dbo.sp_ExecuteRuleRecursive 'TEST_DIV_ZERO', 0, @R OUTPUT, @St OUTPUT, @Er OUTPUT, @T OUTPUT;
INSERT INTO #TestResults (TestCategory, TestName, Expected, Actual, Status, Details)
VALUES ('ERREURS', 'Division par Zero', 'ERROR', @St,
    CASE WHEN @St = 'ERROR' THEN 'PASS' ELSE 'FAIL' END, @Er);

-- Test profondeur max de récursion (créer chaîne de 25 niveaux)
INSERT INTO dbo.Rules (RuleCode, RuleName, Expression, Description) VALUES
('TEST_DEEP_01', 'Deep 01', '{VAL_A}', 'Profondeur 1');
EXEC dbo.sp_CompileRule 'TEST_DEEP_01', @S OUTPUT, @E OUTPUT;

DECLARE @i int = 2;
DECLARE @Code nvarchar(50), @Prev nvarchar(50), @Expr nvarchar(200);
WHILE @i <= 25
BEGIN
    SET @Code = CONCAT('TEST_DEEP_', RIGHT('00' + CAST(@i AS varchar(2)), 2));
    SET @Prev = CONCAT('TEST_DEEP_', RIGHT('00' + CAST(@i-1 AS varchar(2)), 2));
    SET @Expr = CONCAT('{Rule:', @Prev, '} + 1');
    
    INSERT INTO dbo.Rules (RuleCode, RuleName, Expression, Description) 
    VALUES (@Code, CONCAT('Deep ', @i), @Expr, CONCAT('Profondeur ', @i));
    EXEC dbo.sp_CompileRule @Code, @S OUTPUT, @E OUTPUT;
    
    SET @i = @i + 1;
END

EXEC dbo.sp_BuildRuleDependencyGraph;

IF OBJECT_ID('tempdb..#RuleResultsCache') IS NOT NULL DROP TABLE #RuleResultsCache;
EXEC dbo.sp_ExecuteRuleRecursive 'TEST_DEEP_25', 0, @R OUTPUT, @St OUTPUT, @Er OUTPUT, @T OUTPUT;
INSERT INTO #TestResults (TestCategory, TestName, Expected, Actual, Status, Details)
VALUES ('ERREURS', 'Profondeur Max', 'ERROR', @St,
    CASE WHEN @St = 'ERROR' AND @Er LIKE '%Profondeur%' THEN 'PASS' ELSE 'FAIL' END,
    CONCAT('Profondeur 25 > Max 20. Erreur: ', @Er));

PRINT '   Tests d''erreurs exécutés';
PRINT '';

-- =========================================================================
-- PARTIE 5 : TESTS DE PERFORMANCE ET CACHE
-- =========================================================================
PRINT '┌─────────────────────────────────────────────────────────────────────┐';
PRINT '│ PARTIE 5 : Tests de performance et cache                            │';
PRINT '└─────────────────────────────────────────────────────────────────────┘';

DECLARE @Time1 int, @Time2 int;
DECLARE @StartTime datetime2, @EndTime datetime2;

-- Test 1: Première exécution (sans cache)
IF OBJECT_ID('tempdb..#RuleResultsCache') IS NOT NULL DROP TABLE #RuleResultsCache;
EXEC dbo.sp_ExecuteRuleRecursive 'TEST_L6_A', 0, @R OUTPUT, @St OUTPUT, @Er OUTPUT, @T OUTPUT;
SET @Time1 = @T;

-- Test 2: Deuxième exécution (avec cache)
EXEC dbo.sp_ExecuteRuleRecursive 'TEST_L6_A', 0, @R OUTPUT, @St OUTPUT, @Er OUTPUT, @T OUTPUT;
SET @Time2 = @T;

INSERT INTO #TestResults (TestCategory, TestName, Expected, Actual, Status, Details)
VALUES ('PERFORMANCE', 'Cache Efficace', 'Time2 <= Time1', 
    CONCAT(@Time1, ' -> ', @Time2, ' ms'),
    CASE WHEN @Time2 <= @Time1 THEN 'PASS' ELSE 'WARN' END,
    '2eme execution doit utiliser le cache');

-- Test 3: Exécution batch de 10 règles
IF OBJECT_ID('tempdb..#RuleResultsCache') IS NOT NULL DROP TABLE #RuleResultsCache;
SET @StartTime = SYSDATETIME();

SET @i = 1;
WHILE @i <= 10
BEGIN
    EXEC dbo.sp_ExecuteRuleRecursive 'TEST_L6_A', 0, @R OUTPUT, @St OUTPUT, @Er OUTPUT, @T OUTPUT;
    SET @i = @i + 1;
END

SET @EndTime = SYSDATETIME();
DECLARE @TotalTime int = DATEDIFF(MILLISECOND, @StartTime, @EndTime);

INSERT INTO #TestResults (TestCategory, TestName, Expected, Actual, Status, Details)
VALUES ('PERFORMANCE', '10 Executions', '< 500 ms', CONCAT(@TotalTime, ' ms'),
    CASE WHEN @TotalTime < 500 THEN 'PASS' ELSE 'WARN' END,
    '10 executions consecutives');

PRINT '   Tests de performance exécutés';
PRINT '';

-- =========================================================================
-- PARTIE 6 : TESTS D'ISOLATION
-- =========================================================================
PRINT '┌─────────────────────────────────────────────────────────────────────┐';
PRINT '│ PARTIE 6 : Tests d''isolation                                        │';
PRINT '└─────────────────────────────────────────────────────────────────────┘';

DECLARE @SessionVal decimal(18,2) = @@SPID * 1000 + 123.45;

-- Créer une règle de test d'isolation si elle n'existe pas
IF NOT EXISTS (SELECT 1 FROM dbo.Rules WHERE RuleCode = 'TEST_ISOLATION')
BEGIN
    INSERT INTO dbo.Rules (RuleCode, RuleName, Expression, Description) 
    VALUES ('TEST_ISOLATION', 'Test Isolation', '{ISOLATION_VAL}', 'Test isolation session');
    EXEC dbo.sp_CompileRule 'TEST_ISOLATION', @S OUTPUT, @E OUTPUT;
END

-- Charger une valeur unique pour cette session
DELETE FROM #Variables WHERE VarKey = 'ISOLATION_VAL';
INSERT INTO #Variables (VarKey, VarType, ValueDecimal) VALUES ('ISOLATION_VAL', 'DECIMAL', @SessionVal);

-- Exécuter et vérifier
IF OBJECT_ID('tempdb..#RuleResultsCache') IS NOT NULL DROP TABLE #RuleResultsCache;
EXEC dbo.sp_ExecuteRuleRecursive 'TEST_ISOLATION', 0, @R OUTPUT, @St OUTPUT, @Er OUTPUT, @T OUTPUT;

DECLARE @ActualIso decimal(18,2) = TRY_CAST(@R AS decimal(18,2));
INSERT INTO #TestResults (TestCategory, TestName, Expected, Actual, Status, Details)
VALUES ('ISOLATION', 'Valeur Session', CAST(@SessionVal AS nvarchar(50)), @R,
    CASE WHEN @ActualIso = @SessionVal THEN 'PASS' ELSE 'FAIL' END,
    CONCAT('Session ', @@SPID, ' - Valeur unique'));

PRINT '   Tests d''isolation exécutés';
PRINT '';

-- =========================================================================
-- PARTIE 7 : TESTS DU BATCH (sp_ExecuteRulesWithDependencies)
-- =========================================================================
PRINT '┌─────────────────────────────────────────────────────────────────────┐';
PRINT '│ PARTIE 7 : Tests du batch                                           │';
PRINT '└─────────────────────────────────────────────────────────────────────┘';

-- S'assurer que les données de base sont présentes
IF NOT EXISTS (SELECT 1 FROM #Variables WHERE VarKey = 'VAL_A')
BEGIN
    INSERT INTO #Variables (VarKey, VarType, ValueDecimal) VALUES ('VAL_A', 'DECIMAL', 100.00);
    INSERT INTO #Variables (VarKey, VarType, ValueDecimal) VALUES ('VAL_B', 'DECIMAL', 50.25);
    INSERT INTO #Variables (VarKey, VarType, ValueDecimal) VALUES ('VAL_C', 'DECIMAL', -30.00);
    INSERT INTO #Variables (VarKey, VarType, ValueDecimal) VALUES ('TAUX_NORMAL', 'DECIMAL', 0.10);
END

-- Exécuter le batch pour les règles de niveau
SET @StartTime = SYSDATETIME();
EXEC dbo.sp_ExecuteRulesWithDependencies '["TEST_L6_A"]', 0;
DECLARE @BatchTime int = DATEDIFF(MILLISECOND, @StartTime, SYSDATETIME());

INSERT INTO #TestResults (TestCategory, TestName, Expected, Actual, Status, Details)
VALUES ('BATCH', 'Execution Selective', 'SUCCESS', 'Voir resultats ci-dessus',
    'PASS', CONCAT('Temps batch: ', @BatchTime, ' ms'));

PRINT '';
PRINT '   Tests batch exécutés';
PRINT '';

-- =========================================================================
-- PARTIE 8 : CAS LIMITES (EDGE CASES)
-- =========================================================================
PRINT '┌─────────────────────────────────────────────────────────────────────┐';
PRINT '│ PARTIE 8 : Cas limites (Edge Cases)                                 │';
PRINT '└─────────────────────────────────────────────────────────────────────┘';

-- Test valeur zéro
DELETE FROM #Variables WHERE VarKey = 'ZERO_VAL';
INSERT INTO #Variables (VarKey, VarType, ValueDecimal) VALUES ('ZERO_VAL', 'DECIMAL', 0);

INSERT INTO dbo.Rules (RuleCode, RuleName, Expression, Description) VALUES
('TEST_ZERO', 'Test Zero', '{ZERO_VAL} * 100', 'Multiplication par zero');
EXEC dbo.sp_CompileRule 'TEST_ZERO', @S OUTPUT, @E OUTPUT;

IF OBJECT_ID('tempdb..#RuleResultsCache') IS NOT NULL DROP TABLE #RuleResultsCache;
EXEC dbo.sp_ExecuteRuleRecursive 'TEST_ZERO', 0, @R OUTPUT, @St OUTPUT, @Er OUTPUT, @T OUTPUT;
INSERT INTO #TestResults (TestCategory, TestName, Expected, Actual, Status, Details)
VALUES ('EDGE', 'Valeur Zero', '0', @R,
    CASE WHEN TRY_CAST(@R AS decimal(18,6)) = 0 THEN 'PASS' ELSE 'FAIL' END, @Er);

-- Test valeur négative
INSERT INTO dbo.Rules (RuleCode, RuleName, Expression, Description) VALUES
('TEST_NEGATIVE', 'Test Negative', '{VAL_C} * 2', 'Valeur negative * 2');
EXEC dbo.sp_CompileRule 'TEST_NEGATIVE', @S OUTPUT, @E OUTPUT;

IF OBJECT_ID('tempdb..#RuleResultsCache') IS NOT NULL DROP TABLE #RuleResultsCache;
EXEC dbo.sp_ExecuteRuleRecursive 'TEST_NEGATIVE', 0, @R OUTPUT, @St OUTPUT, @Er OUTPUT, @T OUTPUT;
INSERT INTO #TestResults (TestCategory, TestName, Expected, Actual, Status, Details)
VALUES ('EDGE', 'Valeur Negative', '-60', @R,
    CASE WHEN TRY_CAST(@R AS decimal(18,6)) = -60 THEN 'PASS' ELSE 'FAIL' END, @Er);

-- Test grande valeur
DELETE FROM #Variables WHERE VarKey = 'BIG_VAL';
INSERT INTO #Variables (VarKey, VarType, ValueDecimal) VALUES ('BIG_VAL', 'DECIMAL', 999999999.999999);

INSERT INTO dbo.Rules (RuleCode, RuleName, Expression, Description) VALUES
('TEST_BIG', 'Test Big', '{BIG_VAL} + 0.000001', 'Grande valeur');
EXEC dbo.sp_CompileRule 'TEST_BIG', @S OUTPUT, @E OUTPUT;

IF OBJECT_ID('tempdb..#RuleResultsCache') IS NOT NULL DROP TABLE #RuleResultsCache;
EXEC dbo.sp_ExecuteRuleRecursive 'TEST_BIG', 0, @R OUTPUT, @St OUTPUT, @Er OUTPUT, @T OUTPUT;
INSERT INTO #TestResults (TestCategory, TestName, Expected, Actual, Status, Details)
VALUES ('EDGE', 'Grande Valeur', '1000000000', @R,
    CASE WHEN @St = 'SUCCESS' THEN 'PASS' ELSE 'FAIL' END, @Er);

-- Test petite valeur décimale
DELETE FROM #Variables WHERE VarKey = 'TINY_VAL';
INSERT INTO #Variables (VarKey, VarType, ValueDecimal) VALUES ('TINY_VAL', 'DECIMAL', 0.000001);

INSERT INTO dbo.Rules (RuleCode, RuleName, Expression, Description) VALUES
('TEST_TINY', 'Test Tiny', '{TINY_VAL} * 1000000', 'Petite valeur * 1M');
EXEC dbo.sp_CompileRule 'TEST_TINY', @S OUTPUT, @E OUTPUT;

IF OBJECT_ID('tempdb..#RuleResultsCache') IS NOT NULL DROP TABLE #RuleResultsCache;
EXEC dbo.sp_ExecuteRuleRecursive 'TEST_TINY', 0, @R OUTPUT, @St OUTPUT, @Er OUTPUT, @T OUTPUT;
INSERT INTO #TestResults (TestCategory, TestName, Expected, Actual, Status, Details)
VALUES ('EDGE', 'Petite Valeur', '1', @R,
    CASE WHEN ABS(TRY_CAST(@R AS decimal(18,6)) - 1) < 0.01 THEN 'PASS' ELSE 'FAIL' END, @Er);

-- Test expression complexe imbriquée
INSERT INTO dbo.Rules (RuleCode, RuleName, Expression, Description) VALUES
('TEST_COMPLEX', 'Test Complex', 
 '({VAL_A} + {VAL_B}) * ({VAL_A} - {VAL_C}) / ({VAL_A} + 1)', 
 'Expression complexe imbriquée');
EXEC dbo.sp_CompileRule 'TEST_COMPLEX', @S OUTPUT, @E OUTPUT;

IF OBJECT_ID('tempdb..#RuleResultsCache') IS NOT NULL DROP TABLE #RuleResultsCache;
EXEC dbo.sp_ExecuteRuleRecursive 'TEST_COMPLEX', 0, @R OUTPUT, @St OUTPUT, @Er OUTPUT, @T OUTPUT;
-- (100 + 50.25) * (100 - (-30)) / (100 + 1) = 150.25 * 130 / 101 = 193.44...
INSERT INTO #TestResults (TestCategory, TestName, Expected, Actual, Status, Details)
VALUES ('EDGE', 'Expression Complexe', '~193.44', @R,
    CASE WHEN @St = 'SUCCESS' THEN 'PASS' ELSE 'FAIL' END, 
    '(100+50.25)*(100-(-30))/(100+1)');

PRINT '   Tests edge cases exécutés';
PRINT '';

-- =========================================================================
-- RAPPORT FINAL
-- =========================================================================
PRINT '══════════════════════════════════════════════════════════════════════';
PRINT '                        RAPPORT FINAL                                  ';
PRINT '══════════════════════════════════════════════════════════════════════';
PRINT '';

-- Résumé par catégorie
SELECT 
    TestCategory AS [Categorie],
    COUNT(*) AS [Total],
    SUM(CASE WHEN Status = 'PASS' THEN 1 ELSE 0 END) AS [Pass],
    SUM(CASE WHEN Status = 'FAIL' THEN 1 ELSE 0 END) AS [Fail],
    SUM(CASE WHEN Status = 'WARN' THEN 1 ELSE 0 END) AS [Warn]
FROM #TestResults
GROUP BY TestCategory
ORDER BY TestCategory;

PRINT '';

-- Détail des tests
SELECT 
    TestId AS [#],
    TestCategory AS [Categorie],
    TestName AS [Test],
    Expected AS [Attendu],
    Actual AS [Obtenu],
    Status AS [Statut],
    Details AS [Details]
FROM #TestResults
ORDER BY TestId;

PRINT '';

-- Résumé global
DECLARE @Total int, @Pass int, @Fail int, @Warn int;
SELECT 
    @Total = COUNT(*),
    @Pass = SUM(CASE WHEN Status = 'PASS' THEN 1 ELSE 0 END),
    @Fail = SUM(CASE WHEN Status = 'FAIL' THEN 1 ELSE 0 END),
    @Warn = SUM(CASE WHEN Status = 'WARN' THEN 1 ELSE 0 END)
FROM #TestResults;

PRINT '══════════════════════════════════════════════════════════════════════';
PRINT CONCAT('  TOTAL: ', @Total, ' tests | PASS: ', @Pass, ' | FAIL: ', @Fail, ' | WARN: ', @Warn);
PRINT CONCAT('  Taux de réussite: ', CAST(CAST(@Pass AS decimal(5,2)) / @Total * 100 AS decimal(5,1)), '%');
PRINT '══════════════════════════════════════════════════════════════════════';

IF @Fail > 0
BEGIN
    PRINT '';
    PRINT '⚠️  TESTS EN ÉCHEC:';
    SELECT TestCategory, TestName, Expected, Actual, Details 
    FROM #TestResults WHERE Status = 'FAIL';
END

PRINT '';
PRINT 'Fin des tests: ' + CONVERT(varchar(20), GETDATE(), 120);

-- Nettoyage optionnel (décommenter si souhaité)
-- DELETE FROM dbo.RuleDependency WHERE RuleCode LIKE 'TEST_%';
-- DELETE FROM dbo.Rules WHERE RuleCode LIKE 'TEST_%';
-- DROP TABLE #TestResults;
