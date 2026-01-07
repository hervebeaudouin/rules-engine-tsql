/***********************************************************************
    MOTEUR DE RÈGLES T-SQL - VERSION 6.2.3
    Conforme Spec V1.5.5 - CORRIGÉ ET OPTIMISÉ
    
    Compatibilité : SQL Server 2017+
    
    CORRECTIONS PAR RAPPORT À V6.2.2:
    ═════════════════════════════════════════════════════════════════════
    1. [BUG FIX] fn_ParseToken ligne 109: LIKE '%(_%)' incorrect
       - Problème: '_' est un wildcard LIKE (matche n'importe quel char)
       - Solution: Utiliser CHARINDEX + vérification fin par ')'
    
    2. [BUG FIX] JSONIFY ligne 266: échappement backslash no-op
       - Problème: REPLACE([Key], ''\'', ''\'') ne fait rien
       - Solution: REPLACE([Key], ''\'', ''\\') pour JSON valide
    
    3. [OPTIMISATION] Index sur #ThreadState pour patterns LIKE
    
    4. [OPTIMISATION] Index sur RuleDefinitions(IsActive)
    
    5. [ROBUSTESSE] Noms de curseurs uniques pour éviter conflits
    
    6. [ROBUSTESSE] Nettoyage curseurs garanti dans TRY/CATCH
    
    PRINCIPES NORMATIFS:
    - Token = {[AGGREGATEUR(]<pattern>[)]} (structure PLATE, pas imbriquée)
    - Le moteur orchestre, SQL calcule
    - États fermés: NOT_EVALUATED, EVALUATING, EVALUATED, ERROR
    - Ordre canonique = SeqId (ordre d'insertion)
    - Erreurs locales, thread continue
    - Agrégateur par défaut = FIRST
    - 17 agrégateurs fermés
    - Variables = littéraux atomiques (une clé = une valeur)
    - Runner JSON = orchestrateur neutre
    
    COLLATION: SQL_Latin1_General_CP1_CI_AS (case-insensitive)
************************************************************************/

SET NOCOUNT ON;
GO

PRINT '══════════════════════════════════════════════════════════════════════';
PRINT '           MOTEUR DE RÈGLES V6.2.3 - Spec V1.5.5 CORRIGÉ             ';
PRINT '══════════════════════════════════════════════════════════════════════';
PRINT '';
GO

-- =========================================================================
-- PARTIE 1 : NETTOYAGE
-- =========================================================================
PRINT '── Nettoyage ──';

IF OBJECT_ID('dbo.sp_RunRulesEngine','P') IS NOT NULL DROP PROCEDURE dbo.sp_RunRulesEngine;
IF OBJECT_ID('dbo.sp_ExecuteRulesAll','P') IS NOT NULL DROP PROCEDURE dbo.sp_ExecuteRulesAll;
IF OBJECT_ID('dbo.sp_ExecuteRule','P') IS NOT NULL DROP PROCEDURE dbo.sp_ExecuteRule;
IF OBJECT_ID('dbo.sp_ResolveToken','P') IS NOT NULL DROP PROCEDURE dbo.sp_ResolveToken;
IF OBJECT_ID('dbo.fn_ExtractTokens','IF') IS NOT NULL DROP FUNCTION dbo.fn_ExtractTokens;
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

-- Index pour recherche par pattern sur règles actives
CREATE NONCLUSTERED INDEX IX_RuleDefinitions_Active 
ON dbo.RuleDefinitions (IsActive) INCLUDE (RuleCode, Expression);

PRINT '   OK';
GO

-- =========================================================================
-- PARTIE 3 : FONCTION D'EXTRACTION DES TOKENS (Inline TVF + SCHEMABINDING)
-- =========================================================================
PRINT '── Fonctions ──';
GO

