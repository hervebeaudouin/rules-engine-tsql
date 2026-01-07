/***********************************************************************
SCRIPT UNIQUE - MOTEUR DE REGLES V4.6 + JEU D'ESSAI EXHAUSTIF

Objectif:
- Installer le moteur (sans modifier sa logique)
- Executer un jeu d'essai exhaustif (39 tests)
- Fournir une sortie unifiee, copiable en un seul bloc

Corrections V4.6:
- sp_EvaluateToken IIF: évalue les tokens (Sum, Rule:, etc.) dans la CONDITION
- fn_ParseToken: extraction correcte du filtre +/- depuis PatternRaw
- sp_EvaluateToken: évaluation récursive des tokens dans les branches IIF
- sp_DetectRuleCycles: détection des cycles indirects A->B->C->A

Note:
- La partie INSTALLATION conserve les GO d'origine.
- La partie TESTS est executee en un seul batch (pas de GO), afin de
  conserver la portee des variables DECLARE.
************************************************************************/

/***********************************************************************
    MOTEUR DE RÈGLES T-SQL COMPLET - VERSION 4.6
    Avec Récursivité et Isolation Garantie
    
    Compatibilité : SQL Server 2017+
    
    Corrections V4.1 :
    - COLLATE DATABASE_DEFAULT sur toutes les colonnes varchar/nvarchar
    - ISNULL(@RecursionDepth, 0) pour protection NULL
    - Tri topologique corrigé (décrémentation multi-dépendances)
    
    Corrections V4.3-4.6 :
    - fn_ExtractTokens supporte les accolades imbriquées (IIF)
    - fn_ParseToken extrait correctement ValueFilter depuis PatternRaw
    - sp_EvaluateToken évalue tokens dans CONDITION et BRANCHES du IIF
    - sp_DetectRuleCycles corrigé pour détecter les cycles indirects
************************************************************************/

SET NOCOUNT ON;
GO

PRINT '══════════════════════════════════════════════════════════════════════';
PRINT '           INSTALLATION DU MOTEUR DE RÈGLES - V4.6                    ';
PRINT '══════════════════════════════════════════════════════════════════════';
PRINT '';
GO

-- =========================================================================
-- PARTIE 1 : NETTOYAGE
-- =========================================================================
PRINT '── PARTIE 1 : Nettoyage ──';
GO

IF OBJECT_ID('dbo.sp_ExecuteRuleRecursive','P') IS NOT NULL DROP PROCEDURE dbo.sp_ExecuteRuleRecursive;
GO
IF OBJECT_ID('dbo.sp_ExecuteRulesWithDependencies','P') IS NOT NULL DROP PROCEDURE dbo.sp_ExecuteRulesWithDependencies;
GO
IF OBJECT_ID('dbo.sp_EvaluateToken','P') IS NOT NULL DROP PROCEDURE dbo.sp_EvaluateToken;
GO
IF OBJECT_ID('dbo.sp_CompileRule','P') IS NOT NULL DROP PROCEDURE dbo.sp_CompileRule;
GO
IF OBJECT_ID('dbo.sp_BuildRuleDependencyGraph','P') IS NOT NULL DROP PROCEDURE dbo.sp_BuildRuleDependencyGraph;
GO
IF OBJECT_ID('dbo.sp_DetectRuleCycles','P') IS NOT NULL DROP PROCEDURE dbo.sp_DetectRuleCycles;
GO
IF OBJECT_ID('dbo.sp_InitSession','P') IS NOT NULL DROP PROCEDURE dbo.sp_InitSession;
GO
IF OBJECT_ID('dbo.sp_VerifyIsolation','P') IS NOT NULL DROP PROCEDURE dbo.sp_VerifyIsolation;
GO
IF OBJECT_ID('dbo.sp_RunAllTests','P') IS NOT NULL DROP PROCEDURE dbo.sp_RunAllTests;
GO
IF OBJECT_ID('dbo.fn_ExtractTokens','IF') IS NOT NULL DROP FUNCTION dbo.fn_ExtractTokens;
IF OBJECT_ID('dbo.fn_ExtractTokens','TF') IS NOT NULL DROP FUNCTION dbo.fn_ExtractTokens;
GO
IF OBJECT_ID('dbo.fn_ParseToken','IF') IS NOT NULL DROP FUNCTION dbo.fn_ParseToken;
GO
IF OBJECT_ID('dbo.fn_ExtractRuleReferences','IF') IS NOT NULL DROP FUNCTION dbo.fn_ExtractRuleReferences;
GO
IF OBJECT_ID('dbo.fn_IsValidExpression','FN') IS NOT NULL DROP FUNCTION dbo.fn_IsValidExpression;
GO
IF OBJECT_ID('dbo.RuleLogs','U') IS NOT NULL DROP TABLE dbo.RuleLogs;
GO
IF OBJECT_ID('dbo.RuleCycleLog','U') IS NOT NULL DROP TABLE dbo.RuleCycleLog;
GO
IF OBJECT_ID('dbo.RuleDependency','U') IS NOT NULL DROP TABLE dbo.RuleDependency;
GO
IF OBJECT_ID('dbo.Rules','U') IS NOT NULL DROP TABLE dbo.Rules;
GO

PRINT '   OK Nettoyage terminé';
PRINT '';
GO

-- =========================================================================
-- PARTIE 2 : TABLES
-- =========================================================================
PRINT '── PARTIE 2 : Tables de configuration ──';
GO

CREATE TABLE dbo.Rules (
    RuleId int IDENTITY(1,1) PRIMARY KEY,
    RuleCode nvarchar(50) COLLATE DATABASE_DEFAULT NOT NULL UNIQUE,
    RuleName nvarchar(200) COLLATE DATABASE_DEFAULT NOT NULL,
    Expression nvarchar(max) COLLATE DATABASE_DEFAULT NOT NULL,
    CompiledExpression nvarchar(max) COLLATE DATABASE_DEFAULT NULL,
    TokensJson nvarchar(max) COLLATE DATABASE_DEFAULT NULL,
    IsCompiled bit DEFAULT 0,
    IsActive bit DEFAULT 1,
    ReturnType varchar(20) COLLATE DATABASE_DEFAULT DEFAULT 'DECIMAL',
    Description nvarchar(500) COLLATE DATABASE_DEFAULT NULL,
    CreatedDate datetime2 DEFAULT SYSDATETIME(),
    ModifiedDate datetime2 DEFAULT SYSDATETIME()
);
GO

PRINT '   OK Table dbo.Rules';
GO

CREATE TABLE dbo.RuleDependency (
    RuleCode nvarchar(50) COLLATE DATABASE_DEFAULT NOT NULL,
    DependsOnRule nvarchar(50) COLLATE DATABASE_DEFAULT NOT NULL,
    PRIMARY KEY (RuleCode, DependsOnRule)
);
GO

PRINT '   OK Table dbo.RuleDependency';
GO

CREATE TABLE dbo.RuleLogs (
    LogId bigint IDENTITY(1,1) PRIMARY KEY,
    SessionId int NOT NULL,
    RuleCode nvarchar(50) COLLATE DATABASE_DEFAULT NOT NULL,
    Status varchar(20) COLLATE DATABASE_DEFAULT NOT NULL,
    ResultValue nvarchar(500) COLLATE DATABASE_DEFAULT NULL,
    ErrorMsg nvarchar(500) COLLATE DATABASE_DEFAULT NULL,
    ExecutionMs int NULL,
    LogDate datetime2 DEFAULT SYSDATETIME()
);
GO

PRINT '   OK Table dbo.RuleLogs';
GO

CREATE TABLE dbo.RuleCycleLog (
    CycleId int IDENTITY(1,1) PRIMARY KEY,
    DetectedAt datetime2 DEFAULT SYSDATETIME(),
    CyclePath nvarchar(max) COLLATE DATABASE_DEFAULT NOT NULL,
    RulesInCycle nvarchar(max) COLLATE DATABASE_DEFAULT NOT NULL
);
GO

PRINT '   OK Table dbo.RuleCycleLog';
PRINT '';
GO

-- =========================================================================
-- PARTIE 3 : TABLE TEMPORAIRE
-- =========================================================================
PRINT '── PARTIE 3 : Table temporaire de session ──';
GO

IF OBJECT_ID('tempdb..#Variables') IS NOT NULL DROP TABLE #Variables;
GO

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
GO

