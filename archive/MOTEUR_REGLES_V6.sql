/***********************************************************************
    MOTEUR DE RÈGLES T-SQL - VERSION 6.1
    Conforme Spec V1.5.5
    
    Compatibilité : SQL Server 2017+
    
    PRINCIPES (NORMATIFS):
    - Le moteur orchestre, SQL calcule
    - États fermés: NOT_EVALUATED, EVALUATING, EVALUATED, ERROR
    - Ordre canonique = SeqId (ordre d'insertion)
    - Erreurs locales, thread continue
    - Agrégateur par défaut = FIRST
    - 17 agrégateurs fermés
    - Aucune logique SQL dans {...}
    - Variables = littéraux atomiques (une clé = une valeur)
    - Runner JSON = orchestrateur neutre
    
    COLLATION: SQL_Latin1_General_CP1_CI_AS (case-insensitive)
************************************************************************/

SET NOCOUNT ON;
GO

PRINT '══════════════════════════════════════════════════════════════════════';
PRINT '           MOTEUR DE RÈGLES V6.1 - Spec V1.5.5                        ';
PRINT '══════════════════════════════════════════════════════════════════════';
PRINT '';
GO

-- =========================================================================
-- PARTIE 1 : NETTOYAGE
-- =========================================================================
PRINT '── Nettoyage ──';

IF OBJECT_ID('dbo.sp_RunRulesEngine','P') IS NOT NULL DROP PROCEDURE dbo.sp_RunRulesEngine;
IF OBJECT_ID('dbo.sp_ExecuteRule','P') IS NOT NULL DROP PROCEDURE dbo.sp_ExecuteRule;
IF OBJECT_ID('dbo.sp_ResolveToken','P') IS NOT NULL DROP PROCEDURE dbo.sp_ResolveToken;
IF OBJECT_ID('dbo.sp_ExecuteRulesAll','P') IS NOT NULL DROP PROCEDURE dbo.sp_ExecuteRulesAll;
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
-- PARTIE 3 : FONCTION D'EXTRACTION DES TOKENS (Inline TVF + SCHEMABINDING)
-- =========================================================================
PRINT '── Fonctions ──';
GO
IF OBJECT_ID('dbo.fn_ExtractTokens','IF') IS NOT NULL DROP FUNCTION dbo.fn_ExtractTokens;
GO
CREATE FUNCTION dbo.fn_ExtractTokens(@Expr NVARCHAR(MAX))
RETURNS TABLE
WITH SCHEMABINDING
AS
RETURN
WITH
L0 AS (SELECT 1 AS c UNION ALL SELECT 1),
L1 AS (SELECT 1 AS c FROM L0 A CROSS JOIN L0 B),
L2 AS (SELECT 1 AS c FROM L1 A CROSS JOIN L1 B),
L3 AS (SELECT 1 AS c FROM L2 A CROSS JOIN L2 B),
L4 AS (SELECT 1 AS c FROM L3 A CROSS JOIN L3 B),
N(n) AS (SELECT TOP (ISNULL(LEN(@Expr), 0)) ROW_NUMBER() OVER (ORDER BY (SELECT NULL)) FROM L4),
Starts AS (SELECT n AS pos FROM N WHERE SUBSTRING(@Expr, n, 1) = '{'),
Ends AS (SELECT n AS pos FROM N WHERE SUBSTRING(@Expr, n, 1) = '}')
SELECT DISTINCT SUBSTRING(@Expr, s.pos, e.pos - s.pos + 1) AS Token
FROM Starts s
CROSS APPLY (SELECT MIN(pos) AS pos FROM Ends WHERE pos > s.pos) e
WHERE e.pos IS NOT NULL
  AND CHARINDEX('{', SUBSTRING(@Expr, s.pos + 1, e.pos - s.pos - 1)) = 0;
GO

-- =========================================================================
-- PARTIE 4 : FONCTION DE PARSING D'UN TOKEN (Inline TVF + SCHEMABINDING)
-- =========================================================================
GO

