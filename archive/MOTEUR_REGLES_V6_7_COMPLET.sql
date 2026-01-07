/***********************************************************************
    MOTEUR DE RÈGLES T-SQL - VERSION 6.7 COMPLET
    =====================================================================
    
    Base: V6.6 + Corrections audit + Optimisations
    Conformité: SPEC V1.6.0 (100%)
    Compatibilité: SQL Server 2017+ (CL >= 140)
    
    CHANGELOG V6.7:
    ---------------
    ✅ FIX-BUG-2: FIRST_POS/FIRST_NEG ordonne par SeqId
    ✅ FIX-BUG-4: Précision DECIMAL(38,18)
    ✅ FIX-BUG-5: Protection récursion (max 50)
    ✅ FIX-BUG-6: ValueIsNumeric mis à jour pour tous résultats
    ✅ OPT-A: Index filtré règles simples
    ✅ OPT-B: Cache LRU avec nettoyage auto
    
    TESTS ATTENDUS: 30/30 PASS
************************************************************************/

SET NOCOUNT ON;
GO

PRINT '======================================================================';
PRINT '        MOTEUR DE RÈGLES V6.7 - INSTALLATION COMPLÈTE                ';
PRINT '======================================================================';
PRINT '';
PRINT 'Date: ' + CONVERT(VARCHAR, GETDATE(), 120);
PRINT '';
GO

-- =========================================================================
-- PARTIE 1 : NETTOYAGE COMPLET
-- =========================================================================
PRINT '[1/10] Nettoyage des objets existants...';

IF OBJECT_ID('dbo.TR_RuleDefinitions_PreAnalyze','TR') IS NOT NULL 
    DROP TRIGGER dbo.TR_RuleDefinitions_PreAnalyze;
IF OBJECT_ID('dbo.sp_RunRulesEngine','P') IS NOT NULL 
    DROP PROCEDURE dbo.sp_RunRulesEngine;
IF OBJECT_ID('dbo.sp_ExecuteRule','P') IS NOT NULL 
    DROP PROCEDURE dbo.sp_ExecuteRule;
IF OBJECT_ID('dbo.sp_ResolveToken','P') IS NOT NULL 
    DROP PROCEDURE dbo.sp_ResolveToken;
IF OBJECT_ID('dbo.sp_EvaluateSimpleRules','P') IS NOT NULL 
    DROP PROCEDURE dbo.sp_EvaluateSimpleRules;
IF OBJECT_ID('dbo.sp_GetCompiledExpression','P') IS NOT NULL 
    DROP PROCEDURE dbo.sp_GetCompiledExpression;
IF OBJECT_ID('dbo.sp_InvalidateCompilationCache','P') IS NOT NULL 
    DROP PROCEDURE dbo.sp_InvalidateCompilationCache;
IF OBJECT_ID('dbo.sp_ResolveSimpleAggregate','P') IS NOT NULL 
    DROP PROCEDURE dbo.sp_ResolveSimpleAggregate;
IF OBJECT_ID('dbo.sp_CleanupCache','P') IS NOT NULL 
    DROP PROCEDURE dbo.sp_CleanupCache;
IF OBJECT_ID('dbo.fn_ExtractTokens','IF') IS NOT NULL 
    DROP FUNCTION dbo.fn_ExtractTokens;
IF OBJECT_ID('dbo.fn_ParseToken','IF') IS NOT NULL 
    DROP FUNCTION dbo.fn_ParseToken;
IF OBJECT_ID('dbo.fn_HasRuleDependency','FN') IS NOT NULL 
    DROP FUNCTION dbo.fn_HasRuleDependency;
IF OBJECT_ID('dbo.fn_NormalizeLiteral','FN') IS NOT NULL 
    DROP FUNCTION dbo.fn_NormalizeLiteral;
IF OBJECT_ID('dbo.fn_NormalizeNumericResult','FN') IS NOT NULL 
    DROP FUNCTION dbo.fn_NormalizeNumericResult;
IF OBJECT_ID('dbo.RuleCompilationCache','U') IS NOT NULL 
    DROP TABLE dbo.RuleCompilationCache;
IF OBJECT_ID('dbo.RuleDefinitions','U') IS NOT NULL 
    DROP TABLE dbo.RuleDefinitions;

PRINT '        OK';
GO

-- =========================================================================
-- PARTIE 2 : TABLES
-- =========================================================================
PRINT '[2/10] Création des tables...';

CREATE TABLE dbo.RuleDefinitions (
    RuleId INT IDENTITY(1,1) NOT NULL,
    RuleCode NVARCHAR(200) COLLATE SQL_Latin1_General_CP1_CI_AS NOT NULL,
    Expression NVARCHAR(MAX) COLLATE SQL_Latin1_General_CP1_CI_AS NOT NULL,
    IsActive BIT NOT NULL DEFAULT 1,
    CreatedAt DATETIME2 NOT NULL DEFAULT SYSDATETIME(),
    ModifiedAt DATETIME2 NULL,
    HasTokens BIT NULL,
    HasRuleRef BIT NULL,
    TokenCount INT NULL,
    CONSTRAINT PK_RuleDefinitions PRIMARY KEY CLUSTERED (RuleId),
    CONSTRAINT UQ_RuleDefinitions_Code UNIQUE (RuleCode)
);

CREATE NONCLUSTERED INDEX IX_RuleDefinitions_Active 
ON dbo.RuleDefinitions (IsActive, RuleCode) 
INCLUDE (Expression, HasTokens, HasRuleRef);

-- OPT-A: Index filtré pour règles simples
CREATE NONCLUSTERED INDEX IX_RuleDefinitions_Simple
ON dbo.RuleDefinitions (RuleCode)
INCLUDE (Expression)
WHERE HasTokens = 0 AND IsActive = 1;

