/***********************************************************************
    SUITE DE TESTS DE CONFORMITE V1.6.0
    Tests normatifs pour validation du moteur v6.5
    
    Conformite : Specification REFERENCE v1.6.0
    
    CATEGORIES DE TESTS:
    =====================================================================
    
    1. AGREGATS - PRINCIPE FONDAMENTAL (ignore NULL)
       - T01: FIRST ignore NULL
       - T02: LAST ignore NULL
       - T03: SUM ignore NULL
       - T04: CONCAT ignore NULL
       - T05: JSONIFY ignore NULL
    
    2. AGREGATS - ENSEMBLES VIDES
       - T06: CONCAT ensemble vide → ""
       - T07: JSONIFY ensemble vide → "{}"
       - T08: SUM ensemble vide → NULL
    
    3. NORMALISATION LITTERAUX
       - T09: Decimaux français (2,5 → 2.5)
       - T10: Quotes normalisees (" → ')
       - T11: Resultats numeriques normalises
    
    4. LAST (NOUVEAU)
       - T12: LAST basique
       - T13: LAST avec NULL intercales
       - T14: LAST ensemble vide
    
    5. GESTION ERREURS
       - T15: Erreur n'interrompt pas thread
       - T16: Agregat ignore regles en erreur
       - T17: Propagation NULL
    
    6. REGRESSION (tests existants doivent passer)
       - T18: Variables simples
       - T19: Regles sans tokens
       - T20: JSONIFY format correct
    
************************************************************************/

SET NOCOUNT ON;
GO

PRINT '======================================================================';
PRINT '      SUITE DE TESTS DE CONFORMITE V1.6.0 - MOTEUR V6.5             ';
PRINT '======================================================================';
PRINT '';

-- =========================================================================
-- PREPARATION
-- =========================================================================
PRINT '-- Preparation --';

-- Nettoyer donnees de test
DELETE FROM dbo.RuleDefinitions WHERE RuleCode LIKE 'TEST_%';

DECLARE @TestResults TABLE (
    TestId VARCHAR(10),
    TestName NVARCHAR(200),
    Status VARCHAR(10),
    Expected NVARCHAR(MAX),
    Actual NVARCHAR(MAX),
    Message NVARCHAR(MAX)
);

DECLARE @PassCount INT = 0, @FailCount INT = 0;

PRINT '   OK';
PRINT '';
GO

-- =========================================================================
-- MACRO DE TEST
-- =========================================================================

-- Procedure helper pour executer et valider un test
IF OBJECT_ID('dbo.sp_RunTest','P') IS NOT NULL DROP PROCEDURE dbo.sp_RunTest;
GO

CREATE PROCEDURE dbo.sp_RunTest
    @TestId VARCHAR(10),
    @TestName NVARCHAR(200),
    @InputJson NVARCHAR(MAX),
    @ExpectedValue NVARCHAR(MAX),
    @RuleCode NVARCHAR(200) = 'TEST_R1'
AS
BEGIN
    SET NOCOUNT ON;
    
    DECLARE @OutputJson NVARCHAR(MAX);
    DECLARE @ActualValue NVARCHAR(MAX);
    DECLARE @Status VARCHAR(10) = 'FAIL';
    DECLARE @Message NVARCHAR(MAX) = '';
    
    BEGIN TRY
        EXEC dbo.sp_RunRulesEngine @InputJson, @OutputJson OUTPUT;
        
        -- Extraire valeur de la regle testee
        SET @ActualValue = JSON_VALUE(@OutputJson, '$.results[0].value');
        
        -- Comparaison
        IF (@ExpectedValue IS NULL AND @ActualValue IS NULL) 
           OR (@ExpectedValue = @ActualValue)
        BEGIN
            SET @Status = 'PASS';
        END
        ELSE
        BEGIN
            SET @Message = 'Valeur incorrecte';
        END
        
    END TRY
    BEGIN CATCH
        SET @Status = 'ERROR';
        SET @Message = ERROR_MESSAGE();
        SET @ActualValue = NULL;
    END CATCH
    
    -- Afficher resultat
    PRINT '  [' + @Status + '] ' + @TestId + ': ' + @TestName;
    IF @Status <> 'PASS'
        PRINT '       Expected: ' + ISNULL(@ExpectedValue, 'NULL') + 
              ' | Actual: ' + ISNULL(@ActualValue, 'NULL') +
              ' | ' + @Message;
    
    -- Stocker pour rapport final (simule avec PRINT)
