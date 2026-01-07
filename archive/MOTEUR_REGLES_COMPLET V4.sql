/***********************************************************************
    MOTEUR DE RÈGLES T-SQL COMPLET - VERSION 4.0
    Avec Récursivité et Isolation Garantie
    
    Compatibilité : SQL Server 2017+
************************************************************************/

SET NOCOUNT ON;
GO

PRINT '══════════════════════════════════════════════════════════════════════';
PRINT '           INSTALLATION DU MOTEUR DE RÈGLES - V4.2                    ';
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

CREATE OR ALTER PROCEDURE dbo.sp_DFS_CheckCycle
    @RuleCode nvarchar(100)
AS
BEGIN
    SET NOCOUNT ON;

    DECLARE @State char(1);
    SELECT @State = State FROM #State WHERE RuleCode = @RuleCode;

    IF @State = 'V'
    BEGIN
        -- Back-edge to a node currently in recursion stack => cycle
        INSERT INTO #CycleEdges (FromRule, ToRule) VALUES (@RuleCode, @RuleCode);
        RETURN;
    END

    IF @State = 'D'
        RETURN;

    UPDATE #State SET State = 'V' WHERE RuleCode = @RuleCode;

    DECLARE @Next nvarchar(100);

    DECLARE dep CURSOR LOCAL FAST_FORWARD FOR
        SELECT d.DependsOnRule
        FROM dbo.RuleDependency d
        WHERE d.RuleCode = @RuleCode;

    OPEN dep;
    FETCH NEXT FROM dep INTO @Next;

    WHILE @@FETCH_STATUS = 0
    BEGIN
        DECLARE @NextState char(1);
        SELECT @NextState = State FROM #State WHERE RuleCode = @Next;

        IF @NextState = 'V'
        BEGIN
            INSERT INTO #CycleEdges (FromRule, ToRule) VALUES (@RuleCode, @Next);
        END
        ELSE
        BEGIN
            EXEC dbo.sp_DFS_CheckCycle @Next;
        END

        FETCH NEXT FROM dep INTO @Next;
    END

    CLOSE dep;
    DEALLOCATE dep;

    UPDATE #State SET State = 'D' WHERE RuleCode = @RuleCode;
END;
GO

CREATE OR ALTER PROCEDURE dbo.sp_DetectRuleCycles
    @HasCycles bit OUTPUT