/*
    fn_ExtractTokens - Extrait tous les tokens {xxx} d'une expression
    
    Un token est une structure PLATE : {[AGGREGATEUR(]<pattern>[)]}
    Pas d'imbrication - {A}, {B}, {C} dans IIF({A}>0,{B},{C}) sont 3 tokens séparés
    
    V6.2.2 était correct, conservé tel quel
*/
CREATE FUNCTION dbo.fn_ExtractTokens(@Expr NVARCHAR(MAX))
RETURNS TABLE
WITH SCHEMABINDING
AS
RETURN
WITH
-- Générateur de nombres jusqu'à 65536 (expressions très longues supportées)
L0 AS (SELECT 1 AS c UNION ALL SELECT 1),
L1 AS (SELECT 1 AS c FROM L0 A CROSS JOIN L0 B),
L2 AS (SELECT 1 AS c FROM L1 A CROSS JOIN L1 B),
L3 AS (SELECT 1 AS c FROM L2 A CROSS JOIN L2 B),
L4 AS (SELECT 1 AS c FROM L3 A CROSS JOIN L3 B),
N(n) AS (SELECT TOP (ISNULL(LEN(@Expr), 0)) ROW_NUMBER() OVER (ORDER BY (SELECT NULL)) FROM L4),
-- Positions des accolades
Starts AS (SELECT n AS pos FROM N WHERE SUBSTRING(@Expr, n, 1) = '{'),
Ends AS (SELECT n AS pos FROM N WHERE SUBSTRING(@Expr, n, 1) = '}')
-- Pour chaque '{', trouver le premier '}' qui ne contient pas d'autre '{'
SELECT DISTINCT SUBSTRING(@Expr, s.pos, e.pos - s.pos + 1) AS Token
FROM Starts s
CROSS APPLY (SELECT MIN(pos) AS pos FROM Ends WHERE pos > s.pos) e
WHERE e.pos IS NOT NULL
  AND CHARINDEX('{', SUBSTRING(@Expr, s.pos + 1, e.pos - s.pos - 1)) = 0;
GO

-- =========================================================================
-- PARTIE 4 : FONCTION DE PARSING D'UN TOKEN (CORRIGÉE)
-- =========================================================================
GO

/*
    fn_ParseToken - Parse un token en ses composants
    
    Format: {[AGGREGATEUR(]<sélecteur>[)]}
    Où sélecteur = [Rule:]<pattern_like>
    
    CORRECTION V6.2.3:
    - Bug V6.2.2: LIKE '%(_%)' utilise '_' comme wildcard
    - Solution: CHARINDEX pour détecter 'xxx(yyy)' de manière fiable
*/
CREATE FUNCTION dbo.fn_ParseToken(@Token NVARCHAR(1000))
RETURNS TABLE
WITH SCHEMABINDING
AS
RETURN
WITH 
Cleaned AS (
    -- Retirer les accolades externes et trim
    SELECT LTRIM(RTRIM(SUBSTRING(@Token, 2, LEN(@Token) - 2))) AS TokenContent
),
Analysis AS (
    SELECT
        TokenContent,
        CHARINDEX('(', TokenContent) AS OpenParen,
        -- Vérifier si le dernier caractère est ')'
        CASE WHEN RIGHT(TokenContent, 1) = ')' THEN 1 ELSE 0 END AS EndsWithParen
    FROM Cleaned
),
Parsed AS (
    SELECT
        TokenContent,
        OpenParen,
        EndsWithParen,
        -- Un agrégateur valide = forme FUNC(xxx) avec FUNC reconnu
        CASE 
            WHEN OpenParen > 1 AND EndsWithParen = 1
                 AND UPPER(LEFT(TokenContent, OpenParen - 1)) IN (
                     'FIRST','SUM','AVG','MIN','MAX','COUNT',
                     'FIRST_POS','SUM_POS','AVG_POS','MIN_POS','MAX_POS','COUNT_POS',
                     'FIRST_NEG','SUM_NEG','AVG_NEG','MIN_NEG','MAX_NEG','COUNT_NEG',
                     'CONCAT','JSONIFY'
                 )
            THEN UPPER(LEFT(TokenContent, OpenParen - 1))
            ELSE 'FIRST'
        END AS Aggregator,
        CASE 
            WHEN OpenParen > 1 AND EndsWithParen = 1
                 AND UPPER(LEFT(TokenContent, OpenParen - 1)) IN (
                     'FIRST','SUM','AVG','MIN','MAX','COUNT',
                     'FIRST_POS','SUM_POS','AVG_POS','MIN_POS','MAX_POS','COUNT_POS',
                     'FIRST_NEG','SUM_NEG','AVG_NEG','MIN_NEG','MAX_NEG','COUNT_NEG',
                     'CONCAT','JSONIFY'
                 )
            THEN SUBSTRING(TokenContent, OpenParen + 1, LEN(TokenContent) - OpenParen - 1)
            ELSE TokenContent
        END AS Selector
    FROM Analysis
)
SELECT
    @Token AS Token,
    Aggregator,
    CASE WHEN UPPER(LEFT(LTRIM(Selector), 5)) = 'RULE:' THEN 1 ELSE 0 END AS IsRuleRef,
    CASE 
        WHEN UPPER(LEFT(LTRIM(Selector), 5)) = 'RULE:' 
        THEN LTRIM(RTRIM(SUBSTRING(Selector, 6, LEN(Selector))))
        ELSE LTRIM(RTRIM(Selector))
    END AS Pattern
FROM Parsed;
GO

PRINT '   OK';
GO

-- =========================================================================
-- PARTIE 5 : PROCÉDURES DU MOTEUR
-- =========================================================================
PRINT '── Procédures moteur ──';
GO

/*
    sp_ResolveToken - Résout un token {..} en valeur scalaire
    
    CORRECTIONS V6.2.3:
    - Noms de curseurs uniques (resolve_rule_cursor)
    - JSONIFY: échappement backslash correct (\\ au lieu de no-op)
    - TRY/CATCH avec nettoyage curseur garanti
*/
CREATE PROCEDURE dbo.sp_ResolveToken
    @Token NVARCHAR(1000),
    @Result NVARCHAR(MAX) OUTPUT,
    @CallerRuleCode NVARCHAR(200) = NULL
AS
BEGIN
    SET NOCOUNT ON;
    SET ANSI_WARNINGS OFF;  -- Supprime avertissements NULL dans agrégats (§8.4)
    
    DECLARE @Aggregator VARCHAR(20), @IsRuleRef BIT, @Pattern NVARCHAR(500);
    DECLARE @SQL NVARCHAR(MAX), @FilterCondition NVARCHAR(100) = '', @BaseAggregator VARCHAR(20);
    
    -- Parser le token
    SELECT @Aggregator = Aggregator, @IsRuleRef = IsRuleRef, @Pattern = Pattern
    FROM dbo.fn_ParseToken(@Token);
    
    -- Extraire base aggregator et filtre POS/NEG
    SET @BaseAggregator = @Aggregator;
    IF @Aggregator LIKE '%[_]POS'
    BEGIN
        SET @BaseAggregator = LEFT(@Aggregator, LEN(@Aggregator) - 4);
        SET @FilterCondition = N' AND TRY_CAST(ScalarValue AS DECIMAL(38,10)) > 0';
    END
    ELSE IF @Aggregator LIKE '%[_]NEG'
    BEGIN
        SET @BaseAggregator = LEFT(@Aggregator, LEN(@Aggregator) - 4);
        SET @FilterCondition = N' AND TRY_CAST(ScalarValue AS DECIMAL(38,10)) < 0';
    END
    
    -- Si référence à règles, découvrir/insérer/évaluer d'abord (lazy) — Spec v1.5.5
    IF @IsRuleRef = 1
    BEGIN
        -- 1) Découverte : garantir que toutes les règles matching @Pattern existent dans #ThreadState
        INSERT INTO #ThreadState ([Key], IsRule, State)
        SELECT rd.RuleCode, 1, 0
        FROM dbo.RuleDefinitions rd
        WHERE rd.IsActive = 1
          AND rd.RuleCode LIKE @Pattern
          AND NOT EXISTS (
                SELECT 1 FROM #ThreadState ts
                WHERE ts.IsRule = 1 AND ts.[Key] = rd.RuleCode
          );

        -- 2) Évaluation lazy : exécuter les règles NOT_EVALUATED
        DECLARE @RuleKey NVARCHAR(200), @RuleState TINYINT;
        DECLARE @RuleResult NVARCHAR(MAX), @RuleError NVARCHAR(500);

        -- Curseur avec nom unique pour éviter conflits en cas d'appels récursifs
        DECLARE resolve_rule_cursor CURSOR LOCAL FAST_FORWARD FOR
        SELECT [Key], State
        FROM #ThreadState
        WHERE IsRule = 1 AND [Key] LIKE @Pattern
        ORDER BY SeqId;

        OPEN resolve_rule_cursor;
        
        BEGIN TRY
            FETCH NEXT FROM resolve_rule_cursor INTO @RuleKey, @RuleState;
            
            WHILE @@FETCH_STATUS = 0
            BEGIN
                IF @RuleState = 0  -- NOT_EVALUATED : évaluer
                    EXEC dbo.sp_ExecuteRule @RuleKey, @RuleResult OUTPUT, @RuleError OUTPUT;
                ELSE IF @RuleState = 1  -- EVALUATING : récursion détectée
                BEGIN
                    -- Marquer la règle référencée en erreur (§8.1), sans arrêter le thread
                    UPDATE #ThreadState
                    SET State = 3,
                        ScalarValue = NULL,
                        ErrorCategory = 'RECURSION',
                        ErrorCode = CASE
                                      WHEN @CallerRuleCode IS NOT NULL AND @RuleKey = @CallerRuleCode THEN 'DIRECT'
                                      ELSE 'INDIRECT'
                                    END
                    WHERE [Key] = @RuleKey AND IsRule = 1;
                END
                -- State = 2 (EVALUATED) ou 3 (ERROR) : ne rien faire, valeur déjà disponible
                
                FETCH NEXT FROM resolve_rule_cursor INTO @RuleKey, @RuleState;
            END
            
            CLOSE resolve_rule_cursor;
            DEALLOCATE resolve_rule_cursor;
        END TRY
        BEGIN CATCH
            -- Nettoyage du curseur en cas d'erreur
            IF CURSOR_STATUS('local', 'resolve_rule_cursor') >= 0
            BEGIN
                CLOSE resolve_rule_cursor;
                DEALLOCATE resolve_rule_cursor;
            END
            ;THROW;
        END CATCH
    END

    -- Construire clause WHERE selon type (variable ou règle)
    DECLARE @WhereClause NVARCHAR(500);
    IF @IsRuleRef = 1
        SET @WhereClause = N'IsRule = 1 AND [Key] LIKE @P AND State = 2';
    ELSE
        SET @WhereClause = N'IsRule = 0 AND [Key] LIKE @P AND State = 2';
    
    -- Construire SQL selon agrégateur
    IF @BaseAggregator = 'FIRST'
        SET @SQL = N'SELECT TOP 1 @R = ScalarValue FROM #ThreadState WHERE ' + @WhereClause + @FilterCondition + N' AND ScalarValue IS NOT NULL ORDER BY SeqId';
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
        SET @SQL = N'SELECT @R = ISNULL(STRING_AGG(ScalarValue, N'','') WITHIN GROUP (ORDER BY SeqId), N'''') FROM #ThreadState WHERE ' + @WhereClause + N' AND ScalarValue IS NOT NULL';
    ELSE IF @BaseAggregator = 'JSONIFY'
        -- CORRECTION V6.2.3: Échappement JSON correct du backslash
        SET @SQL = N'
            ;WITH S AS (
                SELECT [Key],
                       CASE WHEN IsRule = 1 AND State = 3 THEN NULL ELSE ScalarValue END AS V,
                       SeqId
                FROM #ThreadState
                WHERE ' + @WhereClause + N'
            )
            SELECT @R =
                N''{'' +
                ISNULL(
                    STRING_AGG(
                        N''"'' + REPLACE(REPLACE([Key], N''\'', N''\\''), N''"'', N''\"'') + N''":'' +
                        CASE
                            WHEN V IS NULL THEN N''null''
                            ELSE N''"'' + REPLACE(REPLACE(V, N''\'', N''\\''), N''"'', N''\"'') + N''"''
                        END,
                        N'',''
                    ) WITHIN GROUP (ORDER BY SeqId),
                    N''''
                ) +
                N''}''
            FROM S';
    
    BEGIN TRY
        EXEC sp_executesql @SQL, N'@P NVARCHAR(500), @R NVARCHAR(MAX) OUTPUT', @Pattern, @Result OUTPUT;
    END TRY
    BEGIN CATCH
        SET @Result = NULL;
    END CATCH
    
    SET ANSI_WARNINGS ON;