CREATE FUNCTION dbo.fn_ParseToken(@Token NVARCHAR(1000))
RETURNS TABLE
WITH SCHEMABINDING
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
/****** Object:  Function [dbo].[fn_NormalizeSqlLiterals_v61]    Script Date: 12/11/2025 09:56:15 ******/
IF EXISTS (SELECT * FROM [dbo].sysobjects WHERE id = OBJECT_ID(N'[dbo].[fn_NormalizeSqlLiterals_v61]') and xtype in (N'FN', N'IF', N'TF'))
	DROP FUNCTION [dbo].[fn_NormalizeSqlLiterals_v61]
GO
CREATE FUNCTION dbo.fn_NormalizeSqlLiterals_v61
(
    @Expr NVARCHAR(MAX)
)
RETURNS NVARCHAR(MAX)
AS
BEGIN
    /*
      Normalisation minimale conforme spec:
      - Convertit les littéraux "..." en '...' (échappement des quotes simples)
      - Convertit les décimaux français 2,5 -> 2.5 hors quotes (simple heuristique)
      Ne modifie pas les segments déjà dans des quotes simples.
    */
    DECLARE @i INT = 1, @len INT = LEN(@Expr);
    DECLARE @out NVARCHAR(MAX) = N'';
    DECLARE @inSingle BIT = 0, @inDouble BIT = 0;
    DECLARE @ch NCHAR(1), @prev NCHAR(1), @next NCHAR(1);

    WHILE @i <= @len
    BEGIN
        SET @ch = SUBSTRING(@Expr, @i, 1);
        SET @prev = CASE WHEN @i > 1 THEN SUBSTRING(@Expr, @i-1, 1) ELSE N'' END;
        SET @next = CASE WHEN @i < @len THEN SUBSTRING(@Expr, @i+1, 1) ELSE N'' END;

        -- Toggle single quote only when not inside double quote
        IF @ch = N'''' AND @inDouble = 0
        BEGIN
            SET @inSingle = CASE WHEN @inSingle = 1 THEN 0 ELSE 1 END;
            SET @out += N'''';
            SET @i += 1;
            CONTINUE;
        END

        -- Convert double-quoted literals to single-quoted literals (only when not inside single quotes)
        IF @ch = N'"' AND @inSingle = 0
        BEGIN
            SET @inDouble = CASE WHEN @inDouble = 1 THEN 0 ELSE 1 END;
            SET @out += N'''';
            SET @i += 1;
            CONTINUE;
        END

        -- Inside converted double-quoted literal: escape single quotes
        IF @inDouble = 1 AND @ch = N'''' 
        BEGIN
            SET @out += N''''''; -- double the quote
            SET @i += 1;
            CONTINUE;
        END

        -- Decimal comma -> dot (heuristic: digit , digit) outside any quotes
        IF @inSingle = 0 AND @inDouble = 0 AND @ch = N',' 
           AND @prev LIKE N'[0-9]' AND @next LIKE N'[0-9]'
        BEGIN
            SET @out += N'.';
            SET @i += 1;
            CONTINUE;
        END

        SET @out += @ch;
        SET @i += 1;
    END

    RETURN @out;
END;
GO



PRINT '   OK';
GO

-- =========================================================================
-- PARTIE 5 : PROCÉDURES DU MOTEUR
-- =========================================================================
PRINT '── Procédures moteur ──';
GO
-- sp_ResolveToken : Résout un token {..} en valeur scalaire

CREATE PROCEDURE dbo.sp_ResolveToken
    @Token NVARCHAR(1000),
    @Result NVARCHAR(MAX) OUTPUT