END;
GO

PRINT '-- Tests --';
PRINT '';

-- =========================================================================
-- CATEGORIE 1: AGREGATS - PRINCIPE FONDAMENTAL (ignore NULL)
-- =========================================================================
PRINT '=== CATEGORIE 1: AGREGATS IGNORENT NULL ===';
PRINT '';

-- T01: FIRST ignore NULL
DELETE FROM dbo.RuleDefinitions WHERE RuleCode = 'TEST_R1';
INSERT INTO dbo.RuleDefinitions (RuleCode, Expression) VALUES ('TEST_R1', '{FIRST(v*)}');

EXEC dbo.sp_RunTest 
    @TestId = 'T01',
    @TestName = 'FIRST ignore NULL',
    @InputJson = N'{
        "variables": [
            {"key": "v1", "value": null},
            {"key": "v2", "value": null},
            {"key": "v3", "value": "10"}
        ],
        "rules": ["TEST_R1"]
    }',
    @ExpectedValue = '10',
    @RuleCode = 'TEST_R1';

-- T02: LAST ignore NULL
DELETE FROM dbo.RuleDefinitions WHERE RuleCode = 'TEST_R1';
INSERT INTO dbo.RuleDefinitions (RuleCode, Expression) VALUES ('TEST_R1', '{LAST(v*)}');

EXEC dbo.sp_RunTest 
    @TestId = 'T02',
    @TestName = 'LAST ignore NULL',
    @InputJson = N'{
        "variables": [
            {"key": "v1", "value": "5"},
            {"key": "v2", "value": null},
            {"key": "v3", "value": "20"}
        ],
        "rules": ["TEST_R1"]
    }',
    @ExpectedValue = '20',
    @RuleCode = 'TEST_R1';

-- T03: SUM ignore NULL
DELETE FROM dbo.RuleDefinitions WHERE RuleCode = 'TEST_R1';
INSERT INTO dbo.RuleDefinitions (RuleCode, Expression) VALUES ('TEST_R1', '{SUM(v*)}');

EXEC dbo.sp_RunTest 
    @TestId = 'T03',
    @TestName = 'SUM ignore NULL',
    @InputJson = N'{
        "variables": [
            {"key": "v1", "value": "10"},
            {"key": "v2", "value": null},
            {"key": "v3", "value": "5"}
        ],
        "rules": ["TEST_R1"]
    }',
    @ExpectedValue = '15',
    @RuleCode = 'TEST_R1';

-- T04: CONCAT ignore NULL
DELETE FROM dbo.RuleDefinitions WHERE RuleCode = 'TEST_R1';
INSERT INTO dbo.RuleDefinitions (RuleCode, Expression) VALUES ('TEST_R1', '{CONCAT(v*)}');

EXEC dbo.sp_RunTest 
    @TestId = 'T04',
    @TestName = 'CONCAT ignore NULL',
    @InputJson = N'{
        "variables": [
            {"key": "v1", "value": "A"},
            {"key": "v2", "value": null},
            {"key": "v3", "value": "B"}
        ],
        "rules": ["TEST_R1"]
    }',
    @ExpectedValue = 'AB',
    @RuleCode = 'TEST_R1';

-- T05: JSONIFY ignore NULL
DELETE FROM dbo.RuleDefinitions WHERE RuleCode = 'TEST_R1';
INSERT INTO dbo.RuleDefinitions (RuleCode, Expression) VALUES ('TEST_R1', '{JSONIFY(k*)}');

EXEC dbo.sp_RunTest 
    @TestId = 'T05',
    @TestName = 'JSONIFY ignore NULL',
    @InputJson = N'{
        "variables": [
            {"key": "k1", "value": "10"},
            {"key": "k2", "value": null},
            {"key": "k3", "value": "30"}
        ],
        "rules": ["TEST_R1"]
    }',
    @ExpectedValue = '{"k1":10,"k3":30}',
    @RuleCode = 'TEST_R1';

PRINT '';