END;
GO

/*
    sp_ExecuteRule - Évalue une règle (lazy, avec détection de cycle)
    
    CORRECTIONS V6.2.3:
    - Nom de curseur unique (exec_token_cursor)
    - Nettoyage curseur garanti en cas d'erreur
*/
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
    
    -- Récupérer config debug
    IF OBJECT_ID('tempdb..#ThreadConfig') IS NOT NULL
        SELECT @DebugMode = DebugMode FROM #ThreadConfig;
    
    -- Vérifier état actuel
    SELECT @State = State, @Result = ScalarValue
    FROM #ThreadState WHERE [Key] = @RuleCode AND IsRule = 1;
    
    -- EVALUATED : retourner valeur cachée
    IF @State = 2 
    BEGIN 
        SET @ErrorMsg = NULL; 
        RETURN; 
    END
    
    -- ERROR : retourner NULL avec message d'erreur
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
        SET @ErrorCode = 'DIRECT';
        SET @ErrorMsg = @ErrorCategory + '/' + @ErrorCode;
        SET @Result = NULL;
        UPDATE #ThreadState 
        SET State = 3, ScalarValue = NULL, ErrorCategory = @ErrorCategory, ErrorCode = @ErrorCode 
        WHERE [Key] = @RuleCode AND IsRule = 1;
        RETURN;
    END
    
    -- Passer à EVALUATING (détection cycle)
    UPDATE #ThreadState SET State = 1 WHERE [Key] = @RuleCode AND IsRule = 1;
    
    BEGIN TRY
        -- Récupérer expression depuis la définition
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
        
        -- Extraire et résoudre tous les tokens
        DECLARE exec_token_cursor CURSOR LOCAL FAST_FORWARD FOR
        SELECT Token FROM dbo.fn_ExtractTokens(@Expression);
        
        OPEN exec_token_cursor;
        
        BEGIN TRY
            FETCH NEXT FROM exec_token_cursor INTO @Token;
            
            WHILE @@FETCH_STATUS = 0
            BEGIN
                -- Résoudre le token (peut déclencher évaluation d'autres règles)
                EXEC dbo.sp_ResolveToken @Token, @TokenValue OUTPUT, @RuleCode;
                -- Substituer dans l'expression compilée
                SET @CompiledExpr = REPLACE(@CompiledExpr, @Token, ISNULL(@TokenValue, 'NULL'));
                FETCH NEXT FROM exec_token_cursor INTO @Token;
            END
            
            CLOSE exec_token_cursor;
            DEALLOCATE exec_token_cursor;
        END TRY
        BEGIN CATCH
            IF CURSOR_STATUS('local', 'exec_token_cursor') >= 0
            BEGIN
                CLOSE exec_token_cursor;
                DEALLOCATE exec_token_cursor;
            END
            ;THROW;
        END CATCH
        
        -- Vérifier si la règle est passée en ERROR pendant la résolution (récursion indirecte)
        SELECT @State = State FROM #ThreadState WHERE [Key] = @RuleCode AND IsRule = 1;
        IF @State = 3
        BEGIN
            SET @Result = NULL;
            SELECT @ErrorMsg = ErrorCategory + '/' + ErrorCode 
            FROM #ThreadState WHERE [Key] = @RuleCode AND IsRule = 1;
            RETURN;
        END
        
        -- Compilation finale : " -> ' (convention SQL)
        SET @CompiledExpr = REPLACE(@CompiledExpr, '"', '''');
        
        -- Exécuter le SQL compilé
        DECLARE @SQL NVARCHAR(MAX) = N'SELECT @R = ' + @CompiledExpr;
        EXEC sp_executesql @SQL, N'@R NVARCHAR(MAX) OUTPUT', @Result OUTPUT;
        
        -- Succès : passer à EVALUATED
        UPDATE #ThreadState 
        SET State = 2, ScalarValue = @Result, ErrorCategory = NULL, ErrorCode = NULL 
        WHERE [Key] = @RuleCode AND IsRule = 1;
        SET @ErrorMsg = NULL;
        
        -- Log debug si activé
        IF @DebugMode = 1 AND OBJECT_ID('tempdb..#ThreadDebug') IS NOT NULL
            INSERT INTO #ThreadDebug (RuleCode, Action, DurationMs, CompiledSQL) 
            VALUES (@RuleCode, 'EVALUATED', DATEDIFF(MILLISECOND, @StartTime, SYSDATETIME()), @CompiledExpr);
        
    END TRY
    BEGIN CATCH
        DECLARE @ErrMsg NVARCHAR(4000) = ERROR_MESSAGE();
        DECLARE @ErrNum INT = ERROR_NUMBER();
        
        -- Catégorisation des erreurs SQL
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
        
        -- Passer à ERROR
        UPDATE #ThreadState 
        SET State = 3, ScalarValue = NULL, ErrorCategory = @ErrorCategory, ErrorCode = @ErrorCode 
        WHERE [Key] = @RuleCode AND IsRule = 1;
        
        -- Log debug si activé
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
    sp_RunRulesEngine - Orchestrateur JSON (neutre)
    
    CORRECTIONS V6.2.3:
    - Index sur #ThreadState pour performance des patterns LIKE
    - Nom de curseur unique (runner_rule_cursor)
    - Variable @CursorOpen pour nettoyage garanti
    
    Rôle (neutre):
    1) Initialise le thread et ses tables temporaires
    2) Charge des variables atomiques
    3) Exécute une liste explicite de règles
    4) Retourne les résultats et l'état
    
    Le runner N'INTERPRÈTE JAMAIS:
    - tokens, agrégateurs, dépendances, patterns
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
    DECLARE @CursorOpen BIT = 0;
    
    BEGIN TRY
        -- =====================================================================
        -- 1) PARSER LE JSON D'ENTRÉE
        -- =====================================================================
        
        SET @Mode = ISNULL(JSON_VALUE(@InputJson, '$.mode'), 'NORMAL');
        IF @Mode NOT IN ('NORMAL', 'DEBUG') SET @Mode = 'NORMAL';
        
        SET @StopOnFatal = ISNULL(TRY_CAST(JSON_VALUE(@InputJson, '$.options.stopOnFatal') AS BIT), 0);
        SET @ReturnStateTable = ISNULL(TRY_CAST(JSON_VALUE(@InputJson, '$.options.returnStateTable') AS BIT), 1);
        SET @ReturnDebug = ISNULL(TRY_CAST(JSON_VALUE(@InputJson, '$.options.returnDebug') AS BIT), 0);
        
        -- =====================================================================
        -- 2) INITIALISER LE THREAD
        -- =====================================================================
        
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
        
        -- OPTIMISATION V6.2.3: Index pour les recherches par pattern LIKE
        CREATE NONCLUSTERED INDEX IX_ThreadState_RuleState 
        ON #ThreadState (IsRule, State) INCLUDE ([Key], ScalarValue, SeqId);
        
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
        -- 5) EXÉCUTER LES RÈGLES (liste explicite, ordre canonique SeqId)
        -- =====================================================================
        
        DECLARE @RuleCode NVARCHAR(200);
        DECLARE @Result NVARCHAR(MAX);
        DECLARE @ErrorMsg NVARCHAR(500);
        
        DECLARE runner_rule_cursor CURSOR LOCAL FAST_FORWARD FOR
        SELECT [Key] FROM #ThreadState WHERE IsRule = 1 AND State = 0 ORDER BY SeqId;
        
        OPEN runner_rule_cursor;
        SET @CursorOpen = 1;
        
        FETCH NEXT FROM runner_rule_cursor INTO @RuleCode;
        
        WHILE @@FETCH_STATUS = 0
        BEGIN
            EXEC dbo.sp_ExecuteRule @RuleCode, @Result OUTPUT, @ErrorMsg OUTPUT;
            
            IF @ErrorMsg IS NULL
                SET @SuccessCount = @SuccessCount + 1;
            ELSE
                SET @ErrorCount = @ErrorCount + 1;
            
            FETCH NEXT FROM runner_rule_cursor INTO @RuleCode;
        END
        
        CLOSE runner_rule_cursor;
        DEALLOCATE runner_rule_cursor;
        SET @CursorOpen = 0;
        
        -- =====================================================================
        -- 6) CONSTRUIRE LA SORTIE JSON
        -- =====================================================================
        
        DECLARE @ResultsJson NVARCHAR(MAX);
        DECLARE @StateJson NVARCHAR(MAX) = NULL;
        DECLARE @DebugJson NVARCHAR(MAX) = NULL;
        
        -- Résultats des règles (ordre canonique)
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
        
        -- JSON final
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
        -- Nettoyage du curseur si ouvert
        IF @CursorOpen = 1 AND CURSOR_STATUS('local', 'runner_rule_cursor') >= 0
        BEGIN
            CLOSE runner_rule_cursor;
            DEALLOCATE runner_rule_cursor;
        END
        
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
PRINT '           INSTALLATION TERMINÉE - V6.2.3                             ';
PRINT '══════════════════════════════════════════════════════════════════════';
PRINT '';
PRINT '   Composants installés:';
PRINT '   - dbo.RuleDefinitions       (table + index)';
PRINT '   - dbo.fn_ExtractTokens      (fonction - inchangée)';
PRINT '   - dbo.fn_ParseToken         (fonction CORRIGÉE - sans wildcard LIKE)';
PRINT '   - dbo.sp_ResolveToken       (procédure CORRIGÉE - JSONIFY + curseurs)';
PRINT '   - dbo.sp_ExecuteRule        (procédure ROBUSTIFIÉE - curseurs sécurisés)';
PRINT '   - dbo.sp_RunRulesEngine     (runner JSON OPTIMISÉ - index + cleanup)';
PRINT '';
PRINT '   Corrections V6.2.3:';
PRINT '   - fn_ParseToken: LIKE ''%(_%)'' remplacé par CHARINDEX (bug wildcard)';
PRINT '   - JSONIFY: échappement backslash corrigé (\\ au lieu de no-op)';
PRINT '   - Curseurs: noms uniques + nettoyage garanti en TRY/CATCH';
PRINT '   - Index: #ThreadState et RuleDefinitions pour performance';
PRINT '';
PRINT '   Usage:';
PRINT '   DECLARE @Output NVARCHAR(MAX);';
PRINT '   EXEC dbo.sp_RunRulesEngine @InputJson, @Output OUTPUT;';
PRINT '   SELECT @Output;';
GO