AS
BEGIN
    SET NOCOUNT ON;
    SET ANSI_WARNINGS OFF;  -- NULLs in aggregates are expected by spec

    DECLARE @Aggregator VARCHAR(20), @IsRuleRef BIT, @Pattern NVARCHAR(500);
    DECLARE @BaseAggregator VARCHAR(20), @FilterCondition NVARCHAR(400) = N'';
    DECLARE @SQL NVARCHAR(MAX);

    SELECT @Aggregator = Aggregator, @IsRuleRef = IsRuleRef, @Pattern = Pattern
    FROM dbo.fn_ParseToken(@Token);

    -- Base aggregator + POS/NEG suffix split
    SET @BaseAggregator = UPPER(@Aggregator);

    IF RIGHT(@BaseAggregator, 4) = '_POS'
    BEGIN
        SET @BaseAggregator = LEFT(@BaseAggregator, LEN(@BaseAggregator) - 4);
        SET @FilterCondition = N' AND TRY_CAST(Val AS DECIMAL(38, 10)) > 0';
    END
    ELSE IF RIGHT(@BaseAggregator, 4) = '_NEG'
    BEGIN
        SET @BaseAggregator = LEFT(@BaseAggregator, LEN(@BaseAggregator) - 4);
        SET @FilterCondition = N' AND TRY_CAST(Val AS DECIMAL(38, 10)) < 0';
    END

    /* ============================================================
       RULE: selection must be independent from runner rules[]
       - Ensure rule candidates exist in #ThreadState (lazy insert)
       - Evaluate missing rules lazily
       ============================================================ */
    IF @IsRuleRef = 1
    BEGIN
        -- Insert missing rule rows into thread state (NOT_EVALUATED)
        INSERT INTO #ThreadState ([Key], IsRule, State)
        SELECT rd.RuleCode, 1, 0
        FROM dbo.RuleDefinitions rd
        WHERE rd.RuleCode LIKE @Pattern
          AND NOT EXISTS (
              SELECT 1 FROM #ThreadState ts WHERE ts.IsRule = 1 AND ts.[Key] = rd.RuleCode
          );

        -- Evaluate all matching rules still not evaluated
        DECLARE @RuleKey NVARCHAR(200), @RuleState TINYINT, @TmpVal NVARCHAR(MAX), @TmpErr NVARCHAR(500);

        DECLARE rule_cursor CURSOR LOCAL FAST_FORWARD FOR
        SELECT [Key], State
        FROM #ThreadState
        WHERE IsRule = 1 AND [Key] LIKE @Pattern AND State IN (0, 1);

        OPEN rule_cursor;
        FETCH NEXT FROM rule_cursor INTO @RuleKey, @RuleState;

        WHILE @@FETCH_STATUS = 0
        BEGIN
            IF @RuleState = 0
                EXEC dbo.sp_ExecuteRule @RuleKey, @TmpVal OUTPUT, @TmpErr OUTPUT;
            -- If 1 (EVALUATING) recursion is handled inside sp_ExecuteRule
            FETCH NEXT FROM rule_cursor INTO @RuleKey, @RuleState;
        END

        CLOSE rule_cursor;
        DEALLOCATE rule_cursor;
    END

    /* ============================================================
       Token set = transitory set built by LIKE on atomic keys
       - Variables: State = 2 only
       - Rules: State IN (2,3) (ERROR participates as NULL value)
       ============================================================ */
    DECLARE @WhereClause NVARCHAR(800);
    IF @IsRuleRef = 1
        SET @WhereClause = N'IsRule = 1 AND [Key] LIKE @P AND State IN (2,3)';
    ELSE
        SET @WhereClause = N'IsRule = 0 AND [Key] LIKE @P AND State = 2';

    /* ------------------------------------------------------------
       Build the aggregator SQL.
       We project a derived column Val which maps ERROR => NULL.
       ------------------------------------------------------------ */
    IF @BaseAggregator = 'FIRST'
    BEGIN
        -- FIRST may return NULL (order is SeqId / insertion order)
        SET @SQL = N'
            SELECT TOP (1) @R = Val
            FROM (
                SELECT SeqId,
                       CASE WHEN IsRule = 1 AND State = 3 THEN NULL ELSE ScalarValue END AS Val
                FROM #ThreadState
                WHERE ' + @WhereClause + N'
            ) S
            WHERE 1=1' + @FilterCondition + N'
            ORDER BY SeqId;';
    END
    ELSE IF @BaseAggregator IN ('SUM','AVG','MIN','MAX')
    BEGIN
        SET @SQL = N'
            SELECT @R = CAST(' + @BaseAggregator + N'(TRY_CAST(Val AS DECIMAL(38, 10))) AS NVARCHAR(MAX))
            FROM (
                SELECT CASE WHEN IsRule = 1 AND State = 3 THEN NULL ELSE ScalarValue END AS Val
                FROM #ThreadState
                WHERE ' + @WhereClause + N'
            ) S
            WHERE 1=1' + @FilterCondition + N';';
    END
    ELSE IF @BaseAggregator = 'COUNT'
    BEGIN
        -- COUNT counts numeric values by default (NULL and non-numeric ignored)
        SET @SQL = N'
            SELECT @R = CAST(COUNT(TRY_CAST(Val AS DECIMAL(38, 10))) AS NVARCHAR(MAX))
            FROM (
                SELECT CASE WHEN IsRule = 1 AND State = 3 THEN NULL ELSE ScalarValue END AS Val
                FROM #ThreadState
                WHERE ' + @WhereClause + N'
            ) S
            WHERE 1=1' + @FilterCondition + N';';
    END
    ELSE IF @BaseAggregator = 'CONCAT'
    BEGIN
        SET @SQL = N'
            SELECT @R = STRING_AGG(Val, '','') WITHIN GROUP (ORDER BY SeqId)
            FROM (
                SELECT SeqId,
                       CASE WHEN IsRule = 1 AND State = 3 THEN NULL ELSE ScalarValue END AS Val
                FROM #ThreadState
                WHERE ' + @WhereClause + N'
            ) S
            WHERE Val IS NOT NULL;';
    END
    ELSE IF @BaseAggregator = 'JSONIFY'
    BEGIN
        -- JSON object: {"Key": value | "Key": null, ...}
        -- Values are emitted as JSON scalars. For unknown types, value is a JSON string.
        SET @SQL = N'
            SELECT @R =
                CASE WHEN COUNT(1) = 0 THEN ''{}''
                     ELSE ''{'' + STRING_AGG(
                        ''"'' + STRING_ESCAPE([Key], ''json'') + ''":'' +
                        CASE
                            WHEN Val IS NULL THEN ''null''
                            WHEN UPPER(ValueType) IN (''DECIMAL'',''INTEGER'') AND TRY_CAST(Val AS DECIMAL(38,10)) IS NOT NULL
                                THEN REPLACE(Val, '','', ''.'')
                            WHEN UPPER(ValueType) = ''BOOLEAN'' AND Val IN (''0'',''1'')
                                THEN Val
                            ELSE ''"'' + STRING_ESCAPE(Val, ''json'') + ''"''
                        END
                     , '','') WITHIN GROUP (ORDER BY SeqId) + ''}''
                END
            FROM (
                SELECT SeqId,
                       [Key],
                       ValueType,
                       CASE WHEN IsRule = 1 AND State = 3 THEN NULL ELSE ScalarValue END AS Val
                FROM #ThreadState
                WHERE ' + @WhereClause + N'
            ) S;';
    END
    ELSE
    BEGIN
        SET @Result = NULL;
        RETURN;
    END

    BEGIN TRY
        EXEC sp_executesql @SQL, N'@P NVARCHAR(500), @R NVARCHAR(MAX) OUTPUT', @Pattern, @Result OUTPUT;
    END TRY
    BEGIN CATCH
        SET @Result = NULL;
    END CATCH