AS
BEGIN
    SET NOCOUNT ON;

    SET @HasCycles = 0;

    IF OBJECT_ID('tempdb..#State') IS NOT NULL DROP TABLE #State;
    IF OBJECT_ID('tempdb..#CycleEdges') IS NOT NULL DROP TABLE #CycleEdges;

    CREATE TABLE #State (
        RuleCode nvarchar(100) COLLATE DATABASE_DEFAULT PRIMARY KEY,
        State char(1) NOT NULL -- U, V, D
    );

    INSERT INTO #State (RuleCode, State)
    SELECT r.RuleCode, 'U'
    FROM dbo.Rules r
    WHERE r.IsActive = 1;

    CREATE TABLE #CycleEdges (
        FromRule nvarchar(100) COLLATE DATABASE_DEFAULT,
        ToRule   nvarchar(100) COLLATE DATABASE_DEFAULT
    );

    DECLARE @Rule nvarchar(100);

    DECLARE cur CURSOR LOCAL FAST_FORWARD FOR
        SELECT RuleCode FROM #State WHERE State = 'U' ORDER BY RuleCode;

    OPEN cur;
    FETCH NEXT FROM cur INTO @Rule;

    WHILE @@FETCH_STATUS = 0
    BEGIN
        EXEC dbo.sp_DFS_CheckCycle @Rule;
        FETCH NEXT FROM cur INTO @Rule;
    END

    CLOSE cur;
    DEALLOCATE cur;

    IF EXISTS (SELECT 1 FROM #CycleEdges)
    BEGIN
        SET @HasCycles = 1;

        -- Réinitialiser le log (option: garder l'historique si souhaité)
        DELETE FROM dbo.RuleCycleLog;

        INSERT INTO dbo.RuleCycleLog (RuleCode, DependsOnRule)
        SELECT DISTINCT FromRule, ToRule
        FROM #CycleEdges;

        PRINT 'Cycles détectés (voir dbo.RuleCycleLog).';
    END
END;

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


/* -------------------------------------------------------------------
   V4.2 - Exécution traçable (RunId)
   ------------------------------------------------------------------- */
IF OBJECT_ID('dbo.RuleRun', 'U') IS NULL
BEGIN
    CREATE TABLE dbo.RuleRun (
        RunId bigint IDENTITY(1,1) PRIMARY KEY,
        CreatedAt datetime2 NOT NULL DEFAULT SYSDATETIME(),
        CreatedBy sysname NULL DEFAULT SUSER_SNAME(),
        SessionId int NOT NULL DEFAULT @@SPID,
        RuleCodes nvarchar(max) NULL,
        Notes nvarchar(500) NULL
    );
END

IF OBJECT_ID('dbo.RuleRunInput', 'U') IS NULL
BEGIN
    CREATE TABLE dbo.RuleRunInput (
        RunId bigint NOT NULL,
        VarKey nvarchar(100) NOT NULL,
        Category nvarchar(100) NULL,
        Value nvarchar(500) NULL,
        CONSTRAINT PK_RuleRunInput PRIMARY KEY (RunId, VarKey),
        CONSTRAINT FK_RuleRunInput_Run FOREIGN KEY (RunId) REFERENCES dbo.RuleRun(RunId)
    );
END

IF OBJECT_ID('dbo.RuleRunResult', 'U') IS NULL
BEGIN
    CREATE TABLE dbo.RuleRunResult (
        RunId bigint NOT NULL,
        ExecOrder int NOT NULL,
        RuleCode nvarchar(50) NOT NULL,
        RuleName nvarchar(200) NULL,
        Result nvarchar(500) NULL,
        Status varchar(20) NULL,
        ErrorMsg nvarchar(500) NULL,
        ExecTimeMs int NULL,
        Dependencies nvarchar(max) NULL,
        CONSTRAINT PK_RuleRunResult PRIMARY KEY (RunId, RuleCode),
        CONSTRAINT FK_RuleRunResult_Run FOREIGN KEY (RunId) REFERENCES dbo.RuleRun(RunId)
    );

    CREATE INDEX IX_RuleRunResult_RunId_ExecOrder ON dbo.RuleRunResult(RunId, ExecOrder);
END

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
RETURNS TABLE WITH SCHEMABINDING
AS
RETURN
WITH
L0 AS (SELECT 1 AS c UNION ALL SELECT 1),
L1 AS (SELECT 1 AS c FROM L0 A CROSS JOIN L0 B),
L2 AS (SELECT 1 AS c FROM L1 A CROSS JOIN L1 B),
L3 AS (SELECT 1 AS c FROM L2 A CROSS JOIN L2 B),
L4 AS (SELECT 1 AS c FROM L3 A CROSS JOIN L3 B),
N(n) AS (SELECT TOP (ISNULL(LEN(@Expr),0)) ROW_NUMBER() OVER (ORDER BY (SELECT NULL)) FROM L4),
Starts AS (SELECT n AS pos FROM N WHERE SUBSTRING(@Expr, n, 1) = '{'),
Ends AS (SELECT n AS pos FROM N WHERE SUBSTRING(@Expr, n, 1) = '}')
SELECT DISTINCT SUBSTRING(@Expr, s.pos, e.pos - s.pos + 1) AS Token
FROM Starts s
CROSS APPLY (SELECT MIN(pos) AS pos FROM Ends WHERE pos > s.pos) e
WHERE e.pos IS NOT NULL
  AND CHARINDEX('{', SUBSTRING(@Expr, s.pos + 1, e.pos - s.pos - 1)) = 0;
GO

PRINT '   OK fn_ExtractTokens';
GO

CREATE FUNCTION dbo.fn_ParseToken(@Token nvarchar(200))
RETURNS TABLE WITH SCHEMABINDING
AS
RETURN
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
    END AS Pattern,
    CASE 
        WHEN @Token LIKE '%+}' THEN 'POSITIVE'
        WHEN @Token LIKE '%-}' THEN 'NEGATIVE'
        ELSE 'ALL'
    END AS ValueFilter,
    CASE 
        WHEN @Token LIKE '{Rule:%}' THEN 'RULE_REF'
        WHEN @Token LIKE '{IIF(%)}' THEN 'CONDITIONAL'
        WHEN @Token LIKE '{%(%)}' THEN 'AGGREGATE'
        ELSE 'DIRECT'
    END AS TokenType;
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


/* -------------------------------------------------------------------
   V4.2 - Fiabilisation du graphe: détection de cycles robuste (DFS)
   - Détecte cycles directs et indirects (A->B->C->A)
   - Remplit dbo.RuleCycleLog (RuleCode, DependsOnRule)
   - Retourne @HasCycles = 1 si cycle détecté
   ------------------------------------------------------------------- */

/* -------------------------------------------------------------------
   V4.2 - Helper DFS for cycle detection (uses temp tables from caller)
   Temp tables required:
     #State(RuleCode, State) where State: U=Unvisited, V=Visiting, D=Done
     #CycleEdges(FromRule, ToRule) to record back-edges indicating cycles
   ------------------------------------------------------------------- */

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
            SELECT t.Token, p.AggFunc, p.Pattern, p.ValueFilter,
                CONCAT('@P', CAST(ROW_NUMBER() OVER (ORDER BY t.Token) AS nvarchar(10))) AS Placeholder
            FROM (SELECT DISTINCT Token FROM dbo.fn_ExtractTokens(@WorkExpr)) t
            CROSS APPLY dbo.fn_ParseToken(t.Token) p
            WHERE p.AggFunc <> 'RULE'
            FOR JSON PATH
        );
        
        IF @ResolvedTokens IS NOT NULL
        BEGIN
            DECLARE eval_cur CURSOR LOCAL FAST_FORWARD FOR
            SELECT JSON_VALUE(value,'$.Token'), JSON_VALUE(value,'$.Placeholder'),
                   JSON_VALUE(value,'$.AggFunc'), JSON_VALUE(value,'$.Pattern'),
                   ISNULL(JSON_VALUE(value,'$.ValueFilter'),'ALL')
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


/* -------------------------------------------------------------------
   V4.2 - Fiabilisation du graphe: tri topologique strict (Kahn)
   - Ordre déterministe (ORDER BY RuleCode)
   - Aucune exécution si dépendances non résolues (cycle ou graphe incomplet)
   ------------------------------------------------------------------- */

/* -------------------------------------------------------------------
   V4.2 - Exécution batch topologique + traçabilité RunId (optionnelle)
   - Si @PersistRun = 1: crée un RunId, snapshot #Variables, persiste résultats
   ------------------------------------------------------------------- */
CREATE OR ALTER PROCEDURE dbo.sp_ExecuteRulesWithDependencies
    @RuleCodes nvarchar(max) = NULL,
    @LogToDb bit = 0,
    @PersistRun bit = 0,
    @RunId bigint OUTPUT
AS
BEGIN
    SET NOCOUNT ON;

    SET @RunId = NULL;

    DECLARE @StartTime datetime2 = SYSDATETIME();
    DECLARE @Code nvarchar(50);
    DECLARE @Name nvarchar(200);
    DECLARE @Deps nvarchar(max);
    DECLARE @R nvarchar(500);
    DECLARE @S varchar(20);
    DECLARE @E nvarchar(500);
    DECLARE @T int;
    DECLARE @TotalMs int;

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

    /* --------- Optional RunId creation + input snapshot --------- */
    IF @PersistRun = 1
    BEGIN
        INSERT INTO dbo.RuleRun (RuleCodes, Notes)
        VALUES (@RuleCodes, CONCAT('PersistRun=1 | LogToDb=', @LogToDb));

        SET @RunId = CONVERT(bigint, SCOPE_IDENTITY());

        IF OBJECT_ID('tempdb..#Variables') IS NULL
        BEGIN
            RAISERROR('PersistRun=1 requiert la table temporaire #Variables dans la session.', 16, 1);
            RETURN;
        END

        INSERT INTO dbo.RuleRunInput (RunId, VarKey, Category, Value)
        SELECT @RunId, v.VarKey, v.Category, v.Value
        FROM #Variables v;
    END

    CREATE TABLE #ToExec (
        RuleCode nvarchar(50) COLLATE DATABASE_DEFAULT PRIMARY KEY,
        InDegree int NOT NULL DEFAULT 0
    );

    /* --------- Build target set (requested rules + all dependencies) --------- */
    IF @RuleCodes IS NOT NULL
    BEGIN
        INSERT INTO #ToExec (RuleCode)
        SELECT DISTINCT LTRIM(RTRIM(value))
        FROM string_split(@RuleCodes, ',')
        WHERE LTRIM(RTRIM(value)) <> ''
          AND EXISTS (SELECT 1 FROM dbo.Rules r WHERE r.RuleCode = LTRIM(RTRIM(value)) AND r.IsActive = 1);

        DECLARE @MoreDeps bit = 1;
        WHILE @MoreDeps = 1
        BEGIN
            INSERT INTO #ToExec (RuleCode)
            SELECT DISTINCT d.DependsOnRule
            FROM #ToExec t
            JOIN dbo.RuleDependency d ON d.RuleCode = t.RuleCode
            WHERE NOT EXISTS (SELECT 1 FROM #ToExec x WHERE x.RuleCode = d.DependsOnRule)
              AND EXISTS (SELECT 1 FROM dbo.Rules r WHERE r.RuleCode = d.DependsOnRule AND r.IsActive = 1);

            IF @@ROWCOUNT = 0
                SET @MoreDeps = 0;
        END
    END
    ELSE
    BEGIN
        INSERT INTO #ToExec (RuleCode)
        SELECT r.RuleCode
        FROM dbo.Rules r
        WHERE r.IsActive = 1;
    END

    /* --------- Compute indegrees within induced subgraph --------- */
    UPDATE t SET InDegree = ISNULL(d.Cnt, 0)
    FROM #ToExec t
    OUTER APPLY (
        SELECT COUNT(*) AS Cnt
        FROM dbo.RuleDependency dep
        WHERE dep.RuleCode = t.RuleCode
          AND dep.DependsOnRule IN (SELECT RuleCode FROM #ToExec)
    ) d;

    /* --------- Kahn queue --------- */
    IF OBJECT_ID('tempdb..#Ready') IS NOT NULL DROP TABLE #Ready;
    CREATE TABLE #Ready (RuleCode nvarchar(50) COLLATE DATABASE_DEFAULT PRIMARY KEY);

    INSERT INTO #Ready (RuleCode)
    SELECT RuleCode FROM #ToExec WHERE InDegree = 0;

    IF OBJECT_ID('tempdb..#Order') IS NOT NULL DROP TABLE #Order;
    CREATE TABLE #Order (
        CalcOrder int IDENTITY(1,1) PRIMARY KEY,
        RuleCode nvarchar(50) COLLATE DATABASE_DEFAULT UNIQUE
    );

    WHILE EXISTS (SELECT 1 FROM #Ready)
    BEGIN
        SELECT TOP (1) @Code = RuleCode
        FROM #Ready
        ORDER BY RuleCode;

        DELETE FROM #Ready WHERE RuleCode = @Code;

        INSERT INTO #Order (RuleCode) VALUES (@Code);

        UPDATE t
        SET t.InDegree = t.InDegree - 1
        FROM #ToExec t
        JOIN dbo.RuleDependency d
            ON d.RuleCode = t.RuleCode
           AND d.DependsOnRule = @Code;

        INSERT INTO #Ready (RuleCode)
        SELECT t.RuleCode
        FROM #ToExec t
        WHERE t.InDegree = 0
          AND NOT EXISTS (SELECT 1 FROM #Order o WHERE o.RuleCode = t.RuleCode)
          AND NOT EXISTS (SELECT 1 FROM #Ready r WHERE r.RuleCode = t.RuleCode);
    END

    /* --------- Detect unresolved dependencies (cycle / incomplete graph) --------- */
    IF EXISTS (
        SELECT 1
        FROM #ToExec t
        WHERE NOT EXISTS (SELECT 1 FROM #Order o WHERE o.RuleCode = t.RuleCode)
    )
    BEGIN
        PRINT 'ERREUR: Dépendances non résolues (cycle ou graphe incomplet). Règles concernées:';
        SELECT t.RuleCode
        FROM #ToExec t
        WHERE NOT EXISTS (SELECT 1 FROM #Order o WHERE o.RuleCode = t.RuleCode)
        ORDER BY t.RuleCode;

        RAISERROR('Execution annulée: dépendances non résolues (cycle ou graphe incomplet).', 16, 1);
        RETURN;
    END

    /* --------- Execute in strict topological order --------- */
    DECLARE exec_cur CURSOR LOCAL FAST_FORWARD FOR
    SELECT o.RuleCode, r.RuleName,
           (SELECT STRING_AGG(DependsOnRule, ', ')
            FROM dbo.RuleDependency
            WHERE RuleCode = o.RuleCode) AS Deps
    FROM #Order o
    JOIN dbo.Rules r ON r.RuleCode = o.RuleCode
    ORDER BY o.CalcOrder, o.RuleCode;

    OPEN exec_cur;
    FETCH NEXT FROM exec_cur INTO @Code, @Name, @Deps;

    WHILE @@FETCH_STATUS = 0
    BEGIN
        SET @R = NULL; SET @S = NULL; SET @E = NULL; SET @T = NULL;
        DECLARE @ExecStart datetime2 = SYSDATETIME();

        BEGIN TRY
            EXEC dbo.sp_ExecuteRuleRecursive @Code, @R OUTPUT, @S OUTPUT, @E OUTPUT, @LogToDb;
        END TRY
        BEGIN CATCH
            SET @S = 'ERROR';
            SET @E = ERROR_MESSAGE();
        END CATCH

        SET @T = DATEDIFF(MILLISECOND, @ExecStart, SYSDATETIME());

        INSERT INTO #Results (RuleCode, RuleName, Result, Status, ErrorMsg, ExecTimeMs, Dependencies)
        VALUES (@Code, @Name, @R, @S, @E, @T, @Deps);

        FETCH NEXT FROM exec_cur INTO @Code, @Name, @Deps;
    END

    CLOSE exec_cur;
    DEALLOCATE exec_cur;

    /* --------- Optional persistence --------- */
    IF @PersistRun = 1 AND @RunId IS NOT NULL
    BEGIN
        INSERT INTO dbo.RuleRunResult
            (RunId, ExecOrder, RuleCode, RuleName, Result, Status, ErrorMsg, ExecTimeMs, Dependencies)
        SELECT
            @RunId, ExecOrder, RuleCode, RuleName, Result, Status, ErrorMsg, ExecTimeMs, Dependencies
        FROM #Results;
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
    PRINT CONCAT('Session: ', @@SPID, ' | Durée totale: ', @TotalMs, ' ms',
                 CASE WHEN @PersistRun = 1 THEN CONCAT(' | RunId: ', @RunId) ELSE '' END);

    DROP TABLE #Results;
    DROP TABLE #ToExec;
    DROP TABLE #Ready;
    DROP TABLE #Order;
END;
GO

PRINT '   OK sp_ExecuteRulesWithDependencies';
PRINT '';
GO

-- =========================================================================
-- PARTIE 7 : JEU D'ESSAI
-- =========================================================================
PRINT '── PARTIE 7 : Jeu d''essai (Règles de paie) ──';
GO

INSERT INTO dbo.Rules (RuleCode, RuleName, Expression, Description) VALUES
('HEURES_SUPP', 'Heures Supplementaires', '{Sum(HEURES_SUPP_%)}', 'Total heures sup'),
('SALAIRE_BASE', 'Salaire de Base', '{TAUX_HORAIRE} * {HEURES_NORMALES}', 'Salaire de base'),
('PRIMES_TOTAL', 'Total Primes', '{Sum(PRIME_%)}', 'Somme des primes'),
('SALAIRE_BRUT', 'Salaire Brut', '{Rule:SALAIRE_BASE} + {Rule:HEURES_SUPP} * {TAUX_HORAIRE} * 1.25 + {Rule:PRIMES_TOTAL}', 'Salaire brut'),
('CHARGES_SALARIALES', 'Charges Salariales', '{Rule:SALAIRE_BRUT} * 0.22', 'Charges 22%'),
('CHARGES_PATRONALES', 'Charges Patronales', '{Rule:SALAIRE_BRUT} * 0.42', 'Charges 42%'),
('IMPOT_REVENU', 'Impot sur le Revenu', '{IIF({Rule:SALAIRE_BRUT} > 3000, {Rule:SALAIRE_BRUT} * 0.14, {Rule:SALAIRE_BRUT} * 0.07)}', 'Impot progressif'),
('SALAIRE_NET', 'Salaire Net', '{Rule:SALAIRE_BRUT} - {Rule:CHARGES_SALARIALES} - {Rule:IMPOT_REVENU}', 'Salaire net'),
('COUT_EMPLOYEUR', 'Cout Employeur', '{Rule:SALAIRE_BRUT} + {Rule:CHARGES_PATRONALES}', 'Cout total'),
('RATIO_NET_BRUT', 'Ratio Net/Brut', '{Rule:SALAIRE_NET} / {Rule:SALAIRE_BRUT} * 100', 'Pourcentage'),
('RATIO_COUT_NET', 'Ratio Cout/Net', '{Rule:COUT_EMPLOYEUR} / {Rule:SALAIRE_NET}', 'Ratio');
GO

PRINT '   OK 11 règles inserees';
GO

DECLARE @RCode nvarchar(50), @Success bit, @Error nvarchar(500);
DECLARE comp_cur CURSOR LOCAL FAST_FORWARD FOR SELECT RuleCode FROM dbo.Rules;
OPEN comp_cur;
FETCH NEXT FROM comp_cur INTO @RCode;
WHILE @@FETCH_STATUS = 0
BEGIN
    EXEC dbo.sp_CompileRule @RCode, @Success OUTPUT, @Error OUTPUT;
    FETCH NEXT FROM comp_cur INTO @RCode;
END
CLOSE comp_cur; 
DEALLOCATE comp_cur;
GO

PRINT '   OK Règles compilées';
GO

EXEC dbo.sp_BuildRuleDependencyGraph;
GO

PRINT '';
GO

-- =========================================================================
-- PARTIE 8 : TESTS
-- =========================================================================
PRINT '── PARTIE 8 : Tests ──';
PRINT '';
GO

-- Charger les données de test
TRUNCATE TABLE #Variables;
GO

INSERT INTO #Variables (VarKey, VarType, ValueDecimal, Category) VALUES
    ('TAUX_HORAIRE', 'DECIMAL', 25.00, 'SALAIRE'),
    ('HEURES_NORMALES', 'DECIMAL', 151.67, 'TEMPS'),
    ('HEURES_SUPP_25', 'DECIMAL', 10, 'TEMPS'),
    ('HEURES_SUPP_50', 'DECIMAL', 5, 'TEMPS'),
    ('PRIME_ANCIENNETE', 'DECIMAL', 150.00, 'PRIME'),
    ('PRIME_TRANSPORT', 'DECIMAL', 75.00, 'PRIME'),
    ('PRIME_PANIER', 'DECIMAL', 120.00, 'PRIME');
GO

PRINT 'Données de test chargées:';
SELECT VarKey, CAST(ValueDecimal AS varchar(20)) AS Valeur, Category FROM #Variables;
PRINT '';
GO

-- Test SALAIRE_BASE
PRINT '── TEST: SALAIRE_BASE ──';
IF OBJECT_ID('tempdb..#RuleResultsCache') IS NOT NULL DROP TABLE #RuleResultsCache;
GO

DECLARE @R1 nvarchar(500), @S1 varchar(20), @E1 nvarchar(500), @T1 int;
EXEC dbo.sp_ExecuteRuleRecursive 'SALAIRE_BASE', 0, @R1 OUTPUT, @S1 OUTPUT, @E1 OUTPUT, @T1 OUTPUT;
PRINT CONCAT('   Resultat: ', ISNULL(@R1, 'NULL'));
PRINT CONCAT('   Statut: ', ISNULL(@S1, 'NULL'));
PRINT '   Attendu: 3791.75 (25 x 151.67)';
IF TRY_CAST(@R1 AS decimal(18,2)) = 3791.75 
    PRINT '   >> TEST REUSSI';
ELSE 
    PRINT '   >> TEST ECHOUE';
PRINT '';
GO

-- Test SALAIRE_NET
PRINT '── TEST: SALAIRE_NET ──';
IF OBJECT_ID('tempdb..#RuleResultsCache') IS NOT NULL DROP TABLE #RuleResultsCache;
GO

DECLARE @R2 nvarchar(500), @S2 varchar(20), @E2 nvarchar(500), @T2 int;
EXEC dbo.sp_ExecuteRuleRecursive 'SALAIRE_NET', 0, @R2 OUTPUT, @S2 OUTPUT, @E2 OUTPUT, @T2 OUTPUT;
PRINT CONCAT('   Resultat: ', ISNULL(@R2, 'NULL'));
PRINT CONCAT('   Statut: ', ISNULL(@S2, 'NULL'));
PRINT CONCAT('   Temps: ', ISNULL(@T2, 0), ' ms');
IF @S2 = 'SUCCESS' 
    PRINT '   >> TEST REUSSI';
ELSE 
    PRINT CONCAT('   >> TEST ECHOUE: ', ISNULL(@E2, '?'));
PRINT '';
GO

-- Test batch
PRINT '── TEST: EXECUTION BATCH ──';
EXEC dbo.sp_ExecuteRulesWithDependencies NULL, 0;
PRINT '';
GO

-- Test isolation
PRINT '── TEST: ISOLATION ──';
DECLARE @TestVal decimal(18,2);
SET @TestVal = @@SPID * 1000;

TRUNCATE TABLE #Variables;
INSERT INTO #Variables (VarKey, VarType, ValueDecimal) VALUES ('TEST_VAL', 'DECIMAL', @TestVal);

IF NOT EXISTS (SELECT 1 FROM dbo.Rules WHERE RuleCode = 'TEST_ISOL')
BEGIN
    INSERT INTO dbo.Rules (RuleCode, RuleName, Expression) VALUES ('TEST_ISOL', 'Test Isolation', '{TEST_VAL}');
    DECLARE @S bit, @E nvarchar(500);
    EXEC dbo.sp_CompileRule 'TEST_ISOL', @S OUTPUT, @E OUTPUT;
END

IF OBJECT_ID('tempdb..#RuleResultsCache') IS NOT NULL DROP TABLE #RuleResultsCache;

DECLARE @R3 nvarchar(500), @S3 varchar(20), @E3 nvarchar(500), @T3 int;
EXEC dbo.sp_ExecuteRuleRecursive 'TEST_ISOL', 0, @R3 OUTPUT, @S3 OUTPUT, @E3 OUTPUT, @T3 OUTPUT;

PRINT CONCAT('   Session: ', @@SPID);
PRINT CONCAT('   Valeur attendue: ', @TestVal);
PRINT CONCAT('   Valeur obtenue: ', ISNULL(@R3, 'NULL'));

IF TRY_CAST(@R3 AS decimal(18,2)) = @TestVal
    PRINT '   >> ISOLATION CONFIRMEE';
ELSE
    PRINT '   >> PROBLEME ISOLATION';
PRINT '';
GO

-- =========================================================================
-- FIN
-- =========================================================================
PRINT '══════════════════════════════════════════════════════════════════════';
PRINT '              INSTALLATION TERMINEE AVEC SUCCES                       ';
PRINT '══════════════════════════════════════════════════════════════════════';
PRINT '';
PRINT 'Procedures disponibles:';
PRINT '  - sp_ExecuteRuleRecursive      : Execute une regle';
PRINT '  - sp_ExecuteRulesWithDependencies : Execute toutes les regles';
PRINT '  - sp_CompileRule               : Compile une regle';
PRINT '  - sp_BuildRuleDependencyGraph  : Construit le graphe';
PRINT '  - sp_DetectRuleCycles          : Detecte les cycles';
PRINT '';
PRINT 'Utilisation:';
PRINT '  1. Charger #Variables';
PRINT '  2. EXEC sp_ExecuteRulesWithDependencies NULL, 0;';
PRINT '';
GO