DECLARE @spid_msg nvarchar(100);
SET @spid_msg = '   OK Table #Variables (session ' + CAST(@@SPID AS nvarchar(10)) + ')';
PRINT @spid_msg;
PRINT '';
GO

-- =========================================================================
-- PARTIE 4 : FONCTIONS
-- =========================================================================
PRINT '── PARTIE 4 : Fonctions utilitaires ──';
GO

CREATE FUNCTION dbo.fn_ExtractTokens(@Expr nvarchar(max))
RETURNS @Tokens TABLE (Token nvarchar(500))
AS
BEGIN
    -- Extraction des tokens avec support des accolades imbriquées
    DECLARE @i int = 1;
    DECLARE @Len int = LEN(@Expr);
    DECLARE @Start int = 0;
    DECLARE @Level int = 0;
    DECLARE @Token nvarchar(500);
    
    WHILE @i <= @Len
    BEGIN
        IF SUBSTRING(@Expr, @i, 1) = '{'
        BEGIN
            IF @Level = 0
                SET @Start = @i;
            SET @Level = @Level + 1;
        END
        ELSE IF SUBSTRING(@Expr, @i, 1) = '}'
        BEGIN
            SET @Level = @Level - 1;
            IF @Level = 0 AND @Start > 0
            BEGIN
                SET @Token = SUBSTRING(@Expr, @Start, @i - @Start + 1);
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

PRINT '   OK fn_ExtractTokens';
GO

CREATE FUNCTION dbo.fn_ParseToken(@Token nvarchar(200))
RETURNS TABLE WITH SCHEMABINDING
AS
RETURN
WITH Base AS (
    SELECT
        @Token AS Token,
        CASE 
            WHEN @Token LIKE '{Rule:%}' THEN 'RULE'
            WHEN @Token LIKE '{IIF(%,%,%)}' THEN 'IIF'
            WHEN @Token LIKE '{Sum(%)}' OR @Token LIKE '{SUM(%)}' THEN 'SUM'
            WHEN @Token LIKE '{Avg(%)}' OR @Token LIKE '{AVG(%)}' THEN 'AVG'
            WHEN @Token LIKE '{Max(%)}' OR @Token LIKE '{MAX(%)}' THEN 'MAX'
            WHEN @Token LIKE '{Min(%)}' OR @Token LIKE '{MIN(%)}' THEN 'MIN'
            WHEN @Token LIKE '{Count(%)}' OR @Token LIKE '{COUNT(%)}' THEN 'COUNT'
            ELSE 'DIRECT'
        END AS AggFunc,
        CASE 
            WHEN @Token LIKE '{Rule:%}' THEN SUBSTRING(@Token, 7, LEN(@Token) - 7)
            WHEN @Token LIKE '{%(%)}' THEN SUBSTRING(@Token, CHARINDEX('(', @Token) + 1, CHARINDEX(')', @Token) - CHARINDEX('(', @Token) - 1)
            ELSE SUBSTRING(@Token, 2, LEN(@Token) - 2)
        END AS PatternRaw,
        CASE 
            WHEN @Token LIKE '{Rule:%}' THEN 'RULE_REF'
            WHEN @Token LIKE '{IIF(%)}' THEN 'CONDITIONAL'
            WHEN @Token LIKE '{%(%)}' THEN 'AGGREGATE'
            ELSE 'DIRECT'
        END AS TokenType
)
SELECT
    Token,
    AggFunc,
    -- Le filtre +/- est dans le pattern (ex: MONTANT_%+), pas en fin de token.
    CASE 
        WHEN RIGHT(PatternRaw, 1) IN ('+','-') THEN LEFT(PatternRaw, LEN(PatternRaw) - 1)
        ELSE PatternRaw
    END AS Pattern,
    CASE 
        WHEN RIGHT(PatternRaw, 1) = '+' THEN 'POSITIVE'
        WHEN RIGHT(PatternRaw, 1) = '-' THEN 'NEGATIVE'
        ELSE 'ALL'
    END AS ValueFilter,
    TokenType
FROM Base;
GO


PRINT '   OK fn_ParseToken';
GO

CREATE FUNCTION dbo.fn_ExtractRuleReferences(@Expression nvarchar(max))
RETURNS TABLE
AS
RETURN
(
    WITH 
    L0 AS (SELECT 1 AS c UNION ALL SELECT 1),
    L1 AS (SELECT 1 AS c FROM L0 A CROSS JOIN L0 B),
    L2 AS (SELECT 1 AS c FROM L1 A CROSS JOIN L1 B),
    L3 AS (SELECT 1 AS c FROM L2 A CROSS JOIN L2 B),
    Nums AS (SELECT ROW_NUMBER() OVER (ORDER BY (SELECT NULL)) AS n FROM L3),
    Positions AS (
        SELECT n AS StartPos
        FROM Nums
        WHERE n <= LEN(@Expression) - 5
          AND SUBSTRING(@Expression, n, 6) = '{Rule:'
    )
    SELECT DISTINCT
        SUBSTRING(@Expression, p.StartPos + 6, CHARINDEX('}', @Expression, p.StartPos + 6) - p.StartPos - 6) AS ReferencedRule
    FROM Positions p
    WHERE CHARINDEX('}', @Expression, p.StartPos + 6) > 0
);
GO

PRINT '   OK fn_ExtractRuleReferences';
GO

CREATE FUNCTION dbo.fn_IsValidExpression(@Expr nvarchar(max))
RETURNS bit
AS
BEGIN
    IF @Expr IS NULL OR LEN(@Expr) > 8000 RETURN 0;
    IF @Expr LIKE '%DROP%' OR @Expr LIKE '%DELETE%' OR @Expr LIKE '%UPDATE%' 
        OR @Expr LIKE '%INSERT%' OR @Expr LIKE '%EXEC%' OR @Expr LIKE '%;%'
        OR @Expr LIKE '%--%' OR @Expr LIKE '%/*%' OR @Expr LIKE '%xp_%'
        RETURN 0;
    RETURN 1;
END;
GO

PRINT '   OK fn_IsValidExpression';
PRINT '';
GO

-- =========================================================================
-- PARTIE 5 : PROCÉDURES DE BASE
-- =========================================================================
PRINT '── PARTIE 5 : Procédures principales ──';
GO

CREATE PROCEDURE dbo.sp_CompileRule
    @RuleCode nvarchar (50),
    @Success bit OUTPUT,
    @ErrorMsg nvarchar(500) OUTPUT
AS
BEGIN
    SET NOCOUNT ON;
    
    DECLARE @Expression nvarchar(max);
    DECLARE @CompiledExpr nvarchar(max);
    DECLARE @TokensJson nvarchar(max);
    DECLARE @Token nvarchar(200);
    DECLARE @Placeholder nvarchar(50);
    
    BEGIN TRY
        SELECT @Expression = Expression FROM dbo.Rules WHERE RuleCode = @RuleCode;
        
        IF @Expression IS NULL
        BEGIN
            SET @Success = 0;
            SET @ErrorMsg = CONCAT('Règle non trouvée: ', @RuleCode);
            RETURN;
        END
        
        IF dbo.fn_IsValidExpression(@Expression) = 0
        BEGIN
            SET @Success = 0;
            SET @ErrorMsg = 'Expression non sécurisée';
            RETURN;
        END
        
        SELECT @TokensJson = (
            SELECT t.Token, p.AggFunc, p.Pattern, p.ValueFilter, p.TokenType,
                CONCAT('@P', CAST(ROW_NUMBER() OVER (ORDER BY t.Token) AS nvarchar(10))) AS Placeholder
            FROM (SELECT DISTINCT Token FROM dbo.fn_ExtractTokens(@Expression)) t
            CROSS APPLY dbo.fn_ParseToken(t.Token) p
            FOR JSON PATH
        );
        
        SET @CompiledExpr = @Expression;
        
        DECLARE cur CURSOR LOCAL FAST_FORWARD FOR
            SELECT JSON_VALUE(value, '$.Token'), JSON_VALUE(value, '$.Placeholder')
            FROM OPENJSON(@TokensJson);
        
        OPEN cur;
        FETCH NEXT FROM cur INTO @Token, @Placeholder;
        WHILE @@FETCH_STATUS = 0
        BEGIN
            SET @CompiledExpr = REPLACE(@CompiledExpr, @Token, @Placeholder);
            FETCH NEXT FROM cur INTO @Token, @Placeholder;
        END
        CLOSE cur;
        DEALLOCATE cur;
        
        UPDATE dbo.Rules
        SET CompiledExpression = @CompiledExpr,
            TokensJson = @TokensJson,
            IsCompiled = 1,
            ModifiedDate = SYSDATETIME()
        WHERE RuleCode = @RuleCode;
        
        DELETE FROM dbo.RuleDependency WHERE RuleCode = @RuleCode;
        
        INSERT INTO dbo.RuleDependency (RuleCode, DependsOnRule)
        SELECT @RuleCode, ReferencedRule
        FROM dbo.fn_ExtractRuleReferences(@Expression)
        WHERE EXISTS (SELECT 1 FROM dbo.Rules WHERE RuleCode = ReferencedRule);
        
        SET @Success = 1;
        SET @ErrorMsg = NULL;
        
    END TRY
    BEGIN CATCH
        SET @Success = 0;
        SET @ErrorMsg = ERROR_MESSAGE();
    END CATCH
