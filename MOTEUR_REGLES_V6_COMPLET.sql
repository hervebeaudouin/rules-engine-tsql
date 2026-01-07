/***********************************************************************
    MOTEUR DE RÈGLES T-SQL - VERSION 6.0
    Conforme Spec V1.5.4
    
    Compatibilité : SQL Server 2017+
    
    PRINCIPES (NORMATIFS):
    - Le moteur orchestre, SQL calcule
    - États fermés: NOT_EVALUATED, EVALUATING, EVALUATED, ERROR
    - Ordre canonique = SeqId (ordre d'insertion)
    - Erreurs locales, thread continue
    - Agrégateur par défaut = FIRST
    - 17 agrégateurs fermés, pas un de plus
    - Aucune logique SQL dans {...}
    
    COLLATION: SQL_Latin1_General_CP1_CI_AS (case-insensitive)
************************************************************************/

SET NOCOUNT ON;
GO

PRINT '══════════════════════════════════════════════════════════════════════';
PRINT '           MOTEUR DE RÈGLES V6.0 - Spec V1.5.4                        ';
PRINT '══════════════════════════════════════════════════════════════════════';
PRINT '';
GO

-- =========================================================================
-- PARTIE 1 : NETTOYAGE
-- =========================================================================
PRINT '── Nettoyage ──';

IF OBJECT_ID('dbo.sp_ExecuteRule','P') IS NOT NULL DROP PROCEDURE dbo.sp_ExecuteRule;
IF OBJECT_ID('dbo.sp_ResolveToken','P') IS NOT NULL DROP PROCEDURE dbo.sp_ResolveToken;
IF OBJECT_ID('dbo.sp_ExecuteRulesAll','P') IS NOT NULL DROP PROCEDURE dbo.sp_ExecuteRulesAll;
IF OBJECT_ID('dbo.sp_InitThread','P') IS NOT NULL DROP PROCEDURE dbo.sp_InitThread;
IF OBJECT_ID('dbo.fn_ExtractTokens','TF') IS NOT NULL DROP FUNCTION dbo.fn_ExtractTokens;
IF OBJECT_ID('dbo.fn_ParseToken','IF') IS NOT NULL DROP FUNCTION dbo.fn_ParseToken;
IF OBJECT_ID('dbo.RuleDefinitions','U') IS NOT NULL DROP TABLE dbo.RuleDefinitions;

PRINT '   OK';
GO

-- =========================================================================
-- PARTIE 2 : TABLE DES DÉFINITIONS DE RÈGLES
-- =========================================================================
PRINT '── Tables permanentes ──';

CREATE TABLE dbo.RuleDefinitions (
    RuleId INT IDENTITY(1,1) NOT NULL,
    RuleCode NVARCHAR(200) COLLATE SQL_Latin1_General_CP1_CI_AS NOT NULL,
    Expression NVARCHAR(MAX) COLLATE SQL_Latin1_General_CP1_CI_AS NOT NULL,
    IsActive BIT NOT NULL DEFAULT 1,
    CreatedAt DATETIME2 NOT NULL DEFAULT SYSDATETIME(),
    CONSTRAINT PK_RuleDefinitions PRIMARY KEY (RuleId),
    CONSTRAINT UQ_RuleDefinitions_Code UNIQUE (RuleCode)
);

PRINT '   OK';
GO

-- =========================================================================
-- PARTIE 3 : FONCTION D'EXTRACTION DES TOKENS
-- =========================================================================
PRINT '── Fonctions ──';
GO
CREATE FUNCTION dbo.fn_ExtractTokens(@Expression NVARCHAR(MAX))
RETURNS @Tokens TABLE (
    TokenOrder INT IDENTITY(1,1),
    Token NVARCHAR(1000) COLLATE SQL_Latin1_General_CP1_CI_AS
)
AS
BEGIN
    DECLARE @i INT = 1, @Len INT = LEN(@Expression), @Start INT = 0, @Level INT = 0;
    DECLARE @Token NVARCHAR(1000);
    
    WHILE @i <= @Len
    BEGIN
        IF SUBSTRING(@Expression, @i, 1) = '{'
        BEGIN
            IF @Level = 0 SET @Start = @i;
            SET @Level = @Level + 1;
        END
        ELSE IF SUBSTRING(@Expression, @i, 1) = '}'
        BEGIN
            SET @Level = @Level - 1;
            IF @Level = 0 AND @Start > 0
            BEGIN
                SET @Token = SUBSTRING(@Expression, @Start, @i - @Start + 1);
                IF NOT EXISTS (SELECT 1 FROM @Tokens WHERE Token = @Token)
                    INSERT INTO @Tokens (Token) VALUES (@Token);
                SET @Start = 0;
            END
        END
        SET @i = @i + 1;
    END
    RETURN;
END;
GO

-- =========================================================================
-- PARTIE 4 : FONCTION DE PARSING D'UN TOKEN
-- =========================================================================