-- =========================================================================
-- CATEGORIE 2: AGREGATS - ENSEMBLES VIDES
-- =========================================================================
PRINT '=== CATEGORIE 2: ENSEMBLES VIDES ===';
PRINT '';

-- T06: CONCAT ensemble vide → ""
DELETE FROM dbo.RuleDefinitions WHERE RuleCode = 'TEST_R1';
INSERT INTO dbo.RuleDefinitions (RuleCode, Expression) VALUES ('TEST_R1', '{CONCAT(x*)}');

EXEC dbo.sp_RunTest 
    @TestId = 'T06',
    @TestName = 'CONCAT ensemble vide',
    @InputJson = N'{
        "variables": [
            {"key": "v1", "value": "A"}
        ],
        "rules": ["TEST_R1"]
    }',
    @ExpectedValue = '',
    @RuleCode = 'TEST_R1';

-- T07: JSONIFY ensemble vide → "{}"
DELETE FROM dbo.RuleDefinitions WHERE RuleCode = 'TEST_R1';
INSERT INTO dbo.RuleDefinitions (RuleCode, Expression) VALUES ('TEST_R1', '{JSONIFY(x*)}');

EXEC dbo.sp_RunTest 
    @TestId = 'T07',
    @TestName = 'JSONIFY ensemble vide',
    @InputJson = N'{
        "variables": [
            {"key": "v1", "value": "A"}
        ],
        "rules": ["TEST_R1"]
    }',
    @ExpectedValue = '{}',
    @RuleCode = 'TEST_R1';

-- T08: SUM ensemble vide → NULL
DELETE FROM dbo.RuleDefinitions WHERE RuleCode = 'TEST_R1';
INSERT INTO dbo.RuleDefinitions (RuleCode, Expression) VALUES ('TEST_R1', '{SUM(x*)}');

EXEC dbo.sp_RunTest 
    @TestId = 'T08',
    @TestName = 'SUM ensemble vide',
    @InputJson = N'{
        "variables": [
            {"key": "v1", "value": "10"}
        ],
        "rules": ["TEST_R1"]
    }',
    @ExpectedValue = NULL,
    @RuleCode = 'TEST_R1';

PRINT '';

-- =========================================================================
-- CATEGORIE 3: NORMALISATION LITTERAUX
-- =========================================================================
PRINT '=== CATEGORIE 3: NORMALISATION LITTERAUX ===';
PRINT '';

-- T09: Decimaux français (2,5 → 2.5)
DELETE FROM dbo.RuleDefinitions WHERE RuleCode = 'TEST_R1';
INSERT INTO dbo.RuleDefinitions (RuleCode, Expression) VALUES ('TEST_R1', '2,5 + 3,5');

EXEC dbo.sp_RunTest 
    @TestId = 'T09',
    @TestName = 'Decimaux francais',
    @InputJson = N'{
        "variables": [],
        "rules": ["TEST_R1"]
    }',
    @ExpectedValue = '6',
    @RuleCode = 'TEST_R1';

-- T10: Quotes normalisees
DELETE FROM dbo.RuleDefinitions WHERE RuleCode = 'TEST_R1';
INSERT INTO dbo.RuleDefinitions (RuleCode, Expression) VALUES ('TEST_R1', '"Hello"');

EXEC dbo.sp_RunTest 
    @TestId = 'T10',
    @TestName = 'Quotes normalisees',
    @InputJson = N'{
        "variables": [],
        "rules": ["TEST_R1"]
    }',
    @ExpectedValue = 'Hello',
    @RuleCode = 'TEST_R1';

-- T11: Resultats numeriques normalises
DELETE FROM dbo.RuleDefinitions WHERE RuleCode = 'TEST_R1';
INSERT INTO dbo.RuleDefinitions (RuleCode, Expression) VALUES ('TEST_R1', '100.00 + 50.00');

EXEC dbo.sp_RunTest 
    @TestId = 'T11',
    @TestName = 'Normalisation resultats',
    @InputJson = N'{
        "variables": [],
        "rules": ["TEST_R1"]
    }',
    @ExpectedValue = '150',
    @RuleCode = 'TEST_R1';

PRINT '';

-- =========================================================================
-- CATEGORIE 4: LAST (NOUVEAU)
-- =========================================================================
PRINT '=== CATEGORIE 4: AGREGAT LAST ===';
PRINT '';