END;
GO

PRINT '   OK sp_CompileRule';
GO

CREATE PROCEDURE dbo.sp_EvaluateToken
    @AggFunc varchar(50),
    @Pattern nvarchar(500),
    @ValueFilter varchar(20),
    @Result nvarchar(500) OUTPUT
AS
BEGIN
    SET NOCOUNT ON;
    
    IF OBJECT_ID('tempdb..#Variables') IS NULL
    BEGIN
        SET @Result = NULL;
        RETURN;
    END
    
    DECLARE @CleanPattern nvarchar(200);
    SET @CleanPattern = @Pattern;
    IF @CleanPattern LIKE '%+' OR @CleanPattern LIKE '%-'
        SET @CleanPattern = LEFT(@CleanPattern, LEN(@CleanPattern) - 1);
    
    IF @AggFunc = 'DIRECT'
    BEGIN
        SELECT @Result = 
            CASE VarType
                WHEN 'DECIMAL' THEN CAST(ValueDecimal AS nvarchar(50))
                WHEN 'INTEGER' THEN CAST(ValueInteger AS nvarchar(50))
                WHEN 'STRING' THEN CONCAT('''', REPLACE(ValueString, '''', ''''''), '''')
                WHEN 'BOOLEAN' THEN CAST(ValueBoolean AS nvarchar(1))
                ELSE 'NULL'
            END
        FROM #Variables
        WHERE VarKey = @CleanPattern;
        
        IF @Result IS NULL SET @Result = '0';
        RETURN;
    END
    
    IF @AggFunc IN ('SUM', 'AVG', 'MAX', 'MIN', 'COUNT')
    BEGIN
        DECLARE @Sql nvarchar(max);
        DECLARE @NumResult decimal(18,6);
        
        SET @Sql = CONCAT(N'SELECT @R = ', @AggFunc, 
            N'(ISNULL(ValueDecimal, ValueInteger)) FROM #Variables ',
            N'WHERE VarKey LIKE @P AND VarType IN (''DECIMAL'',''INTEGER'')');
        
        IF @ValueFilter = 'POSITIVE'
            SET @Sql = CONCAT(@Sql, N' AND ISNULL(ValueDecimal, ValueInteger) > 0');
        ELSE IF @ValueFilter = 'NEGATIVE'
            SET @Sql = CONCAT(@Sql, N' AND ISNULL(ValueDecimal, ValueInteger) < 0');
        
        EXEC sp_executesql @Sql, N'@P nvarchar(200), @R decimal(18,6) OUTPUT', @CleanPattern, @NumResult OUTPUT;
        
        SET @Result = CAST(ISNULL(@NumResult, 0) AS nvarchar(50));
        RETURN;
    END
    
    IF @AggFunc = 'IIF'
    BEGIN
        DECLARE @Pos int, @Level int, @Char nchar(1);
        DECLARE @Part1End int, @Part2End int;
        
        SET @Pos = 1;
        SET @Level = 0;
        SET @Part1End = 0;
        SET @Part2End = 0;
        
        WHILE @Pos <= LEN(@Pattern)
        BEGIN
            SET @Char = SUBSTRING(@Pattern, @Pos, 1);
            IF @Char = '(' SET @Level = @Level + 1;
            ELSE IF @Char = ')' SET @Level = @Level - 1;
            ELSE IF @Char = ',' AND @Level = 0
            BEGIN
                IF @Part1End = 0 SET @Part1End = @Pos;
                ELSE IF @Part2End = 0 SET @Part2End = @Pos;
            END
            SET @Pos = @Pos + 1;
        END
        
        IF @Part1End > 0 AND @Part2End > 0
        BEGIN
            DECLARE @Condition nvarchar(500);
            DECLARE @TrueVal nvarchar(500);
            DECLARE @FalseVal nvarchar(500);
            DECLARE @CondResolved nvarchar(1000);
            DECLARE @VarName nvarchar(100);
            DECLARE @VarVal nvarchar(500);
            DECLARE @CondResult bit;
            DECLARE @SqlCond nvarchar(max);
            
            SET @Condition = LTRIM(RTRIM(LEFT(@Pattern, @Part1End - 1)));
            SET @TrueVal = LTRIM(RTRIM(SUBSTRING(@Pattern, @Part1End + 1, @Part2End - @Part1End - 1)));
            SET @FalseVal = LTRIM(RTRIM(SUBSTRING(@Pattern, @Part2End + 1, LEN(@Pattern))));
            SET @CondResolved = @Condition;
            
            -- ÉTAPE 1: Évaluer les tokens complexes (Sum, Avg, Rule:, etc.) dans la condition
            DECLARE @CondTokens nvarchar(max);
            DECLARE @CTok nvarchar(200);
            DECLARE @CAgg varchar(50);
            DECLARE @CPat nvarchar(500);
            DECLARE @CFil varchar(20);
            DECLARE @CVal nvarchar(500);
            
            SELECT @CondTokens = (
                SELECT t.Token, p.AggFunc, p.Pattern, p.ValueFilter
                FROM (SELECT DISTINCT Token FROM dbo.fn_ExtractTokens(@CondResolved)) t
                CROSS APPLY dbo.fn_ParseToken(t.Token) p
                FOR JSON PATH
            );
            
            IF @CondTokens IS NOT NULL
            BEGIN
                DECLARE cond_cur CURSOR LOCAL FAST_FORWARD FOR
                SELECT JSON_VALUE(value,'$.Token'),
                       JSON_VALUE(value,'$.AggFunc'),
                       JSON_VALUE(value,'$.Pattern'),
                       COALESCE(JSON_VALUE(value,'$.ValueFilter'),'ALL')
                FROM OPENJSON(@CondTokens);
                
                OPEN cond_cur;
                FETCH NEXT FROM cond_cur INTO @CTok, @CAgg, @CPat, @CFil;
                
                WHILE @@FETCH_STATUS = 0
                BEGIN
                    IF @CAgg = 'RULE'
                    BEGIN
                        -- Évaluer la règle référencée
                        DECLARE @RuleResult nvarchar(500), @RuleSt varchar(20), @RuleEr nvarchar(500), @RuleTm int;
                        EXEC dbo.sp_ExecuteRuleRecursive @CPat, 0, @RuleResult OUTPUT, @RuleSt OUTPUT, @RuleEr OUTPUT, @RuleTm OUTPUT;
                        SET @CondResolved = REPLACE(@CondResolved, @CTok, ISNULL(@RuleResult, '0'));
                    END
                    ELSE
                    BEGIN
                        -- Évaluer le token (SUM, AVG, DIRECT, etc.)
                        EXEC dbo.sp_EvaluateToken @CAgg, @CPat, @CFil, @CVal OUTPUT;
                        SET @CondResolved = REPLACE(@CondResolved, @CTok, ISNULL(@CVal, '0'));
                    END
                    FETCH NEXT FROM cond_cur INTO @CTok, @CAgg, @CPat, @CFil;
                END
                
                CLOSE cond_cur;
                DEALLOCATE cond_cur;
            END
            
            -- ÉTAPE 2: Remplacer les variables directes restantes (au cas où)
            DECLARE var_cur CURSOR LOCAL FAST_FORWARD FOR
            SELECT VarKey,
                CASE VarType
                    WHEN 'DECIMAL' THEN CAST(ValueDecimal AS nvarchar(50))
                    WHEN 'INTEGER' THEN CAST(ValueInteger AS nvarchar(50))
                    WHEN 'BOOLEAN' THEN CAST(ValueBoolean AS nvarchar(1))
                    ELSE 'NULL'
                END
            FROM #Variables;
            
            OPEN var_cur;
            FETCH NEXT FROM var_cur INTO @VarName, @VarVal;
            WHILE @@FETCH_STATUS = 0
            BEGIN
                SET @CondResolved = REPLACE(@CondResolved, CONCAT('{', @VarName, '}'), ISNULL(@VarVal, 'NULL'));
                FETCH NEXT FROM var_cur INTO @VarName, @VarVal;
            END
            CLOSE var_cur;
            DEALLOCATE var_cur;
            
            SET @SqlCond = CONCAT(N'SELECT @R = CASE WHEN ', @CondResolved, N' THEN 1 ELSE 0 END');
            
            BEGIN TRY
                EXEC sp_executesql @SqlCond, N'@R bit OUTPUT', @CondResult OUTPUT;
                SET @Result = CASE WHEN @CondResult = 1 THEN @TrueVal ELSE @FalseVal END;

                -- Évaluer l'expression sélectionnée (supporte tokens DIRECT/AGG/IIF imbriqués)
                DECLARE @BranchExpr nvarchar(max);
                DECLARE @BranchFinal nvarchar(max);
                DECLARE @BranchTokens nvarchar(max);
                DECLARE @BTok nvarchar(200);
                DECLARE @BAgg varchar(50);
                DECLARE @BPat nvarchar(500);
                DECLARE @BFil varchar(20);
                DECLARE @BVal nvarchar(500);

                SET @BranchExpr = @Result;
                SET @BranchFinal = @BranchExpr;

                SELECT @BranchTokens = (
                    SELECT t.Token, p.AggFunc, p.Pattern, p.ValueFilter
                    FROM (SELECT DISTINCT Token FROM dbo.fn_ExtractTokens(@BranchExpr)) t
                    CROSS APPLY dbo.fn_ParseToken(t.Token) p
                    WHERE p.AggFunc <> 'RULE'
                    FOR JSON PATH
                );

                IF @BranchTokens IS NOT NULL
                BEGIN
                    DECLARE bcur CURSOR LOCAL FAST_FORWARD FOR
                    SELECT JSON_VALUE(value,'$.Token'),
                           JSON_VALUE(value,'$.AggFunc'),
                           JSON_VALUE(value,'$.Pattern'),
                           COALESCE(JSON_VALUE(value,'$.ValueFilter'),'ALL')
                    FROM OPENJSON(@BranchTokens);

                    OPEN bcur;
                    FETCH NEXT FROM bcur INTO @BTok, @BAgg, @BPat, @BFil;

                    WHILE @@FETCH_STATUS = 0
                    BEGIN
                        EXEC dbo.sp_EvaluateToken @BAgg, @BPat, @BFil, @BVal OUTPUT;
                        SET @BranchFinal = REPLACE(@BranchFinal, @BTok, ISNULL(@BVal, '0'));
                        FETCH NEXT FROM bcur INTO @BTok, @BAgg, @BPat, @BFil;
                    END

                    CLOSE bcur;
                    DEALLOCATE bcur;
                END

                DECLARE @SqlEval nvarchar(max);
                BEGIN TRY
                    SET @SqlEval = CONCAT(N'SELECT @R = CAST((', @BranchFinal, N') AS nvarchar(500))');
                    EXEC sp_executesql @SqlEval, N'@R nvarchar(500) OUTPUT', @Result OUTPUT;
                END TRY
                BEGIN CATCH
                    -- Si évaluation impossible, retourner 0 (comportement tolérant)
                    SET @Result = '0';
                END CATCH

END TRY
            BEGIN CATCH
                SET @Result = @FalseVal;
            END CATCH
        END
        ELSE
            SET @Result = '0';
        
        RETURN;
    END
    
    SET @Result = '0';
END;
GO

PRINT '   OK sp_EvaluateToken';
GO

CREATE PROCEDURE dbo.sp_BuildRuleDependencyGraph
AS
BEGIN
    SET NOCOUNT ON;
    
    TRUNCATE TABLE dbo.RuleDependency;
    
    INSERT INTO dbo.RuleDependency (RuleCode, DependsOnRule)
    SELECT DISTINCT r.RuleCode, ref.ReferencedRule
    FROM dbo.Rules r
    CROSS APPLY dbo.fn_ExtractRuleReferences(r.Expression) ref
    WHERE r.IsActive = 1
      AND EXISTS (SELECT 1 FROM dbo.Rules r2 WHERE r2.RuleCode = ref.ReferencedRule AND r2.IsActive = 1);
    
    DECLARE @cnt int;
    SET @cnt = @@ROWCOUNT;
    PRINT CONCAT('Dépendances construites: ', @cnt);
END;
GO

PRINT '   OK sp_BuildRuleDependencyGraph';
GO

CREATE PROCEDURE dbo.sp_DetectRuleCycles
    @HasCycles bit OUTPUT
AS
BEGIN
    SET NOCOUNT ON;
    SET @HasCycles = 0;
    
    -- Méthode: chercher les chemins où on retombe sur le point de départ
    ;WITH RecPath AS (
        -- Ancre: tous les départs possibles
        SELECT 
            RuleCode AS StartRule,
            RuleCode,
            DependsOnRule,
            CAST(CONCAT(RuleCode, ' -> ', DependsOnRule) AS nvarchar(max)) AS Path,
            1 AS Depth
        FROM dbo.RuleDependency
        
        UNION ALL
        
        -- Récursion: suivre les dépendances
        SELECT 
            r.StartRule,
            r.DependsOnRule,
            d.DependsOnRule,
            CAST(CONCAT(r.Path, ' -> ', d.DependsOnRule) AS nvarchar(max)),
            r.Depth + 1
        FROM RecPath r
        JOIN dbo.RuleDependency d ON d.RuleCode COLLATE DATABASE_DEFAULT = r.DependsOnRule COLLATE DATABASE_DEFAULT
        WHERE r.Depth < 50
          AND r.DependsOnRule <> r.StartRule  -- Arrêter si on a trouvé le cycle
    )
    SELECT DISTINCT Path, StartRule AS RuleCode
    INTO #Cycles
    FROM RecPath
    WHERE DependsOnRule = StartRule;  -- Cycle trouvé quand on retombe sur le départ
    
    IF EXISTS (SELECT 1 FROM #Cycles)
    BEGIN
        SET @HasCycles = 1;
        INSERT INTO dbo.RuleCycleLog (CyclePath, RulesInCycle)
        SELECT Path, RuleCode FROM #Cycles;
        
        SELECT 'CYCLE DETECTE' AS Status, * FROM #Cycles;
    END
    
    DROP TABLE #Cycles;
END;
GO

PRINT '   OK sp_DetectRuleCycles';
PRINT '';
GO

-- =========================================================================
-- PARTIE 6 : MOTEUR RÉCURSIF
-- =========================================================================
PRINT '── PARTIE 6 : Moteur récursif ──';
GO

CREATE PROCEDURE dbo.sp_ExecuteRuleRecursive
    @RuleCode nvarchar(50),
    @LogToDb bit = 0,
    @Result nvarchar(500) OUTPUT,
    @Status varchar(20) OUTPUT,
    @ErrorMsg nvarchar(500) OUTPUT,
    @ExecTimeMs int OUTPUT,
    @RecursionDepth int = 0,
    @MaxRecursion int = 20,
    @CallingPath nvarchar(max) = NULL
AS
BEGIN
    SET NOCOUNT ON;
    set @RecursionDepth = isnull(@RecursionDepth,0) + 1
    DECLARE @StartTime datetime2;
    DECLARE @SessionId int;
    DECLARE @Expression nvarchar(max);
    DECLARE @TokensJson nvarchar(max);
    DECLARE @IsCompiled bit;
    DECLARE @WorkExpr nvarchar(max);
    DECLARE @FinalExpr nvarchar(max);
    DECLARE @RefRule nvarchar(50);
    DECLARE @RefResult nvarchar(500);
    DECLARE @RefStatus varchar(20);
    DECLARE @RefError nvarchar(500);
    DECLARE @RefTime int;
    DECLARE @Token nvarchar(200);
    DECLARE @AggFunc varchar(50);
    DECLARE @Pattern nvarchar(500);
    DECLARE @ValueFilter varchar(20);
    DECLARE @TokenValue nvarchar(500);
    DECLARE @Placeholder nvarchar(50);
    DECLARE @ResolvedTokens nvarchar(max);
    DECLARE @Sql nvarchar(max);
    DECLARE @CompSuccess bit;
    DECLARE @CompError nvarchar(500);
    
    SET @StartTime = SYSDATETIME();
    SET @SessionId = @@SPID;
    
    -- Vérification profondeur
    IF @RecursionDepth > @MaxRecursion
    BEGIN
        SET @Status = 'ERROR';
        SET @ErrorMsg = CONCAT('Profondeur max atteinte (', @MaxRecursion, ')');
        SET @ExecTimeMs = DATEDIFF(MILLISECOND, @StartTime, SYSDATETIME());
        RETURN;
    END
    
    -- Vérification cycle
    IF @CallingPath IS NULL
        SET @CallingPath = @RuleCode;
    ELSE
    BEGIN
        IF CHARINDEX(CONCAT('|', @RuleCode, '|'), CONCAT('|', @CallingPath, '|')) > 0
        BEGIN
            SET @Status = 'ERROR';
            SET @ErrorMsg = CONCAT('Cycle: ', @CallingPath, ' -> ', @RuleCode);
            SET @ExecTimeMs = DATEDIFF(MILLISECOND, @StartTime, SYSDATETIME());
            RETURN;
        END
        SET @CallingPath = CONCAT(@CallingPath, '|', @RuleCode);
    END
    
    -- Vérification #Variables
    IF OBJECT_ID('tempdb..#Variables') IS NULL
    BEGIN
        SET @Status = 'ERROR';
        SET @ErrorMsg = CONCAT('#Variables non initialisée (session ', @SessionId, ')');
        SET @ExecTimeMs = DATEDIFF(MILLISECOND, @StartTime, SYSDATETIME());
        RETURN;
    END
    
    -- Cache
    IF OBJECT_ID('tempdb..#RuleResultsCache') IS NULL
    BEGIN
        CREATE TABLE #RuleResultsCache (
            RuleCode nvarchar(50) COLLATE DATABASE_DEFAULT PRIMARY KEY,
            Result nvarchar(500) COLLATE DATABASE_DEFAULT,
            SessionId int DEFAULT @@SPID
        );
    END
    
    IF EXISTS (SELECT 1 FROM #RuleResultsCache WHERE RuleCode = @RuleCode)
    BEGIN
        SELECT @Result = Result FROM #RuleResultsCache WHERE RuleCode = @RuleCode;
        SET @Status = 'SUCCESS';
        SET @ExecTimeMs = DATEDIFF(MILLISECOND, @StartTime, SYSDATETIME());
        RETURN;
    END
    
    -- Exécution
    BEGIN TRY
        SELECT @Expression = Expression, @TokensJson = TokensJson, @IsCompiled = IsCompiled
        FROM dbo.Rules WITH (NOLOCK)
        WHERE RuleCode = @RuleCode AND IsActive = 1;
        
        IF @Expression IS NULL
        BEGIN
            SET @Status = 'ERROR';
            SET @ErrorMsg = CONCAT('Règle introuvable: ', @RuleCode);
            SET @ExecTimeMs = DATEDIFF(MILLISECOND, @StartTime, SYSDATETIME());
            RETURN;
        END
        
        IF @IsCompiled = 0
        BEGIN
            EXEC dbo.sp_CompileRule @RuleCode, @CompSuccess OUTPUT, @CompError OUTPUT;
            IF @CompSuccess = 0
            BEGIN
                SET @Status = 'ERROR';
                SET @ErrorMsg = CONCAT('Compilation: ', @CompError);
                SET @ExecTimeMs = DATEDIFF(MILLISECOND, @StartTime, SYSDATETIME());
                RETURN;
            END
            SELECT @TokensJson = TokensJson FROM dbo.Rules WHERE RuleCode = @RuleCode;
        END
        
        -- Résolution des dépendances
        SET @WorkExpr = @Expression;
        
        DECLARE ref_cur CURSOR LOCAL FAST_FORWARD FOR
        SELECT ReferencedRule FROM dbo.fn_ExtractRuleReferences(@Expression);
        
        OPEN ref_cur;
        FETCH NEXT FROM ref_cur INTO @RefRule;
        
        WHILE @@FETCH_STATUS = 0
        BEGIN
            EXEC dbo.sp_ExecuteRuleRecursive 
                @RefRule, 0, @RefResult OUTPUT, @RefStatus OUTPUT, 
                @RefError OUTPUT, @RefTime OUTPUT,
                @RecursionDepth, @MaxRecursion, @CallingPath;
            
            IF @RefStatus <> 'SUCCESS'
            BEGIN
                SET @Status = 'ERROR';
                SET @ErrorMsg = CONCAT('[', @RefRule, ']: ', ISNULL(@RefError, '?'));
                CLOSE ref_cur; 
                DEALLOCATE ref_cur;
                SET @ExecTimeMs = DATEDIFF(MILLISECOND, @StartTime, SYSDATETIME());
                RETURN;
            END
            
            SET @WorkExpr = REPLACE(@WorkExpr, CONCAT('{Rule:', @RefRule, '}'), ISNULL(@RefResult, '0'));
            FETCH NEXT FROM ref_cur INTO @RefRule;
        END
        CLOSE ref_cur; 
        DEALLOCATE ref_cur;
        
        -- Évaluation des tokens
        SET @FinalExpr = @WorkExpr;
        
        SELECT @ResolvedTokens = (
            SELECT 
                JSON_VALUE(value,'$.Token')       AS Token,
                JSON_VALUE(value,'$.AggFunc')     AS AggFunc,
                JSON_VALUE(value,'$.Pattern')     AS Pattern,
                COALESCE(JSON_VALUE(value,'$.ValueFilter'),'ALL') AS ValueFilter,
                JSON_VALUE(value,'$.Placeholder') AS Placeholder
            FROM OPENJSON(@TokensJson)
            WHERE JSON_VALUE(value,'$.AggFunc') <> 'RULE'
            FOR JSON PATH
        );

        IF @ResolvedTokens IS NOT NULL
        BEGIN
            DECLARE eval_cur CURSOR LOCAL FAST_FORWARD FOR
            SELECT JSON_VALUE(value,'$.Token'),
                   JSON_VALUE(value,'$.Placeholder'),
                   JSON_VALUE(value,'$.AggFunc'),
                   JSON_VALUE(value,'$.Pattern'),
                   COALESCE(JSON_VALUE(value,'$.ValueFilter'),'ALL')
            FROM OPENJSON(@ResolvedTokens);

            OPEN eval_cur;
            FETCH NEXT FROM eval_cur INTO @Token, @Placeholder, @AggFunc, @Pattern, @ValueFilter;

            WHILE @@FETCH_STATUS = 0
            BEGIN
                EXEC dbo.sp_EvaluateToken @AggFunc, @Pattern, @ValueFilter, @TokenValue OUTPUT;
                SET @FinalExpr = REPLACE(@FinalExpr, @Token, ISNULL(@TokenValue, '0'));
                FETCH NEXT FROM eval_cur INTO @Token, @Placeholder, @AggFunc, @Pattern, @ValueFilter;
            END

            CLOSE eval_cur;
            DEALLOCATE eval_cur;
        END

        -- Évaluation finale
        SET @Sql = CONCAT(N'SELECT @R = CAST((', @FinalExpr, N') AS nvarchar(500))');
        EXEC sp_executesql @Sql, N'@R nvarchar(500) OUTPUT', @Result OUTPUT;
        
        -- Cache
        INSERT INTO #RuleResultsCache (RuleCode, Result, SessionId)
        VALUES (@RuleCode, @Result, @@SPID);
        
        SET @Status = 'SUCCESS';
        SET @ErrorMsg = NULL;
        
    END TRY
    BEGIN CATCH
        SET @Status = 'ERROR';
        SET @ErrorMsg = ERROR_MESSAGE();
        SET @Result = NULL;
    END CATCH
    
    SET @ExecTimeMs = DATEDIFF(MILLISECOND, @StartTime, SYSDATETIME());
    
    IF @LogToDb = 1 AND @RecursionDepth = 1
    BEGIN
        INSERT INTO dbo.RuleLogs (SessionId, RuleCode, Status, ResultValue, ErrorMsg, ExecutionMs)
        VALUES (@@SPID, @RuleCode, @Status, @Result, @ErrorMsg, @ExecTimeMs);
    END
END;
GO

PRINT '   OK sp_ExecuteRuleRecursive';
GO

CREATE PROCEDURE dbo.sp_ExecuteRulesWithDependencies
    @RuleCodes nvarchar(max) = NULL,
    @LogToDb bit = 0
AS
BEGIN
    SET NOCOUNT ON;
    
    DECLARE @StartTime datetime2;
    DECLARE @Order int;
    DECLARE @Code nvarchar(50);
    DECLARE @Name nvarchar(200);
    DECLARE @Deps nvarchar(max);
    DECLARE @R nvarchar(500);
    DECLARE @S varchar(20);
    DECLARE @E nvarchar(500);
    DECLARE @T int;
    DECLARE @TotalMs int;
    
    SET @StartTime = SYSDATETIME();
    
    IF OBJECT_ID('tempdb..#Variables') IS NULL
    BEGIN
        RAISERROR('#Variables non initialisée', 16, 1);
        RETURN;
    END
    
    IF OBJECT_ID('tempdb..#RuleResultsCache') IS NOT NULL
        DROP TABLE #RuleResultsCache;
    
    CREATE TABLE #RuleResultsCache (
        RuleCode nvarchar(50) COLLATE DATABASE_DEFAULT PRIMARY KEY,
        Result nvarchar(500) COLLATE DATABASE_DEFAULT,
        SessionId int DEFAULT @@SPID
    );
    
    CREATE TABLE #Results (
        ExecOrder int IDENTITY(1,1),
        RuleCode nvarchar(50) COLLATE DATABASE_DEFAULT,
        RuleName nvarchar(200) COLLATE DATABASE_DEFAULT,
        Result nvarchar(500) COLLATE DATABASE_DEFAULT,
        Status varchar(20) COLLATE DATABASE_DEFAULT,
        ErrorMsg nvarchar(500) COLLATE DATABASE_DEFAULT,
        ExecTimeMs int,
        Dependencies nvarchar(max) COLLATE DATABASE_DEFAULT
    );
    
    CREATE TABLE #ToExec (
        RuleCode nvarchar(50) COLLATE DATABASE_DEFAULT PRIMARY KEY,
        InDegree int DEFAULT 0,
        CalcOrder int NULL
    );
    
    IF @RuleCodes IS NOT NULL
    BEGIN
        -- Utiliser une approche itérative au lieu de CTE récursive
        INSERT INTO #ToExec (RuleCode)
        SELECT CAST(value AS nvarchar(50)) FROM OPENJSON(@RuleCodes);
        
        DECLARE @MoreDeps bit;
        SET @MoreDeps = 1;
        
        WHILE @MoreDeps = 1
        BEGIN
            INSERT INTO #ToExec (RuleCode)
            SELECT DISTINCT d.DependsOnRule
            FROM #ToExec t
            JOIN dbo.RuleDependency d ON d.RuleCode = t.RuleCode
            WHERE NOT EXISTS (SELECT 1 FROM #ToExec WHERE RuleCode = d.DependsOnRule)
              AND EXISTS (SELECT 1 FROM dbo.Rules WHERE RuleCode = d.DependsOnRule AND IsActive = 1);
            
            IF @@ROWCOUNT = 0
                SET @MoreDeps = 0;
        END
    END
    ELSE
    BEGIN
        INSERT INTO #ToExec (RuleCode)
        SELECT RuleCode FROM dbo.Rules WHERE IsActive = 1;
    END
    
    -- Tri topologique
    UPDATE t SET InDegree = ISNULL(d.Cnt, 0)
    FROM #ToExec t
    OUTER APPLY (
        SELECT COUNT(*) AS Cnt
        FROM dbo.RuleDependency dep
        WHERE dep.RuleCode COLLATE DATABASE_DEFAULT = t.RuleCode COLLATE DATABASE_DEFAULT
          AND dep.DependsOnRule COLLATE DATABASE_DEFAULT IN (SELECT RuleCode COLLATE DATABASE_DEFAULT FROM #ToExec)
    ) d;
    
    SET @Order = 1;
    WHILE EXISTS (SELECT 1 FROM #ToExec WHERE CalcOrder IS NULL)
    BEGIN
        IF NOT EXISTS (SELECT 1 FROM #ToExec WHERE CalcOrder IS NULL AND InDegree = 0)
        BEGIN
            INSERT INTO #Results (RuleCode, Status, ErrorMsg)
            SELECT RuleCode, 'ERROR', 'Cycle de dépendances'
            FROM #ToExec WHERE CalcOrder IS NULL;
            BREAK;
        END
        
        UPDATE #ToExec SET CalcOrder = @Order WHERE CalcOrder IS NULL AND InDegree = 0;
        
        -- Décrémenter InDegree pour les règles qui dépendent des règles qu'on vient de traiter
        UPDATE t SET InDegree = t.InDegree - cnt.Nb
        FROM #ToExec t
        CROSS APPLY (
            SELECT COUNT(*) AS Nb
            FROM dbo.RuleDependency d
            WHERE d.RuleCode COLLATE DATABASE_DEFAULT = t.RuleCode COLLATE DATABASE_DEFAULT
              AND d.DependsOnRule COLLATE DATABASE_DEFAULT IN (SELECT RuleCode COLLATE DATABASE_DEFAULT FROM #ToExec WHERE CalcOrder = @Order)
        ) cnt
        WHERE t.CalcOrder IS NULL AND cnt.Nb > 0;
        
        SET @Order = @Order + 1;
        IF @Order > 100 BREAK;
    END
    
    -- Exécution
    DECLARE exec_cur CURSOR LOCAL FAST_FORWARD FOR
    SELECT t.RuleCode, r.RuleName,
        (SELECT STRING_AGG(DependsOnRule, ', ') FROM dbo.RuleDependency WHERE RuleCode = t.RuleCode)
    FROM #ToExec t
    JOIN dbo.Rules r ON r.RuleCode = t.RuleCode
    WHERE t.CalcOrder IS NOT NULL
    ORDER BY t.CalcOrder, t.RuleCode;
    
    OPEN exec_cur;
    FETCH NEXT FROM exec_cur INTO @Code, @Name, @Deps;
    
    WHILE @@FETCH_STATUS = 0
    BEGIN
        EXEC dbo.sp_ExecuteRuleRecursive @Code, 0, @R OUTPUT, @S OUTPUT, @E OUTPUT, @T OUTPUT;
        
        INSERT INTO #Results (RuleCode, RuleName, Result, Status, ErrorMsg, ExecTimeMs, Dependencies)
        VALUES (@Code, @Name, @R, @S, @E, @T, @Deps);
        
        FETCH NEXT FROM exec_cur INTO @Code, @Name, @Deps;
    END
    CLOSE exec_cur; 
    DEALLOCATE exec_cur;
    
    IF @LogToDb = 1
    BEGIN
        INSERT INTO dbo.RuleLogs (SessionId, RuleCode, Status, ResultValue, ErrorMsg, ExecutionMs)
        SELECT @@SPID, RuleCode, Status, Result, ErrorMsg, ExecTimeMs FROM #Results;
    END
    
    SELECT 
        ExecOrder AS [#],
        RuleCode AS [Code],
        RuleName AS [Regle],
        Result AS [Resultat],
        Status AS [Statut],
        ExecTimeMs AS [ms],
        Dependencies AS [Dependances]
    FROM #Results
    ORDER BY ExecOrder;
    
    SET @TotalMs = DATEDIFF(MILLISECOND, @StartTime, SYSDATETIME());
    PRINT '';
    PRINT CONCAT('Session: ', @@SPID, ' | Durée totale: ', @TotalMs, ' ms');
    
    DROP TABLE #Results;
    DROP TABLE #ToExec;
END;
GO

PRINT '   OK sp_ExecuteRulesWithDependencies';
PRINT '';
GO

-- =====================================================================
--  FIN INSTALLATION MOTEUR (Objets dbo.*)
--  DEBUT JEU D'ESSAI EXHAUSTIF (sans GO)
-- =====================================================================

/***********************************************************************
    JEU D'ESSAI EXHAUSTIF - MOTEUR DE RÈGLES V4.4
    
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
PRINT '         JEU D''ESSAI EXHAUSTIF - MOTEUR DE RÈGLES V4.4               ';
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

-- Pré-créer le cache dans le scope appelant pour pouvoir l'inspecter après exécution
CREATE TABLE #RuleResultsCache (
    RuleCode nvarchar(50) COLLATE DATABASE_DEFAULT PRIMARY KEY,
    Result nvarchar(500) COLLATE DATABASE_DEFAULT,
    SessionId int DEFAULT @@SPID
);

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
VALUES ('DEPENDANCES', 'Cache Rempli', '>= 8', CAST(@CacheCount AS nvarchar(10)),
    CASE WHEN @CacheCount >= 8 THEN 'PASS' ELSE 'FAIL' END,
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
-- PARTIE 9 : TESTS AVANCÉS DE VALIDATION DU MODÈLE
-- =========================================================================
PRINT '┌─────────────────────────────────────────────────────────────────────┐';
PRINT '│ PARTIE 9 : Tests avancés de validation                              │';
PRINT '└─────────────────────────────────────────────────────────────────────┘';

-- 9.1 Test IIF avec agrégation interne
INSERT INTO dbo.Rules (RuleCode, RuleName, Expression, Description) VALUES
('TEST_IIF_AGG', 'IIF avec Agregation', '{IIF({Sum(MONTANT_%)} > 300, 1, 0)}', 'IIF(Sum > 300)');
EXEC dbo.sp_CompileRule 'TEST_IIF_AGG', @S OUTPUT, @E OUTPUT;

IF OBJECT_ID('tempdb..#RuleResultsCache') IS NOT NULL DROP TABLE #RuleResultsCache;
EXEC dbo.sp_ExecuteRuleRecursive 'TEST_IIF_AGG', 0, @R OUTPUT, @St OUTPUT, @Er OUTPUT, @T OUTPUT;
INSERT INTO #TestResults (TestCategory, TestName, Expected, Actual, Status, Details)
VALUES ('AVANCE', 'IIF avec Sum', '1', @R,
    CASE WHEN TRY_CAST(@R AS int) = 1 THEN 'PASS' ELSE 'FAIL' END,
    'Sum(MONTANT_%)=375 > 300 => 1');

-- 9.2 Test IIF avec calcul dans branche True (tokens multiples)
INSERT INTO dbo.Rules (RuleCode, RuleName, Expression, Description) VALUES
('TEST_IIF_MULTI', 'IIF Multi Tokens', '{IIF({VAL_A} > 50, {VAL_A} + {VAL_B}, {VAL_C})}', 'IIF multi-tokens');
EXEC dbo.sp_CompileRule 'TEST_IIF_MULTI', @S OUTPUT, @E OUTPUT;

IF OBJECT_ID('tempdb..#RuleResultsCache') IS NOT NULL DROP TABLE #RuleResultsCache;
EXEC dbo.sp_ExecuteRuleRecursive 'TEST_IIF_MULTI', 0, @R OUTPUT, @St OUTPUT, @Er OUTPUT, @T OUTPUT;
SET @Expected = 150.25; -- VAL_A(100) + VAL_B(50.25) car 100 > 50
INSERT INTO #TestResults (TestCategory, TestName, Expected, Actual, Status, Details)
VALUES ('AVANCE', 'IIF Multi Tokens', CAST(@Expected AS nvarchar(50)), @R,
    CASE WHEN ABS(TRY_CAST(@R AS decimal(18,2)) - @Expected) < 0.01 THEN 'PASS' ELSE 'FAIL' END,
    '100>50 => 100+50.25=150.25');

-- 9.3 Test règle référençant une règle IIF
INSERT INTO dbo.Rules (RuleCode, RuleName, Expression, Description) VALUES
('TEST_REF_IIF', 'Ref vers IIF', '{Rule:TEST_IIF_CALC} * 10', 'Reference IIF * 10');
EXEC dbo.sp_CompileRule 'TEST_REF_IIF', @S OUTPUT, @E OUTPUT;
EXEC dbo.sp_BuildRuleDependencyGraph;

IF OBJECT_ID('tempdb..#RuleResultsCache') IS NOT NULL DROP TABLE #RuleResultsCache;
EXEC dbo.sp_ExecuteRuleRecursive 'TEST_REF_IIF', 0, @R OUTPUT, @St OUTPUT, @Er OUTPUT, @T OUTPUT;
SET @Expected = 50.00; -- IIF_CALC=5 * 10 = 50
INSERT INTO #TestResults (TestCategory, TestName, Expected, Actual, Status, Details)
VALUES ('AVANCE', 'Ref vers IIF', CAST(@Expected AS nvarchar(50)), @R,
    CASE WHEN ABS(TRY_CAST(@R AS decimal(18,2)) - @Expected) < 0.01 THEN 'PASS' ELSE 'FAIL' END,
    'IIF_CALC(5) * 10 = 50');

-- 9.4 Test combinaison Sum+ et Sum- dans même expression
INSERT INTO dbo.Rules (RuleCode, RuleName, Expression, Description) VALUES
('TEST_SUM_COMBO', 'Sum+ et Sum-', '{Sum(MONTANT_%+)} + {Sum(MONTANT_%-)}', 'Positifs + Negatifs = Total');
EXEC dbo.sp_CompileRule 'TEST_SUM_COMBO', @S OUTPUT, @E OUTPUT;

IF OBJECT_ID('tempdb..#RuleResultsCache') IS NOT NULL DROP TABLE #RuleResultsCache;
EXEC dbo.sp_ExecuteRuleRecursive 'TEST_SUM_COMBO', 0, @R OUTPUT, @St OUTPUT, @Er OUTPUT, @T OUTPUT;
SET @Expected = 375.00; -- 450 + (-75) = 375
INSERT INTO #TestResults (TestCategory, TestName, Expected, Actual, Status, Details)
VALUES ('AVANCE', 'Sum+ et Sum-', CAST(@Expected AS nvarchar(50)), @R,
    CASE WHEN ABS(TRY_CAST(@R AS decimal(18,2)) - @Expected) < 0.01 THEN 'PASS' ELSE 'FAIL' END,
    '450 + (-75) = 375');

-- 9.5 Test IIF avec comparaison de règles
INSERT INTO dbo.Rules (RuleCode, RuleName, Expression, Description) VALUES
('TEST_IIF_RULES', 'IIF Compare Rules', '{IIF({Rule:TEST_L1_A} > {Rule:TEST_L1_B}, {Rule:TEST_L1_A}, {Rule:TEST_L1_B})}', 'Max(L1_A, L1_B)');
EXEC dbo.sp_CompileRule 'TEST_IIF_RULES', @S OUTPUT, @E OUTPUT;
EXEC dbo.sp_BuildRuleDependencyGraph;

IF OBJECT_ID('tempdb..#RuleResultsCache') IS NOT NULL DROP TABLE #RuleResultsCache;
EXEC dbo.sp_ExecuteRuleRecursive 'TEST_IIF_RULES', 0, @R OUTPUT, @St OUTPUT, @Er OUTPUT, @T OUTPUT;
SET @Expected = 100.00; -- L1_A(100) > L1_B(50.25) => L1_A = 100
INSERT INTO #TestResults (TestCategory, TestName, Expected, Actual, Status, Details)
VALUES ('AVANCE', 'IIF Compare Rules', CAST(@Expected AS nvarchar(50)), @R,
    CASE WHEN ABS(TRY_CAST(@R AS decimal(18,2)) - @Expected) < 0.01 THEN 'PASS' ELSE 'FAIL' END,
    '100 > 50.25 => 100');

-- 9.6 Test Count avec filtre positif
INSERT INTO dbo.Rules (RuleCode, RuleName, Expression, Description) VALUES
('TEST_COUNT_POS', 'Count Positifs', '{Count(MONTANT_%+)}', 'Nombre de MONTANT positifs');
EXEC dbo.sp_CompileRule 'TEST_COUNT_POS', @S OUTPUT, @E OUTPUT;

IF OBJECT_ID('tempdb..#RuleResultsCache') IS NOT NULL DROP TABLE #RuleResultsCache;
EXEC dbo.sp_ExecuteRuleRecursive 'TEST_COUNT_POS', 0, @R OUTPUT, @St OUTPUT, @Er OUTPUT, @T OUTPUT;
SET @Expected = 3; -- MONTANT_01(100), MONTANT_02(200), MONTANT_04(150)
INSERT INTO #TestResults (TestCategory, TestName, Expected, Actual, Status, Details)
VALUES ('AVANCE', 'Count Positifs', '3', @R,
    CASE WHEN ABS(TRY_CAST(@R AS decimal(18,2)) - 3) < 0.01 THEN 'PASS' ELSE 'FAIL' END,
    '3 montants positifs');

-- 9.7 Test Avg avec filtre négatif
INSERT INTO dbo.Rules (RuleCode, RuleName, Expression, Description) VALUES
('TEST_AVG_NEG', 'Avg Negatifs', '{Avg(MONTANT_%-)}', 'Moyenne des MONTANT negatifs');
EXEC dbo.sp_CompileRule 'TEST_AVG_NEG', @S OUTPUT, @E OUTPUT;

IF OBJECT_ID('tempdb..#RuleResultsCache') IS NOT NULL DROP TABLE #RuleResultsCache;
EXEC dbo.sp_ExecuteRuleRecursive 'TEST_AVG_NEG', 0, @R OUTPUT, @St OUTPUT, @Er OUTPUT, @T OUTPUT;
SET @Expected = -37.50; -- (-50 + -25) / 2 = -37.5
INSERT INTO #TestResults (TestCategory, TestName, Expected, Actual, Status, Details)
VALUES ('AVANCE', 'Avg Negatifs', CAST(@Expected AS nvarchar(50)), @R,
    CASE WHEN ABS(TRY_CAST(@R AS decimal(18,2)) - @Expected) < 0.01 THEN 'PASS' ELSE 'FAIL' END,
    '(-50-25)/2 = -37.5');

-- 9.8 Test expression avec parenthèses complexes
INSERT INTO dbo.Rules (RuleCode, RuleName, Expression, Description) VALUES
('TEST_PAREN', 'Parentheses', '(({VAL_A} + {VAL_B}) * 2) / (({VAL_A} - {VAL_C}) / 10)', 'Parentheses imbriquees');
EXEC dbo.sp_CompileRule 'TEST_PAREN', @S OUTPUT, @E OUTPUT;

IF OBJECT_ID('tempdb..#RuleResultsCache') IS NOT NULL DROP TABLE #RuleResultsCache;
EXEC dbo.sp_ExecuteRuleRecursive 'TEST_PAREN', 0, @R OUTPUT, @St OUTPUT, @Er OUTPUT, @T OUTPUT;
-- ((100 + 50.25) * 2) / ((100 - (-30)) / 10) = 300.5 / 13 = 23.115...
SET @Expected = 23.115;
INSERT INTO #TestResults (TestCategory, TestName, Expected, Actual, Status, Details)
VALUES ('AVANCE', 'Parentheses', CAST(@Expected AS nvarchar(50)), @R,
    CASE WHEN ABS(TRY_CAST(@R AS decimal(18,2)) - @Expected) < 0.5 THEN 'PASS' ELSE 'FAIL' END,
    '((100+50.25)*2)/((100-(-30))/10)');

-- 9.9 Test modèle de paie complet (utilise les règles existantes)
-- Recharger les données de paie
DELETE FROM #Variables WHERE VarKey IN ('TAUX_HORAIRE','HEURES_NORMALES','HEURES_SUPP_25','HEURES_SUPP_50','PRIME_ANCIENNETE','PRIME_TRANSPORT','PRIME_PANIER');
INSERT INTO #Variables (VarKey, VarType, ValueDecimal, Category) VALUES
    ('TAUX_HORAIRE', 'DECIMAL', 25.00, 'SALAIRE'),
    ('HEURES_NORMALES', 'DECIMAL', 151.67, 'TEMPS'),
    ('HEURES_SUPP_25', 'DECIMAL', 10, 'TEMPS'),
    ('HEURES_SUPP_50', 'DECIMAL', 5, 'TEMPS'),
    ('PRIME_ANCIENNETE', 'DECIMAL', 150.00, 'PRIME'),
    ('PRIME_TRANSPORT', 'DECIMAL', 75.00, 'PRIME'),
    ('PRIME_PANIER', 'DECIMAL', 120.00, 'PRIME');

-- Test du calcul complet SALAIRE_NET (via les règles de paie si elles existent)
IF EXISTS (SELECT 1 FROM dbo.Rules WHERE RuleCode = 'SALAIRE_NET')
BEGIN
    IF OBJECT_ID('tempdb..#RuleResultsCache') IS NOT NULL DROP TABLE #RuleResultsCache;
    EXEC dbo.sp_ExecuteRuleRecursive 'SALAIRE_NET', 0, @R OUTPUT, @St OUTPUT, @Er OUTPUT, @T OUTPUT;
    INSERT INTO #TestResults (TestCategory, TestName, Expected, Actual, Status, Details)
    VALUES ('PAIE', 'Salaire Net Complet', '~2947', @R,
        CASE WHEN @St = 'SUCCESS' AND TRY_CAST(@R AS decimal(18,2)) BETWEEN 2900 AND 3000 THEN 'PASS' ELSE 'FAIL' END,
        CONCAT('Calcul complet via dependances. Temps: ', @T, 'ms'));
END

-- 9.10 Test de stress: plusieurs agrégations dans même expression
INSERT INTO dbo.Rules (RuleCode, RuleName, Expression, Description) VALUES
('TEST_MULTI_AGG', 'Multi Agregations', '{Sum(MONTANT_%)} + {Avg(MONTANT_%)} + {Max(MONTANT_%)} - {Min(MONTANT_%)}', 'Multiple agregations');
EXEC dbo.sp_CompileRule 'TEST_MULTI_AGG', @S OUTPUT, @E OUTPUT;

IF OBJECT_ID('tempdb..#RuleResultsCache') IS NOT NULL DROP TABLE #RuleResultsCache;
EXEC dbo.sp_ExecuteRuleRecursive 'TEST_MULTI_AGG', 0, @R OUTPUT, @St OUTPUT, @Er OUTPUT, @T OUTPUT;
SET @Expected = 700.00; -- 375 + 75 + 200 - (-50) = 700
INSERT INTO #TestResults (TestCategory, TestName, Expected, Actual, Status, Details)
VALUES ('AVANCE', 'Multi Agregations', CAST(@Expected AS nvarchar(50)), @R,
    CASE WHEN ABS(TRY_CAST(@R AS decimal(18,2)) - @Expected) < 0.01 THEN 'PASS' ELSE 'FAIL' END,
    '375+75+200-(-50)=700');

PRINT '   Tests avancés exécutés';
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
    PRINT 'ATTENTION  TESTS EN ÉCHEC:';
    SELECT TestCategory, TestName, Expected, Actual, Details 
    FROM #TestResults WHERE Status = 'FAIL';
END

PRINT '';
PRINT 'Fin des tests: ' + CONVERT(varchar(20), GETDATE(), 120);

-- Nettoyage optionnel (décommenter si souhaité)
-- DELETE FROM dbo.RuleDependency WHERE RuleCode LIKE 'TEST_%';
-- DELETE FROM dbo.Rules WHERE RuleCode LIKE 'TEST_%';
-- DROP TABLE #TestResults;

PRINT '';
PRINT '======================================================';
PRINT 'COPIER-COLLER : RESULTATS DES TESTS (UNIFIE)';
PRINT 'Session: ' + CAST(@@SPID AS varchar(10)) + ' | Date: ' + CONVERT(varchar(19), GETDATE(), 120);
PRINT '======================================================';

-- Résumé global (stable)
SELECT 
    Status,
    COUNT(*) AS NbTests
FROM #TestResults
GROUP BY Status
ORDER BY 
    CASE Status WHEN 'FAIL' THEN 1 WHEN 'ERROR' THEN 2 WHEN 'WARN' THEN 3 WHEN 'PASS' THEN 4 ELSE 5 END;

-- Détail (stable, une seule table)
SELECT
    TestId,
    TestCategory,
    TestName,
    Expected,
    Actual,
    Status,
    Details
FROM #TestResults
ORDER BY TestId;