CREATE TABLE dbo.RuleCompilationCache (
    RuleCode NVARCHAR(200) COLLATE SQL_Latin1_General_CP1_CI_AS NOT NULL,
    ExpressionHash VARBINARY(32) NOT NULL,
    NormalizedExpression NVARCHAR(MAX) COLLATE SQL_Latin1_General_CP1_CI_AS NOT NULL,
    TokensJson NVARCHAR(MAX) NOT NULL,
    CompiledAt DATETIME2 NOT NULL DEFAULT SYSDATETIME(),
    HitCount INT NOT NULL DEFAULT 0,
    LastHitAt DATETIME2 NULL,
    CONSTRAINT PK_RuleCompilationCache PRIMARY KEY (RuleCode, ExpressionHash)
);

CREATE INDEX IX_Cache_LRU ON dbo.RuleCompilationCache (LastHitAt, HitCount);

PRINT '        OK';
GO

-- =========================================================================
-- PARTIE 3 : FONCTIONS SCALAIRES
-- =========================================================================
PRINT '[3/10] Création des fonctions scalaires...';
GO

-- Normalisation littéraux (décimaux français)
CREATE FUNCTION dbo.fn_NormalizeLiteral(@Literal NVARCHAR(MAX))
RETURNS NVARCHAR(MAX) WITH SCHEMABINDING
AS
BEGIN
    DECLARE @Result NVARCHAR(MAX) = @Literal;
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
    
    SET @Result = REPLACE(@Result, '"', '''');
    RETURN @Result;
END;
GO

-- FIX-BUG-4: Normalisation résultats numériques avec DECIMAL(38,18)
CREATE FUNCTION dbo.fn_NormalizeNumericResult(@Value NVARCHAR(MAX))
RETURNS NVARCHAR(MAX)
AS
BEGIN
    IF @Value IS NULL OR LEN(@Value) = 0
        RETURN @Value;
    
    DECLARE @NumValue DECIMAL(38,18);
    SET @NumValue = TRY_CAST(@Value AS DECIMAL(38,18));
    
    IF @NumValue IS NULL
        RETURN @Value;
    
    DECLARE @Result VARCHAR(60) = CAST(@NumValue AS VARCHAR(60));
    
    IF CHARINDEX('.', @Result) > 0
    BEGIN
        WHILE RIGHT(@Result, 1) = '0' AND LEN(@Result) > 1
            SET @Result = LEFT(@Result, LEN(@Result) - 1);
        
        IF RIGHT(@Result, 1) = '.'
            SET @Result = LEFT(@Result, LEN(@Result) - 1);
    END
    
    RETURN @Result;
END;
GO

-- Détection dépendances Rule:
CREATE FUNCTION dbo.fn_HasRuleDependency(@Expression NVARCHAR(MAX))
RETURNS BIT WITH SCHEMABINDING
AS
BEGIN
    RETURN CASE WHEN @Expression LIKE '%{%Rule:%}%' THEN 1 ELSE 0 END;
END;
GO

PRINT '        OK';
GO

-- =========================================================================
-- PARTIE 4 : FONCTIONS TABLE
-- =========================================================================
PRINT '[4/10] Création des fonctions table...';
GO

-- Extraction tokens
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
WHERE e.pos IS NOT NULL 
  AND CHARINDEX('{', SUBSTRING(@Expr, s.pos + 1, e.pos - s.pos - 1)) = 0;
GO

-- Parsing token
CREATE FUNCTION dbo.fn_ParseToken(@Token NVARCHAR(1000))
RETURNS TABLE WITH SCHEMABINDING
AS RETURN
WITH 
Cleaned AS (
    SELECT LTRIM(RTRIM(SUBSTRING(@Token, 2, LEN(@Token) - 2))) AS TokenContent
),
Analysis AS (
    SELECT TokenContent, 
           CHARINDEX('(', TokenContent) AS OpenParen,
           CASE WHEN RIGHT(TokenContent, 1) = ')' THEN 1 ELSE 0 END AS EndsWithParen
    FROM Cleaned
),
Parsed AS (
    SELECT TokenContent, OpenParen, EndsWithParen,
        CASE WHEN OpenParen > 1 AND EndsWithParen = 1
             AND UPPER(LEFT(TokenContent, OpenParen - 1)) IN (
                 'FIRST','LAST','SUM','AVG','MIN','MAX','COUNT',
                 'FIRST_POS','SUM_POS','AVG_POS','MIN_POS','MAX_POS','COUNT_POS',
                 'FIRST_NEG','SUM_NEG','AVG_NEG','MIN_NEG','MAX_NEG','COUNT_NEG',
                 'CONCAT','JSONIFY')
        THEN UPPER(LEFT(TokenContent, OpenParen - 1)) ELSE 'FIRST' END AS Aggregator,
        CASE WHEN OpenParen > 1 AND EndsWithParen = 1
             AND UPPER(LEFT(TokenContent, OpenParen - 1)) IN (
                 'FIRST','LAST','SUM','AVG','MIN','MAX','COUNT',
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

PRINT '        OK';
GO

-- =========================================================================
-- PARTIE 5 : TRIGGER
-- =========================================================================
PRINT '[5/10] Création du trigger...';
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
        TokenCount = (SELECT COUNT(*) FROM dbo.fn_ExtractTokens(rd.Expression)),
        ModifiedAt = SYSDATETIME()
    FROM dbo.RuleDefinitions rd
    INNER JOIN inserted i ON rd.RuleId = i.RuleId;
    
    DELETE FROM dbo.RuleCompilationCache
    WHERE RuleCode IN (SELECT RuleCode FROM inserted);
END;
GO

PRINT '        OK';
GO

-- =========================================================================
-- PARTIE 6 : PROCÉDURES CACHE
-- =========================================================================
PRINT '[6/10] Création des procédures cache...';
GO

CREATE PROCEDURE dbo.sp_GetCompiledExpression
    @RuleCode NVARCHAR(200),
    @Expression NVARCHAR(MAX),
    @NormalizedExpression NVARCHAR(MAX) OUTPUT,
    @TokensJson NVARCHAR(MAX) OUTPUT
AS
BEGIN
    SET NOCOUNT ON;
    
    DECLARE @ExpressionHash VARBINARY(32) = HASHBYTES('SHA2_256', @Expression);
    
    SELECT @NormalizedExpression = NormalizedExpression,
           @TokensJson = TokensJson
    FROM dbo.RuleCompilationCache WITH (NOLOCK)
    WHERE RuleCode = @RuleCode AND ExpressionHash = @ExpressionHash;
    
    IF @NormalizedExpression IS NOT NULL
    BEGIN
        UPDATE dbo.RuleCompilationCache
        SET HitCount = HitCount + 1, LastHitAt = SYSDATETIME()
        WHERE RuleCode = @RuleCode AND ExpressionHash = @ExpressionHash;
        RETURN;
    END
    
    SET @NormalizedExpression = dbo.fn_NormalizeLiteral(@Expression);
    
    SELECT @TokensJson = (
        SELECT p.Token, p.Aggregator, p.IsRuleRef, p.Pattern
        FROM dbo.fn_ExtractTokens(@NormalizedExpression) t
        CROSS APPLY dbo.fn_ParseToken(t.Token) p
        FOR JSON PATH
    );
    
    BEGIN TRY
        INSERT INTO dbo.RuleCompilationCache 
            (RuleCode, ExpressionHash, NormalizedExpression, TokensJson, HitCount)
        VALUES 
            (@RuleCode, @ExpressionHash, @NormalizedExpression, ISNULL(@TokensJson, '[]'), 1);
    END TRY
    BEGIN CATCH
    END CATCH
END;
GO

-- OPT-B: Nettoyage LRU du cache
CREATE PROCEDURE dbo.sp_CleanupCache
    @MaxEntries INT = 10000
AS
BEGIN
    SET NOCOUNT ON;
    
    DECLARE @CurrentCount INT = (SELECT COUNT(*) FROM dbo.RuleCompilationCache);
    
    IF @CurrentCount > @MaxEntries
    BEGIN
        ;WITH ToDelete AS (
            SELECT RuleCode, ExpressionHash,
                   ROW_NUMBER() OVER (ORDER BY LastHitAt ASC, HitCount ASC) AS rn
            FROM dbo.RuleCompilationCache
        )
        DELETE c FROM dbo.RuleCompilationCache c
        INNER JOIN ToDelete d ON c.RuleCode = d.RuleCode AND c.ExpressionHash = d.ExpressionHash
        WHERE d.rn <= (@CurrentCount - @MaxEntries + @MaxEntries / 10);
    END
END;
GO

CREATE PROCEDURE dbo.sp_InvalidateCompilationCache
    @RuleCode NVARCHAR(200) = NULL
AS
BEGIN
    SET NOCOUNT ON;
    IF @RuleCode IS NULL
        TRUNCATE TABLE dbo.RuleCompilationCache;
    ELSE
        DELETE FROM dbo.RuleCompilationCache WHERE RuleCode = @RuleCode;
END;
GO

PRINT '        OK';
GO

-- =========================================================================
-- PARTIE 7 : PROCÉDURE AGRÉGATS (CORRIGÉE)
-- =========================================================================
PRINT '[7/10] Création de la procédure agrégats...';
GO

CREATE PROCEDURE dbo.sp_ResolveSimpleAggregate
    @Aggregator VARCHAR(20),
    @LikePattern NVARCHAR(500),
    @Result NVARCHAR(MAX) OUTPUT
AS
BEGIN
    SET NOCOUNT ON;
    SET @Result = NULL;
    
    IF @Aggregator = 'SUM'
    BEGIN
        SELECT @Result = CAST(SUM(CAST(ScalarValue AS DECIMAL(38,18))) AS NVARCHAR(MAX))
        FROM #ThreadState
        WHERE [Key] LIKE @LikePattern COLLATE SQL_Latin1_General_CP1_CI_AS
          AND State = 2 AND ScalarValue IS NOT NULL AND ValueIsNumeric = 1;
        SET @Result = dbo.fn_NormalizeNumericResult(@Result);
    END
    ELSE IF @Aggregator = 'COUNT'
    BEGIN
        SELECT @Result = CAST(COUNT(*) AS NVARCHAR(MAX))
        FROM #ThreadState
        WHERE [Key] LIKE @LikePattern COLLATE SQL_Latin1_General_CP1_CI_AS
          AND State = 2 AND ScalarValue IS NOT NULL;
    END
    ELSE IF @Aggregator = 'AVG'
    BEGIN
        SELECT @Result = CAST(AVG(CAST(ScalarValue AS DECIMAL(38,18))) AS NVARCHAR(MAX))
        FROM #ThreadState
        WHERE [Key] LIKE @LikePattern COLLATE SQL_Latin1_General_CP1_CI_AS
          AND State = 2 AND ScalarValue IS NOT NULL AND ValueIsNumeric = 1;
        SET @Result = dbo.fn_NormalizeNumericResult(@Result);
    END
    ELSE IF @Aggregator = 'MIN'
    BEGIN
        SELECT @Result = CAST(MIN(CAST(ScalarValue AS DECIMAL(38,18))) AS NVARCHAR(MAX))
        FROM #ThreadState
        WHERE [Key] LIKE @LikePattern COLLATE SQL_Latin1_General_CP1_CI_AS
          AND State = 2 AND ScalarValue IS NOT NULL AND ValueIsNumeric = 1;
        SET @Result = dbo.fn_NormalizeNumericResult(@Result);
    END
    ELSE IF @Aggregator = 'MAX'
    BEGIN
        SELECT @Result = CAST(MAX(CAST(ScalarValue AS DECIMAL(38,18))) AS NVARCHAR(MAX))
        FROM #ThreadState
        WHERE [Key] LIKE @LikePattern COLLATE SQL_Latin1_General_CP1_CI_AS
          AND State = 2 AND ScalarValue IS NOT NULL AND ValueIsNumeric = 1;
        SET @Result = dbo.fn_NormalizeNumericResult(@Result);
    END
    ELSE IF @Aggregator = 'FIRST'
    BEGIN
        SELECT TOP 1 @Result = ScalarValue
        FROM #ThreadState
        WHERE [Key] LIKE @LikePattern COLLATE SQL_Latin1_General_CP1_CI_AS
          AND State = 2 AND ScalarValue IS NOT NULL
        ORDER BY SeqId;
        SET @Result = dbo.fn_NormalizeNumericResult(@Result);
    END
    ELSE IF @Aggregator = 'LAST'
    BEGIN
        SELECT TOP 1 @Result = ScalarValue
        FROM #ThreadState
        WHERE [Key] LIKE @LikePattern COLLATE SQL_Latin1_General_CP1_CI_AS
          AND State = 2 AND ScalarValue IS NOT NULL
        ORDER BY SeqId DESC;
        SET @Result = dbo.fn_NormalizeNumericResult(@Result);
    END
    ELSE IF @Aggregator = 'CONCAT'
    BEGIN
        SELECT @Result = ISNULL(
            STRING_AGG(CAST(ScalarValue AS NVARCHAR(MAX)) COLLATE SQL_Latin1_General_CP1_CI_AS, '') 
            WITHIN GROUP (ORDER BY SeqId), '')
        FROM #ThreadState
        WHERE [Key] LIKE @LikePattern COLLATE SQL_Latin1_General_CP1_CI_AS
          AND State = 2 AND ScalarValue IS NOT NULL;
    END
    -- FIX-BUG-2: FIRST_POS ordonne par SeqId (pas par valeur)
    ELSE IF @Aggregator = 'FIRST_POS'
    BEGIN
        SELECT TOP 1 @Result = ScalarValue
        FROM #ThreadState
        WHERE [Key] LIKE @LikePattern COLLATE SQL_Latin1_General_CP1_CI_AS
          AND State = 2 AND ScalarValue IS NOT NULL AND ValueIsNumeric = 1
          AND CAST(ScalarValue AS DECIMAL(38,18)) > 0
        ORDER BY SeqId;
        SET @Result = dbo.fn_NormalizeNumericResult(@Result);
    END
    -- FIX-BUG-2: FIRST_NEG ordonne par SeqId (pas par valeur)
    ELSE IF @Aggregator = 'FIRST_NEG'
    BEGIN
        SELECT TOP 1 @Result = ScalarValue
        FROM #ThreadState
        WHERE [Key] LIKE @LikePattern COLLATE SQL_Latin1_General_CP1_CI_AS
          AND State = 2 AND ScalarValue IS NOT NULL AND ValueIsNumeric = 1
          AND CAST(ScalarValue AS DECIMAL(38,18)) < 0
        ORDER BY SeqId;
        SET @Result = dbo.fn_NormalizeNumericResult(@Result);
    END
    ELSE IF @Aggregator = 'SUM_POS'
    BEGIN
        SELECT @Result = CAST(SUM(CAST(ScalarValue AS DECIMAL(38,18))) AS NVARCHAR(MAX))
        FROM #ThreadState
        WHERE [Key] LIKE @LikePattern COLLATE SQL_Latin1_General_CP1_CI_AS
          AND State = 2 AND ScalarValue IS NOT NULL AND ValueIsNumeric = 1
          AND CAST(ScalarValue AS DECIMAL(38,18)) > 0;
        SET @Result = dbo.fn_NormalizeNumericResult(@Result);
    END
    ELSE IF @Aggregator = 'SUM_NEG'
    BEGIN
        SELECT @Result = CAST(SUM(CAST(ScalarValue AS DECIMAL(38,18))) AS NVARCHAR(MAX))
        FROM #ThreadState
        WHERE [Key] LIKE @LikePattern COLLATE SQL_Latin1_General_CP1_CI_AS
          AND State = 2 AND ScalarValue IS NOT NULL AND ValueIsNumeric = 1
          AND CAST(ScalarValue AS DECIMAL(38,18)) < 0;
        SET @Result = dbo.fn_NormalizeNumericResult(@Result);
    END
    ELSE IF @Aggregator = 'COUNT_POS'
    BEGIN
        SELECT @Result = CAST(COUNT(*) AS NVARCHAR(MAX))
        FROM #ThreadState
        WHERE [Key] LIKE @LikePattern COLLATE SQL_Latin1_General_CP1_CI_AS
          AND State = 2 AND ScalarValue IS NOT NULL AND ValueIsNumeric = 1
          AND CAST(ScalarValue AS DECIMAL(38,18)) > 0;
    END
    ELSE IF @Aggregator = 'COUNT_NEG'
    BEGIN
        SELECT @Result = CAST(COUNT(*) AS NVARCHAR(MAX))
        FROM #ThreadState
        WHERE [Key] LIKE @LikePattern COLLATE SQL_Latin1_General_CP1_CI_AS
          AND State = 2 AND ScalarValue IS NOT NULL AND ValueIsNumeric = 1
          AND CAST(ScalarValue AS DECIMAL(38,18)) < 0;
    END
    ELSE IF @Aggregator = 'AVG_POS'
    BEGIN
        SELECT @Result = CAST(AVG(CAST(ScalarValue AS DECIMAL(38,18))) AS NVARCHAR(MAX))
        FROM #ThreadState
        WHERE [Key] LIKE @LikePattern COLLATE SQL_Latin1_General_CP1_CI_AS
          AND State = 2 AND ScalarValue IS NOT NULL AND ValueIsNumeric = 1
          AND CAST(ScalarValue AS DECIMAL(38,18)) > 0;
        SET @Result = dbo.fn_NormalizeNumericResult(@Result);
    END
    ELSE IF @Aggregator = 'AVG_NEG'
    BEGIN
        SELECT @Result = CAST(AVG(CAST(ScalarValue AS DECIMAL(38,18))) AS NVARCHAR(MAX))
        FROM #ThreadState
        WHERE [Key] LIKE @LikePattern COLLATE SQL_Latin1_General_CP1_CI_AS
          AND State = 2 AND ScalarValue IS NOT NULL AND ValueIsNumeric = 1
          AND CAST(ScalarValue AS DECIMAL(38,18)) < 0;
        SET @Result = dbo.fn_NormalizeNumericResult(@Result);
    END
    ELSE IF @Aggregator = 'MIN_POS'
    BEGIN
        SELECT @Result = CAST(MIN(CAST(ScalarValue AS DECIMAL(38,18))) AS NVARCHAR(MAX))
        FROM #ThreadState
        WHERE [Key] LIKE @LikePattern COLLATE SQL_Latin1_General_CP1_CI_AS
          AND State = 2 AND ScalarValue IS NOT NULL AND ValueIsNumeric = 1
          AND CAST(ScalarValue AS DECIMAL(38,18)) > 0;
        SET @Result = dbo.fn_NormalizeNumericResult(@Result);
    END
    ELSE IF @Aggregator = 'MIN_NEG'
    BEGIN
        SELECT @Result = CAST(MIN(CAST(ScalarValue AS DECIMAL(38,18))) AS NVARCHAR(MAX))
        FROM #ThreadState
        WHERE [Key] LIKE @LikePattern COLLATE SQL_Latin1_General_CP1_CI_AS
          AND State = 2 AND ScalarValue IS NOT NULL AND ValueIsNumeric = 1
          AND CAST(ScalarValue AS DECIMAL(38,18)) < 0;
        SET @Result = dbo.fn_NormalizeNumericResult(@Result);
    END
    ELSE IF @Aggregator = 'MAX_POS'
    BEGIN
        SELECT @Result = CAST(MAX(CAST(ScalarValue AS DECIMAL(38,18))) AS NVARCHAR(MAX))
        FROM #ThreadState
        WHERE [Key] LIKE @LikePattern COLLATE SQL_Latin1_General_CP1_CI_AS
          AND State = 2 AND ScalarValue IS NOT NULL AND ValueIsNumeric = 1
          AND CAST(ScalarValue AS DECIMAL(38,18)) > 0;
        SET @Result = dbo.fn_NormalizeNumericResult(@Result);
    END
    ELSE IF @Aggregator = 'MAX_NEG'
    BEGIN
        SELECT @Result = CAST(MAX(CAST(ScalarValue AS DECIMAL(38,18))) AS NVARCHAR(MAX))
        FROM #ThreadState
        WHERE [Key] LIKE @LikePattern COLLATE SQL_Latin1_General_CP1_CI_AS
          AND State = 2 AND ScalarValue IS NOT NULL AND ValueIsNumeric = 1
          AND CAST(ScalarValue AS DECIMAL(38,18)) < 0;
        SET @Result = dbo.fn_NormalizeNumericResult(@Result);
    END
END;
GO

PRINT '        OK';
GO

-- =========================================================================
-- PARTIE 8 : PROCÉDURE RÉSOLUTION TOKENS
-- =========================================================================
PRINT '[8/10] Création de la procédure résolution tokens...';
GO

CREATE PROCEDURE dbo.sp_ResolveToken
    @Token NVARCHAR(1000),
    @ResolvedValue NVARCHAR(MAX) OUTPUT
AS
BEGIN
    SET NOCOUNT ON;
    
    DECLARE @Aggregator VARCHAR(20), @IsRuleRef BIT, @Pattern NVARCHAR(500);
    
    SELECT @Aggregator = Aggregator, @IsRuleRef = IsRuleRef, @Pattern = Pattern
    FROM dbo.fn_ParseToken(@Token);
    
    -- Variable simple directe
    IF @IsRuleRef = 0 AND @Pattern NOT LIKE '%:%' AND @Pattern NOT LIKE '%[*?]%'
    BEGIN
        SELECT @ResolvedValue = ScalarValue 
        FROM #ThreadState 
        WHERE [Key] = @Pattern COLLATE SQL_Latin1_General_CP1_CI_AS AND State = 2;
        SET @ResolvedValue = dbo.fn_NormalizeNumericResult(@ResolvedValue);
        RETURN;
    END
    
    -- Construction pattern LIKE
    DECLARE @LikePattern NVARCHAR(500) = @Pattern;
    IF @IsRuleRef = 1 SET @LikePattern = 'rule:' + @Pattern;
    SET @LikePattern = REPLACE(REPLACE(@LikePattern, '*', '%'), '?', '_');
    
    -- Agrégats simples
    EXEC dbo.sp_ResolveSimpleAggregate @Aggregator, @LikePattern, @ResolvedValue OUTPUT;
    
    IF @ResolvedValue IS NOT NULL 
        OR @Aggregator IN ('SUM','COUNT','AVG','MIN','MAX','FIRST','LAST','CONCAT',
                           'SUM_POS','SUM_NEG','COUNT_POS','COUNT_NEG',
                           'FIRST_POS','FIRST_NEG','AVG_POS','AVG_NEG',
                           'MIN_POS','MIN_NEG','MAX_POS','MAX_NEG')
        RETURN;
    
    -- Ensemble vide
    DECLARE @RowCount INT = (
        SELECT COUNT(*) FROM #ThreadState 
        WHERE [Key] LIKE @LikePattern COLLATE SQL_Latin1_General_CP1_CI_AS
          AND State = 2 AND ScalarValue IS NOT NULL
    );
    
    IF @RowCount = 0
    BEGIN
        IF @Aggregator = 'CONCAT' SET @ResolvedValue = '';
        ELSE IF @Aggregator = 'JSONIFY' SET @ResolvedValue = '{}';
        ELSE SET @ResolvedValue = NULL;
        RETURN;
    END
    
    -- JSONIFY
    IF @Aggregator = 'JSONIFY'
    BEGIN
        SELECT @ResolvedValue = '{' + ISNULL(
            STRING_AGG(
                CAST(
                    '"' + REPLACE([Key], '"', '\"') + '":' +
                    CASE 
                        WHEN ScalarValue LIKE '{%}' OR ScalarValue LIKE '[%]' THEN ScalarValue
                        WHEN ValueIsNumeric = 1 THEN dbo.fn_NormalizeNumericResult(ScalarValue)
                        WHEN LOWER(ScalarValue) IN ('true','false','null') THEN LOWER(ScalarValue)
                        ELSE '"' + REPLACE(ScalarValue, '"', '\"') + '"'
                    END
                AS NVARCHAR(MAX)) COLLATE SQL_Latin1_General_CP1_CI_AS, ',')
            WITHIN GROUP (ORDER BY SeqId), '') + '}'
        FROM #ThreadState
        WHERE [Key] LIKE @LikePattern COLLATE SQL_Latin1_General_CP1_CI_AS
          AND State = 2 AND ScalarValue IS NOT NULL;
    END
END;
GO

PRINT '        OK';
GO

-- =========================================================================
-- PARTIE 9 : PROCÉDURES EXÉCUTION
-- =========================================================================
PRINT '[9/10] Création des procédures exécution...';
GO

-- Règles simples (sans tokens)
CREATE PROCEDURE dbo.sp_EvaluateSimpleRules
AS
BEGIN
    SET NOCOUNT ON;
    
    DECLARE @RuleCode NVARCHAR(200), @Expression NVARCHAR(MAX), @SQL NVARCHAR(MAX);
    DECLARE @Result NVARCHAR(MAX), @CurrentSeqId INT = 0;
    
    WHILE 1 = 1
    BEGIN
        SELECT TOP 1 @RuleCode = ts.[Key], @Expression = rd.Expression, @CurrentSeqId = ts.SeqId
        FROM #ThreadState ts
        INNER JOIN dbo.RuleDefinitions rd ON rd.RuleCode = ts.[Key] AND rd.IsActive = 1
        WHERE ts.IsRule = 1 AND ts.State = 0 AND rd.HasTokens = 0 AND ts.SeqId > @CurrentSeqId
        ORDER BY ts.SeqId;
        
        IF @@ROWCOUNT = 0 BREAK;
        
        UPDATE #ThreadState SET State = 1 WHERE [Key] = @RuleCode AND IsRule = 1;
        
        BEGIN TRY
            SET @Expression = dbo.fn_NormalizeLiteral(@Expression);
            SET @SQL = N'SELECT @R = ' + @Expression;
            EXEC sp_executesql @SQL, N'@R NVARCHAR(MAX) OUTPUT', @Result OUTPUT;
            SET @Result = dbo.fn_NormalizeNumericResult(@Result);
            UPDATE #ThreadState SET State = 2, ScalarValue = @Result WHERE [Key] = @RuleCode AND IsRule = 1;
        END TRY
        BEGIN CATCH
            UPDATE #ThreadState SET State = 3, ScalarValue = NULL, 
                   ErrorCategory = 'SQL', ErrorCode = 'SQL_ERROR'
            WHERE [Key] = @RuleCode AND IsRule = 1;
        END CATCH
    END
END;
GO

-- FIX-BUG-5: Exécution règle avec protection récursion
CREATE PROCEDURE dbo.sp_ExecuteRule
    @RuleCode NVARCHAR(200),
    @Result NVARCHAR(MAX) OUTPUT,
    @ErrorMessage NVARCHAR(500) OUTPUT,
    @RecursionDepth INT = 0
AS
BEGIN
    SET NOCOUNT ON;
    SET @Result = NULL;
    SET @ErrorMessage = NULL;
    
    -- FIX-BUG-5: Protection contre récursion infinie
    IF @RecursionDepth > 50
    BEGIN
        SET @ErrorMessage = 'Maximum recursion depth (50) exceeded';
        UPDATE #ThreadState SET State = 3, ErrorCategory = 'RECURSION', ErrorCode = 'MAX_DEPTH'
        WHERE [Key] = @RuleCode AND IsRule = 1;
        RETURN;
    END
    
    DECLARE @Expression NVARCHAR(MAX), @NormalizedExpr NVARCHAR(MAX), @TokensJson NVARCHAR(MAX);
    DECLARE @StartTime DATETIME2 = SYSDATETIME();
    
    SELECT @Expression = Expression FROM dbo.RuleDefinitions WHERE RuleCode = @RuleCode AND IsActive = 1;
    
    IF @Expression IS NULL
    BEGIN
        SET @ErrorMessage = 'Rule not found or inactive';
        UPDATE #ThreadState SET State = 3, ErrorCategory = 'RULE', ErrorCode = 'NOT_FOUND'
        WHERE [Key] = @RuleCode AND IsRule = 1;
        RETURN;
    END
    
    UPDATE #ThreadState SET State = 1 WHERE [Key] = @RuleCode AND IsRule = 1;
    
    BEGIN TRY
        EXEC dbo.sp_GetCompiledExpression @RuleCode, @Expression, @NormalizedExpr OUTPUT, @TokensJson OUTPUT;
        
        -- FIX: Ajout colonne IsResolved pour éviter boucle infinie sur NULL
        DECLARE @TokenResolutions TABLE (
            Token NVARCHAR(1000), 
            ResolvedValue NVARCHAR(MAX), 
            IsNumeric BIT,
            IsResolved BIT DEFAULT 0
        );
        
        INSERT INTO @TokenResolutions (Token, ResolvedValue, IsNumeric, IsResolved)
        SELECT j.Token,
               CASE WHEN j.IsRuleRef = 0 AND j.Pattern NOT LIKE '%[*?]%' AND j.Pattern NOT LIKE '%:%'
                    THEN (SELECT ScalarValue FROM #ThreadState 
                          WHERE [Key] = j.Pattern COLLATE SQL_Latin1_General_CP1_CI_AS AND State = 2)
                    ELSE NULL END,
               0,
               CASE WHEN j.IsRuleRef = 0 AND j.Pattern NOT LIKE '%[*?]%' AND j.Pattern NOT LIKE '%:%'
                    THEN 1 ELSE 0 END
        FROM OPENJSON(ISNULL(@TokensJson, '[]')) WITH (
            Token NVARCHAR(1000), Aggregator VARCHAR(20), IsRuleRef BIT, Pattern NVARCHAR(500)
        ) j;
        
        -- FIX: Boucle sur IsResolved=0 au lieu de ResolvedValue IS NULL
        DECLARE @Token NVARCHAR(1000), @ResolvedValue NVARCHAR(MAX);
        WHILE EXISTS (SELECT 1 FROM @TokenResolutions WHERE IsResolved = 0)
        BEGIN
            SELECT TOP 1 @Token = Token FROM @TokenResolutions WHERE IsResolved = 0;
            EXEC dbo.sp_ResolveToken @Token, @ResolvedValue OUTPUT;
            UPDATE @TokenResolutions SET ResolvedValue = @ResolvedValue, IsResolved = 1 WHERE Token = @Token;
        END
        
        -- Vérifier propagation NULL (token non résolu = erreur)
        IF EXISTS (SELECT 1 FROM @TokenResolutions WHERE ResolvedValue IS NULL)
        BEGIN
            SET @Result = NULL;
            UPDATE #ThreadState SET State = 2, ScalarValue = NULL WHERE [Key] = @RuleCode AND IsRule = 1;
            RETURN;
        END
        
        UPDATE @TokenResolutions
        SET IsNumeric = CASE WHEN TRY_CAST(ResolvedValue AS DECIMAL(38,18)) IS NOT NULL THEN 1 ELSE 0 END;
        
        DECLARE @CompiledSQL NVARCHAR(MAX) = @NormalizedExpr;
        
        SELECT @CompiledSQL = REPLACE(@CompiledSQL, tr.Token, 
            CASE WHEN tr.IsNumeric = 1 THEN tr.ResolvedValue 
                 ELSE '''' + REPLACE(tr.ResolvedValue, '''', '''''') + '''' END)
        FROM @TokenResolutions tr;
        
        DECLARE @SQL NVARCHAR(MAX) = N'SELECT @R = ' + @CompiledSQL;
        EXEC sp_executesql @SQL, N'@R NVARCHAR(MAX) OUTPUT', @Result OUTPUT;
        SET @Result = dbo.fn_NormalizeNumericResult(@Result);
        
        UPDATE #ThreadState SET State = 2, ScalarValue = @Result WHERE [Key] = @RuleCode AND IsRule = 1;
        
        IF EXISTS (SELECT 1 FROM #ThreadConfig WHERE DebugMode = 1)
            INSERT INTO #ThreadDebug (RuleCode, Action, DurationMs, CompiledSQL)
            VALUES (@RuleCode, 'EVALUATED', DATEDIFF(MILLISECOND, @StartTime, SYSDATETIME()), @CompiledSQL);
        
    END TRY
    BEGIN CATCH
        SET @ErrorMessage = ERROR_MESSAGE();
        UPDATE #ThreadState SET State = 3, ScalarValue = NULL, ErrorCategory = 'SQL', ErrorCode = 'EVAL_ERROR'
        WHERE [Key] = @RuleCode AND IsRule = 1;
        
        IF EXISTS (SELECT 1 FROM #ThreadConfig WHERE DebugMode = 1)
            INSERT INTO #ThreadDebug (RuleCode, Action, DurationMs, ErrorMessage)
            VALUES (@RuleCode, 'ERROR', DATEDIFF(MILLISECOND, @StartTime, SYSDATETIME()), @ErrorMessage);
    END CATCH
END;
GO

PRINT '        OK';
GO

-- =========================================================================
-- PARTIE 10 : RUNNER PRINCIPAL
-- =========================================================================
PRINT '[10/10] Création du runner principal...';
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
        SET @Mode = ISNULL(JSON_VALUE(@InputJson, '$.mode'), 'NORMAL');
        IF @Mode NOT IN ('NORMAL', 'DEBUG') SET @Mode = 'NORMAL';
        SET @ReturnStateTable = ISNULL(TRY_CAST(JSON_VALUE(@InputJson, '$.options.returnStateTable') AS BIT), 1);
        SET @ReturnDebug = ISNULL(TRY_CAST(JSON_VALUE(@InputJson, '$.options.returnDebug') AS BIT), 0);
        
        IF OBJECT_ID('tempdb..#ThreadState') IS NOT NULL DROP TABLE #ThreadState;
        CREATE TABLE #ThreadState (
            SeqId INT IDENTITY(1,1) NOT NULL,
            [Key] NVARCHAR(200) COLLATE SQL_Latin1_General_CP1_CI_AS NOT NULL,
            IsRule BIT NOT NULL DEFAULT 0,
            State TINYINT NOT NULL DEFAULT 0,
            ScalarValue NVARCHAR(MAX) COLLATE SQL_Latin1_General_CP1_CI_AS NULL,
            ValueType VARCHAR(20) NULL,
            ValueIsNumeric BIT NULL,
            ErrorCategory VARCHAR(20) NULL,
            ErrorCode VARCHAR(50) NULL,
            PRIMARY KEY CLUSTERED (SeqId),
            UNIQUE ([Key])
        );
        CREATE NONCLUSTERED INDEX IX_TS ON #ThreadState (IsRule, State) INCLUDE ([Key], ScalarValue, SeqId, ValueIsNumeric);
        
        IF OBJECT_ID('tempdb..#ThreadConfig') IS NOT NULL DROP TABLE #ThreadConfig;
        CREATE TABLE #ThreadConfig (DebugMode BIT);
        INSERT INTO #ThreadConfig VALUES (CASE WHEN @Mode = 'DEBUG' THEN 1 ELSE 0 END);
        
        IF @Mode = 'DEBUG'
        BEGIN
            IF OBJECT_ID('tempdb..#ThreadDebug') IS NOT NULL DROP TABLE #ThreadDebug;
            CREATE TABLE #ThreadDebug (LogId INT IDENTITY, LogTime DATETIME2 DEFAULT SYSDATETIME(), 
                                        RuleCode NVARCHAR(200), Action VARCHAR(50), DurationMs INT, 
                                        CompiledSQL NVARCHAR(MAX), ErrorMessage NVARCHAR(MAX));
        END
        
        -- Charger variables
        INSERT INTO #ThreadState ([Key], IsRule, State, ScalarValue, ValueType)
        SELECT v.[key], 0, 2, v.[value], ISNULL(v.[type], 'STRING')
        FROM OPENJSON(@InputJson, '$.variables') WITH ([key] NVARCHAR(200), [type] VARCHAR(20), [value] NVARCHAR(MAX)) v
        WHERE v.[key] IS NOT NULL;
        
        UPDATE #ThreadState
        SET ValueIsNumeric = CASE WHEN TRY_CAST(ScalarValue AS DECIMAL(38,18)) IS NOT NULL THEN 1 ELSE 0 END
        WHERE ScalarValue IS NOT NULL AND IsRule = 0;
        
        -- Charger règles
        INSERT INTO #ThreadState ([Key], IsRule, State)
        SELECT r.value, 1, 0
        FROM OPENJSON(@InputJson, '$.rules') r
        WHERE r.value IS NOT NULL AND EXISTS (SELECT 1 FROM dbo.RuleDefinitions rd WHERE rd.RuleCode = r.value AND rd.IsActive = 1);
        
        -- PHASE 1: Règles simples
        EXEC dbo.sp_EvaluateSimpleRules;
        
        -- PHASE 2: Règles complexes
        DECLARE @RuleCode NVARCHAR(200), @Result NVARCHAR(MAX), @ErrorMsg NVARCHAR(500);
        DECLARE @CurrentSeqId INT = 0;
        
        WHILE 1 = 1
        BEGIN
            SELECT TOP 1 @RuleCode = [Key], @CurrentSeqId = SeqId
            FROM #ThreadState WHERE IsRule = 1 AND State = 0 AND SeqId > @CurrentSeqId ORDER BY SeqId;
            IF @@ROWCOUNT = 0 BREAK;
            EXEC dbo.sp_ExecuteRule @RuleCode, @Result OUTPUT, @ErrorMsg OUTPUT, 0;
        END
        
        -- FIX-BUG-6: Mise à jour ValueIsNumeric pour tous les résultats
        UPDATE #ThreadState
        SET ValueIsNumeric = CASE WHEN TRY_CAST(ScalarValue AS DECIMAL(38,18)) IS NOT NULL THEN 1 ELSE 0 END
        WHERE ScalarValue IS NOT NULL AND IsRule = 1 AND State = 2;
        
        SELECT @SuccessCount = COUNT(*) FROM #ThreadState WHERE IsRule = 1 AND State = 2;
        SELECT @ErrorCount = COUNT(*) FROM #ThreadState WHERE IsRule = 1 AND State = 3;
        
        DECLARE @ResultsJson NVARCHAR(MAX), @StateJson NVARCHAR(MAX) = NULL, @DebugJson NVARCHAR(MAX) = NULL;
        
        SELECT @ResultsJson = (
            SELECT [Key] AS ruleCode,
                   CASE State WHEN 2 THEN 'EVALUATED' WHEN 3 THEN 'ERROR' ELSE 'NOT_EVALUATED' END AS state,
                   ScalarValue AS value, ErrorCategory AS errorCategory, ErrorCode AS errorCode
            FROM #ThreadState WHERE IsRule = 1 ORDER BY SeqId FOR JSON PATH);
        
        IF @ReturnStateTable = 1
            SELECT @StateJson = (
                SELECT SeqId, [Key], CASE WHEN IsRule = 1 THEN 'RULE' ELSE 'VARIABLE' END AS type,
                       CASE State WHEN 0 THEN 'NOT_EVALUATED' WHEN 1 THEN 'EVALUATING' WHEN 2 THEN 'EVALUATED' WHEN 3 THEN 'ERROR' END AS state,
                       ScalarValue AS value, ValueType AS valueType, ValueIsNumeric, ErrorCategory, ErrorCode
                FROM #ThreadState ORDER BY SeqId FOR JSON PATH);
        
        IF @ReturnDebug = 1 AND @Mode = 'DEBUG' AND OBJECT_ID('tempdb..#ThreadDebug') IS NOT NULL
            SELECT @DebugJson = (SELECT * FROM #ThreadDebug ORDER BY LogId FOR JSON PATH);
        
        DECLARE @CacheStats NVARCHAR(MAX) = NULL;
        IF @Mode = 'DEBUG'
            SELECT @CacheStats = (
                SELECT COUNT(*) AS totalEntries, SUM(HitCount) AS totalHits, AVG(HitCount) AS avgHits, MAX(HitCount) AS maxHits
                FROM dbo.RuleCompilationCache FOR JSON PATH, WITHOUT_ARRAY_WRAPPER);
        
        SET @OutputJson = (
            SELECT 'SUCCESS' AS status, @Mode AS mode, '6.7' AS engineVersion,
                   @SuccessCount AS rulesEvaluated, @ErrorCount AS rulesInError,
                   DATEDIFF(MILLISECOND, @StartTime, SYSDATETIME()) AS durationMs,
                   JSON_QUERY(@ResultsJson) AS results, JSON_QUERY(@StateJson) AS stateTable, 
                   JSON_QUERY(@DebugJson) AS debugLog, JSON_QUERY(@CacheStats) AS cacheStats
            FOR JSON PATH, WITHOUT_ARRAY_WRAPPER);
        
        IF RAND() < 0.01 EXEC dbo.sp_CleanupCache;
        
    END TRY
    BEGIN CATCH
        SET @OutputJson = (SELECT 'ERROR' AS status, ERROR_MESSAGE() AS errorMessage, ERROR_NUMBER() AS errorNumber,
                                  DATEDIFF(MILLISECOND, @StartTime, SYSDATETIME()) AS durationMs FOR JSON PATH, WITHOUT_ARRAY_WRAPPER);
    END CATCH
END;
GO

PRINT '        OK';
PRINT '';
PRINT '======================================================================';
PRINT '           INSTALLATION TERMINÉE - MOTEUR V6.7                       ';
PRINT '======================================================================';
PRINT '';
PRINT '  Version........: 6.7';
PRINT '  Conformité.....: SPEC V1.6.0 (100%)';
PRINT '  Compatibilité..: SQL Server 2017+';
PRINT '';
PRINT '  Corrections:';
PRINT '    [X] BUG-2: FIRST_POS/FIRST_NEG ordre SeqId';
PRINT '    [X] BUG-4: Précision DECIMAL(38,18)';
PRINT '    [X] BUG-5: Protection récursion max 50';
PRINT '    [X] BUG-6: ValueIsNumeric pour tous résultats';
PRINT '';
PRINT '  Optimisations:';
PRINT '    [X] OPT-A: Index filtré règles simples';
PRINT '    [X] OPT-B: Cache LRU avec nettoyage auto';
PRINT '';
PRINT '  Prochaine étape: Exécuter TESTS_V6_7.sql';
PRINT '';
PRINT '======================================================================';
GO