END;
GO


-- sp_ExecuteRule : Évalue une règle (lazy, avec détection de cycle)
CREATE PROCEDURE dbo.sp_ExecuteRule
    @RuleCode NVARCHAR(200),
    @Result NVARCHAR(MAX) OUTPUT,
    @ErrorMsg NVARCHAR(500) OUTPUT
AS
BEGIN
    SET NOCOUNT ON;
    
    DECLARE @State TINYINT, @Expression NVARCHAR(MAX), @CompiledExpr NVARCHAR(MAX);
    DECLARE @Token NVARCHAR(1000), @TokenValue NVARCHAR(MAX);
    DECLARE @ErrorCategory VARCHAR(20), @ErrorCode VARCHAR(50);
    DECLARE @StartTime DATETIME2 = SYSDATETIME();
    DECLARE @DebugMode BIT = 0;
    
    IF OBJECT_ID('tempdb..#ThreadConfig') IS NOT NULL
        SELECT @DebugMode = DebugMode FROM #ThreadConfig;
    
    -- Vérifier état actuel
    SELECT @State = State, @Result = ScalarValue
    FROM #ThreadState WHERE [Key] = @RuleCode AND IsRule = 1;
    
    -- EVALUATED : retourner valeur cachée
    IF @State = 2 BEGIN SET @ErrorMsg = NULL; RETURN; END
    
    -- ERROR : retourner NULL
    IF @State = 3 
    BEGIN 
        SET @Result = NULL; 
        SELECT @ErrorMsg = ErrorCategory + '/' + ErrorCode 
        FROM #ThreadState WHERE [Key] = @RuleCode AND IsRule = 1; 
        RETURN; 
    END
    
    -- EVALUATING : récursion détectée!
    IF @State = 1
    BEGIN
        SET @ErrorCategory = 'RECURSION';
        SET @ErrorCode = 'RECURSIVE_DEPENDENCY';
        SET @ErrorMsg = @ErrorCategory + '/' + @ErrorCode;
        SET @Result = NULL;
        UPDATE #ThreadState 
        SET State = 3, ScalarValue = NULL, ErrorCategory = @ErrorCategory, ErrorCode = @ErrorCode 
        WHERE [Key] = @RuleCode AND IsRule = 1;
        RETURN;
    END
    
    -- Passer à EVALUATING
    UPDATE #ThreadState SET State = 1 WHERE [Key] = @RuleCode AND IsRule = 1;
    
    BEGIN TRY
        -- Récupérer expression
        SELECT @Expression = Expression 
        FROM dbo.RuleDefinitions 
        WHERE RuleCode = @RuleCode AND IsActive = 1;
        
        IF @Expression IS NULL
        BEGIN
            SET @ErrorCategory = 'SQL';
            SET @ErrorCode = 'RULE_NOT_FOUND';
            RAISERROR('Rule not found', 16, 1);
        END
        
        SET @CompiledExpr = @Expression;
        
        -- Extraire et résoudre tokens
        DECLARE token_cursor CURSOR LOCAL FAST_FORWARD FOR
        SELECT Token FROM dbo.fn_ExtractTokens(@Expression);
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
        
        -- Vérifier si la règle est passée en ERROR pendant la résolution (récursion)
        SELECT @State = State FROM #ThreadState WHERE [Key] = @RuleCode AND IsRule = 1;
        IF @State = 3
        BEGIN
            SET @Result = NULL;
            SELECT @ErrorMsg = ErrorCategory + '/' + ErrorCode 
            FROM #ThreadState WHERE [Key] = @RuleCode AND IsRule = 1;
            RETURN;
        END
        
        -- Compilation (spec): normalisation des littéraux et décimaux
        SET @CompiledExpr = dbo.fn_NormalizeSqlLiterals_v61(@CompiledExpr);
        
        -- Exécuter SQL
        DECLARE @SQL NVARCHAR(MAX) = N'SELECT @R = ' + @CompiledExpr;
        EXEC sp_executesql @SQL, N'@R NVARCHAR(MAX) OUTPUT', @Result OUTPUT;
        
        -- Succès : EVALUATED
        UPDATE #ThreadState 
        SET State = 2, ScalarValue = @Result, ErrorCategory = NULL, ErrorCode = NULL 
        WHERE [Key] = @RuleCode AND IsRule = 1;
        SET @ErrorMsg = NULL;
        
        -- Debug log
        IF @DebugMode = 1 AND OBJECT_ID('tempdb..#ThreadDebug') IS NOT NULL
            INSERT INTO #ThreadDebug (RuleCode, Action, DurationMs, CompiledSQL) 
            VALUES (@RuleCode, 'EVALUATED', DATEDIFF(MILLISECOND, @StartTime, SYSDATETIME()), @CompiledExpr);
        
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
        
        UPDATE #ThreadState 
        SET State = 3, ScalarValue = NULL, ErrorCategory = @ErrorCategory, ErrorCode = @ErrorCode 
        WHERE [Key] = @RuleCode AND IsRule = 1;
        
        IF @DebugMode = 1 AND OBJECT_ID('tempdb..#ThreadDebug') IS NOT NULL
            INSERT INTO #ThreadDebug (RuleCode, Action, DurationMs, ErrorMessage) 
            VALUES (@RuleCode, 'ERROR', DATEDIFF(MILLISECOND, @StartTime, SYSDATETIME()), @ErrMsg);
    END CATCH