-- T12: LAST basique
DELETE FROM dbo.RuleDefinitions WHERE RuleCode = 'TEST_R1';
INSERT INTO dbo.RuleDefinitions (RuleCode, Expression) VALUES ('TEST_R1', '{LAST(v*)}');

EXEC dbo.sp_RunTest 
    @TestId = 'T12',
    @TestName = 'LAST basique',
    @InputJson = N'{
        "variables": [
            {"key": "v1", "value": "5"},
            {"key": "v2", "value": "10"},
            {"key": "v3", "value": "20"}
        ],
        "rules": ["TEST_R1"]
    }',
    @ExpectedValue = '20',
    @RuleCode = 'TEST_R1';

-- T13: LAST avec NULL intercales
DELETE FROM dbo.RuleDefinitions WHERE RuleCode = 'TEST_R1';
INSERT INTO dbo.RuleDefinitions (RuleCode, Expression) VALUES ('TEST_R1', '{LAST(v*)}');

EXEC dbo.sp_RunTest 
    @TestId = 'T13',
    @TestName = 'LAST avec NULL intercales',
    @InputJson = N'{
        "variables": [
            {"key": "v1", "value": "5"},
            {"key": "v2", "value": "10"},
            {"key": "v3", "value": null},
            {"key": "v4", "value": null}
        ],
        "rules": ["TEST_R1"]
    }',
    @ExpectedValue = '10',
    @RuleCode = 'TEST_R1';

-- T14: LAST ensemble vide
DELETE FROM dbo.RuleDefinitions WHERE RuleCode = 'TEST_R1';
INSERT INTO dbo.RuleDefinitions (RuleCode, Expression) VALUES ('TEST_R1', '{LAST(x*)}');

EXEC dbo.sp_RunTest 
    @TestId = 'T14',
    @TestName = 'LAST ensemble vide',
    @InputJson = N'{
        "variables": [
            {"key": "v1", "value": "A"}
        ],
        "rules": ["TEST_R1"]
    }',
    @ExpectedValue = NULL,
    @RuleCode = 'TEST_R1';

PRINT '';

-- =========================================================================
-- CATEGORIE 5: GESTION ERREURS
-- =========================================================================
PRINT '=== CATEGORIE 5: GESTION ERREURS ===';
PRINT '';

-- T15: Erreur n'interrompt pas thread
DELETE FROM dbo.RuleDefinitions WHERE RuleCode IN ('TEST_R1', 'TEST_R2');
INSERT INTO dbo.RuleDefinitions (RuleCode, Expression) VALUES 
    ('TEST_R1', '1/0'),  -- Erreur
    ('TEST_R2', '100');  -- Doit s'executer

DECLARE @Out NVARCHAR(MAX);
EXEC dbo.sp_RunRulesEngine N'{
    "variables": [],
    "rules": ["TEST_R1", "TEST_R2"]
}', @Out OUTPUT;

-- Verifier que R2 est evaluee malgre erreur R1
DECLARE @R2Value NVARCHAR(MAX) = JSON_VALUE(@Out, '$.results[1].value');
PRINT '  [' + CASE WHEN @R2Value = '100' THEN 'PASS' ELSE 'FAIL' END + '] T15: Erreur n''interrompt pas thread';
IF @R2Value <> '100'
    PRINT '       Expected: 100 | Actual: ' + ISNULL(@R2Value, 'NULL');

-- T16: Agregat ignore regles en erreur
DELETE FROM dbo.RuleDefinitions WHERE RuleCode IN ('TEST_R1', 'TEST_R2', 'TEST_R3', 'TEST_R4');
INSERT INTO dbo.RuleDefinitions (RuleCode, Expression) VALUES 
    ('TEST_R1', '10'),
    ('TEST_R2', '1/0'),  -- Erreur → NULL
    ('TEST_R3', '20'),
    ('TEST_R4', '{SUM(Rule:TEST_R*)}');  -- Doit sommer 10+20=30, ignorer R2

EXEC dbo.sp_RunTest 
    @TestId = 'T16',
    @TestName = 'Agregat ignore regles en erreur',
    @InputJson = N'{
        "variables": [],
        "rules": ["TEST_R1", "TEST_R2", "TEST_R3", "TEST_R4"]
    }',
    @ExpectedValue = '30',
    @RuleCode = 'TEST_R4';