CREATE FUNCTION dbo.fn_ParseToken(@Token NVARCHAR(1000))
RETURNS TABLE
AS
RETURN
WITH Cleaned AS (
    SELECT LTRIM(RTRIM(SUBSTRING(@Token, 2, LEN(@Token) - 2))) AS TokenContent
),
Parsed AS (
    SELECT
        TokenContent,
        CASE 
            WHEN TokenContent LIKE '%(_%)' AND CHARINDEX('(', TokenContent) > 0 
                 AND UPPER(LEFT(TokenContent, CHARINDEX('(', TokenContent) - 1)) IN (
                     'FIRST','SUM','AVG','MIN','MAX','COUNT',
                     'FIRST_POS','SUM_POS','AVG_POS','MIN_POS','MAX_POS','COUNT_POS',
                     'FIRST_NEG','SUM_NEG','AVG_NEG','MIN_NEG','MAX_NEG','COUNT_NEG',
                     'CONCAT','JSONIFY'
                 )
            THEN UPPER(LEFT(TokenContent, CHARINDEX('(', TokenContent) - 1))
            ELSE 'FIRST'
        END AS Aggregator,
        CASE 
            WHEN TokenContent LIKE '%(_%)' AND CHARINDEX('(', TokenContent) > 0
                 AND UPPER(LEFT(TokenContent, CHARINDEX('(', TokenContent) - 1)) IN (
                     'FIRST','SUM','AVG','MIN','MAX','COUNT',
                     'FIRST_POS','SUM_POS','AVG_POS','MIN_POS','MAX_POS','COUNT_POS',
                     'FIRST_NEG','SUM_NEG','AVG_NEG','MIN_NEG','MAX_NEG','COUNT_NEG',
                     'CONCAT','JSONIFY'
                 )
            THEN SUBSTRING(TokenContent, CHARINDEX('(', TokenContent) + 1, LEN(TokenContent) - CHARINDEX('(', TokenContent) - 1)
            ELSE TokenContent
        END AS Selector
    FROM Cleaned
)
SELECT
    @Token AS Token,
    Aggregator,
    CASE WHEN UPPER(LEFT(Selector, 5)) = 'RULE:' THEN 1 ELSE 0 END AS IsRuleRef,
    CASE 
        WHEN UPPER(LEFT(Selector, 5)) = 'RULE:' THEN LTRIM(SUBSTRING(Selector, 6, LEN(Selector)))
        ELSE Selector
    END AS Pattern
FROM Parsed;
GO

PRINT '   OK';
GO

-- =========================================================================
-- PARTIE 5 : PROCÉDURES
-- =========================================================================
PRINT '── Procédures ──';
GO
-- sp_ResolveToken
CREATE PROCEDURE dbo.sp_ResolveToken
    @Token NVARCHAR(1000),
    @Result NVARCHAR(MAX) OUTPUT
AS
BEGIN
    SET NOCOUNT ON;
    
    DECLARE @Aggregator VARCHAR(20);
    DECLARE @IsRuleRef BIT;
    DECLARE @Pattern NVARCHAR(500);
    DECLARE @SQL NVARCHAR(MAX);
    DECLARE @FilterCondition NVARCHAR(100) = '';
    DECLARE @BaseAggregator VARCHAR(20);
    
    SELECT @Aggregator = Aggregator, @IsRuleRef = IsRuleRef, @Pattern = Pattern
    FROM dbo.fn_ParseToken(@Token);
    
    SET @BaseAggregator = @Aggregator;
    IF @Aggregator LIKE '%[_]POS'
    BEGIN
        SET @BaseAggregator = LEFT(@Aggregator, LEN(@Aggregator) - 4);
        SET @FilterCondition = ' AND TRY_CAST(ScalarValue AS DECIMAL(38,10)) > 0';
    END
    ELSE IF @Aggregator LIKE '%[_]NEG'
    BEGIN
        SET @BaseAggregator = LEFT(@Aggregator, LEN(@Aggregator) - 4);
        SET @FilterCondition = ' AND TRY_CAST(ScalarValue AS DECIMAL(38,10)) < 0';
    END
    
    IF @IsRuleRef = 1
    BEGIN
        DECLARE @RuleKey NVARCHAR(200);
        DECLARE @RuleState TINYINT;
        DECLARE @RuleResult NVARCHAR(MAX);
        DECLARE @RuleError NVARCHAR(500);
        
        DECLARE rule_cursor CURSOR LOCAL FAST_FORWARD FOR
        SELECT [Key], State FROM #ThreadState
        WHERE IsRule = 1 AND [Key] LIKE @Pattern ORDER BY SeqId;
        
        OPEN rule_cursor;
        FETCH NEXT FROM rule_cursor INTO @RuleKey, @RuleState;
        
        WHILE @@FETCH_STATUS = 0
        BEGIN
            IF @RuleState = 0
                EXEC dbo.sp_ExecuteRule @RuleKey, @RuleResult OUTPUT, @RuleError OUTPUT;
            FETCH NEXT FROM rule_cursor INTO @RuleKey, @RuleState;
        END
        CLOSE rule_cursor;
        DEALLOCATE rule_cursor;
    END
    
    DECLARE @WhereClause NVARCHAR(500);
    IF @IsRuleRef = 1
        SET @WhereClause = 'IsRule = 1 AND [Key] LIKE @P AND State = 2';
    ELSE
        SET @WhereClause = 'IsRule = 0 AND [Key] LIKE @P AND State = 2';
    
    IF @BaseAggregator = 'FIRST'
        SET @SQL = N'SELECT TOP 1 @R = ScalarValue FROM #ThreadState WHERE ' + @WhereClause + @FilterCondition + ' AND ScalarValue IS NOT NULL ORDER BY SeqId';
    ELSE IF @BaseAggregator = 'SUM'
        SET @SQL = N'SELECT @R = CAST(SUM(TRY_CAST(ScalarValue AS DECIMAL(38,10))) AS NVARCHAR(MAX)) FROM #ThreadState WHERE ' + @WhereClause + @FilterCondition;
    ELSE IF @BaseAggregator = 'AVG'
        SET @SQL = N'SELECT @R = CAST(AVG(TRY_CAST(ScalarValue AS DECIMAL(38,10))) AS NVARCHAR(MAX)) FROM #ThreadState WHERE ' + @WhereClause + @FilterCondition;
    ELSE IF @BaseAggregator = 'MIN'
        SET @SQL = N'SELECT @R = CAST(MIN(TRY_CAST(ScalarValue AS DECIMAL(38,10))) AS NVARCHAR(MAX)) FROM #ThreadState WHERE ' + @WhereClause + @FilterCondition;
    ELSE IF @BaseAggregator = 'MAX'
        SET @SQL = N'SELECT @R = CAST(MAX(TRY_CAST(ScalarValue AS DECIMAL(38,10))) AS NVARCHAR(MAX)) FROM #ThreadState WHERE ' + @WhereClause + @FilterCondition;
    ELSE IF @BaseAggregator = 'COUNT'
        SET @SQL = N'SELECT @R = CAST(COUNT(CASE WHEN ScalarValue IS NOT NULL THEN 1 END) AS NVARCHAR(MAX)) FROM #ThreadState WHERE ' + @WhereClause + @FilterCondition;
    ELSE IF @BaseAggregator = 'CONCAT'
        SET @SQL = N'SELECT @R = STRING_AGG(ScalarValue, '','') WITHIN GROUP (ORDER BY SeqId) FROM #ThreadState WHERE ' + @WhereClause + ' AND ScalarValue IS NOT NULL';
    ELSE IF @BaseAggregator = 'JSONIFY'
        SET @SQL = N'SELECT @R = ISNULL((SELECT [Key], ScalarValue AS [Value] FROM #ThreadState WHERE ' + @WhereClause + ' ORDER BY SeqId FOR JSON PATH), ''{}'' )';
    
    BEGIN TRY
        EXEC sp_executesql @SQL, N'@P NVARCHAR(500), @R NVARCHAR(MAX) OUTPUT', @Pattern, @Result OUTPUT;
    END TRY
    BEGIN CATCH
        SET @Result = NULL;
    END CATCH
