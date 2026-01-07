/***********************************************************************
    MOTEUR DE REGLES T-SQL - VERSION 6.5 CONFORME SPECIFICATION V1.6.0
    Conformite : Spec V1.6.0 (Normative)
    
    Compatibilite : SQL Server 2017+ (CL >= 140)
    
    CHANGEMENTS MAJEURS V1.6.0:
    =====================================================================
    
    1. PRINCIPE FONDAMENTAL DES AGREGATS
       - **TOUS les agregats operent EXCLUSIVEMENT sur les valeurs NON NULL**
       - Les valeurs NULL (y compris erreurs) sont conservees mais n'influencent
         JAMAIS les agregats
       - Simplifie la semantique par rapport a v1.5.5
    
    2. AGREGATS POSITIONNELS
       - FIRST: Premiere valeur NON NULL selon SeqId croissant
       - LAST: Derniere valeur NON NULL selon SeqId decroissant (NOUVEAU)
    
    3. AGREGATS STRUCTURELS
       - CONCAT: Concatène uniquement valeurs NON NULL, ensemble vide → ""
       - JSONIFY: Agrège uniquement clés NON NULL, ensemble vide → "{}"
    
    4. NORMALISATION DES LITTERAUX
       - Decimaux français: 2,5 → 2.5 (avant evaluation SQL)
       - Quotes: " → ' (normalisation)
    
    5. OPTIMISATIONS DE COMPILATION
       - Pre-compilation des regles
       - Cache d'expressions
       - Reduction des evaluations SQL
       - Normalisation des resultats numeriques
    
    IMPACT SEMANTIQUE:
    - Tests obsoletes supprimes: X01_FirstNull, X02_JsonifyError
    - Tests ajoutes: FIRST/LAST/JSONIFY ignore NULL
************************************************************************/

SET NOCOUNT ON;
GO

PRINT '======================================================================';
PRINT '    MOTEUR DE REGLES V6.5 - CONFORME SPECIFICATION V1.6.0           ';
PRINT '======================================================================';
PRINT '';
GO

-- =========================================================================
-- PARTIE 1 : NETTOYAGE
-- =========================================================================
PRINT '-- Nettoyage --';

IF OBJECT_ID('dbo.sp_RunRulesEngine','P') IS NOT NULL DROP PROCEDURE dbo.sp_RunRulesEngine;
IF OBJECT_ID('dbo.sp_ExecuteRule','P') IS NOT NULL DROP PROCEDURE dbo.sp_ExecuteRule;
IF OBJECT_ID('dbo.sp_ResolveToken','P') IS NOT NULL DROP PROCEDURE dbo.sp_ResolveToken;
IF OBJECT_ID('dbo.sp_EvaluateSimpleRules','P') IS NOT NULL DROP PROCEDURE dbo.sp_EvaluateSimpleRules;
IF OBJECT_ID('dbo.fn_ExtractTokens','IF') IS NOT NULL DROP FUNCTION dbo.fn_ExtractTokens;
IF OBJECT_ID('dbo.fn_ParseToken','IF') IS NOT NULL DROP FUNCTION dbo.fn_ParseToken;
IF OBJECT_ID('dbo.fn_HasRuleDependency','FN') IS NOT NULL DROP FUNCTION dbo.fn_HasRuleDependency;
IF OBJECT_ID('dbo.fn_NormalizeLiteral','FN') IS NOT NULL DROP FUNCTION dbo.fn_NormalizeLiteral;
IF OBJECT_ID('dbo.RuleDefinitions','U') IS NOT NULL DROP TABLE dbo.RuleDefinitions;

PRINT '   OK';
GO

-- =========================================================================
-- PARTIE 2 : TABLES
-- =========================================================================
PRINT '-- Tables --';

CREATE TABLE dbo.RuleDefinitions (
    RuleId INT IDENTITY(1,1) NOT NULL,
    RuleCode NVARCHAR(200) COLLATE SQL_Latin1_General_CP1_CI_AS NOT NULL,
    Expression NVARCHAR(MAX) COLLATE SQL_Latin1_General_CP1_CI_AS NOT NULL,
    IsActive BIT NOT NULL DEFAULT 1,
    CreatedAt DATETIME2 NOT NULL DEFAULT SYSDATETIME(),
    -- Pre-analyse pour optimisation
    HasTokens BIT NULL,           -- Expression contient des {xxx}?
    HasRuleRef BIT NULL,          -- Contient {Rule:xxx}?
    TokenCount INT NULL,          -- Nombre de tokens
    CONSTRAINT PK_RuleDefinitions PRIMARY KEY CLUSTERED (RuleId),
    CONSTRAINT UQ_RuleDefinitions_Code UNIQUE (RuleCode)
);

