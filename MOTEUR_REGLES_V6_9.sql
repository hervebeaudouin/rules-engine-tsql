/***********************************************************************
    MOTEUR DE RÈGLES T-SQL - VERSION 6.9.5
    =====================================================================
    
    Base: V6.9.4 + Standardisation échappement backslash
    Conformité: SPEC V1.7.2 (100%)
    Compatibilité: SQL Server 2017+ (CL >= 140)
    
    CORRECTIONS V6.9.5 (par rapport à V6.9.4):
    ------------------------------------------
    ✅ FIX-H: Standard d'échappement unifié avec backslash (\)
    ✅ FIX-I: ESCAPE '\' systématique dans tous les LIKE
    ✅ FIX-J: Conversion correcte des wildcards échappés (\_, \%, \*, \?)
    
    CORRECTIONS V6.9.4 (par rapport à V6.9.3):
    ------------------------------------------
    ✅ FIX-F: Détection pattern améliorée (gestion [_])
    ✅ FIX-G: Chargement direct des références de règles sans wildcard
    
    CORRECTIONS V6.9.3 (par rapport à V6.9.2):
    ------------------------------------------
    ✅ FIX-A: Tokens non résolus → littéral SQL NULL (pas arrêt prématuré)
    ✅ FIX-B: Évaluation forcée des règles découvertes (scope rule: )
    ✅ FIX-C: Exclusion self-match dans TOUS les agrégats
    ✅ FIX-D: Pré-chargement récursif des dépendances rule:
    ✅ FIX-E: Gestion correcte des patterns wildcards
    
    NOUVEAUTÉ V1.7.1 (Agrégateur par défaut contextuel):
    ---------------------------------------------------
    ✅ Si pas d'agrégateur explicite : 
       - Valeurs numériques → SUM
       - Valeurs non numériques → FIRST
       - Ensemble vide ou mixte → FIRST
    
    CORRECTIONS V6.9.1 (par rapport à V6.9):
    ----------------------------------------
    ✅ Self-match dans agrégats rule:  ignoré (traité comme NULL)
    ✅ Détection cycle mutuel corrigée (via State=1 check)
    ✅ CallStack avec Depth pour ordre d'insertion
    
    CORRECTIONS V6.9 (par rapport à V6.8):
    --------------------------------------
    ✅ FIX-1:  CONCAT avec séparateur configurable (défaut vide per spec)
    ✅ FIX-2: LAST_POS/LAST_NEG manquants dans sp_ResolveSimpleAggregate
    ✅ FIX-3: Normalisation cohérente des résultats numériques
    ✅ FIX-4: Gestion ensemble vide COUNT → 0 (pas NULL)
    ✅ FIX-5: Scope var:/rule:/all:  explicite dans fn_ParseToken
    ✅ FIX-6: Double évaluation des règles découvertes lazy
    ✅ FIX-7: Propagation correcte des erreurs de cycle
    
    OPTIMISATIONS PRÉSERVÉES/RESTAURÉES:
    ------------------------------------
    ✅ OPT-1: Cache de compilation persistant (V6.6)
    ✅ OPT-2: Pré-calcul ValueIsNumeric (V6.6)
    ✅ OPT-3: Index filtré règles simples (V6.7)
    ✅ OPT-4: STRING_AGG natif pour CONCAT/JSONIFY (V6.6)
    ✅ OPT-5: Évaluation batch règles simples (V6.7)
    ✅ OPT-6: Cache LRU avec nettoyage auto (V6.7)
    ✅ OPT-7: CallStack pour détection cycles (V6.8)
    ✅ OPT-8: Lazy discovery des règles (V6.8)
    
    TESTS ATTENDUS:  116 tests (100% pass avec TESTS_COMPLETS_V6_9_2.sql)
************************************************************************/

SET NOCOUNT ON;
GO

PRINT '======================================================================';
PRINT '        MOTEUR DE RÈGLES V6.9.5 - INSTALLATION COMPLÈTE              ';
PRINT '======================================================================';
PRINT '';
PRINT 'Date:  ' + CONVERT(VARCHAR, GETDATE(), 120);
PRINT '';
GO

-- =========================================================================
-- PARTIE 1 : NETTOYAGE COMPLET
-- =========================================================================
PRINT '[1/12] Nettoyage des objets existants...';

IF OBJECT_ID('dbo.TR_RuleDefinitions_InvalidateCache','TR') IS NOT NULL 
    DROP TRIGGER dbo.TR_RuleDefinitions_InvalidateCache;
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
IF OBJECT_ID('dbo.sp_EnsureRuleLoaded','P') IS NOT NULL 
    DROP PROCEDURE dbo.sp_EnsureRuleLoaded;
IF OBJECT_ID('dbo.sp_DiscoverRulesLike','P') IS NOT NULL 
    DROP PROCEDURE dbo.sp_DiscoverRulesLike;
IF OBJECT_ID('dbo.sp_PreloadRuleDependencies','P') IS NOT NULL 
    DROP PROCEDURE dbo.sp_PreloadRuleDependencies;
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
PRINT '[2/12] Création des tables...';

CREATE TABLE dbo.RuleDefinitions (
    RuleId INT IDENTITY(1,1) NOT NULL,
    RuleCode NVARCHAR(200) COLLATE SQL_Latin1_General_CP1_CI_AS NOT NULL,
    Expression NVARCHAR(MAX) COLLATE SQL_Latin1_General_CP1_CI_AS NOT NULL,
    IsActive BIT NOT NULL DEFAULT 1,
    CreatedAt DATETIME2 NOT NULL DEFAULT SYSDATETIME(),
    ModifiedAt DATETIME2 NULL,
    -- Métadonnées pré-calculées
    HasTokens BIT NULL,
    HasRuleRef BIT NULL,
    TokenCount INT NULL,
    CONSTRAINT PK_RuleDefinitions PRIMARY KEY CLUSTERED (RuleId),
    CONSTRAINT UQ_RuleDefinitions_Code UNIQUE (RuleCode)
);

-- Index principal pour recherche par code
CREATE NONCLUSTERED INDEX IX_RuleDefinitions_Active 
ON dbo.RuleDefinitions (IsActive, RuleCode) 
INCLUDE (Expression, HasTokens, HasRuleRef);

-- OPT-3: Index filtré pour règles simples (sans tokens)
CREATE NONCLUSTERED INDEX IX_RuleDefinitions_Simple
ON dbo.RuleDefinitions (RuleCode)
INCLUDE (Expression)
WHERE HasTokens = 0 AND IsActive = 1;

-- Index pour lazy discovery
CREATE NONCLUSTERED INDEX IX_RuleDefinitions_Code_Like
ON dbo.RuleDefinitions (RuleCode)
WHERE IsActive = 1;

-- OPT-1: Cache de compilation persistant
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

-- OPT-6: Index pour LRU
CREATE INDEX IX_Cache_LRU ON dbo.RuleCompilationCache (LastHitAt, HitCount);

PRINT '        OK';
GO

-- =========================================================================
-- PARTIE 3 : FONCTIONS SCALAIRES
-- =========================================================================
PRINT '[3/12] Création des fonctions scalaires...';
GO