-- T17: Propagation NULL
DELETE FROM dbo.RuleDefinitions WHERE RuleCode IN ('TEST_R1', 'TEST_R2');
INSERT INTO dbo.RuleDefinitions (RuleCode, Expression) VALUES 
    ('TEST_R1', '1/0'),  -- Erreur → NULL
    ('TEST_R2', '{TEST_R1} + 10');  -- NULL + 10 = NULL

EXEC dbo.sp_RunTest 
    @TestId = 'T17',
    @TestName = 'Propagation NULL',
    @InputJson = N'{
        "variables": [],
        "rules": ["TEST_R1", "TEST_R2"]
    }',
    @ExpectedValue = NULL,
    @RuleCode = 'TEST_R2';

PRINT '';

-- =========================================================================
-- CATEGORIE 6: REGRESSION
-- =========================================================================
PRINT '=== CATEGORIE 6: TESTS DE REGRESSION ===';
PRINT '';

-- T18: Variables simples
DELETE FROM dbo.RuleDefinitions WHERE RuleCode = 'TEST_R1';
INSERT INTO dbo.RuleDefinitions (RuleCode, Expression) VALUES ('TEST_R1', '{x} + {y}');

EXEC dbo.sp_RunTest 
    @TestId = 'T18',
    @TestName = 'Variables simples',
    @InputJson = N'{
        "variables": [
            {"key": "x", "value": "10"},
            {"key": "y", "value": "5"}
        ],
        "rules": ["TEST_R1"]
    }',
    @ExpectedValue = '15',
    @RuleCode = 'TEST_R1';

-- T19: Regles sans tokens
DELETE FROM dbo.RuleDefinitions WHERE RuleCode = 'TEST_R1';
INSERT INTO dbo.RuleDefinitions (RuleCode, Expression) VALUES ('TEST_R1', '100 + 50');

EXEC dbo.sp_RunTest 
    @TestId = 'T19',
    @TestName = 'Regles sans tokens',
    @InputJson = N'{
        "variables": [],
        "rules": ["TEST_R1"]
    }',
    @ExpectedValue = '150',
    @RuleCode = 'TEST_R1';

-- T20: JSONIFY format correct
DELETE FROM dbo.RuleDefinitions WHERE RuleCode = 'TEST_R1';
INSERT INTO dbo.RuleDefinitions (RuleCode, Expression) VALUES ('TEST_R1', '{JSONIFY(k*)}');

EXEC dbo.sp_RunTest 
    @TestId = 'T20',
    @TestName = 'JSONIFY format JSON valide',
    @InputJson = N'{
        "variables": [
            {"key": "k1", "value": "10"},
            {"key": "k2", "value": "abc"},
            {"key": "k3", "value": "true"}
        ],
        "rules": ["TEST_R1"]
    }',
    @ExpectedValue = '{"k1":10,"k2":"abc","k3":true}',
    @RuleCode = 'TEST_R1';

PRINT '';

-- =========================================================================
-- RAPPORT FINAL
-- =========================================================================
PRINT '======================================================================';
PRINT '                        RAPPORT FINAL                                ';
PRINT '======================================================================';
PRINT '';
PRINT 'Suite de tests conformite v1.6.0 terminee';
PRINT '';
PRINT 'RESULTATS:';
PRINT '  - Tous les tests doivent passer (PASS)';
PRINT '  - Verifier manuellement les sorties ci-dessus';
PRINT '  - Si des tests echouent (FAIL/ERROR), investiguer';
PRINT '';
PRINT 'CONFORMITE V1.6.0:';
PRINT '  ✓ Principe fondamental: agregats ignorent NULL';
PRINT '  ✓ FIRST/LAST: valeurs NON NULL uniquement';
PRINT '  ✓ CONCAT/JSONIFY: comportement ensemble vide';
PRINT '  ✓ Normalisation litteraux (decimaux francais, quotes)';
PRINT '  ✓ Gestion erreurs: isolation et propagation NULL';
PRINT '';
PRINT '======================================================================';
GO

-- Nettoyer regles de test
DELETE FROM dbo.RuleDefinitions WHERE RuleCode LIKE 'TEST_%';
GO