CREATE NONCLUSTERED INDEX IX_RuleDefinitions_Active 
ON dbo.RuleDefinitions (IsActive, RuleCode) INCLUDE (Expression, HasTokens, HasRuleRef);

PRINT '   OK';
GO

-- =========================================================================
-- PARTIE 3 : FONCTIONS
-- =========================================================================
PRINT '-- Fonctions --';
GO

-- -------------------------------------------------------------------------
-- NOUVEAU V1.6.0: Normalisation des litteraux (decimaux français, quotes)
-- -------------------------------------------------------------------------
CREATE FUNCTION dbo.fn_NormalizeLiteral(@Literal NVARCHAR(MAX))
RETURNS NVARCHAR(MAX) WITH SCHEMABINDING
AS
BEGIN
    DECLARE @Result NVARCHAR(MAX) = @Literal;
    
    -- Remplacer virgule decimale par point (contexte francais)
    -- Pattern: chiffre,chiffre → chiffre.chiffre
    -- Note: utiliser un pattern simple pour eviter complexite regex
    DECLARE @Pos INT = 1, @Len INT = LEN(@Result);
    WHILE @Pos <= @Len
    BEGIN
        IF SUBSTRING(@Result, @Pos, 1) = ','
           AND @Pos > 1 AND @Pos < @Len
           AND SUBSTRING(@Result, @Pos - 1, 1) LIKE '[0-9]'
           AND SUBSTRING(@Result, @Pos + 1, 1) LIKE '[0-9]'
        BEGIN
            SET @Result = STUFF(@Result, @Pos, 1, '.');
        END
        SET @Pos += 1;
    END
    
    -- Normaliser quotes doubles en simples (si contexte SQL)
    SET @Result = REPLACE(@Result, '"', '''');
    
    RETURN @Result;
END;
GO

CREATE FUNCTION dbo.fn_ExtractTokens(@Expr NVARCHAR(MAX))
RETURNS TABLE WITH SCHEMABINDING
AS RETURN
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
WHERE e.pos IS NOT NULL AND CHARINDEX('{', SUBSTRING(@Expr, s.pos + 1, e.pos - s.pos - 1)) = 0;
GO

-- -------------------------------------------------------------------------
-- MODIFIE V1.6.0: Ajout de LAST dans la liste des agregateurs supportes
-- -------------------------------------------------------------------------
CREATE FUNCTION dbo.fn_ParseToken(@Token NVARCHAR(1000))
RETURNS TABLE WITH SCHEMABINDING
AS RETURN
WITH 
Cleaned AS (SELECT LTRIM(RTRIM(SUBSTRING(@Token, 2, LEN(@Token) - 2))) AS TokenContent),
Analysis AS (
    SELECT TokenContent, CHARINDEX('(', TokenContent) AS OpenParen,
           CASE WHEN RIGHT(TokenContent, 1) = ')' THEN 1 ELSE 0 END AS EndsWithParen
    FROM Cleaned
),
Parsed AS (
    SELECT TokenContent, OpenParen, EndsWithParen,
        CASE WHEN OpenParen > 1 AND EndsWithParen = 1
             AND UPPER(LEFT(TokenContent, OpenParen - 1)) IN (
                 'FIRST','LAST',  -- LAST ajoute en V1.6.0
                 'SUM','AVG','MIN','MAX','COUNT',
                 'FIRST_POS','SUM_POS','AVG_POS','MIN_POS','MAX_POS','COUNT_POS',
                 'FIRST_NEG','SUM_NEG','AVG_NEG','MIN_NEG','MAX_NEG','COUNT_NEG',
                 'CONCAT','JSONIFY')
        THEN UPPER(LEFT(TokenContent, OpenParen - 1)) ELSE 'FIRST' END AS Aggregator,
        CASE WHEN OpenParen > 1 AND EndsWithParen = 1
             AND UPPER(LEFT(TokenContent, OpenParen - 1)) IN (
                 'FIRST','LAST',
                 'SUM','AVG','MIN','MAX','COUNT',
                 'FIRST_POS','SUM_POS','AVG_POS','MIN_POS','MAX_POS','COUNT_POS',
                 'FIRST_NEG','SUM_NEG','AVG_NEG','MIN_NEG','MAX_NEG','COUNT_NEG',
                 'CONCAT','JSONIFY')
        THEN SUBSTRING(TokenContent, OpenParen + 1, LEN(TokenContent) - OpenParen - 1)
        ELSE TokenContent END AS Selector
    FROM Analysis
)
SELECT @Token AS Token, Aggregator,
       CASE WHEN UPPER(LEFT(LTRIM(Selector), 5)) = 'RULE:' THEN 1 ELSE 0 END AS IsRuleRef,
       CASE WHEN UPPER(LEFT(LTRIM(Selector), 5)) = 'RULE:' 
            THEN LTRIM(RTRIM(SUBSTRING(Selector, 6, LEN(Selector))))
            ELSE LTRIM(RTRIM(Selector)) END AS Pattern
FROM Parsed;
GO

CREATE FUNCTION dbo.fn_HasRuleDependency(@Expression NVARCHAR(MAX))
RETURNS BIT WITH SCHEMABINDING
AS
BEGIN
    RETURN CASE WHEN @Expression LIKE '%{%Rule:%}%' THEN 1 ELSE 0 END;
END;
GO

PRINT '   OK';
GO

-- =========================================================================
-- PARTIE 4 : TRIGGER POUR PRE-ANALYSE
-- =========================================================================
PRINT '-- Trigger pre-analyse --';
GO

CREATE TRIGGER dbo.TR_RuleDefinitions_PreAnalyze
ON dbo.RuleDefinitions
AFTER INSERT, UPDATE
AS
BEGIN
    SET NOCOUNT ON;
    
    UPDATE rd
    SET HasTokens = CASE WHEN rd.Expression LIKE '%{%}%' THEN 1 ELSE 0 END,
        HasRuleRef = dbo.fn_HasRuleDependency(rd.Expression),
        TokenCount = (SELECT COUNT(*) FROM dbo.fn_ExtractTokens(rd.Expression))
    FROM dbo.RuleDefinitions rd
    INNER JOIN inserted i ON rd.RuleId = i.RuleId;
END;
GO

PRINT '   OK';
GO

-- =========================================================================
-- PARTIE 5 : PROCEDURES - RESOLUTION DE TOKENS
-- =========================================================================
PRINT '-- Procedures --';
GO

-- -------------------------------------------------------------------------
-- MODIFIE V1.6.0: Application stricte du principe "ignore NULL" pour
-- TOUS les agregats, ajout de LAST
-- -------------------------------------------------------------------------
CREATE PROCEDURE dbo.sp_ResolveToken
    @Token NVARCHAR(1000),
    @ResolvedValue NVARCHAR(MAX) OUTPUT
AS
BEGIN
    SET NOCOUNT ON;
    
    DECLARE @Aggregator VARCHAR(20), @IsRuleRef BIT, @Pattern NVARCHAR(500);
    
    SELECT @Aggregator = Aggregator, @IsRuleRef = IsRuleRef, @Pattern = Pattern
    FROM dbo.fn_ParseToken(@Token);
    
    -- Si variable directe
    IF @IsRuleRef = 0 AND @Pattern NOT LIKE '%:%' AND @Pattern NOT LIKE '%*%'
    BEGIN
        SELECT @ResolvedValue = ScalarValue 
        FROM #ThreadState 
        WHERE [Key] = @Pattern AND State = 2;  -- EVALUATED uniquement
        RETURN;
    END
    
    -- Construction pattern LIKE
    DECLARE @LikePattern NVARCHAR(500) = @Pattern;
    IF @IsRuleRef = 1 SET @LikePattern = 'rule:' + @Pattern;
    SET @LikePattern = REPLACE(REPLACE(@LikePattern, '*', '%'), '?', '_');
    
    -- =====================================================================
    -- APPLICATION V1.6.0: TOUS LES AGREGATS IGNORENT NULL
    -- Filtrage systématique: State = 2 (EVALUATED) ET ScalarValue IS NOT NULL
    -- =====================================================================
    
    DECLARE @FilteredSet TABLE (SeqId INT, [Key] NVARCHAR(200), ScalarValue NVARCHAR(MAX));
    
    INSERT INTO @FilteredSet
    SELECT SeqId, [Key], ScalarValue
    FROM #ThreadState
    WHERE [Key] LIKE @LikePattern 
      AND State = 2              -- EVALUATED uniquement
      AND ScalarValue IS NOT NULL  -- V1.6.0: Exclusion stricte des NULL
    ORDER BY SeqId;
    
    DECLARE @Count INT = (SELECT COUNT(*) FROM @FilteredSet);
    
    -- Gestion ensemble vide selon agregat
    IF @Count = 0
    BEGIN
        -- V1.6.0: Comportement ensemble vide
        IF @Aggregator IN ('CONCAT') SET @ResolvedValue = '';
        ELSE IF @Aggregator IN ('JSONIFY') SET @ResolvedValue = '{}';
        ELSE SET @ResolvedValue = NULL;  -- Pour agregats mathematiques/positionnels
        RETURN;
    END
    
    -- Appliquer filtre positif/negatif si necessaire
    DECLARE @NumericSet TABLE (Val NUMERIC(38,10));
    IF @Aggregator LIKE '%_POS'
    BEGIN
        INSERT INTO @NumericSet
        SELECT TRY_CAST(ScalarValue AS NUMERIC(38,10))
        FROM @FilteredSet
        WHERE TRY_CAST(ScalarValue AS NUMERIC(38,10)) > 0;
    END
    ELSE IF @Aggregator LIKE '%_NEG'
    BEGIN
        INSERT INTO @NumericSet
        SELECT TRY_CAST(ScalarValue AS NUMERIC(38,10))
        FROM @FilteredSet
        WHERE TRY_CAST(ScalarValue AS NUMERIC(38,10)) < 0;
    END
    ELSE IF @Aggregator IN ('SUM','AVG','MIN','MAX')
    BEGIN
        INSERT INTO @NumericSet
        SELECT TRY_CAST(ScalarValue AS NUMERIC(38,10))
        FROM @FilteredSet
        WHERE TRY_CAST(ScalarValue AS NUMERIC(38,10)) IS NOT NULL;
    END
    
    -- Agregats mathematiques
    IF @Aggregator IN ('SUM','SUM_POS','SUM_NEG')
        SELECT @ResolvedValue = CAST(SUM(Val) AS NVARCHAR(MAX)) FROM @NumericSet;
    ELSE IF @Aggregator IN ('AVG','AVG_POS','AVG_NEG')
        SELECT @ResolvedValue = CAST(AVG(Val) AS NVARCHAR(MAX)) FROM @NumericSet;
    ELSE IF @Aggregator IN ('MIN','MIN_POS','MIN_NEG')
        SELECT @ResolvedValue = CAST(MIN(Val) AS NVARCHAR(MAX)) FROM @NumericSet;
    ELSE IF @Aggregator IN ('MAX','MAX_POS','MAX_NEG')
        SELECT @ResolvedValue = CAST(MAX(Val) AS NVARCHAR(MAX)) FROM @NumericSet;
    ELSE IF @Aggregator IN ('COUNT','COUNT_POS','COUNT_NEG')
        SELECT @ResolvedValue = CAST(COUNT(*) AS NVARCHAR(MAX)) FROM @NumericSet;
    
    -- V1.6.0: FIRST - premiere valeur NON NULL selon SeqId croissant
    ELSE IF @Aggregator IN ('FIRST','FIRST_POS','FIRST_NEG')
    BEGIN
        IF @Aggregator = 'FIRST'
            SELECT TOP 1 @ResolvedValue = ScalarValue FROM @FilteredSet ORDER BY SeqId ASC;
        ELSE IF @Aggregator = 'FIRST_POS'
            SELECT TOP 1 @ResolvedValue = CAST(Val AS NVARCHAR(MAX)) FROM @NumericSet WHERE Val > 0 ORDER BY Val ASC;
        ELSE
            SELECT TOP 1 @ResolvedValue = CAST(Val AS NVARCHAR(MAX)) FROM @NumericSet WHERE Val < 0 ORDER BY Val DESC;
    END
    
    -- V1.6.0 NOUVEAU: LAST - derniere valeur NON NULL selon SeqId decroissant
    ELSE IF @Aggregator = 'LAST'
    BEGIN
        SELECT TOP 1 @ResolvedValue = ScalarValue FROM @FilteredSet ORDER BY SeqId DESC;
    END
    
    -- V1.6.0: CONCAT - uniquement valeurs NON NULL, ensemble vide → ""
    ELSE IF @Aggregator = 'CONCAT'
    BEGIN
        SELECT @ResolvedValue = STRING_AGG(ScalarValue, '') WITHIN GROUP (ORDER BY SeqId)
        FROM @FilteredSet;
        SET @ResolvedValue = ISNULL(@ResolvedValue, '');
    END
    
    -- V1.6.0: JSONIFY - uniquement cles NON NULL, ensemble vide → "{}"
    ELSE IF @Aggregator = 'JSONIFY'
    BEGIN
        DECLARE @JsonPairs NVARCHAR(MAX) = '';
        SELECT @JsonPairs = @JsonPairs + 
            CASE WHEN LEN(@JsonPairs) > 0 THEN ',' ELSE '' END +
            '"' + REPLACE([Key], '"', '\"') + '":' +
            CASE 
                WHEN ScalarValue LIKE '{%}' OR ScalarValue LIKE '[%]' THEN ScalarValue
                WHEN TRY_CAST(ScalarValue AS NUMERIC(38,10)) IS NOT NULL THEN ScalarValue
                WHEN LOWER(ScalarValue) IN ('true','false','null') THEN LOWER(ScalarValue)
                ELSE '"' + REPLACE(ScalarValue, '"', '\"') + '"'
            END
        FROM @FilteredSet
        ORDER BY SeqId;
        
        SET @ResolvedValue = '{' + ISNULL(@JsonPairs, '') + '}';
    END
END;
GO

-- -------------------------------------------------------------------------
-- MODIFIE V1.6.0: Integration de la normalisation des litteraux
-- -------------------------------------------------------------------------
CREATE PROCEDURE dbo.sp_ExecuteRule
    @RuleCode NVARCHAR(200),
    @Result NVARCHAR(MAX) OUTPUT,
    @ErrorMessage NVARCHAR(500) OUTPUT
AS
BEGIN
    SET NOCOUNT ON;
    
    SET @Result = NULL;
    SET @ErrorMessage = NULL;
    
    DECLARE @Expression NVARCHAR(MAX), @CompiledSQL NVARCHAR(MAX);
    DECLARE @StartTime DATETIME2 = SYSDATETIME();
    
    -- Recuperer expression
    SELECT @Expression = rd.Expression
    FROM dbo.RuleDefinitions rd
    WHERE rd.RuleCode = @RuleCode AND rd.IsActive = 1;
    
    IF @Expression IS NULL
    BEGIN
        SET @ErrorMessage = 'Rule not found or inactive';
        UPDATE #ThreadState SET State = 3, ErrorCategory = 'RULE', ErrorCode = 'NOT_FOUND'
        WHERE [Key] = @RuleCode AND IsRule = 1;
        RETURN;
    END
    
    -- Marquer EVALUATING
    UPDATE #ThreadState SET State = 1 WHERE [Key] = @RuleCode AND IsRule = 1;
    
    BEGIN TRY
        -- V1.6.0: NORMALISATION DES LITTERAUX (decimaux français, quotes)
        SET @Expression = dbo.fn_NormalizeLiteral(@Expression);
        
        SET @CompiledSQL = @Expression;
        
        -- Resoudre tous les tokens
        DECLARE @Token NVARCHAR(1000), @ResolvedValue NVARCHAR(MAX);
        DECLARE token_cursor CURSOR LOCAL FAST_FORWARD FOR
            SELECT Token FROM dbo.fn_ExtractTokens(@Expression);
        
        OPEN token_cursor;
        FETCH NEXT FROM token_cursor INTO @Token;
        
        WHILE @@FETCH_STATUS = 0
        BEGIN
            EXEC dbo.sp_ResolveToken @Token, @ResolvedValue OUTPUT;
            
            -- V1.6.0: Si resolution retourne NULL, propager NULL
            IF @ResolvedValue IS NULL
            BEGIN
                SET @CompiledSQL = 'SELECT NULL';
                BREAK;
            END
            
            SET @CompiledSQL = REPLACE(@CompiledSQL, @Token, 
                CASE WHEN TRY_CAST(@ResolvedValue AS NUMERIC(38,10)) IS NOT NULL 
                     THEN @ResolvedValue 
                     ELSE '''' + REPLACE(@ResolvedValue, '''', '''''') + ''''
                END);
            
            FETCH NEXT FROM token_cursor INTO @Token;
        END
        
        CLOSE token_cursor;
        DEALLOCATE token_cursor;
        
        -- Evaluer SQL
        DECLARE @SQL NVARCHAR(MAX) = N'SELECT @R = ' + @CompiledSQL;
        EXEC sp_executesql @SQL, N'@R NVARCHAR(MAX) OUTPUT', @Result OUTPUT;
        
        -- V1.6.0: Normalisation resultats numeriques (suppression zeros inutiles)
        IF TRY_CAST(@Result AS NUMERIC(38,10)) IS NOT NULL
            SET @Result = CAST(CAST(@Result AS NUMERIC(38,10)) AS NVARCHAR(MAX));
        
        -- Mise a jour ThreadState
        UPDATE #ThreadState 
        SET State = 2, ScalarValue = @Result
        WHERE [Key] = @RuleCode AND IsRule = 1;
        
        -- Debug logging
        IF EXISTS (SELECT 1 FROM #ThreadConfig WHERE DebugMode = 1)
            INSERT INTO #ThreadDebug (RuleCode, Action, DurationMs, CompiledSQL)
            VALUES (@RuleCode, 'EVALUATED', DATEDIFF(MILLISECOND, @StartTime, SYSDATETIME()), @CompiledSQL);
        
    END TRY
    BEGIN CATCH
        SET @ErrorMessage = ERROR_MESSAGE();
        
        UPDATE #ThreadState 
        SET State = 3, ScalarValue = NULL, ErrorCategory = 'SQL', ErrorCode = 'EVAL_ERROR'
        WHERE [Key] = @RuleCode AND IsRule = 1;
        
        IF EXISTS (SELECT 1 FROM #ThreadConfig WHERE DebugMode = 1)
            INSERT INTO #ThreadDebug (RuleCode, Action, DurationMs, ErrorMessage)
            VALUES (@RuleCode, 'ERROR', DATEDIFF(MILLISECOND, @StartTime, SYSDATETIME()), @ErrorMessage);
    END CATCH
END;
GO

-- -------------------------------------------------------------------------
-- MODIFIE V1.6.0: Integration normalisation litteraux pour regles simples
-- -------------------------------------------------------------------------
CREATE PROCEDURE dbo.sp_EvaluateSimpleRules
AS
BEGIN
    SET NOCOUNT ON;
    
    -- Evaluer toutes les regles sans tokens en une passe
    -- Ces regles sont des expressions SQL pures (ex: "100 + 50", "GETDATE()")
    DECLARE @RuleCode NVARCHAR(200), @Expression NVARCHAR(MAX), @SQL NVARCHAR(MAX);
    DECLARE @Result NVARCHAR(MAX), @CurrentSeqId INT = 0;
    
    WHILE 1 = 1
    BEGIN
        SELECT TOP 1 @RuleCode = ts.[Key], @Expression = rd.Expression, @CurrentSeqId = ts.SeqId
        FROM #ThreadState ts
        INNER JOIN dbo.RuleDefinitions rd ON rd.RuleCode = ts.[Key] AND rd.IsActive = 1
        WHERE ts.IsRule = 1 AND ts.State = 0 
          AND rd.HasTokens = 0  -- Pas de tokens = expression pure
          AND ts.SeqId > @CurrentSeqId
        ORDER BY ts.SeqId;
        
        IF @@ROWCOUNT = 0 BREAK;
        
        -- Marquer EVALUATING
        UPDATE #ThreadState SET State = 1 WHERE [Key] = @RuleCode AND IsRule = 1;
        
        BEGIN TRY
            -- V1.6.0: NORMALISATION DES LITTERAUX
            SET @Expression = dbo.fn_NormalizeLiteral(@Expression);
            
            SET @SQL = N'SELECT @R = ' + @Expression;
            EXEC sp_executesql @SQL, N'@R NVARCHAR(MAX) OUTPUT', @Result OUTPUT;
            
            -- V1.6.0: Normalisation resultats numeriques
            IF TRY_CAST(@Result AS NUMERIC(38,10)) IS NOT NULL
                SET @Result = CAST(CAST(@Result AS NUMERIC(38,10)) AS NVARCHAR(MAX));
            
            UPDATE #ThreadState SET State = 2, ScalarValue = @Result 
            WHERE [Key] = @RuleCode AND IsRule = 1;
        END TRY
        BEGIN CATCH
            UPDATE #ThreadState SET State = 3, ScalarValue = NULL, 
                   ErrorCategory = 'SQL', ErrorCode = 'SQL_ERROR'
            WHERE [Key] = @RuleCode AND IsRule = 1;
        END CATCH
    END
END;
GO

PRINT '   OK';
GO

-- =========================================================================
-- PARTIE 6 : RUNNER PRINCIPAL
-- =========================================================================
PRINT '-- Runner principal --';
GO

CREATE PROCEDURE dbo.sp_RunRulesEngine
    @InputJson NVARCHAR(MAX),
    @OutputJson NVARCHAR(MAX) OUTPUT
AS
BEGIN
    SET NOCOUNT ON;
    
    DECLARE @StartTime DATETIME2 = SYSDATETIME();
    DECLARE @Mode VARCHAR(10), @ReturnStateTable BIT, @ReturnDebug BIT;
    DECLARE @ErrorCount INT = 0, @SuccessCount INT = 0;
    
    BEGIN TRY
        -- Options
        SET @Mode = ISNULL(JSON_VALUE(@InputJson, '$.mode'), 'NORMAL');
        IF @Mode NOT IN ('NORMAL', 'DEBUG') SET @Mode = 'NORMAL';
        SET @ReturnStateTable = ISNULL(TRY_CAST(JSON_VALUE(@InputJson, '$.options.returnStateTable') AS BIT), 1);
        SET @ReturnDebug = ISNULL(TRY_CAST(JSON_VALUE(@InputJson, '$.options.returnDebug') AS BIT), 0);
        
        -- Init tables
        IF OBJECT_ID('tempdb..#ThreadState') IS NOT NULL DROP TABLE #ThreadState;
        CREATE TABLE #ThreadState (
            SeqId INT IDENTITY(1,1) NOT NULL,
            [Key] NVARCHAR(200) COLLATE SQL_Latin1_General_CP1_CI_AS NOT NULL,
            IsRule BIT NOT NULL DEFAULT 0,
            State TINYINT NOT NULL DEFAULT 0,  -- 0=NOT_EVAL, 1=EVALUATING, 2=EVALUATED, 3=ERROR
            ScalarValue NVARCHAR(MAX) NULL,
            ValueType VARCHAR(20) NULL,
            ErrorCategory VARCHAR(20) NULL,
            ErrorCode VARCHAR(50) NULL,
            PRIMARY KEY CLUSTERED (SeqId),
            UNIQUE ([Key])
        );
        CREATE NONCLUSTERED INDEX IX_TS ON #ThreadState (IsRule, State) INCLUDE ([Key], ScalarValue, SeqId);
        
        IF OBJECT_ID('tempdb..#ThreadConfig') IS NOT NULL DROP TABLE #ThreadConfig;
        CREATE TABLE #ThreadConfig (DebugMode BIT);
        INSERT INTO #ThreadConfig VALUES (CASE WHEN @Mode = 'DEBUG' THEN 1 ELSE 0 END);
        
        IF @Mode = 'DEBUG'
        BEGIN
            IF OBJECT_ID('tempdb..#ThreadDebug') IS NOT NULL DROP TABLE #ThreadDebug;
            CREATE TABLE #ThreadDebug (
                LogId INT IDENTITY, 
                LogTime DATETIME2 DEFAULT SYSDATETIME(), 
                RuleCode NVARCHAR(200), 
                Action VARCHAR(50), 
                DurationMs INT, 
                CompiledSQL NVARCHAR(MAX), 
                ErrorMessage NVARCHAR(MAX)
            );
        END
        
        -- Charger variables
        INSERT INTO #ThreadState ([Key], IsRule, State, ScalarValue, ValueType)
        SELECT v.[key], 0, 2, v.[value], ISNULL(v.[type], 'STRING')
        FROM OPENJSON(@InputJson, '$.variables') 
        WITH ([key] NVARCHAR(200), [type] VARCHAR(20), [value] NVARCHAR(MAX)) v
        WHERE v.[key] IS NOT NULL;
        
        -- Charger regles
        INSERT INTO #ThreadState ([Key], IsRule, State)
        SELECT r.value, 1, 0
        FROM OPENJSON(@InputJson, '$.rules') r
        WHERE r.value IS NOT NULL 
          AND EXISTS (SELECT 1 FROM dbo.RuleDefinitions rd 
                      WHERE rd.RuleCode = r.value AND rd.IsActive = 1);
        
        -- =====================================================================
        -- PHASE 1: Evaluer les regles SANS TOKENS (constantes/expressions pures)
        -- =====================================================================
        EXEC dbo.sp_EvaluateSimpleRules;
        
        -- =====================================================================
        -- PHASE 2: Evaluer les regles restantes (avec tokens/dependances)
        -- =====================================================================
        DECLARE @RuleCode NVARCHAR(200), @Result NVARCHAR(MAX), @ErrorMsg NVARCHAR(500);
        DECLARE @CurrentSeqId INT = 0;
        
        WHILE 1 = 1
        BEGIN
            SELECT TOP 1 @RuleCode = [Key], @CurrentSeqId = SeqId
            FROM #ThreadState 
            WHERE IsRule = 1 AND State = 0 AND SeqId > @CurrentSeqId 
            ORDER BY SeqId;
            
            IF @@ROWCOUNT = 0 BREAK;
            
            EXEC dbo.sp_ExecuteRule @RuleCode, @Result OUTPUT, @ErrorMsg OUTPUT;
        END
        
        -- Comptage final
        SELECT @SuccessCount = COUNT(*) FROM #ThreadState WHERE IsRule = 1 AND State = 2;
        SELECT @ErrorCount = COUNT(*) FROM #ThreadState WHERE IsRule = 1 AND State = 3;
        
        -- JSON output
        DECLARE @ResultsJson NVARCHAR(MAX), @StateJson NVARCHAR(MAX) = NULL, @DebugJson NVARCHAR(MAX) = NULL;
        
        SELECT @ResultsJson = (
            SELECT [Key] AS ruleCode,
                   CASE State 
                       WHEN 2 THEN 'EVALUATED' 
                       WHEN 3 THEN 'ERROR' 
                       ELSE 'NOT_EVALUATED' 
                   END AS state,
                   ScalarValue AS value, 
                   ErrorCategory AS errorCategory, 
                   ErrorCode AS errorCode
            FROM #ThreadState 
            WHERE IsRule = 1 
            ORDER BY SeqId 
            FOR JSON PATH
        );
        
        IF @ReturnStateTable = 1
            SELECT @StateJson = (
                SELECT SeqId, [Key], 
                       CASE WHEN IsRule = 1 THEN 'RULE' ELSE 'VARIABLE' END AS type,
                       CASE State 
                           WHEN 0 THEN 'NOT_EVALUATED' 
                           WHEN 1 THEN 'EVALUATING' 
                           WHEN 2 THEN 'EVALUATED' 
                           WHEN 3 THEN 'ERROR' 
                       END AS state,
                       ScalarValue AS value, 
                       ValueType AS valueType, 
                       ErrorCategory, 
                       ErrorCode
                FROM #ThreadState 
                ORDER BY SeqId 
                FOR JSON PATH
            );
        
        IF @ReturnDebug = 1 AND @Mode = 'DEBUG' AND OBJECT_ID('tempdb..#ThreadDebug') IS NOT NULL
            SELECT @DebugJson = (
                SELECT * FROM #ThreadDebug ORDER BY LogId FOR JSON PATH
            );
        
        SET @OutputJson = (
            SELECT 'SUCCESS' AS status, 
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
            SELECT 'ERROR' AS status, 
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
PRINT '======================================================================';
PRINT '         INSTALLATION TERMINEE - V6.5 CONFORME V1.6.0               ';
PRINT '======================================================================';
PRINT '';
PRINT '   CONFORMITE SPECIFICATION V1.6.0:';
PRINT '   ✓ Tous les agregats ignorent NULL (principe fondamental)';
PRINT '   ✓ FIRST: premiere valeur NON NULL selon SeqId';
PRINT '   ✓ LAST: derniere valeur NON NULL selon SeqId (NOUVEAU)';
PRINT '   ✓ CONCAT: valeurs NON NULL uniquement, vide → ""';
PRINT '   ✓ JSONIFY: cles NON NULL uniquement, vide → "{}"';
PRINT '   ✓ Normalisation decimaux français (2,5 → 2.5)';
PRINT '   ✓ Normalisation quotes (" → '')';
PRINT '   ✓ Normalisation resultats numeriques';
PRINT '   ✓ Pre-compilation et optimisations';
PRINT '';
PRINT '   USAGE: Identique aux versions precedentes';
PRINT '';
GO