END;
GO

PRINT '   OK';
GO

-- =========================================================================
-- PARTIE 6 : RUNNER JSON (§9.1 - V1.5.5)
-- =========================================================================
PRINT '── Runner JSON ──';
GO
/*
    sp_RunRulesEngine - Orchestrateur JSON
    
    Rôle (neutre):
    1) Initialise le thread et ses tables temporaires
    2) Charge des variables atomiques
    3) Exécute une liste explicite de règles
    4) Retourne les résultats et l'état
    
    Le runner N'INTERPRÈTE JAMAIS:
    - tokens
    - agrégateurs
    - dépendances
    - sélection par motif de règles
    
    @InputJson format:
    {
      "mode": "NORMAL|DEBUG",
      "variables": [{ "key": "...", "type": "...", "value": "..." }],
      "rules": ["RULE_A", "RULE_B"],
      "options": {
        "stopOnFatal": false,
        "returnStateTable": true,
        "returnDebug": false
      }
    }
*/
CREATE PROCEDURE dbo.sp_RunRulesEngine
    @InputJson NVARCHAR(MAX),
    @OutputJson NVARCHAR(MAX) OUTPUT
AS
BEGIN
    SET NOCOUNT ON;
    
    DECLARE @StartTime DATETIME2 = SYSDATETIME();
    DECLARE @Mode VARCHAR(10) = 'NORMAL';
    DECLARE @StopOnFatal BIT = 0;
    DECLARE @ReturnStateTable BIT = 1;
    DECLARE @ReturnDebug BIT = 0;
    DECLARE @ErrorCount INT = 0;
    DECLARE @SuccessCount INT = 0;
    
    BEGIN TRY
        -- =====================================================================
        -- 1) PARSER LE JSON D'ENTRÉE
        -- =====================================================================
        
        -- Mode
        SET @Mode = ISNULL(JSON_VALUE(@InputJson, '$.mode'), 'NORMAL');
        IF @Mode NOT IN ('NORMAL', 'DEBUG') SET @Mode = 'NORMAL';
        
        -- Options
        SET @StopOnFatal = ISNULL(TRY_CAST(JSON_VALUE(@InputJson, '$.options.stopOnFatal') AS BIT), 0);
        SET @ReturnStateTable = ISNULL(TRY_CAST(JSON_VALUE(@InputJson, '$.options.returnStateTable') AS BIT), 1);
        SET @ReturnDebug = ISNULL(TRY_CAST(JSON_VALUE(@InputJson, '$.options.returnDebug') AS BIT), 0);
        
        -- =====================================================================
        -- 2) INITIALISER LE THREAD
        -- =====================================================================
        
        -- Table d'état
        IF OBJECT_ID('tempdb..#ThreadState') IS NOT NULL DROP TABLE #ThreadState;
        CREATE TABLE #ThreadState (
            SeqId INT IDENTITY(1,1) NOT NULL,
            [Key] NVARCHAR(200) COLLATE SQL_Latin1_General_CP1_CI_AS NOT NULL,
            IsRule BIT NOT NULL DEFAULT 0,
            State TINYINT NOT NULL DEFAULT 0,  -- 0=NOT_EVALUATED, 1=EVALUATING, 2=EVALUATED, 3=ERROR
            ScalarValue NVARCHAR(MAX) COLLATE SQL_Latin1_General_CP1_CI_AS NULL,
            ValueType VARCHAR(20) COLLATE SQL_Latin1_General_CP1_CI_AS NULL,
            ErrorCategory VARCHAR(20) COLLATE SQL_Latin1_General_CP1_CI_AS NULL,
            ErrorCode VARCHAR(50) COLLATE SQL_Latin1_General_CP1_CI_AS NULL,
            CONSTRAINT PK_ThreadState PRIMARY KEY (SeqId),
            CONSTRAINT UQ_ThreadState_Key UNIQUE ([Key])
        );
        
        -- Config
        IF OBJECT_ID('tempdb..#ThreadConfig') IS NOT NULL DROP TABLE #ThreadConfig;
        CREATE TABLE #ThreadConfig (DebugMode BIT);
        INSERT INTO #ThreadConfig VALUES (CASE WHEN @Mode = 'DEBUG' THEN 1 ELSE 0 END);
        
        -- Table debug si mode DEBUG
        IF @Mode = 'DEBUG'
        BEGIN
            IF OBJECT_ID('tempdb..#ThreadDebug') IS NOT NULL DROP TABLE #ThreadDebug;
            CREATE TABLE #ThreadDebug (
                LogId INT IDENTITY(1,1),
                LogTime DATETIME2 DEFAULT SYSDATETIME(),
                RuleCode NVARCHAR(200),
                Action VARCHAR(50),
                DurationMs INT,
                CompiledSQL NVARCHAR(MAX),
                ErrorMessage NVARCHAR(MAX)
            );
        END
        
        -- =====================================================================
        -- 3) CHARGER LES VARIABLES (atomiques, une par clé)
        -- =====================================================================
        
        INSERT INTO #ThreadState ([Key], IsRule, State, ScalarValue, ValueType)
        SELECT 
            v.[key],
            0,  -- IsRule = false
            2,  -- State = EVALUATED (variable = valeur directe)
            v.[value],
            ISNULL(v.[type], 'STRING')
        FROM OPENJSON(@InputJson, '$.variables')
        WITH (
            [key]   NVARCHAR(200) '$.key',
            [type]  VARCHAR(20)   '$.type',
            [value] NVARCHAR(MAX) '$.value'
        ) v
        WHERE v.[key] IS NOT NULL;