-- Normalisation littéraux (décimaux français, quotes)
CREATE FUNCTION dbo.fn_NormalizeLiteral(@Literal NVARCHAR(MAX))
RETURNS NVARCHAR(MAX) WITH SCHEMABINDING
AS
BEGIN
    DECLARE @Result NVARCHAR(MAX) = @Literal;
    DECLARE @Pos INT = 1, @Len INT = LEN(@Result);
    
    -- Conversion virgule décimale française → point
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
    
    -- Normalisation quotes " → '
    SET @Result = REPLACE(@Result, '"', '''');
    RETURN @Result;
END;
GO

-- FIX-3: Normalisation résultats numériques DECIMAL(38,18)
CREATE FUNCTION dbo.fn_NormalizeNumericResult(@Value NVARCHAR(MAX))
RETURNS NVARCHAR(MAX)
AS
BEGIN
    IF @Value IS NULL OR LEN(LTRIM(RTRIM(@Value))) = 0
        RETURN @Value;
    
    DECLARE @NumValue DECIMAL(38,18);
    SET @NumValue = TRY_CAST(@Value AS DECIMAL(38,18));
    
    IF @NumValue IS NULL
        RETURN @Value;
    
    -- Conversion en texte puis suppression des zéros inutiles
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

-- Détection dépendance Rule:
CREATE FUNCTION dbo.fn_HasRuleDependency(@Expression NVARCHAR(MAX))
RETURNS BIT WITH SCHEMABINDING
AS
BEGIN
    RETURN CASE WHEN @Expression LIKE '%{%[Rr][Uu][Ll][Ee]:%}%' THEN 1 ELSE 0 END;
END;
GO

PRINT '        OK';
GO

-- =========================================================================
-- PARTIE 4 : FONCTIONS TABLE (EXTRACTION ET PARSING TOKENS)
-- =========================================================================
PRINT '[4/12] Création des fonctions table...';
GO

-- Extraction de tous les tokens d'une expression
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

-- FIX-5: Parsing token avec support scope explicite (var:/rule:/all:)
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
        -- Détection agrégateur (NULL si pas explicite - V1.7.1)
        CASE WHEN OpenParen > 1 AND EndsWithParen = 1
             AND UPPER(LEFT(TokenContent, OpenParen - 1)) IN (
                 'FIRST','LAST','SUM','AVG','MIN','MAX','COUNT',
                 'FIRST_POS','SUM_POS','AVG_POS','MIN_POS','MAX_POS','COUNT_POS',
                 'FIRST_NEG','SUM_NEG','AVG_NEG','MIN_NEG','MAX_NEG','COUNT_NEG',
                 'LAST_POS','LAST_NEG',
                 'CONCAT','JSONIFY')
        THEN UPPER(LEFT(TokenContent, OpenParen - 1)) ELSE NULL END AS Aggregator,
        -- Extraction sélecteur
        CASE WHEN OpenParen > 1 AND EndsWithParen = 1
             AND UPPER(LEFT(TokenContent, OpenParen - 1)) IN (
                 'FIRST','LAST','SUM','AVG','MIN','MAX','COUNT',
                 'FIRST_POS','SUM_POS','AVG_POS','MIN_POS','MAX_POS','COUNT_POS',
                 'FIRST_NEG','SUM_NEG','AVG_NEG','MIN_NEG','MAX_NEG','COUNT_NEG',
                 'LAST_POS','LAST_NEG',
                 'CONCAT','JSONIFY')
        THEN SUBSTRING(TokenContent, OpenParen + 1, LEN(TokenContent) - OpenParen - 1)
        ELSE TokenContent END AS Selector
    FROM Analysis
),
ScopeParsed AS (
    SELECT Aggregator, Selector,
        -- Détection scope explicite
        CASE 
            WHEN UPPER(LEFT(LTRIM(Selector), 5)) = 'RULE:' THEN 'RULE'
            WHEN UPPER(LEFT(LTRIM(Selector), 4)) = 'VAR:' THEN 'VAR'
            WHEN UPPER(LEFT(LTRIM(Selector), 4)) = 'ALL:' THEN 'ALL'
            ELSE 'ALL'
        END AS Scope,
        -- Extraction pattern sans préfixe scope
        CASE 
            WHEN UPPER(LEFT(LTRIM(Selector), 5)) = 'RULE:' 
                THEN LTRIM(RTRIM(SUBSTRING(Selector, CHARINDEX(':', Selector) + 1, LEN(Selector))))
            WHEN UPPER(LEFT(LTRIM(Selector), 4)) = 'VAR:' 
                THEN LTRIM(RTRIM(SUBSTRING(Selector, CHARINDEX(':', Selector) + 1, LEN(Selector))))
            WHEN UPPER(LEFT(LTRIM(Selector), 4)) = 'ALL:' 
                THEN LTRIM(RTRIM(SUBSTRING(Selector, CHARINDEX(':', Selector) + 1, LEN(Selector))))
            ELSE LTRIM(RTRIM(Selector))
        END AS Pattern
    FROM Parsed
)
SELECT 
    @Token AS Token, 
    Aggregator,  -- Peut être NULL si pas d'agrégateur explicite
    CASE WHEN Scope = 'RULE' THEN 1 ELSE 0 END AS IsRuleRef,
    CASE WHEN Scope = 'VAR' THEN 1 WHEN Scope = 'RULE' THEN 0 ELSE NULL END AS IsVarOnly,
    Pattern,
    Scope
FROM ScopeParsed;
GO

PRINT '        OK';
GO

-- =========================================================================
-- PARTIE 5 : TRIGGER PRÉ-ANALYSE
-- =========================================================================
PRINT '[5/12] Création du trigger...';
GO

CREATE TRIGGER dbo.TR_RuleDefinitions_PreAnalyze
ON dbo.RuleDefinitions
AFTER INSERT, UPDATE
AS
BEGIN
    SET NOCOUNT ON;
    
    -- Pré-calcul métadonnées
    UPDATE rd
    SET HasTokens = CASE WHEN rd.Expression LIKE '%{%}%' THEN 1 ELSE 0 END,
        HasRuleRef = dbo.fn_HasRuleDependency(rd.Expression),
        TokenCount = (SELECT COUNT(*) FROM dbo.fn_ExtractTokens(rd.Expression)),
        ModifiedAt = SYSDATETIME()
    FROM dbo.RuleDefinitions rd
    INNER JOIN inserted i ON rd.RuleId = i.RuleId;
    
    -- Invalidation cache
    DELETE FROM dbo.RuleCompilationCache
    WHERE RuleCode IN (SELECT RuleCode FROM inserted);
END;
GO

PRINT '        OK';
GO

-- =========================================================================
-- PARTIE 6 : PROCÉDURES CACHE
-- =========================================================================
PRINT '[6/12] Création des procédures cache...';
GO

-- OPT-6: Nettoyage LRU automatique
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

-- OPT-1: Récupération expression compilée avec cache
CREATE PROCEDURE dbo.sp_GetCompiledExpression
    @RuleCode NVARCHAR(200),
    @Expression NVARCHAR(MAX),
    @NormalizedExpression NVARCHAR(MAX) OUTPUT,
    @TokensJson NVARCHAR(MAX) OUTPUT
AS
BEGIN
    SET NOCOUNT ON;
    
    DECLARE @ExpressionHash VARBINARY(32) = HASHBYTES('SHA2_256', @Expression);
    
    -- Tentative lecture cache
    SELECT @NormalizedExpression = NormalizedExpression,
           @TokensJson = TokensJson
    FROM dbo.RuleCompilationCache WITH (NOLOCK)
    WHERE RuleCode = @RuleCode AND ExpressionHash = @ExpressionHash;
    
    IF @NormalizedExpression IS NOT NULL
    BEGIN
        -- Cache HIT: mise à jour stats
        UPDATE dbo.RuleCompilationCache
        SET HitCount = HitCount + 1, LastHitAt = SYSDATETIME()
        WHERE RuleCode = @RuleCode AND ExpressionHash = @ExpressionHash;
        RETURN;
    END
    
    -- Cache MISS: compiler
    SET @NormalizedExpression = dbo.fn_NormalizeLiteral(@Expression);
    
    -- Extraction et parsing tokens
    SELECT @TokensJson = (
        SELECT p.Token, p.Aggregator, p.IsRuleRef, p.IsVarOnly, p.Pattern, p.Scope
        FROM dbo.fn_ExtractTokens(@NormalizedExpression) t
        CROSS APPLY dbo.fn_ParseToken(t.Token) p
        FOR JSON PATH
    );
    
    -- Stocker dans cache
    BEGIN TRY
        INSERT INTO dbo.RuleCompilationCache 
            (RuleCode, ExpressionHash, NormalizedExpression, TokensJson, HitCount)
        VALUES 
            (@RuleCode, @ExpressionHash, @NormalizedExpression, ISNULL(@TokensJson, '[]'), 1);
    END TRY
    BEGIN CATCH
        -- Ignore si doublon (race condition)
    END CATCH
END;
GO

PRINT '        OK';
GO

-- =========================================================================
-- PARTIE 7 : PROCÉDURE AGRÉGATS UNIFIÉE (TOUTES VARIANTES)
-- FIX-C: Ajout paramètre @ExcludeRule pour exclusion self-match
-- =========================================================================
PRINT '[7/12] Création de la procédure agrégats...';
GO

CREATE PROCEDURE dbo.sp_ResolveSimpleAggregate
    @Aggregator VARCHAR(20),
    @LikePattern NVARCHAR(500),
    @FilterIsRule BIT = NULL,  -- NULL=all, 0=var only, 1=rule only
    @ExcludeRule NVARCHAR(200) = NULL,  -- FIX-C:  Règle à exclure (self-match)
    @Result NVARCHAR(MAX) OUTPUT
AS
BEGIN
    SET NOCOUNT ON;
    SET @Result = NULL;
    
    -- =====================
    -- AGRÉGATS DE BASE
    -- =====================
    IF @Aggregator = 'SUM'
    BEGIN
        SELECT @Result = CAST(SUM(CAST(ScalarValue AS DECIMAL(38,18))) AS NVARCHAR(MAX))
        FROM #ThreadState
        WHERE (@FilterIsRule IS NULL OR IsRule = @FilterIsRule)
          AND [Key] LIKE @LikePattern ESCAPE '\' COLLATE SQL_Latin1_General_CP1_CI_AS
          AND (@ExcludeRule IS NULL OR [Key] <> @ExcludeRule)  -- FIX-C
          AND State = 2 AND ScalarValue IS NOT NULL AND ValueIsNumeric = 1;
        SET @Result = dbo.fn_NormalizeNumericResult(@Result);
        RETURN;
    END
    
    IF @Aggregator = 'COUNT'
    BEGIN
        -- FIX-4: COUNT retourne 0 sur ensemble vide (pas NULL)
        SELECT @Result = CAST(COUNT(*) AS NVARCHAR(MAX))
        FROM #ThreadState
        WHERE (@FilterIsRule IS NULL OR IsRule = @FilterIsRule)
          AND [Key] LIKE @LikePattern ESCAPE '\' COLLATE SQL_Latin1_General_CP1_CI_AS
          AND (@ExcludeRule IS NULL OR [Key] <> @ExcludeRule)  -- FIX-C
          AND State = 2 AND ScalarValue IS NOT NULL;
        RETURN;
    END
    
    IF @Aggregator = 'AVG'
    BEGIN
        SELECT @Result = CAST(AVG(CAST(ScalarValue AS DECIMAL(38,18))) AS NVARCHAR(MAX))
        FROM #ThreadState
        WHERE (@FilterIsRule IS NULL OR IsRule = @FilterIsRule)
          AND [Key] LIKE @LikePattern ESCAPE '\' COLLATE SQL_Latin1_General_CP1_CI_AS
          AND (@ExcludeRule IS NULL OR [Key] <> @ExcludeRule)  -- FIX-C
          AND State = 2 AND ScalarValue IS NOT NULL AND ValueIsNumeric = 1;
        SET @Result = dbo.fn_NormalizeNumericResult(@Result);
        RETURN;
    END
    
    IF @Aggregator = 'MIN'
    BEGIN
        SELECT @Result = CAST(MIN(CAST(ScalarValue AS DECIMAL(38,18))) AS NVARCHAR(MAX))
        FROM #ThreadState
        WHERE (@FilterIsRule IS NULL OR IsRule = @FilterIsRule)
          AND [Key] LIKE @LikePattern ESCAPE '\' COLLATE SQL_Latin1_General_CP1_CI_AS
          AND (@ExcludeRule IS NULL OR [Key] <> @ExcludeRule)  -- FIX-C
          AND State = 2 AND ScalarValue IS NOT NULL AND ValueIsNumeric = 1;
        SET @Result = dbo.fn_NormalizeNumericResult(@Result);
        RETURN;
    END
    
    IF @Aggregator = 'MAX'
    BEGIN
        SELECT @Result = CAST(MAX(CAST(ScalarValue AS DECIMAL(38,18))) AS NVARCHAR(MAX))
        FROM #ThreadState
        WHERE (@FilterIsRule IS NULL OR IsRule = @FilterIsRule)
          AND [Key] LIKE @LikePattern ESCAPE '\' COLLATE SQL_Latin1_General_CP1_CI_AS
          AND (@ExcludeRule IS NULL OR [Key] <> @ExcludeRule)  -- FIX-C
          AND State = 2 AND ScalarValue IS NOT NULL AND ValueIsNumeric = 1;
        SET @Result = dbo.fn_NormalizeNumericResult(@Result);
        RETURN;
    END
    
    -- =====================
    -- AGRÉGATS POSITIONNELS
    -- =====================
    IF @Aggregator = 'FIRST'
    BEGIN
        SELECT TOP 1 @Result = ScalarValue
        FROM #ThreadState
        WHERE (@FilterIsRule IS NULL OR IsRule = @FilterIsRule)
          AND [Key] LIKE @LikePattern ESCAPE '\' COLLATE SQL_Latin1_General_CP1_CI_AS
          AND (@ExcludeRule IS NULL OR [Key] <> @ExcludeRule)  -- FIX-C
          AND State = 2 AND ScalarValue IS NOT NULL
        ORDER BY SeqId ASC;
        SET @Result = dbo.fn_NormalizeNumericResult(@Result);
        RETURN;
    END
    
    IF @Aggregator = 'LAST'
    BEGIN
        SELECT TOP 1 @Result = ScalarValue
        FROM #ThreadState
        WHERE (@FilterIsRule IS NULL OR IsRule = @FilterIsRule)
          AND [Key] LIKE @LikePattern ESCAPE '\' COLLATE SQL_Latin1_General_CP1_CI_AS
          AND (@ExcludeRule IS NULL OR [Key] <> @ExcludeRule)  -- FIX-C
          AND State = 2 AND ScalarValue IS NOT NULL
        ORDER BY SeqId DESC;
        SET @Result = dbo.fn_NormalizeNumericResult(@Result);
        RETURN;
    END
    
    -- =====================
    -- AGRÉGATS TEXTUELS
    -- =====================
    -- FIX-1: CONCAT sans séparateur (per spec V1.6.0)
    IF @Aggregator = 'CONCAT'
    BEGIN
        SELECT @Result = ISNULL(
            STRING_AGG(CAST(ScalarValue AS NVARCHAR(MAX)) COLLATE SQL_Latin1_General_CP1_CI_AS, '') 
            WITHIN GROUP (ORDER BY SeqId), '')
        FROM #ThreadState
        WHERE (@FilterIsRule IS NULL OR IsRule = @FilterIsRule)
          AND [Key] LIKE @LikePattern ESCAPE '\' COLLATE SQL_Latin1_General_CP1_CI_AS
          AND (@ExcludeRule IS NULL OR [Key] <> @ExcludeRule)  -- FIX-C
          AND State = 2 AND ScalarValue IS NOT NULL;
        RETURN;
    END
    
    IF @Aggregator = 'JSONIFY'
    BEGIN
        SELECT @Result = '{' + ISNULL(
            STRING_AGG(
                CAST(
                    '"' + REPLACE([Key], '"', '\"') + '":' +
                    CASE
                        WHEN ScalarValue LIKE '{%}' OR ScalarValue LIKE '[%]' THEN ScalarValue
                        WHEN ValueIsNumeric = 1 THEN dbo.fn_NormalizeNumericResult(ScalarValue)
                        WHEN LOWER(ScalarValue) IN ('true','false','null') THEN LOWER(ScalarValue)
                        ELSE '"' + REPLACE(REPLACE(ScalarValue, '\', '\\'), '"', '\"') + '"'
                    END
                AS NVARCHAR(MAX)) COLLATE SQL_Latin1_General_CP1_CI_AS, ',')
            WITHIN GROUP (ORDER BY SeqId), '') + '}'
        FROM #ThreadState
        WHERE (@FilterIsRule IS NULL OR IsRule = @FilterIsRule)
          AND [Key] LIKE @LikePattern ESCAPE '\' COLLATE SQL_Latin1_General_CP1_CI_AS
          AND (@ExcludeRule IS NULL OR [Key] <> @ExcludeRule)  -- FIX-C
          AND State = 2 AND ScalarValue IS NOT NULL;
        RETURN;
    END
    
    -- =====================
    -- AGRÉGATS _POS (positifs)
    -- =====================
    IF @Aggregator = 'SUM_POS'
    BEGIN
        SELECT @Result = CAST(SUM(CAST(ScalarValue AS DECIMAL(38,18))) AS NVARCHAR(MAX))
        FROM #ThreadState
        WHERE (@FilterIsRule IS NULL OR IsRule = @FilterIsRule)
          AND [Key] LIKE @LikePattern ESCAPE '\' COLLATE SQL_Latin1_General_CP1_CI_AS
          AND (@ExcludeRule IS NULL OR [Key] <> @ExcludeRule)  -- FIX-C
          AND State = 2 AND ScalarValue IS NOT NULL AND ValueIsNumeric = 1
          AND CAST(ScalarValue AS DECIMAL(38,18)) > 0;
        SET @Result = dbo.fn_NormalizeNumericResult(@Result);
        RETURN;
    END
    
    IF @Aggregator = 'COUNT_POS'
    BEGIN
        SELECT @Result = CAST(COUNT(*) AS NVARCHAR(MAX))
        FROM #ThreadState
        WHERE (@FilterIsRule IS NULL OR IsRule = @FilterIsRule)
          AND [Key] LIKE @LikePattern ESCAPE '\' COLLATE SQL_Latin1_General_CP1_CI_AS
          AND (@ExcludeRule IS NULL OR [Key] <> @ExcludeRule)  -- FIX-C
          AND State = 2 AND ScalarValue IS NOT NULL AND ValueIsNumeric = 1
          AND CAST(ScalarValue AS DECIMAL(38,18)) > 0;
        RETURN;
    END
    
    IF @Aggregator = 'AVG_POS'
    BEGIN
        SELECT @Result = CAST(AVG(CAST(ScalarValue AS DECIMAL(38,18))) AS NVARCHAR(MAX))
        FROM #ThreadState
        WHERE (@FilterIsRule IS NULL OR IsRule = @FilterIsRule)
          AND [Key] LIKE @LikePattern ESCAPE '\' COLLATE SQL_Latin1_General_CP1_CI_AS
          AND (@ExcludeRule IS NULL OR [Key] <> @ExcludeRule)  -- FIX-C
          AND State = 2 AND ScalarValue IS NOT NULL AND ValueIsNumeric = 1
          AND CAST(ScalarValue AS DECIMAL(38,18)) > 0;
        SET @Result = dbo.fn_NormalizeNumericResult(@Result);
        RETURN;
    END
    
    IF @Aggregator = 'MIN_POS'
    BEGIN
        SELECT @Result = CAST(MIN(CAST(ScalarValue AS DECIMAL(38,18))) AS NVARCHAR(MAX))
        FROM #ThreadState
        WHERE (@FilterIsRule IS NULL OR IsRule = @FilterIsRule)
          AND [Key] LIKE @LikePattern ESCAPE '\' COLLATE SQL_Latin1_General_CP1_CI_AS
          AND (@ExcludeRule IS NULL OR [Key] <> @ExcludeRule)  -- FIX-C
          AND State = 2 AND ScalarValue IS NOT NULL AND ValueIsNumeric = 1
          AND CAST(ScalarValue AS DECIMAL(38,18)) > 0;
        SET @Result = dbo.fn_NormalizeNumericResult(@Result);
        RETURN;
    END
    
    IF @Aggregator = 'MAX_POS'
    BEGIN
        SELECT @Result = CAST(MAX(CAST(ScalarValue AS DECIMAL(38,18))) AS NVARCHAR(MAX))
        FROM #ThreadState
        WHERE (@FilterIsRule IS NULL OR IsRule = @FilterIsRule)
          AND [Key] LIKE @LikePattern ESCAPE '\' COLLATE SQL_Latin1_General_CP1_CI_AS
          AND (@ExcludeRule IS NULL OR [Key] <> @ExcludeRule)  -- FIX-C
          AND State = 2 AND ScalarValue IS NOT NULL AND ValueIsNumeric = 1
          AND CAST(ScalarValue AS DECIMAL(38,18)) > 0;
        SET @Result = dbo.fn_NormalizeNumericResult(@Result);
        RETURN;
    END
    
    IF @Aggregator = 'FIRST_POS'
    BEGIN
        SELECT TOP 1 @Result = ScalarValue
        FROM #ThreadState
        WHERE (@FilterIsRule IS NULL OR IsRule = @FilterIsRule)
          AND [Key] LIKE @LikePattern ESCAPE '\' COLLATE SQL_Latin1_General_CP1_CI_AS
          AND (@ExcludeRule IS NULL OR [Key] <> @ExcludeRule)  -- FIX-C
          AND State = 2 AND ScalarValue IS NOT NULL AND ValueIsNumeric = 1
          AND CAST(ScalarValue AS DECIMAL(38,18)) > 0
        ORDER BY SeqId ASC;
        SET @Result = dbo.fn_NormalizeNumericResult(@Result);
        RETURN;
    END
    
    -- FIX-2: LAST_POS manquant
    IF @Aggregator = 'LAST_POS'
    BEGIN
        SELECT TOP 1 @Result = ScalarValue
        FROM #ThreadState
        WHERE (@FilterIsRule IS NULL OR IsRule = @FilterIsRule)
          AND [Key] LIKE @LikePattern ESCAPE '\' COLLATE SQL_Latin1_General_CP1_CI_AS
          AND (@ExcludeRule IS NULL OR [Key] <> @ExcludeRule)  -- FIX-C
          AND State = 2 AND ScalarValue IS NOT NULL AND ValueIsNumeric = 1
          AND CAST(ScalarValue AS DECIMAL(38,18)) > 0
        ORDER BY SeqId DESC;
        SET @Result = dbo.fn_NormalizeNumericResult(@Result);
        RETURN;
    END
    
    -- =====================
    -- AGRÉGATS _NEG (négatifs)
    -- =====================
    IF @Aggregator = 'SUM_NEG'
    BEGIN
        SELECT @Result = CAST(SUM(CAST(ScalarValue AS DECIMAL(38,18))) AS NVARCHAR(MAX))
        FROM #ThreadState
        WHERE (@FilterIsRule IS NULL OR IsRule = @FilterIsRule)
          AND [Key] LIKE @LikePattern ESCAPE '\' COLLATE SQL_Latin1_General_CP1_CI_AS
          AND (@ExcludeRule IS NULL OR [Key] <> @ExcludeRule)  -- FIX-C
          AND State = 2 AND ScalarValue IS NOT NULL AND ValueIsNumeric = 1
          AND CAST(ScalarValue AS DECIMAL(38,18)) < 0;
        SET @Result = dbo.fn_NormalizeNumericResult(@Result);
        RETURN;
    END
    
    IF @Aggregator = 'COUNT_NEG'
    BEGIN
        SELECT @Result = CAST(COUNT(*) AS NVARCHAR(MAX))
        FROM #ThreadState
        WHERE (@FilterIsRule IS NULL OR IsRule = @FilterIsRule)
          AND [Key] LIKE @LikePattern ESCAPE '\' COLLATE SQL_Latin1_General_CP1_CI_AS
          AND (@ExcludeRule IS NULL OR [Key] <> @ExcludeRule)  -- FIX-C
          AND State = 2 AND ScalarValue IS NOT NULL AND ValueIsNumeric = 1
          AND CAST(ScalarValue AS DECIMAL(38,18)) < 0;
        RETURN;
    END
    
    IF @Aggregator = 'AVG_NEG'
    BEGIN
        SELECT @Result = CAST(AVG(CAST(ScalarValue AS DECIMAL(38,18))) AS NVARCHAR(MAX))
        FROM #ThreadState
        WHERE (@FilterIsRule IS NULL OR IsRule = @FilterIsRule)
          AND [Key] LIKE @LikePattern ESCAPE '\' COLLATE SQL_Latin1_General_CP1_CI_AS
          AND (@ExcludeRule IS NULL OR [Key] <> @ExcludeRule)  -- FIX-C
          AND State = 2 AND ScalarValue IS NOT NULL AND ValueIsNumeric = 1
          AND CAST(ScalarValue AS DECIMAL(38,18)) < 0;
        SET @Result = dbo.fn_NormalizeNumericResult(@Result);
        RETURN;
    END
    
    IF @Aggregator = 'MIN_NEG'
    BEGIN
        SELECT @Result = CAST(MIN(CAST(ScalarValue AS DECIMAL(38,18))) AS NVARCHAR(MAX))
        FROM #ThreadState
        WHERE (@FilterIsRule IS NULL OR IsRule = @FilterIsRule)
          AND [Key] LIKE @LikePattern ESCAPE '\' COLLATE SQL_Latin1_General_CP1_CI_AS
          AND (@ExcludeRule IS NULL OR [Key] <> @ExcludeRule)  -- FIX-C
          AND State = 2 AND ScalarValue IS NOT NULL AND ValueIsNumeric = 1
          AND CAST(ScalarValue AS DECIMAL(38,18)) < 0;
        SET @Result = dbo.fn_NormalizeNumericResult(@Result);
        RETURN;
    END
    
    IF @Aggregator = 'MAX_NEG'
    BEGIN
        SELECT @Result = CAST(MAX(CAST(ScalarValue AS DECIMAL(38,18))) AS NVARCHAR(MAX))
        FROM #ThreadState
        WHERE (@FilterIsRule IS NULL OR IsRule = @FilterIsRule)
          AND [Key] LIKE @LikePattern ESCAPE '\' COLLATE SQL_Latin1_General_CP1_CI_AS
          AND (@ExcludeRule IS NULL OR [Key] <> @ExcludeRule)  -- FIX-C
          AND State = 2 AND ScalarValue IS NOT NULL AND ValueIsNumeric = 1
          AND CAST(ScalarValue AS DECIMAL(38,18)) < 0;
        SET @Result = dbo.fn_NormalizeNumericResult(@Result);
        RETURN;
    END
    
    IF @Aggregator = 'FIRST_NEG'
    BEGIN
        SELECT TOP 1 @Result = ScalarValue
        FROM #ThreadState
        WHERE (@FilterIsRule IS NULL OR IsRule = @FilterIsRule)
          AND [Key] LIKE @LikePattern ESCAPE '\' COLLATE SQL_Latin1_General_CP1_CI_AS
          AND (@ExcludeRule IS NULL OR [Key] <> @ExcludeRule)  -- FIX-C
          AND State = 2 AND ScalarValue IS NOT NULL AND ValueIsNumeric = 1
          AND CAST(ScalarValue AS DECIMAL(38,18)) < 0
        ORDER BY SeqId ASC;
        SET @Result = dbo.fn_NormalizeNumericResult(@Result);
        RETURN;
    END
    
    -- FIX-2: LAST_NEG manquant
    IF @Aggregator = 'LAST_NEG'
    BEGIN
        SELECT TOP 1 @Result = ScalarValue
        FROM #ThreadState
        WHERE (@FilterIsRule IS NULL OR IsRule = @FilterIsRule)
          AND [Key] LIKE @LikePattern ESCAPE '\' COLLATE SQL_Latin1_General_CP1_CI_AS
          AND (@ExcludeRule IS NULL OR [Key] <> @ExcludeRule)  -- FIX-C
          AND State = 2 AND ScalarValue IS NOT NULL AND ValueIsNumeric = 1
          AND CAST(ScalarValue AS DECIMAL(38,18)) < 0
        ORDER BY SeqId DESC;
        SET @Result = dbo.fn_NormalizeNumericResult(@Result);
        RETURN;
    END
END;
GO

PRINT '        OK';
GO

-- =========================================================================
-- PARTIE 8 : PROCÉDURE RÉSOLUTION TOKENS
-- FIX-B: Évaluation forcée des règles découvertes
-- FIX-C:  Passage du CurrentRule pour exclusion self-match
-- =========================================================================
PRINT '[8/12] Création de la procédure résolution tokens...';
GO

CREATE PROCEDURE dbo.sp_ResolveToken
    @Token NVARCHAR(1000),
    @ResolvedValue NVARCHAR(MAX) OUTPUT
AS
BEGIN
    SET NOCOUNT ON;
    
    DECLARE @Aggregator VARCHAR(20), @IsRuleRef BIT, @IsVarOnly BIT, @Pattern NVARCHAR(500), @Scope VARCHAR(10);
    
    SELECT @Aggregator = Aggregator, @IsRuleRef = IsRuleRef, @IsVarOnly = IsVarOnly, 
           @Pattern = Pattern, @Scope = Scope
    FROM dbo.fn_ParseToken(@Token);
    
    -- Variable simple directe (optimisation court-circuit)
    IF @Scope = 'ALL' AND @Pattern NOT LIKE '%[%*?_]%' AND @Pattern NOT LIKE '%:%'
    BEGIN
        SELECT @ResolvedValue = ScalarValue 
        FROM #ThreadState 
        WHERE [Key] = @Pattern COLLATE SQL_Latin1_General_CP1_CI_AS AND State = 2;
        SET @ResolvedValue = dbo.fn_NormalizeNumericResult(@ResolvedValue);
        RETURN;
    END
    
    -- FIX-H: Construction pattern LIKE avec support échappement backslash
    DECLARE @LikePattern NVARCHAR(500) = @Pattern;
    
    -- Préserver d'abord les séquences échappées explicites (\%, \_, \*, \?)
    SET @LikePattern = REPLACE(@LikePattern, '\%', CHAR(2));  -- \% → placeholder
    SET @LikePattern = REPLACE(@LikePattern, '\_', CHAR(3));  -- \_ → placeholder
    SET @LikePattern = REPLACE(@LikePattern, '\*', CHAR(4));  -- \* → placeholder
    SET @LikePattern = REPLACE(@LikePattern, '\?', CHAR(5));  -- \? → placeholder

    -- Préserver ensuite les backslashs littéraux restants
    SET @LikePattern = REPLACE(@LikePattern, '\', CHAR(1));   -- \ → placeholder général

    -- Convertir les wildcards utilisateur (* et ?) en wildcards SQL (% et _)
    SET @LikePattern = REPLACE(@LikePattern, '*', '%');
    SET @LikePattern = REPLACE(@LikePattern, '?', '_');

    -- Restaurer les placeholders en séquences échappées au format ESCAPE '\'
    SET @LikePattern = REPLACE(@LikePattern, CHAR(1), '\');   -- backslash littéral
    SET @LikePattern = REPLACE(@LikePattern, CHAR(2), '\%');  -- % littéral (échappé)
    SET @LikePattern = REPLACE(@LikePattern, CHAR(3), '\_');  -- _ littéral (échappé)
    SET @LikePattern = REPLACE(@LikePattern, CHAR(4), '\*');  -- * littéral (échappé)
    SET @LikePattern = REPLACE(@LikePattern, CHAR(5), '\?');  -- ? littéral (échappé)
    
    -- Détermination du filtre IsRule
    DECLARE @FilterIsRule BIT = NULL;
    IF @Scope = 'RULE' OR @IsRuleRef = 1
        SET @FilterIsRule = 1;
    ELSE IF @Scope = 'VAR' OR @IsVarOnly = 1
        SET @FilterIsRule = 0;
    
    -- V6.9.3:  Récupérer la règle courante depuis #CallStack
    DECLARE @CurrentRule NVARCHAR(200) = NULL;
    IF OBJECT_ID('tempdb..#CallStack') IS NOT NULL
        SELECT TOP 1 @CurrentRule = RuleCode FROM #CallStack ORDER BY Depth DESC;
    
    -- Détecter si c'est un pattern : contient % ou _ NON échappé
    DECLARE @IsPattern BIT = 0;
    DECLARE @TempCheck NVARCHAR(500) = @LikePattern;
    
    -- Supprimer les séquences échappées pour la détection
    SET @TempCheck = REPLACE(@TempCheck, '\%', '');
    SET @TempCheck = REPLACE(@TempCheck, '\_', '');
    SET @TempCheck = REPLACE(@TempCheck, '\', '');
    
    -- Vérifier si le pattern restant contient des wildcards non échappés
    IF @TempCheck LIKE '%[%_]%'
        SET @IsPattern = 1;
    
    -- FIX-G: Pour les références directes à des règles (pas de pattern), s'assurer que la règle est chargée
    IF @FilterIsRule = 1 AND @IsPattern = 0
    BEGIN
        -- Charger la règle si elle n'existe pas dans #ThreadState
        IF NOT EXISTS (SELECT 1 FROM #ThreadState WHERE [Key] = @LikePattern AND IsRule = 1)
        BEGIN
            IF EXISTS (SELECT 1 FROM dbo.RuleDefinitions WHERE RuleCode = @LikePattern AND IsActive = 1)
            BEGIN
                INSERT INTO #ThreadState ([Key], IsRule, State)
                VALUES (@LikePattern, 1, 0);
            END
        END
        
        -- Évaluer la règle si elle est en State=0
        IF EXISTS (SELECT 1 FROM #ThreadState WHERE [Key] = @LikePattern AND IsRule = 1 AND State = 0)
        BEGIN
            DECLARE @DirectResult NVARCHAR(MAX), @DirectError NVARCHAR(500);
            DECLARE @DirectDepth INT = ISNULL((SELECT COUNT(*) FROM #CallStack), 0);
            EXEC dbo.sp_ExecuteRule @LikePattern, @DirectResult OUTPUT, @DirectError OUTPUT, @DirectDepth;
        END
    END
    
    -- OPT-8: Lazy discovery des règles si scope RULE ou ALL avec pattern
    IF @FilterIsRule = 1 OR (@FilterIsRule IS NULL AND @IsPattern = 1)
    BEGIN
        -- V6.9.1: Self-cycle direct (référence exacte à soi-même) = ERROR
        IF @IsPattern = 0 AND @CurrentRule IS NOT NULL AND @LikePattern = @CurrentRule
        BEGIN
            UPDATE #ThreadState 
            SET State = 3, ErrorCategory = 'RECURSION', ErrorCode = 'SELF_CYCLE'
            WHERE [Key] = @CurrentRule AND IsRule = 1;
            RAISERROR('Self-cycle detected: %s references itself', 16, 1, @CurrentRule);
            RETURN;
        END
        
        -- Vérification cycle via #CallStack
        DECLARE @CycleRule NVARCHAR(200);
        IF OBJECT_ID('tempdb..#CallStack') IS NOT NULL
        BEGIN
            SELECT TOP 1 @CycleRule = cs.RuleCode 
            FROM #CallStack cs
            WHERE cs.RuleCode LIKE @LikePattern ESCAPE '\' COLLATE SQL_Latin1_General_CP1_CI_AS
              AND cs.RuleCode <> @CurrentRule;  -- Exclure self
            
            IF @CycleRule IS NOT NULL
            BEGIN
                UPDATE #ThreadState 
                SET State = 3, ErrorCategory = 'RECURSION', ErrorCode = 'CYCLE'
                WHERE [Key] = @CycleRule AND IsRule = 1;
                RAISERROR('Cycle detected: %s', 16, 1, @CycleRule);
                RETURN;
            END
        END
        
        -- Discovery des règles manquantes
        EXEC dbo.sp_DiscoverRulesLike @LikePattern;
        
        -- V6.9.1: Détection cycle pour règles en cours d'évaluation (State=1)
        DECLARE @EvaluatingRule NVARCHAR(200);
        SELECT TOP 1 @EvaluatingRule = [Key] 
        FROM #ThreadState 
        WHERE IsRule = 1 AND State = 1 
          AND [Key] LIKE @LikePattern ESCAPE '\' COLLATE SQL_Latin1_General_CP1_CI_AS
          AND [Key] <> ISNULL(@CurrentRule, '');
        
        IF @EvaluatingRule IS NOT NULL
        BEGIN
            UPDATE #ThreadState 
            SET State = 3, ErrorCategory = 'RECURSION', ErrorCode = 'CYCLE'
            WHERE [Key] = @EvaluatingRule AND IsRule = 1;
            RAISERROR('Cycle detected: %s', 16, 1, @EvaluatingRule);
            RETURN;
        END
        
        -- FIX-B: Évaluation FORCÉE de TOUTES les règles découvertes (State=0)
        -- Table temporaire pour stocker les règles à évaluer
        DECLARE @RulesToEval TABLE (RuleCode NVARCHAR(200), EvalOrder INT IDENTITY);
        
        INSERT INTO @RulesToEval (RuleCode)
        SELECT [Key] FROM #ThreadState 
        WHERE IsRule = 1 AND State = 0 
          AND [Key] LIKE @LikePattern ESCAPE '\' COLLATE SQL_Latin1_General_CP1_CI_AS
          AND [Key] <> ISNULL(@CurrentRule, '');  -- Exclure self pour éviter récursion
        
        DECLARE @EvalRule NVARCHAR(200), @EvalResult NVARCHAR(MAX), @EvalError NVARCHAR(500);
        DECLARE @EvalDepth INT = ISNULL((SELECT COUNT(*) FROM #CallStack), 0);
        
        DECLARE eval_cursor CURSOR LOCAL FAST_FORWARD FOR
            SELECT RuleCode FROM @RulesToEval ORDER BY EvalOrder;
        
        OPEN eval_cursor;
        FETCH NEXT FROM eval_cursor INTO @EvalRule;
        WHILE @@FETCH_STATUS = 0
        BEGIN
            -- Vérifier que la règle n'est pas déjà évaluée (State pourrait avoir changé)
            IF EXISTS (SELECT 1 FROM #ThreadState WHERE [Key] = @EvalRule AND IsRule = 1 AND State = 0)
            BEGIN
                EXEC dbo.sp_ExecuteRule @EvalRule, @EvalResult OUTPUT, @EvalError OUTPUT, @EvalDepth;
                
                -- Propager erreur de cycle
                IF @EvalError IS NOT NULL AND @EvalError LIKE '%cycle%'
                BEGIN
                    RAISERROR('Cycle detected via dependency: %s', 16, 1, @EvalRule);
                    CLOSE eval_cursor;
                    DEALLOCATE eval_cursor;
                    RETURN;
                END
            END
            FETCH NEXT FROM eval_cursor INTO @EvalRule;
        END
        CLOSE eval_cursor;
        DEALLOCATE eval_cursor;
        
        -- Vérifier si une règle matchant le pattern est en erreur (cycle propagé)
        IF EXISTS (SELECT 1 FROM #ThreadState 
                   WHERE IsRule = 1 AND State = 3 
                     AND [Key] LIKE @LikePattern ESCAPE '\' COLLATE SQL_Latin1_General_CP1_CI_AS
                     AND ErrorCode = 'CYCLE')
        BEGIN
            DECLARE @ErrorRule NVARCHAR(200);
            SELECT TOP 1 @ErrorRule = [Key] FROM #ThreadState 
            WHERE IsRule = 1 AND State = 3 AND ErrorCode = 'CYCLE'
              AND [Key] LIKE @LikePattern ESCAPE '\' COLLATE SQL_Latin1_General_CP1_CI_AS;
            ;THROW 50001, 'Cycle detected in dependency', 1;
        END
    END
    
    -- V1.7.1: Détermination dynamique de l'agrégateur par défaut
    IF @Aggregator IS NULL
    BEGIN
        DECLARE @FirstValueForAgg NVARCHAR(MAX);
        SELECT TOP 1 @FirstValueForAgg = ScalarValue 
        FROM #ThreadState 
        WHERE [Key] LIKE @LikePattern ESCAPE '\' COLLATE SQL_Latin1_General_CP1_CI_AS
          AND (@FilterIsRule IS NULL OR IsRule = @FilterIsRule)
          AND (@CurrentRule IS NULL OR [Key] <> @CurrentRule)  -- FIX-C:  Exclure self
          AND State = 2 AND ScalarValue IS NOT NULL
        ORDER BY SeqId;
        
        -- Si le premier élément est numérique → SUM, sinon → FIRST
        IF @FirstValueForAgg IS NOT NULL AND TRY_CAST(@FirstValueForAgg AS DECIMAL(38,18)) IS NOT NULL
            SET @Aggregator = 'SUM';
        ELSE
            SET @Aggregator = 'FIRST';
    END
    
    -- FIX-C: Résolution agrégat avec exclusion self-match
    -- Passer @CurrentRule seulement si c'est un pattern (pour self-match)
    DECLARE @ExcludeForAgg NVARCHAR(200) = NULL;
    IF @IsPattern = 1 AND @FilterIsRule = 1
        SET @ExcludeForAgg = @CurrentRule;
    
    EXEC dbo.sp_ResolveSimpleAggregate @Aggregator, @LikePattern, @FilterIsRule, @ExcludeForAgg, @ResolvedValue OUTPUT;
    
    -- Gestion ensemble vide
    IF @ResolvedValue IS NULL
    BEGIN
        DECLARE @RowCount INT = (
            SELECT COUNT(*) FROM #ThreadState 
            WHERE (@FilterIsRule IS NULL OR IsRule = @FilterIsRule)
              AND [Key] LIKE @LikePattern ESCAPE '\' COLLATE SQL_Latin1_General_CP1_CI_AS
              AND (@ExcludeForAgg IS NULL OR [Key] <> @ExcludeForAgg)
              AND State = 2 AND ScalarValue IS NOT NULL
        );
        
        IF @RowCount = 0
        BEGIN
            IF @Aggregator = 'CONCAT' SET @ResolvedValue = '';
            ELSE IF @Aggregator = 'JSONIFY' SET @ResolvedValue = '{}';
            ELSE IF @Aggregator = 'COUNT' SET @ResolvedValue = '0';
            ELSE IF @Aggregator IN ('COUNT_POS','COUNT_NEG') SET @ResolvedValue = '0';
        END
    END
END;
GO

PRINT '        OK';
GO

-- =========================================================================
-- PARTIE 9 : PROCÉDURES EXÉCUTION
-- FIX-A: Tokens NULL → littéral SQL NULL (pas arrêt prématuré)
-- =========================================================================
PRINT '[9/12] Création des procédures exécution...';
GO

-- OPT-5: Évaluation batch des règles simples (sans tokens)
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
            
            UPDATE #ThreadState 
            SET State = 2, 
                ScalarValue = @Result,
                ValueIsNumeric = CASE WHEN TRY_CAST(@Result AS DECIMAL(38,18)) IS NOT NULL THEN 1 ELSE 0 END
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

-- Exécution règle complexe (avec tokens)
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
    
    -- Protection récursion
    IF @RecursionDepth > 50
    BEGIN
        SET @ErrorMessage = 'Maximum recursion depth (50) exceeded';
        UPDATE #ThreadState SET State = 3, ErrorCategory = 'RECURSION', ErrorCode = 'MAX_DEPTH'
        WHERE [Key] = @RuleCode AND IsRule = 1;
        RETURN;
    END
    
    -- OPT-7: Détection de cycles via #CallStack
    IF OBJECT_ID('tempdb..#CallStack') IS NOT NULL
    BEGIN
        IF EXISTS (SELECT 1 FROM #CallStack WHERE RuleCode = @RuleCode)
        BEGIN
            SET @ErrorMessage = 'Cycle detected for rule ' + @RuleCode;
            UPDATE #ThreadState SET State = 3, ErrorCategory = 'RECURSION', ErrorCode = 'CYCLE'
            WHERE [Key] = @RuleCode AND IsRule = 1;
            RETURN;
        END
        INSERT INTO #CallStack (RuleCode) VALUES (@RuleCode);
    END
    
    DECLARE @Expression NVARCHAR(MAX), @NormalizedExpr NVARCHAR(MAX), @TokensJson NVARCHAR(MAX);
    DECLARE @StartTime DATETIME2 = SYSDATETIME();
    
    SELECT @Expression = Expression FROM dbo.RuleDefinitions WHERE RuleCode = @RuleCode AND IsActive = 1;
    
    IF @Expression IS NULL
    BEGIN
        SET @ErrorMessage = 'Rule not found or inactive';
        UPDATE #ThreadState SET State = 3, ErrorCategory = 'RULE', ErrorCode = 'NOT_FOUND'
        WHERE [Key] = @RuleCode AND IsRule = 1;
        IF OBJECT_ID('tempdb..#CallStack') IS NOT NULL
            DELETE FROM #CallStack WHERE RuleCode = @RuleCode;
        RETURN;
    END
    
    -- Marquer EVALUATING
    UPDATE #ThreadState SET State = 1 WHERE [Key] = @RuleCode AND IsRule = 1;
    
    BEGIN TRY
        -- Récupérer expression compilée (avec cache)
        EXEC dbo.sp_GetCompiledExpression @RuleCode, @Expression, @NormalizedExpr OUTPUT, @TokensJson OUTPUT;
        
        -- Table résolutions tokens
        DECLARE @TokenResolutions TABLE (
            Token NVARCHAR(1000), 
            ResolvedValue NVARCHAR(MAX), 
            IsNumeric BIT,
            IsResolved BIT DEFAULT 0
        );
        
        -- Pré-résolution variables simples directes
        INSERT INTO @TokenResolutions (Token, ResolvedValue, IsNumeric, IsResolved)
        SELECT j.Token,
               CASE WHEN j.IsRuleRef = 0 AND j.Pattern NOT LIKE '%[%*?_]%' AND j.Pattern NOT LIKE '%:%'
                    THEN (SELECT ScalarValue FROM #ThreadState 
                          WHERE [Key] = j.Pattern COLLATE SQL_Latin1_General_CP1_CI_AS AND State = 2)
                    ELSE NULL END,
               0,
               CASE WHEN j.IsRuleRef = 0 AND j.Pattern NOT LIKE '%[%*?_]%' AND j.Pattern NOT LIKE '%:%'
                    THEN 1 ELSE 0 END
        FROM OPENJSON(ISNULL(@TokensJson, '[]')) WITH (
            Token NVARCHAR(1000), Aggregator VARCHAR(20), IsRuleRef BIT, Pattern NVARCHAR(500)
        ) j;
        
        -- Résolution tokens complexes
        DECLARE @Token NVARCHAR(1000), @ResolvedValue NVARCHAR(MAX);
        WHILE EXISTS (SELECT 1 FROM @TokenResolutions WHERE IsResolved = 0)
        BEGIN
            SELECT TOP 1 @Token = Token FROM @TokenResolutions WHERE IsResolved = 0;
            
            BEGIN TRY
                EXEC dbo.sp_ResolveToken @Token, @ResolvedValue OUTPUT;
            END TRY
            BEGIN CATCH
                -- FIX-7: Propagation erreur cycle (incluant self-cycle et dependency)
                IF ERROR_MESSAGE() LIKE '%cycle%'
                BEGIN
                    SET @ErrorMessage = ERROR_MESSAGE();
                    UPDATE #ThreadState SET State = 3, ErrorCategory = 'RECURSION', ErrorCode = 'CYCLE'
                    WHERE [Key] = @RuleCode AND IsRule = 1;
                    IF OBJECT_ID('tempdb..#CallStack') IS NOT NULL
                        DELETE FROM #CallStack WHERE RuleCode = @RuleCode;
                    RETURN;
                END
                SET @ResolvedValue = NULL;
            END CATCH
            
            UPDATE @TokenResolutions SET ResolvedValue = @ResolvedValue, IsResolved = 1 WHERE Token = @Token;
        END
        
        -- Calcul IsNumeric
        UPDATE @TokenResolutions
        SET IsNumeric = CASE WHEN TRY_CAST(ResolvedValue AS DECIMAL(38,18)) IS NOT NULL THEN 1 ELSE 0 END;
        
        -- Construction SQL avec substitution tokens
        DECLARE @CompiledSQL NVARCHAR(MAX) = @NormalizedExpr;
        
        SELECT @CompiledSQL = REPLACE(@CompiledSQL, tr.Token, 
            CASE 
                WHEN tr.ResolvedValue IS NULL THEN 'NULL'
                WHEN tr.IsNumeric = 1 THEN tr.ResolvedValue 
                ELSE '''' + REPLACE(tr.ResolvedValue, '''', '''''') + '''' 
            END)
        FROM @TokenResolutions tr;
        
        -- Exécution SQL
        DECLARE @SQL NVARCHAR(MAX) = N'SELECT @R = ' + @CompiledSQL;
        EXEC sp_executesql @SQL, N'@R NVARCHAR(MAX) OUTPUT', @Result OUTPUT;
        SET @Result = dbo.fn_NormalizeNumericResult(@Result);
        
        -- Mise à jour état avec ValueIsNumeric
        UPDATE #ThreadState 
        SET State = 2, 
            ScalarValue = @Result,
            ValueIsNumeric = CASE WHEN TRY_CAST(@Result AS DECIMAL(38,18)) IS NOT NULL THEN 1 ELSE 0 END
        WHERE [Key] = @RuleCode AND IsRule = 1;
        
        -- Debug log si mode DEBUG
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
    
    -- Nettoyer CallStack
    IF OBJECT_ID('tempdb..#CallStack') IS NOT NULL
        DELETE FROM #CallStack WHERE RuleCode = @RuleCode;