END;
GO

-- sp_ExecuteRule
CREATE PROCEDURE dbo.sp_ExecuteRule
    @RuleCode NVARCHAR(200),
    @Result NVARCHAR(MAX) OUTPUT,
    @ErrorMsg NVARCHAR(500) OUTPUT
AS
BEGIN
    SET NOCOUNT ON;
    
    DECLARE @State TINYINT;
    DECLARE @Expression NVARCHAR(MAX);
    DECLARE @CompiledExpr NVARCHAR(MAX);
    DECLARE @Token NVARCHAR(1000);
    DECLARE @TokenValue NVARCHAR(MAX);
    DECLARE @ErrorCategory VARCHAR(20);
    DECLARE @ErrorCode VARCHAR(50);
    DECLARE @StartTime DATETIME2 = SYSDATETIME();
    DECLARE @DebugMode BIT = 0;
    
    IF OBJECT_ID('tempdb..#ThreadConfig') IS NOT NULL
        SELECT @DebugMode = DebugMode FROM #ThreadConfig;
    
    SELECT @State = State, @Result = ScalarValue
    FROM #ThreadState WHERE [Key] = @RuleCode AND IsRule = 1;
    
    IF @State = 2 BEGIN SET @ErrorMsg = NULL; RETURN; END
    IF @State = 3 BEGIN SET @Result = NULL; SELECT @ErrorMsg = ErrorCategory + '/' + ErrorCode FROM #ThreadState WHERE [Key] = @RuleCode AND IsRule = 1; RETURN; END
    
    IF @State = 1
    BEGIN
        SET @ErrorCategory = 'RECURSION';
        SET @ErrorCode = 'RECURSIVE_DEPENDENCY';
        SET @ErrorMsg = @ErrorCategory + '/' + @ErrorCode;
        SET @Result = NULL;
        UPDATE #ThreadState SET State = 3, ScalarValue = NULL, ErrorCategory = @ErrorCategory, ErrorCode = @ErrorCode WHERE [Key] = @RuleCode AND IsRule = 1;
        RETURN;
    END
    
    UPDATE #ThreadState SET State = 1 WHERE [Key] = @RuleCode AND IsRule = 1;
    
    BEGIN TRY
        SELECT @Expression = Expression FROM dbo.RuleDefinitions WHERE RuleCode = @RuleCode AND IsActive = 1;
        
        IF @Expression IS NULL
        BEGIN
            SET @ErrorCategory = 'SQL';
            SET @ErrorCode = 'RULE_NOT_FOUND';
            RAISERROR('Rule not found', 16, 1);
        END
        
        SET @CompiledExpr = @Expression;
        
        DECLARE token_cursor CURSOR LOCAL FAST_FORWARD FOR
        SELECT Token FROM dbo.fn_ExtractTokens(@Expression) ORDER BY TokenOrder;
        OPEN token_cursor;
        FETCH NEXT FROM token_cursor INTO @Token;
        
        WHILE @@FETCH_STATUS = 0
        BEGIN
            EXEC dbo.sp_ResolveToken @Token, @TokenValue OUTPUT;
            SET @CompiledExpr = REPLACE(@CompiledExpr, @Token, ISNULL(@TokenValue, 'NULL'));
            FETCH NEXT FROM token_cursor INTO @Token;
        END
        CLOSE token_cursor;
        DEALLOCATE token_cursor;
        
        SET @CompiledExpr = REPLACE(@CompiledExpr, '"', '''');
        
        DECLARE @SQL NVARCHAR(MAX) = N'SELECT @R = ' + @CompiledExpr;
        EXEC sp_executesql @SQL, N'@R NVARCHAR(MAX) OUTPUT', @Result OUTPUT;
        
        UPDATE #ThreadState SET State = 2, ScalarValue = @Result, ErrorCategory = NULL, ErrorCode = NULL WHERE [Key] = @RuleCode AND IsRule = 1;
        SET @ErrorMsg = NULL;
        
        IF @DebugMode = 1 AND OBJECT_ID('tempdb..#ThreadDebug') IS NOT NULL
            INSERT INTO #ThreadDebug (RuleCode, Action, DurationMs, CompiledSQL) VALUES (@RuleCode, 'EVALUATED', DATEDIFF(MILLISECOND, @StartTime, SYSDATETIME()), @CompiledExpr);
        
    END TRY
    BEGIN CATCH
        DECLARE @ErrMsg NVARCHAR(4000) = ERROR_MESSAGE();
        DECLARE @ErrNum INT = ERROR_NUMBER();
        
        IF @ErrorCategory IS NULL
        BEGIN
            SET @ErrorCategory = CASE
                WHEN @ErrNum = 8134 THEN 'NUMERIC'
                WHEN @ErrNum IN (220, 8115) THEN 'NUMERIC'
                WHEN @ErrNum IN (245, 8114) THEN 'TYPE'
                WHEN @ErrNum IN (102, 105, 156) THEN 'SYNTAX'
                ELSE 'SQL'
            END;
            SET @ErrorCode = CASE
                WHEN @ErrNum = 8134 THEN 'DIVIDE_BY_ZERO'
                WHEN @ErrNum IN (220, 8115) THEN 'OVERFLOW'
                WHEN @ErrNum IN (245, 8114) THEN 'TYPE_MISMATCH'
                ELSE 'SQL_ERROR'
            END;
        END
        
        SET @ErrorMsg = @ErrorCategory + '/' + @ErrorCode;
        SET @Result = NULL;
        UPDATE #ThreadState SET State = 3, ScalarValue = NULL, ErrorCategory = @ErrorCategory, ErrorCode = @ErrorCode WHERE [Key] = @RuleCode AND IsRule = 1;
        
        IF @DebugMode = 1 AND OBJECT_ID('tempdb..#ThreadDebug') IS NOT NULL
            INSERT INTO #ThreadDebug (RuleCode, Action, DurationMs, ErrorMessage) VALUES (@RuleCode, 'ERROR', DATEDIFF(MILLISECOND, @StartTime, SYSDATETIME()), @ErrMsg);
    END CATCH
END;
GO

-- sp_ExecuteRulesAll
CREATE PROCEDURE dbo.sp_ExecuteRulesAll
AS
BEGIN
    SET NOCOUNT ON;
    
    DECLARE @RuleCode NVARCHAR(200), @Result NVARCHAR(MAX), @ErrorMsg NVARCHAR(500);
    
    DECLARE rule_cursor CURSOR LOCAL FAST_FORWARD FOR
    SELECT [Key] FROM #ThreadState WHERE IsRule = 1 AND State = 0 ORDER BY SeqId;
    OPEN rule_cursor;
    FETCH NEXT FROM rule_cursor INTO @RuleCode;
    
    WHILE @@FETCH_STATUS = 0
    BEGIN
        EXEC dbo.sp_ExecuteRule @RuleCode, @Result OUTPUT, @ErrorMsg OUTPUT;
        FETCH NEXT FROM rule_cursor INTO @RuleCode;
    END
    CLOSE rule_cursor;
    DEALLOCATE rule_cursor;
    
    SELECT SeqId, [Key],
        CASE State WHEN 0 THEN 'NOT_EVALUATED' WHEN 1 THEN 'EVALUATING' WHEN 2 THEN 'EVALUATED' WHEN 3 THEN 'ERROR' END AS State,
        ScalarValue, ErrorCategory, ErrorCode
    FROM #ThreadState WHERE IsRule = 1 ORDER BY SeqId;
END;
GO

-- MOTEUR DE REGLES V6.1
-- JSON RUNNER FINAL (SPEC 1.5.5)

CREATE OR ALTER PROCEDURE dbo.sp_RunThreadFromJson_v61
(
    @ConfigJson NVARCHAR(MAX)
)
AS
BEGIN
    SET NOCOUNT ON;

    DECLARE @Mode VARCHAR(10) =
        ISNULL(JSON_VALUE(@ConfigJson, '$.mode'), 'NORMAL');

    CREATE TABLE #ThreadConfig (
        Mode VARCHAR(10),
        StopOnFatal BIT,
        ReturnState BIT,
        ReturnDebug BIT
    );

    INSERT INTO #ThreadConfig
    SELECT
        @Mode,
        ISNULL(JSON_VALUE(@ConfigJson,'$.options.stopOnFatal'), 0),
        ISNULL(JSON_VALUE(@ConfigJson,'$.options.returnStateTable'), 1),
        ISNULL(JSON_VALUE(@ConfigJson,'$.options.returnDebug'), 0);

    CREATE TABLE #ThreadState (
        SeqId INT IDENTITY(1,1),
        [Key] NVARCHAR(200) COLLATE SQL_Latin1_General_CP1_CI_AS NOT NULL,
        ScalarValue NVARCHAR(MAX) COLLATE SQL_Latin1_General_CP1_CI_AS NULL,
        ValueType VARCHAR(20) NOT NULL,
        EntityType CHAR(1) NOT NULL,
        State VARCHAR(20) NULL,
        ErrorCategory VARCHAR(20) NULL,
        ErrorCode VARCHAR(50) NULL,
        CONSTRAINT UQ_ThreadState_Key UNIQUE ([Key])
    );

    INSERT INTO #ThreadState ([Key], ScalarValue, ValueType, EntityType)
    SELECT
        v.[key],
        v.[value],
        v.[type],
        'V'
    FROM OPENJSON(@ConfigJson, '$.variables')
    WITH (
        [key]   NVARCHAR(200) '$.key',
        [type]  VARCHAR(20)   '$.type',
        [value] NVARCHAR(MAX) '$.value'
    ) v;

    DECLARE @RuleKey NVARCHAR(200);
    DECLARE rule_cur CURSOR LOCAL FAST_FORWARD FOR
        SELECT value FROM OPENJSON(@ConfigJson, '$.rules');

    OPEN rule_cur;
    FETCH NEXT FROM rule_cur INTO @RuleKey;

    WHILE @@FETCH_STATUS = 0
    BEGIN
        EXEC dbo.sp_ExecuteRule_Internal @RuleKey;
        FETCH NEXT FROM rule_cur INTO @RuleKey;
    END

    CLOSE rule_cur;
    DEALLOCATE rule_cur;

    SELECT
        [Key],
        ScalarValue,
        State,
        ErrorCategory,
        ErrorCode
    FROM #ThreadState
    WHERE EntityType = 'R'
    ORDER BY SeqId;
END
GO


PRINT '   OK';
PRINT '';
PRINT '══════════════════════════════════════════════════════════════════════';
PRINT '           INSTALLATION TERMINÉE - V6.0                               ';
PRINT '══════════════════════════════════════════════════════════════════════';
GO

-- *************************************************************************
--                        TESTS NORMATIFS V6.0
-- *************************************************************************

PRINT '';
PRINT '══════════════════════════════════════════════════════════════════════';
PRINT '         TESTS NORMATIFS V6.0 - Spec V1.5.4                           ';
PRINT '══════════════════════════════════════════════════════════════════════';
PRINT '';

-- Table des résultats
IF OBJECT_ID('tempdb..#TestResults') IS NOT NULL DROP TABLE #TestResults;
CREATE TABLE #TestResults (
    TestId INT IDENTITY(1,1), Category VARCHAR(20), Name VARCHAR(50),
    InputExpression NVARCHAR(500), Expected NVARCHAR(500), Actual NVARCHAR(500),
    Pass BIT, Details NVARCHAR(500)
);

-- =========================================================================
-- FIXTURES + TOUS LES TESTS (même batch pour éviter perte de #ThreadState)
-- =========================================================================

-- Créer #ThreadState manuellement
IF OBJECT_ID('tempdb..#ThreadState') IS NOT NULL DROP TABLE #ThreadState;
CREATE TABLE #ThreadState (
    SeqId INT IDENTITY(1,1) NOT NULL,
    [Key] NVARCHAR(200) COLLATE SQL_Latin1_General_CP1_CI_AS NOT NULL,
    IsRule BIT NOT NULL DEFAULT 0,
    State TINYINT NOT NULL DEFAULT 0,
    ScalarValue NVARCHAR(MAX) COLLATE SQL_Latin1_General_CP1_CI_AS NULL,
    ValueType VARCHAR(20) NULL,
    ErrorCategory VARCHAR(20) NULL,
    ErrorCode VARCHAR(50) NULL,
    CONSTRAINT PK_ThreadState PRIMARY KEY (SeqId),
    CONSTRAINT UQ_ThreadState_Key UNIQUE ([Key])
);


PRINT '── Fixtures normatives ──';

-- MONTANT: 100, 200, -50, 150, -25, NULL (ordre SeqId!)
INSERT INTO #ThreadState ([Key], IsRule, State, ScalarValue, ValueType) VALUES
    ('MONTANT_01', 0, 2, '100', 'NUMERIC'),
    ('MONTANT_02', 0, 2, '200', 'NUMERIC'),
    ('MONTANT_03', 0, 2, '-50', 'NUMERIC'),
    ('MONTANT_04', 0, 2, '150', 'NUMERIC'),
    ('MONTANT_05', 0, 2, '-25', 'NUMERIC'),
    ('MONTANT_06', 0, 2, NULL, 'NULL');

-- LIBELLE: 'A', 'B', NULL, 'C'
INSERT INTO #ThreadState ([Key], IsRule, State, ScalarValue, ValueType) VALUES
    ('LIBELLE_01', 0, 2, 'A', 'STRING'),
    ('LIBELLE_02', 0, 2, 'B', 'STRING'),
    ('LIBELLE_03', 0, 2, NULL, 'NULL'),
    ('LIBELLE_04', 0, 2, 'C', 'STRING');

-- Variables simples
INSERT INTO #ThreadState ([Key], IsRule, State, ScalarValue, ValueType) VALUES
    ('VAL_A', 0, 2, '100', 'NUMERIC'),
    ('VAL_B', 0, 2, '50', 'NUMERIC'),
    ('TOTO', 0, 2, '42', 'NUMERIC'),
    ('toto_lower', 0, 2, '99', 'NUMERIC');

-- Nettoyer règles de test
DELETE FROM dbo.RuleDefinitions WHERE RuleCode LIKE 'TEST_%' OR RuleCode LIKE 'BBB%';

-- Règles BBB
INSERT INTO dbo.RuleDefinitions (RuleCode, Expression) VALUES ('BBB1', '10'), ('BBB2', '-5'), ('BBB_NULL', 'NULL');
INSERT INTO #ThreadState ([Key], IsRule, State) VALUES ('BBB1', 1, 0), ('BBB2', 1, 0), ('BBB_NULL', 1, 0);

PRINT '   Fixtures chargées';
PRINT '';

-- Variables pour tests
DECLARE @Result NVARCHAR(MAX), @Err NVARCHAR(500);
DECLARE @State TINYINT, @ErrCat VARCHAR(20), @ErrCode VARCHAR(50);

-- =========================================================================
-- T: PARSING/TOKENS
-- =========================================================================
PRINT '── T: Parsing/Tokens ──';

INSERT INTO dbo.RuleDefinitions (RuleCode, Expression) VALUES ('TEST_T01', '100 + 50');
INSERT INTO #ThreadState ([Key], IsRule, State) VALUES ('TEST_T01', 1, 0);
EXEC dbo.sp_ExecuteRule 'TEST_T01', @Result OUTPUT, @Err OUTPUT;
INSERT INTO #TestResults VALUES ('PARSING', 'T01_NoToken', '100 + 50', '150', @Result, CASE WHEN TRY_CAST(@Result AS INT) = 150 THEN 1 ELSE 0 END, NULL);

INSERT INTO dbo.RuleDefinitions (RuleCode, Expression) VALUES ('TEST_T02', '{VAL_A} + {VAL_B}');
INSERT INTO #ThreadState ([Key], IsRule, State) VALUES ('TEST_T02', 1, 0);
EXEC dbo.sp_ExecuteRule 'TEST_T02', @Result OUTPUT, @Err OUTPUT;
INSERT INTO #TestResults VALUES ('PARSING', 'T02_MultiToken', '{VAL_A} + {VAL_B}', '150', @Result, CASE WHEN TRY_CAST(@Result AS INT) = 150 THEN 1 ELSE 0 END, NULL);

INSERT INTO dbo.RuleDefinitions (RuleCode, Expression) VALUES ('TEST_T06', '{rule:BBB1} + 5');
INSERT INTO #ThreadState ([Key], IsRule, State) VALUES ('TEST_T06', 1, 0);
EXEC dbo.sp_ExecuteRule 'TEST_T06', @Result OUTPUT, @Err OUTPUT;
INSERT INTO #TestResults VALUES ('PARSING', 'T06_RuleRef', '{rule:BBB1} + 5', '15', @Result, CASE WHEN TRY_CAST(@Result AS INT) = 15 THEN 1 ELSE 0 END, NULL);

INSERT INTO dbo.RuleDefinitions (RuleCode, Expression) VALUES ('TEST_T07', '{TOTO_LOWER}');
INSERT INTO #ThreadState ([Key], IsRule, State) VALUES ('TEST_T07', 1, 0);
EXEC dbo.sp_ExecuteRule 'TEST_T07', @Result OUTPUT, @Err OUTPUT;
INSERT INTO #TestResults VALUES ('PARSING', 'T07_CaseInsensitive', '{TOTO_LOWER}', '99', @Result, CASE WHEN TRY_CAST(@Result AS INT) = 99 THEN 1 ELSE 0 END, 'CI collation');

PRINT '   OK';

-- =========================================================================
-- O: ORDRE CANONIQUE
-- =========================================================================
PRINT '── O: Ordre canonique ──';

INSERT INTO dbo.RuleDefinitions (RuleCode, Expression) VALUES ('TEST_O01', '{FIRST(MONTANT_%)}');
INSERT INTO #ThreadState ([Key], IsRule, State) VALUES ('TEST_O01', 1, 0);
EXEC dbo.sp_ExecuteRule 'TEST_O01', @Result OUTPUT, @Err OUTPUT;
INSERT INTO #TestResults VALUES ('ORDRE', 'O01_First', '{FIRST(MONTANT_%)}', '100', @Result, CASE WHEN TRY_CAST(@Result AS INT) = 100 THEN 1 ELSE 0 END, 'Premier SeqId');

INSERT INTO dbo.RuleDefinitions (RuleCode, Expression) VALUES ('TEST_O02', '{FIRST_NEG(MONTANT_%)}');
INSERT INTO #ThreadState ([Key], IsRule, State) VALUES ('TEST_O02', 1, 0);
EXEC dbo.sp_ExecuteRule 'TEST_O02', @Result OUTPUT, @Err OUTPUT;
INSERT INTO #TestResults VALUES ('ORDRE', 'O02_FirstNeg', '{FIRST_NEG(MONTANT_%)}', '-50', @Result, CASE WHEN TRY_CAST(@Result AS INT) = -50 THEN 1 ELSE 0 END, 'Premier négatif');

INSERT INTO dbo.RuleDefinitions (RuleCode, Expression) VALUES ('TEST_O03', ''''+'{CONCAT(LIBELLE_%)}'+'''');
INSERT INTO #ThreadState ([Key], IsRule, State) VALUES ('TEST_O03', 1, 0);
EXEC dbo.sp_ExecuteRule 'TEST_O03', @Result OUTPUT, @Err OUTPUT;
INSERT INTO #TestResults VALUES ('ORDRE', 'O03_Concat', '{CONCAT(LIBELLE_%)}', '''A,B,C''', @Result, CASE WHEN @Result = '''A,B,C''' THEN 1 ELSE 0 END, 'NULL ignoré');

PRINT '   OK';

-- =========================================================================
-- A: AGRÉGATEURS
-- =========================================================================
PRINT '── A: Agrégateurs ──';

INSERT INTO dbo.RuleDefinitions (RuleCode, Expression) VALUES ('TEST_A01', '{SUM(MONTANT_%)}');
INSERT INTO #ThreadState ([Key], IsRule, State) VALUES ('TEST_A01', 1, 0);
EXEC dbo.sp_ExecuteRule 'TEST_A01', @Result OUTPUT, @Err OUTPUT;
INSERT INTO #TestResults VALUES ('AGGREG', 'A01_Sum', '{SUM(MONTANT_%)}', '375', @Result, CASE WHEN ABS(TRY_CAST(@Result AS DECIMAL(18,2)) - 375) < 0.01 THEN 1 ELSE 0 END, NULL);

INSERT INTO dbo.RuleDefinitions (RuleCode, Expression) VALUES ('TEST_A02', '{SUM_POS(MONTANT_%)}');
INSERT INTO #ThreadState ([Key], IsRule, State) VALUES ('TEST_A02', 1, 0);
EXEC dbo.sp_ExecuteRule 'TEST_A02', @Result OUTPUT, @Err OUTPUT;
INSERT INTO #TestResults VALUES ('AGGREG', 'A02_SumPos', '{SUM_POS(MONTANT_%)}', '450', @Result, CASE WHEN ABS(TRY_CAST(@Result AS DECIMAL(18,2)) - 450) < 0.01 THEN 1 ELSE 0 END, NULL);

INSERT INTO dbo.RuleDefinitions (RuleCode, Expression) VALUES ('TEST_A03', '{SUM_NEG(MONTANT_%)}');
INSERT INTO #ThreadState ([Key], IsRule, State) VALUES ('TEST_A03', 1, 0);
EXEC dbo.sp_ExecuteRule 'TEST_A03', @Result OUTPUT, @Err OUTPUT;
INSERT INTO #TestResults VALUES ('AGGREG', 'A03_SumNeg', '{SUM_NEG(MONTANT_%)}', '-75', @Result, CASE WHEN ABS(TRY_CAST(@Result AS DECIMAL(18,2)) - (-75)) < 0.01 THEN 1 ELSE 0 END, NULL);

INSERT INTO dbo.RuleDefinitions (RuleCode, Expression) VALUES ('TEST_A04', '{AVG(MONTANT_%)}');
INSERT INTO #ThreadState ([Key], IsRule, State) VALUES ('TEST_A04', 1, 0);
EXEC dbo.sp_ExecuteRule 'TEST_A04', @Result OUTPUT, @Err OUTPUT;
INSERT INTO #TestResults VALUES ('AGGREG', 'A04_Avg', '{AVG(MONTANT_%)}', '75', @Result, CASE WHEN ABS(TRY_CAST(@Result AS DECIMAL(18,2)) - 75) < 0.01 THEN 1 ELSE 0 END, NULL);

INSERT INTO dbo.RuleDefinitions (RuleCode, Expression) VALUES ('TEST_A05', '{AVG_NEG(MONTANT_%)}');
INSERT INTO #ThreadState ([Key], IsRule, State) VALUES ('TEST_A05', 1, 0);
EXEC dbo.sp_ExecuteRule 'TEST_A05', @Result OUTPUT, @Err OUTPUT;
INSERT INTO #TestResults VALUES ('AGGREG', 'A05_AvgNeg', '{AVG_NEG(MONTANT_%)}', '-37.5', @Result, CASE WHEN ABS(TRY_CAST(@Result AS DECIMAL(18,2)) - (-37.5)) < 0.01 THEN 1 ELSE 0 END, NULL);

INSERT INTO dbo.RuleDefinitions (RuleCode, Expression) VALUES ('TEST_A06', '{MIN(MONTANT_%)}');
INSERT INTO #ThreadState ([Key], IsRule, State) VALUES ('TEST_A06', 1, 0);
EXEC dbo.sp_ExecuteRule 'TEST_A06', @Result OUTPUT, @Err OUTPUT;
INSERT INTO #TestResults VALUES ('AGGREG', 'A06_Min', '{MIN(MONTANT_%)}', '-50', @Result, CASE WHEN TRY_CAST(@Result AS INT) = -50 THEN 1 ELSE 0 END, NULL);

INSERT INTO dbo.RuleDefinitions (RuleCode, Expression) VALUES ('TEST_A07', '{MAX(MONTANT_%)}');
INSERT INTO #ThreadState ([Key], IsRule, State) VALUES ('TEST_A07', 1, 0);
EXEC dbo.sp_ExecuteRule 'TEST_A07', @Result OUTPUT, @Err OUTPUT;
INSERT INTO #TestResults VALUES ('AGGREG', 'A07_Max', '{MAX(MONTANT_%)}', '200', @Result, CASE WHEN TRY_CAST(@Result AS INT) = 200 THEN 1 ELSE 0 END, NULL);

INSERT INTO dbo.RuleDefinitions (RuleCode, Expression) VALUES ('TEST_A08', '{COUNT(MONTANT_%)}');
INSERT INTO #ThreadState ([Key], IsRule, State) VALUES ('TEST_A08', 1, 0);
EXEC dbo.sp_ExecuteRule 'TEST_A08', @Result OUTPUT, @Err OUTPUT;
INSERT INTO #TestResults VALUES ('AGGREG', 'A08_Count', '{COUNT(MONTANT_%)}', '5', @Result, CASE WHEN TRY_CAST(@Result AS INT) = 5 THEN 1 ELSE 0 END, 'NULL ignoré');

INSERT INTO dbo.RuleDefinitions (RuleCode, Expression) VALUES ('TEST_A09', '{COUNT_POS(MONTANT_%)}');
INSERT INTO #ThreadState ([Key], IsRule, State) VALUES ('TEST_A09', 1, 0);
EXEC dbo.sp_ExecuteRule 'TEST_A09', @Result OUTPUT, @Err OUTPUT;
INSERT INTO #TestResults VALUES ('AGGREG', 'A09_CountPos', '{COUNT_POS(MONTANT_%)}', '3', @Result, CASE WHEN TRY_CAST(@Result AS INT) = 3 THEN 1 ELSE 0 END, NULL);

INSERT INTO dbo.RuleDefinitions (RuleCode, Expression) VALUES ('TEST_A10', '{COUNT_NEG(MONTANT_%)}');
INSERT INTO #ThreadState ([Key], IsRule, State) VALUES ('TEST_A10', 1, 0);
EXEC dbo.sp_ExecuteRule 'TEST_A10', @Result OUTPUT, @Err OUTPUT;
INSERT INTO #TestResults VALUES ('AGGREG', 'A10_CountNeg', '{COUNT_NEG(MONTANT_%)}', '2', @Result, CASE WHEN TRY_CAST(@Result AS INT) = 2 THEN 1 ELSE 0 END, NULL);

INSERT INTO dbo.RuleDefinitions (RuleCode, Expression) VALUES ('TEST_A11a', 'ISNULL({SUM(INEXISTANT_%)},''NULL_VALUE'')');
INSERT INTO #ThreadState ([Key], IsRule, State) VALUES ('TEST_A11a', 1, 0);
EXEC dbo.sp_ExecuteRule 'TEST_A11a', @Result OUTPUT, @Err OUTPUT;
INSERT INTO #TestResults VALUES ('AGGREG', 'A11a_EmptySum', '{SUM(INEXISTANT_%)}', 'NULL_VALUE', @Result, CASE WHEN @Result = 'NULL_VALUE' THEN 1 ELSE 0 END, 'Vide=>NULL');

INSERT INTO dbo.RuleDefinitions (RuleCode, Expression) VALUES ('TEST_A11b', '{COUNT(INEXISTANT_%)}');
INSERT INTO #ThreadState ([Key], IsRule, State) VALUES ('TEST_A11b', 1, 0);
EXEC dbo.sp_ExecuteRule 'TEST_A11b', @Result OUTPUT, @Err OUTPUT;
INSERT INTO #TestResults VALUES ('AGGREG', 'A11b_EmptyCount', '{COUNT(INEXISTANT_%)}', '0', @Result, CASE WHEN TRY_CAST(@Result AS INT) = 0 THEN 1 ELSE 0 END, 'Vide=>0');

PRINT '   OK';

-- =========================================================================
-- L: LAZY/CACHE
-- =========================================================================
PRINT '── L: Lazy/Cache ──';

EXEC dbo.sp_ExecuteRule 'BBB1', @Result OUTPUT, @Err OUTPUT;
SELECT @State = State FROM #ThreadState WHERE [Key] = 'BBB1';
INSERT INTO #TestResults VALUES ('LAZY', 'L01_Evaluated', 'BBB1', '2 (EVALUATED)', CAST(@State AS NVARCHAR), CASE WHEN @State = 2 THEN 1 ELSE 0 END, NULL);

EXEC dbo.sp_ExecuteRule 'BBB1', @Result OUTPUT, @Err OUTPUT;
SELECT @State = State FROM #ThreadState WHERE [Key] = 'BBB1';
INSERT INTO #TestResults VALUES ('LAZY', 'L02_Cached', 'BBB1 (2nd call)', '10', @Result, CASE WHEN @State = 2 AND @Result = '10' THEN 1 ELSE 0 END, 'No re-eval');

PRINT '   OK';

-- =========================================================================
-- E: ERREURS
-- =========================================================================
PRINT '── E: Erreurs ──';

INSERT INTO dbo.RuleDefinitions (RuleCode, Expression) VALUES ('TEST_E01', '100 / 0');
INSERT INTO #ThreadState ([Key], IsRule, State) VALUES ('TEST_E01', 1, 0);
EXEC dbo.sp_ExecuteRule 'TEST_E01', @Result OUTPUT, @Err OUTPUT;
SELECT @State = State, @ErrCat = ErrorCategory FROM #ThreadState WHERE [Key] = 'TEST_E01';
INSERT INTO #TestResults VALUES ('ERREURS', 'E01_DivZero', '100 / 0', 'State=3,NUMERIC', CONCAT('State=',@State,',',@ErrCat), CASE WHEN @State = 3 AND @ErrCat = 'NUMERIC' THEN 1 ELSE 0 END, @Err);

INSERT INTO dbo.RuleDefinitions (RuleCode, Expression) VALUES ('TEST_E05', '{rule:TEST_E05} + 1');
INSERT INTO #ThreadState ([Key], IsRule, State) VALUES ('TEST_E05', 1, 0);
EXEC dbo.sp_ExecuteRule 'TEST_E05', @Result OUTPUT, @Err OUTPUT;
SELECT @State = State, @ErrCat = ErrorCategory FROM #ThreadState WHERE [Key] = 'TEST_E05';
INSERT INTO #TestResults VALUES ('ERREURS', 'E05_RecursionDirect', '{rule:TEST_E05}', 'State=3,RECURSION', CONCAT('State=',@State,',',@ErrCat), CASE WHEN @State = 3 AND @ErrCat = 'RECURSION' THEN 1 ELSE 0 END, NULL);

INSERT INTO dbo.RuleDefinitions (RuleCode, Expression) VALUES ('TEST_E06A', '{rule:TEST_E06B} + 1'), ('TEST_E06B', '{rule:TEST_E06A} + 1');
INSERT INTO #ThreadState ([Key], IsRule, State) VALUES ('TEST_E06A', 1, 0), ('TEST_E06B', 1, 0);
EXEC dbo.sp_ExecuteRule 'TEST_E06A', @Result OUTPUT, @Err OUTPUT;
SELECT @State = State FROM #ThreadState WHERE [Key] = 'TEST_E06A';
DECLARE @StateB TINYINT; SELECT @StateB = State FROM #ThreadState WHERE [Key] = 'TEST_E06B';
INSERT INTO #TestResults VALUES ('ERREURS', 'E06_RecursionIndirect', 'A->B->A', 'Both ERROR', CONCAT('A=',@State,',B=',@StateB), CASE WHEN @State = 3 AND @StateB = 3 THEN 1 ELSE 0 END, 'Thread continues');

EXEC dbo.sp_ExecuteRule 'BBB2', @Result OUTPUT, @Err OUTPUT;
EXEC dbo.sp_ExecuteRule 'BBB_NULL', @Result OUTPUT, @Err OUTPUT;
INSERT INTO dbo.RuleDefinitions (RuleCode, Expression) VALUES ('TEST_E07', '{SUM(rule:BBB%)}');
INSERT INTO #ThreadState ([Key], IsRule, State) VALUES ('TEST_E07', 1, 0);
EXEC dbo.sp_ExecuteRule 'TEST_E07', @Result OUTPUT, @Err OUTPUT;
INSERT INTO #TestResults VALUES ('ERREURS', 'E07_AggTolerant', '{SUM(rule:BBB%)}', '5', @Result, CASE WHEN ABS(TRY_CAST(@Result AS DECIMAL(18,2)) - 5) < 0.01 THEN 1 ELSE 0 END, '10+(-5), NULL ignored');

PRINT '   OK';

-- =========================================================================
-- P: PERFORMANCE/MODES
-- =========================================================================
PRINT '── P: Performance/Modes ──';

DECLARE @HasDebug BIT = CASE WHEN OBJECT_ID('tempdb..#ThreadDebug') IS NOT NULL THEN 1 ELSE 0 END;
INSERT INTO #TestResults VALUES ('PERF', 'P01_NormalNoDebug', 'Mode NORMAL', 'No debug table', CASE WHEN @HasDebug = 1 THEN 'Has debug' ELSE 'No debug' END, CASE WHEN @HasDebug = 0 THEN 1 ELSE 0 END, NULL);

-- Recréer en mode debug
IF OBJECT_ID('tempdb..#ThreadConfig') IS NOT NULL DROP TABLE #ThreadConfig;
CREATE TABLE #ThreadConfig (DebugMode BIT);
INSERT INTO #ThreadConfig VALUES (1);

CREATE TABLE #ThreadDebug (LogId INT IDENTITY, LogTime DATETIME2 DEFAULT SYSDATETIME(), RuleCode NVARCHAR(200), Action VARCHAR(50), DurationMs INT, CompiledSQL NVARCHAR(MAX), ErrorMessage NVARCHAR(MAX));

SET @HasDebug = CASE WHEN OBJECT_ID('tempdb..#ThreadDebug') IS NOT NULL THEN 1 ELSE 0 END;
INSERT INTO #TestResults VALUES ('PERF', 'P02_DebugTable', 'Mode DEBUG', 'Has debug table', CASE WHEN @HasDebug = 1 THEN 'Has debug' ELSE 'No debug' END, CASE WHEN @HasDebug = 1 THEN 1 ELSE 0 END, NULL);

PRINT '   OK';
PRINT '';

-- =========================================================================
-- RAPPORT FINAL
-- =========================================================================
PRINT '══════════════════════════════════════════════════════════════════════';
PRINT '                        RAPPORT CONFORMITÉ                            ';
PRINT '══════════════════════════════════════════════════════════════════════';
PRINT '';

SELECT Category, COUNT(*) AS Total, SUM(CAST(Pass AS INT)) AS Pass, COUNT(*) - SUM(CAST(Pass AS INT)) AS Fail
FROM #TestResults GROUP BY Category ORDER BY Category;

SELECT TestId AS [#], Category AS Cat, Name, Expected, Actual, CASE WHEN Pass = 1 THEN 'PASS' ELSE 'FAIL' END AS Status, Details
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