-- =====================================================================
        -- 4) CHARGER LES RÈGLES DEMANDÉES DANS LE THREAD
        -- =====================================================================
        
        INSERT INTO #ThreadState ([Key], IsRule, State)
        SELECT 
            r.value,
            1,  -- IsRule = true
            0   -- State = NOT_EVALUATED
        FROM OPENJSON(@InputJson, '$.rules') r
        WHERE r.value IS NOT NULL
          AND EXISTS (SELECT 1 FROM dbo.RuleDefinitions rd WHERE rd.RuleCode = r.value AND rd.IsActive = 1);
        
        -- =====================================================================
        -- 5) EXÉCUTER LES RÈGLES (liste explicite, pas de pattern)
        -- =====================================================================
        
        DECLARE @RuleCode NVARCHAR(200);
        DECLARE @Result NVARCHAR(MAX);
        DECLARE @ErrorMsg NVARCHAR(500);
        
        DECLARE rule_cursor CURSOR LOCAL FAST_FORWARD FOR
        SELECT [Key] FROM #ThreadState WHERE IsRule = 1 AND State = 0 ORDER BY SeqId;
        
        OPEN rule_cursor;
        FETCH NEXT FROM rule_cursor INTO @RuleCode;
        
        WHILE @@FETCH_STATUS = 0
        BEGIN
            EXEC dbo.sp_ExecuteRule @RuleCode, @Result OUTPUT, @ErrorMsg OUTPUT;
            
            -- Compter succès/erreurs
            IF @ErrorMsg IS NULL
                SET @SuccessCount = @SuccessCount + 1;
            ELSE
                SET @ErrorCount = @ErrorCount + 1;
            
            FETCH NEXT FROM rule_cursor INTO @RuleCode;
        END
        
        CLOSE rule_cursor;
        DEALLOCATE rule_cursor;
        
        -- =====================================================================
        -- 6) CONSTRUIRE LA SORTIE JSON
        -- =====================================================================
        
        DECLARE @ResultsJson NVARCHAR(MAX);
        DECLARE @StateJson NVARCHAR(MAX) = NULL;
        DECLARE @DebugJson NVARCHAR(MAX) = NULL;
        
        -- Résultats des règles
        SELECT @ResultsJson = (
            SELECT 
                [Key] AS ruleCode,
                CASE State WHEN 2 THEN 'EVALUATED' WHEN 3 THEN 'ERROR' ELSE 'NOT_EVALUATED' END AS state,
                ScalarValue AS value,
                ErrorCategory AS errorCategory,
                ErrorCode AS errorCode
            FROM #ThreadState
            WHERE IsRule = 1
            ORDER BY SeqId
            FOR JSON PATH
        );
        
        -- Table d'état complète si demandée
        IF @ReturnStateTable = 1
        BEGIN
            SELECT @StateJson = (
                SELECT 
                    SeqId,
                    [Key],
                    CASE WHEN IsRule = 1 THEN 'RULE' ELSE 'VARIABLE' END AS type,
                    CASE State 
                        WHEN 0 THEN 'NOT_EVALUATED' 
                        WHEN 1 THEN 'EVALUATING' 
                        WHEN 2 THEN 'EVALUATED' 
                        WHEN 3 THEN 'ERROR' 
                    END AS state,
                    ScalarValue AS value,
                    ValueType AS valueType,
                    ErrorCategory AS errorCategory,
                    ErrorCode AS errorCode
                FROM #ThreadState
                ORDER BY SeqId
                FOR JSON PATH
            );
        END
        
        -- Logs debug si demandés
        IF @ReturnDebug = 1 AND @Mode = 'DEBUG' AND OBJECT_ID('tempdb..#ThreadDebug') IS NOT NULL
        BEGIN
            SELECT @DebugJson = (
                SELECT * FROM #ThreadDebug ORDER BY LogId FOR JSON PATH
            );
        END
        
        -- Construire JSON final
        SET @OutputJson = (
            SELECT
                'SUCCESS' AS status,
                @Mode AS mode,
                @SuccessCount AS rulesEvaluated,
                @ErrorCount AS rulesInError,
                DATEDIFF(MILLISECOND, @StartTime, SYSDATETIME()) AS durationMs,
                JSON_QUERY(@ResultsJson) AS results,
                JSON_QUERY(@StateJson) AS stateTable,
                JSON_QUERY(@DebugJson) AS debugLog
            FOR JSON PATH, WITHOUT_ARRAY_WRAPPER
        );
        
    END TRY
    BEGIN CATCH
        SET @OutputJson = (
            SELECT
                'ERROR' AS status,
                ERROR_MESSAGE() AS errorMessage,
                ERROR_NUMBER() AS errorNumber,
                DATEDIFF(MILLISECOND, @StartTime, SYSDATETIME()) AS durationMs
            FOR JSON PATH, WITHOUT_ARRAY_WRAPPER
        );
    END CATCH
END;
GO

PRINT '   OK';
PRINT '';
PRINT '══════════════════════════════════════════════════════════════════════';
PRINT '           INSTALLATION TERMINÉE - V6.1                               ';
PRINT '══════════════════════════════════════════════════════════════════════';
PRINT '';
PRINT '   Composants installés:';
PRINT '   - dbo.RuleDefinitions       (table)';
PRINT '   - dbo.fn_ExtractTokens      (fonction)';
PRINT '   - dbo.fn_ParseToken         (fonction)';
PRINT '   - dbo.sp_ResolveToken       (procédure)';
PRINT '   - dbo.sp_ExecuteRule        (procédure)';
PRINT '   - dbo.sp_RunRulesEngine     (runner JSON)';
PRINT '';
PRINT '   Usage:';
PRINT '   DECLARE @Output NVARCHAR(MAX);';
PRINT '   EXEC dbo.sp_RunRulesEngine @InputJson, @Output OUTPUT;';
PRINT '   SELECT @Output;';
GO