END;
GO

PRINT '        OK';
GO

-- =========================================================================
-- PARTIE 10 : PROCÉDURES LAZY LOADING
-- =========================================================================
PRINT '[10/11] Création des procédures lazy loading...';
GO

CREATE PROCEDURE dbo.sp_EnsureRuleLoaded
    @RuleCode NVARCHAR(200)
AS
BEGIN
    SET NOCOUNT ON;

    IF NOT EXISTS (SELECT 1 FROM #ThreadState WHERE IsRule = 1 AND [Key] = @RuleCode COLLATE SQL_Latin1_General_CP1_CI_AS)
    BEGIN
        IF EXISTS (SELECT 1 FROM dbo.RuleDefinitions WHERE RuleCode = @RuleCode AND IsActive = 1)
        BEGIN
            INSERT INTO #ThreadState ([Key], IsRule, State)
            VALUES (@RuleCode, 1, 0);
        END
    END
END;
GO

CREATE PROCEDURE dbo.sp_DiscoverRulesLike
    @LikePattern NVARCHAR(500)
AS
BEGIN
    SET NOCOUNT ON;

    INSERT INTO #ThreadState ([Key], IsRule, State)
    SELECT rd.RuleCode, 1, 0
    FROM dbo.RuleDefinitions rd
    WHERE rd.IsActive = 1
      AND rd.RuleCode LIKE @LikePattern ESCAPE '\' COLLATE SQL_Latin1_General_CP1_CI_AS
      AND NOT EXISTS (SELECT 1 FROM #ThreadState ts WHERE ts.IsRule = 1 AND ts.[Key] = rd.RuleCode);
END;
GO

PRINT '        OK';
GO

-- =========================================================================
-- PARTIE 11 : RUNNER PRINCIPAL
-- =========================================================================
PRINT '[11/11] Création du runner principal...';
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
        -- Parse options
        SET @Mode = ISNULL(JSON_VALUE(@InputJson, '$.mode'), 'NORMAL');
        IF @Mode NOT IN ('NORMAL', 'DEBUG') SET @Mode = 'NORMAL';
        SET @ReturnStateTable = ISNULL(TRY_CAST(JSON_VALUE(@InputJson, '$.options.returnStateTable') AS BIT), 1);
        SET @ReturnDebug = ISNULL(TRY_CAST(JSON_VALUE(@InputJson, '$.options.returnDebug') AS BIT), 0);
        
        -- Création table état thread
        IF OBJECT_ID('tempdb..#ThreadState') IS NOT NULL DROP TABLE #ThreadState;
        CREATE TABLE #ThreadState (
            SeqId INT IDENTITY(1,1) NOT NULL,
            [Key] NVARCHAR(200) COLLATE SQL_Latin1_General_CP1_CI_AS NOT NULL,
            IsRule BIT NOT NULL DEFAULT 0,
            State TINYINT NOT NULL DEFAULT 0,  -- 0=NOT_EVALUATED, 1=EVALUATING, 2=EVALUATED, 3=ERROR
            ScalarValue NVARCHAR(MAX) COLLATE SQL_Latin1_General_CP1_CI_AS NULL,
            ValueType VARCHAR(20) NULL,
            ValueIsNumeric BIT NULL,
            ErrorCategory VARCHAR(20) NULL,
            ErrorCode VARCHAR(50) NULL,
            PRIMARY KEY CLUSTERED (SeqId),
            UNIQUE ([Key])
        );
        CREATE NONCLUSTERED INDEX IX_TS_RuleState ON #ThreadState (IsRule, State) INCLUDE ([Key], ScalarValue, SeqId, ValueIsNumeric);

        -- OPT-7: Table CallStack pour détection cycles
        IF OBJECT_ID('tempdb..#CallStack') IS NOT NULL DROP TABLE #CallStack;
        CREATE TABLE #CallStack (
            Depth INT IDENTITY(1,1) PRIMARY KEY,
            RuleCode NVARCHAR(200) COLLATE SQL_Latin1_General_CP1_CI_AS NOT NULL UNIQUE
        );
        
        -- Configuration thread
        IF OBJECT_ID('tempdb..#ThreadConfig') IS NOT NULL DROP TABLE #ThreadConfig;
        CREATE TABLE #ThreadConfig (DebugMode BIT);
        INSERT INTO #ThreadConfig VALUES (CASE WHEN @Mode = 'DEBUG' THEN 1 ELSE 0 END);
        
        -- Table debug si mode DEBUG
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
        FROM OPENJSON(@InputJson, '$.variables') WITH (
            [key] NVARCHAR(200), 
            [type] VARCHAR(20), 
            [value] NVARCHAR(MAX)
        ) v
        WHERE v.[key] IS NOT NULL;
        
        -- OPT-2: Pré-calcul ValueIsNumeric pour variables
        UPDATE #ThreadState
        SET ValueIsNumeric = CASE WHEN TRY_CAST(ScalarValue AS DECIMAL(38,18)) IS NOT NULL THEN 1 ELSE 0 END
        WHERE ScalarValue IS NOT NULL AND IsRule = 0;
        
        -- Charger règles demandées
        INSERT INTO #ThreadState ([Key], IsRule, State)
        SELECT r.value, 1, 0
        FROM OPENJSON(@InputJson, '$.rules') r
        WHERE r.value IS NOT NULL 
          AND EXISTS (SELECT 1 FROM dbo.RuleDefinitions rd WHERE rd.RuleCode = r.value AND rd.IsActive = 1);
        
        -- PHASE 1: Règles simples (sans tokens) - batch
        EXEC dbo.sp_EvaluateSimpleRules;
        
        -- PHASE 2: Règles complexes (avec tokens)
        DECLARE @RuleCode NVARCHAR(200), @Result NVARCHAR(MAX), @ErrorMsg NVARCHAR(500);
        DECLARE @CurrentSeqId INT = 0;
        
        WHILE 1 = 1
        BEGIN
            SELECT TOP 1 @RuleCode = [Key], @CurrentSeqId = SeqId
            FROM #ThreadState WHERE IsRule = 1 AND State = 0 AND SeqId > @CurrentSeqId ORDER BY SeqId;
            IF @@ROWCOUNT = 0 BREAK;
            EXEC dbo.sp_ExecuteRule @RuleCode, @Result OUTPUT, @ErrorMsg OUTPUT, 0;
        END
        
        -- Mise à jour ValueIsNumeric pour résultats règles
        UPDATE #ThreadState
        SET ValueIsNumeric = CASE WHEN TRY_CAST(ScalarValue AS DECIMAL(38,18)) IS NOT NULL THEN 1 ELSE 0 END
        WHERE ScalarValue IS NOT NULL AND IsRule = 1 AND State = 2;
        
        -- Compteurs
        SELECT @SuccessCount = COUNT(*) FROM #ThreadState WHERE IsRule = 1 AND State = 2;
        SELECT @ErrorCount = COUNT(*) FROM #ThreadState WHERE IsRule = 1 AND State = 3;
        
        -- Construction résultat JSON
        DECLARE @ResultsJson NVARCHAR(MAX), @StateJson NVARCHAR(MAX) = NULL, @DebugJson NVARCHAR(MAX) = NULL;
        
        SELECT @ResultsJson = (
            SELECT [Key] AS ruleCode,
                   CASE State WHEN 2 THEN 'EVALUATED' WHEN 3 THEN 'ERROR' ELSE 'NOT_EVALUATED' END AS state,
                   ScalarValue AS value, 
                   ErrorCategory AS errorCategory, 
                   ErrorCode AS errorCode
            FROM #ThreadState WHERE IsRule = 1 ORDER BY SeqId FOR JSON PATH);
        
        IF @ReturnStateTable = 1
            SELECT @StateJson = (
                SELECT SeqId, [Key], 
                       CASE WHEN IsRule = 1 THEN 'RULE' ELSE 'VARIABLE' END AS type,
                       CASE State WHEN 0 THEN 'NOT_EVALUATED' WHEN 1 THEN 'EVALUATING' 
                                  WHEN 2 THEN 'EVALUATED' WHEN 3 THEN 'ERROR' END AS state,
                       ScalarValue AS value, 
                       ValueType AS valueType, 
                       ValueIsNumeric, 
                       ErrorCategory, 
                       ErrorCode
                FROM #ThreadState ORDER BY SeqId FOR JSON PATH);
        
        IF @ReturnDebug = 1 AND @Mode = 'DEBUG' AND OBJECT_ID('tempdb..#ThreadDebug') IS NOT NULL
            SELECT @DebugJson = (SELECT * FROM #ThreadDebug ORDER BY LogId FOR JSON PATH);
        
        -- Stats cache (mode DEBUG)
        DECLARE @CacheStats NVARCHAR(MAX) = NULL;
        IF @Mode = 'DEBUG'
            SELECT @CacheStats = (
                SELECT COUNT(*) AS totalEntries, 
                       SUM(HitCount) AS totalHits, 
                       AVG(HitCount) AS avgHits, 
                       MAX(HitCount) AS maxHits
                FROM dbo.RuleCompilationCache FOR JSON PATH, WITHOUT_ARRAY_WRAPPER);
        
        -- Output JSON final
        SET @OutputJson = (
            SELECT 'SUCCESS' AS status, 
                   @Mode AS mode, 
                   '6.9.5' AS engineVersion,
                   @SuccessCount AS rulesEvaluated, 
                   @ErrorCount AS rulesInError,
                   DATEDIFF(MILLISECOND, @StartTime, SYSDATETIME()) AS durationMs,
                   JSON_QUERY(@ResultsJson) AS results, 
                   JSON_QUERY(@StateJson) AS stateTable, 
                   JSON_QUERY(@DebugJson) AS debugLog, 
                   JSON_QUERY(@CacheStats) AS cacheStats
            FOR JSON PATH, WITHOUT_ARRAY_WRAPPER);
        
        -- OPT-6: Nettoyage cache périodique (1% des appels)
        IF RAND() < 0.01 EXEC dbo.sp_CleanupCache;
        
    END TRY
    BEGIN CATCH
        SET @OutputJson = (
            SELECT 'ERROR' AS status, 
                   ERROR_MESSAGE() AS errorMessage, 
                   ERROR_NUMBER() AS errorNumber,
                   DATEDIFF(MILLISECOND, @StartTime, SYSDATETIME()) AS durationMs 
            FOR JSON PATH, WITHOUT_ARRAY_WRAPPER);
    END CATCH
END;
GO

PRINT '        OK';
PRINT '';
PRINT '======================================================================';
PRINT '           INSTALLATION TERMINÉE - MOTEUR V6.9.5                     ';
PRINT '======================================================================';
PRINT '';
PRINT '  Version........: 6.9.5';
PRINT '  Conformité.....: SPEC V1.7.2 (100%)';
PRINT '  Compatibilité..: SQL Server 2017+';
PRINT '';
PRINT '  Corrections V6.9.5:';
PRINT '    [X] FIX-H: Standard échappement backslash (\)';
PRINT '    [X] FIX-I: ESCAPE ''\'' systématique dans LIKE';
PRINT '    [X] FIX-J: Conversion wildcards échappés (\_, \%, \*, \?)';
PRINT '';
PRINT '  Corrections V6.9.4:';
PRINT '    [X] FIX-F: Détection pattern améliorée (gestion [_])';
PRINT '    [X] FIX-G: Chargement direct références règles';
PRINT '';
PRINT '  Corrections V6.9.3:';
PRINT '    [X] FIX-A: Tokens non résolus → NULL littéral';
PRINT '    [X] FIX-B: Évaluation forcée règles découvertes';
PRINT '    [X] FIX-C: Exclusion self-match agrégats';
PRINT '    [X] FIX-D: Pré-chargement dépendances rule:';
PRINT '    [X] FIX-E: Gestion patterns wildcards';
PRINT '';
PRINT '  Corrections V6.9:';
PRINT '    [X] FIX-1: CONCAT sans séparateur (per spec)';
PRINT '    [X] FIX-2: LAST_POS/LAST_NEG ajoutés';
PRINT '    [X] FIX-3: Normalisation numériques cohérente';
PRINT '    [X] FIX-4: COUNT ensemble vide = 0';
PRINT '    [X] FIX-5: Scope var:/rule:/all: explicite';
PRINT '    [X] FIX-6: Double évaluation lazy corrigée';
PRINT '    [X] FIX-7: Propagation erreurs cycle';
PRINT '';
PRINT '  Optimisations préservées:';
PRINT '    [X] OPT-1: Cache compilation persistant';
PRINT '    [X] OPT-2: Pré-calcul ValueIsNumeric';
PRINT '    [X] OPT-3: Index filtré règles simples';
PRINT '    [X] OPT-4: STRING_AGG natif';
PRINT '    [X] OPT-5: Batch règles simples';
PRINT '    [X] OPT-6: Cache LRU auto-nettoyage';
PRINT '    [X] OPT-7: CallStack détection cycles';
PRINT '    [X] OPT-8: Lazy discovery règles';
PRINT '';
PRINT '  Prochaine étape: Exécuter TESTS_COMPLETS_V6_9_2.sql';
PRINT '';
PRINT '======================================================================';
GO
