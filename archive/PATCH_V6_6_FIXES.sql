/***********************************************************************
    PATCH MOTEUR V6.6 - CORRECTIONS TESTS CONFORMITE
    
    Corrige 3 problemes identifies dans les tests:
    1. Normalisation numerique incomplete (15.0000000000 au lieu de 15)
    2. CONCAT avec separateur incorrect (A,B au lieu de AB)
    3. Agregat SUM avec regles en erreur
    
    A appliquer APRES installation V6.6
************************************************************************/

SET NOCOUNT ON;
GO

PRINT '======================================================================';
PRINT '           PATCH V6.6 - CORRECTIONS TESTS CONFORMITE                ';
PRINT '======================================================================';
PRINT '';

-- =========================================================================
-- FIX 1: NORMALISATION NUMERIQUE COMPLETE
-- =========================================================================
PRINT '-- Fix 1: Normalisation numerique --';

-- Fonction amelioree pour supprimer TOUS les zeros inutiles
IF OBJECT_ID('dbo.fn_NormalizeNumericResult','FN') IS NOT NULL 
    DROP FUNCTION dbo.fn_NormalizeNumericResult;
GO

CREATE FUNCTION dbo.fn_NormalizeNumericResult(@Value NVARCHAR(MAX))
RETURNS NVARCHAR(MAX)
AS
BEGIN
    DECLARE @NumValue NUMERIC(38,10);
    
    -- Tenter conversion numerique
    SET @NumValue = TRY_CAST(@Value AS NUMERIC(38,10));
    
    IF @NumValue IS NULL
        RETURN @Value;  -- Pas un nombre, retourner tel quel
    
    -- Convertir en VARCHAR pour controle format
    DECLARE @Result VARCHAR(50) = CAST(@NumValue AS VARCHAR(50));
    
    -- Supprimer zeros decimaux inutiles
    IF CHARINDEX('.', @Result) > 0
    BEGIN
        -- Supprimer zeros a droite
        WHILE RIGHT(@Result, 1) = '0'
            SET @Result = LEFT(@Result, LEN(@Result) - 1);
        
        -- Supprimer point decimal si plus de decimales
        IF RIGHT(@Result, 1) = '.'
            SET @Result = LEFT(@Result, LEN(@Result) - 1);
    END
    
    RETURN @Result;
END;
GO

PRINT '   OK';
GO

-- =========================================================================
-- FIX 2: PROCEDURE sp_ResolveSimpleAggregate CORRIGEE
-- =========================================================================
PRINT '-- Fix 2: sp_ResolveSimpleAggregate --';

IF OBJECT_ID('dbo.sp_ResolveSimpleAggregate','P') IS NOT NULL 
    DROP PROCEDURE dbo.sp_ResolveSimpleAggregate;
GO

CREATE PROCEDURE dbo.sp_ResolveSimpleAggregate
    @Aggregator VARCHAR(20),
    @LikePattern NVARCHAR(500),
    @Result NVARCHAR(MAX) OUTPUT
AS
BEGIN
    SET NOCOUNT ON;
    SET @Result = NULL;
    
    -- Court-circuit pour les 80% de cas simples
    IF @Aggregator = 'SUM'
    BEGIN
        SELECT @Result = CAST(SUM(CAST(ScalarValue AS NUMERIC(38,10))) AS NVARCHAR(MAX))
        FROM #ThreadState
        WHERE [Key] LIKE @LikePattern COLLATE SQL_Latin1_General_CP1_CI_AS
          AND State = 2 AND ScalarValue IS NOT NULL AND ValueIsNumeric = 1;
        
        -- FIX 1: Normalisation
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
        SELECT @Result = CAST(AVG(CAST(ScalarValue AS NUMERIC(38,10))) AS NVARCHAR(MAX))
        FROM #ThreadState
        WHERE [Key] LIKE @LikePattern COLLATE SQL_Latin1_General_CP1_CI_AS
          AND State = 2 AND ScalarValue IS NOT NULL AND ValueIsNumeric = 1;
        
        -- FIX 1: Normalisation
        SET @Result = dbo.fn_NormalizeNumericResult(@Result);
    END
    ELSE IF @Aggregator = 'MIN'
    BEGIN
        SELECT @Result = CAST(MIN(CAST(ScalarValue AS NUMERIC(38,10))) AS NVARCHAR(MAX))
        FROM #ThreadState
        WHERE [Key] LIKE @LikePattern COLLATE SQL_Latin1_General_CP1_CI_AS
          AND State = 2 AND ScalarValue IS NOT NULL AND ValueIsNumeric = 1;
        
        -- FIX 1: Normalisation
        SET @Result = dbo.fn_NormalizeNumericResult(@Result);
    END
    ELSE IF @Aggregator = 'MAX'
    BEGIN
        SELECT @Result = CAST(MAX(CAST(ScalarValue AS NUMERIC(38,10))) AS NVARCHAR(MAX))
        FROM #ThreadState
        WHERE [Key] LIKE @LikePattern COLLATE SQL_Latin1_General_CP1_CI_AS
          AND State = 2 AND ScalarValue IS NOT NULL AND ValueIsNumeric = 1;
        
        -- FIX 1: Normalisation
        SET @Result = dbo.fn_NormalizeNumericResult(@Result);
    END
    ELSE IF @Aggregator = 'FIRST'
    BEGIN
        SELECT TOP 1 @Result = ScalarValue
        FROM #ThreadState
        WHERE [Key] LIKE @LikePattern COLLATE SQL_Latin1_General_CP1_CI_AS
          AND State = 2 AND ScalarValue IS NOT NULL
        ORDER BY SeqId;
        
        -- FIX 1: Normalisation si numerique
        SET @Result = dbo.fn_NormalizeNumericResult(@Result);
    END
    ELSE IF @Aggregator = 'LAST'
    BEGIN
        SELECT TOP 1 @Result = ScalarValue
        FROM #ThreadState
        WHERE [Key] LIKE @LikePattern COLLATE SQL_Latin1_General_CP1_CI_AS
          AND State = 2 AND ScalarValue IS NOT NULL
        ORDER BY SeqId DESC;
        
        -- FIX 1: Normalisation si numerique
        SET @Result = dbo.fn_NormalizeNumericResult(@Result);
    END
    ELSE IF @Aggregator = 'CONCAT'
    BEGIN
        -- FIX 2: Pas de separateur pour CONCAT
        SELECT @Result = ISNULL(STRING_AGG(ScalarValue, '') WITHIN GROUP (ORDER BY SeqId), '')
        FROM #ThreadState
        WHERE [Key] LIKE @LikePattern COLLATE SQL_Latin1_General_CP1_CI_AS
          AND State = 2 AND ScalarValue IS NOT NULL;
    END
END;
GO

PRINT '   OK';
GO

-- =========================================================================
-- FIX 3: PROCEDURE sp_ResolveToken CORRIGEE
-- =========================================================================
PRINT '-- Fix 3: sp_ResolveToken (JSONIFY + normalisation) --';

IF OBJECT_ID('dbo.sp_ResolveToken','P') IS NOT NULL 
    DROP PROCEDURE dbo.sp_ResolveToken;
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
    
    -- Variable simple directe (court-circuit)
    IF @IsRuleRef = 0 AND @Pattern NOT LIKE '%:%' AND @Pattern NOT LIKE '%*%'
    BEGIN
        SELECT @ResolvedValue = ScalarValue 
        FROM #ThreadState 
        WHERE [Key] = @Pattern COLLATE SQL_Latin1_General_CP1_CI_AS AND State = 2;
        
        -- FIX 1: Normalisation
        SET @ResolvedValue = dbo.fn_NormalizeNumericResult(@ResolvedValue);
        RETURN;
    END
    
    -- Construction pattern LIKE
    DECLARE @LikePattern NVARCHAR(500) = @Pattern;
    IF @IsRuleRef = 1 SET @LikePattern = 'rule:' + @Pattern;
    SET @LikePattern = REPLACE(REPLACE(@LikePattern, '*', '%'), '?', '_');
    
    -- Court-circuit agregats simples (80% des cas)
    EXEC dbo.sp_ResolveSimpleAggregate @Aggregator, @LikePattern, @ResolvedValue OUTPUT;
    
    IF @ResolvedValue IS NOT NULL 
        OR @Aggregator IN ('SUM','COUNT','AVG','MIN','MAX','FIRST','LAST','CONCAT')
        RETURN;
    
    -- Detection taille ensemble pour strategie optimale
    DECLARE @RowCount INT = (
        SELECT COUNT(*) FROM #ThreadState 
        WHERE [Key] LIKE @LikePattern COLLATE SQL_Latin1_General_CP1_CI_AS
          AND State = 2 AND ScalarValue IS NOT NULL
    );
    
    -- Ensemble vide: comportement selon agregat
    IF @RowCount = 0
    BEGIN
        IF @Aggregator IN ('CONCAT') SET @ResolvedValue = '';
        ELSE IF @Aggregator IN ('JSONIFY') SET @ResolvedValue = '{}';
        ELSE SET @ResolvedValue = NULL;
        RETURN;
    END
    
    -- Strategie adaptative selon taille
    IF @RowCount > 100
    BEGIN
        -- Grand ensemble: table temporaire avec statistiques
        CREATE TABLE #FilteredSetLarge (
            SeqId INT, 
            [Key] NVARCHAR(200) COLLATE SQL_Latin1_General_CP1_CI_AS, 
            ScalarValue NVARCHAR(MAX),
            ValueIsNumeric BIT,
            INDEX IX_SeqId NONCLUSTERED (SeqId)
        );
        
        INSERT INTO #FilteredSetLarge
        SELECT SeqId, [Key], ScalarValue, ValueIsNumeric
        FROM #ThreadState
        WHERE [Key] LIKE @LikePattern COLLATE SQL_Latin1_General_CP1_CI_AS
          AND State = 2 AND ScalarValue IS NOT NULL;
        
        -- Agregats complexes sur table temp
        IF @Aggregator = 'JSONIFY'
        BEGIN
            -- STRING_AGG natif pour JSONIFY
            SELECT @ResolvedValue = '{' + ISNULL(
                STRING_AGG(
                    '"' + REPLACE([Key], '"', '\"') + '":' +
                    CASE 
                        WHEN ScalarValue LIKE '{%}' OR ScalarValue LIKE '[%]' THEN ScalarValue
                        WHEN ValueIsNumeric = 1 THEN dbo.fn_NormalizeNumericResult(ScalarValue)
                        WHEN LOWER(ScalarValue) IN ('true','false','null') THEN LOWER(ScalarValue)
                        ELSE '"' + REPLACE(ScalarValue, '"', '\"') + '"'
                    END,
                    ','
                ) WITHIN GROUP (ORDER BY SeqId),
                ''
            ) + '}'
            FROM #FilteredSetLarge;
        END
        -- Autres agregats complexes (POS/NEG)
        ELSE IF @Aggregator LIKE '%_POS' OR @Aggregator LIKE '%_NEG'
        BEGIN
            DECLARE @NumVal NUMERIC(38,10);
            DECLARE @NumericSet TABLE (Val NUMERIC(38,10));
            
            INSERT INTO @NumericSet
            SELECT CAST(ScalarValue AS NUMERIC(38,10))
            FROM #FilteredSetLarge
            WHERE ValueIsNumeric = 1
              AND (@Aggregator LIKE '%_POS' AND CAST(ScalarValue AS NUMERIC(38,10)) > 0
                   OR @Aggregator LIKE '%_NEG' AND CAST(ScalarValue AS NUMERIC(38,10)) < 0);
            
            IF @Aggregator LIKE 'SUM%' 
                SELECT @ResolvedValue = CAST(SUM(Val) AS NVARCHAR(MAX)) FROM @NumericSet;
            ELSE IF @Aggregator LIKE 'AVG%' 
                SELECT @ResolvedValue = CAST(AVG(Val) AS NVARCHAR(MAX)) FROM @NumericSet;
            ELSE IF @Aggregator LIKE 'MIN%' 
                SELECT @ResolvedValue = CAST(MIN(Val) AS NVARCHAR(MAX)) FROM @NumericSet;
            ELSE IF @Aggregator LIKE 'MAX%' 
                SELECT @ResolvedValue = CAST(MAX(Val) AS NVARCHAR(MAX)) FROM @NumericSet;
            ELSE IF @Aggregator LIKE 'COUNT%' 
                SELECT @ResolvedValue = CAST(COUNT(*) AS NVARCHAR(MAX)) FROM @NumericSet;
            ELSE IF @Aggregator LIKE 'FIRST%'
                SELECT TOP 1 @ResolvedValue = CAST(Val AS NVARCHAR(MAX)) FROM @NumericSet 
                ORDER BY CASE WHEN @Aggregator LIKE '%_POS' THEN Val ELSE -Val END;
            
            -- FIX 1: Normalisation
            SET @ResolvedValue = dbo.fn_NormalizeNumericResult(@ResolvedValue);
        END
        
        DROP TABLE #FilteredSetLarge;
    END
    ELSE
    BEGIN
        -- Petit ensemble: variable table (plus rapide)
        DECLARE @FilteredSetSmall TABLE (
            SeqId INT, 
            [Key] NVARCHAR(200) COLLATE SQL_Latin1_General_CP1_CI_AS, 
            ScalarValue NVARCHAR(MAX), 
            ValueIsNumeric BIT
        );
        
        INSERT INTO @FilteredSetSmall
        SELECT SeqId, [Key], ScalarValue, ValueIsNumeric
        FROM #ThreadState
        WHERE [Key] LIKE @LikePattern COLLATE SQL_Latin1_General_CP1_CI_AS
          AND State = 2 AND ScalarValue IS NOT NULL;
        
        IF @Aggregator = 'JSONIFY'
        BEGIN
            -- STRING_AGG pour JSONIFY
            SELECT @ResolvedValue = '{' + ISNULL(
                STRING_AGG(
                    '"' + REPLACE([Key], '"', '\"') + '":' +
                    CASE 
                        WHEN ScalarValue LIKE '{%}' OR ScalarValue LIKE '[%]' THEN ScalarValue
                        WHEN ValueIsNumeric = 1 THEN dbo.fn_NormalizeNumericResult(ScalarValue)
                        WHEN LOWER(ScalarValue) IN ('true','false','null') THEN LOWER(ScalarValue)
                        ELSE '"' + REPLACE(ScalarValue, '"', '\"') + '"'
                    END,
                    ','
                ) WITHIN GROUP (ORDER BY SeqId),
                ''
            ) + '}'
            FROM @FilteredSetSmall;
        END
        ELSE IF @Aggregator LIKE '%_POS' OR @Aggregator LIKE '%_NEG'
        BEGIN
            DECLARE @NumericSetSmall TABLE (Val NUMERIC(38,10));
            
            INSERT INTO @NumericSetSmall
            SELECT CAST(ScalarValue AS NUMERIC(38,10))
            FROM @FilteredSetSmall
            WHERE ValueIsNumeric = 1
              AND (@Aggregator LIKE '%_POS' AND CAST(ScalarValue AS NUMERIC(38,10)) > 0
                   OR @Aggregator LIKE '%_NEG' AND CAST(ScalarValue AS NUMERIC(38,10)) < 0);
            
            IF @Aggregator LIKE 'SUM%' 
                SELECT @ResolvedValue = CAST(SUM(Val) AS NVARCHAR(MAX)) FROM @NumericSetSmall;
            ELSE IF @Aggregator LIKE 'AVG%' 
                SELECT @ResolvedValue = CAST(AVG(Val) AS NVARCHAR(MAX)) FROM @NumericSetSmall;
            ELSE IF @Aggregator LIKE 'MIN%' 
                SELECT @ResolvedValue = CAST(MIN(Val) AS NVARCHAR(MAX)) FROM @NumericSetSmall;
            ELSE IF @Aggregator LIKE 'MAX%' 
                SELECT @ResolvedValue = CAST(MAX(Val) AS NVARCHAR(MAX)) FROM @NumericSetSmall;
            ELSE IF @Aggregator LIKE 'COUNT%' 
                SELECT @ResolvedValue = CAST(COUNT(*) AS NVARCHAR(MAX)) FROM @NumericSetSmall;
            ELSE IF @Aggregator LIKE 'FIRST%'
                SELECT TOP 1 @ResolvedValue = CAST(Val AS NVARCHAR(MAX)) FROM @NumericSetSmall 
                ORDER BY CASE WHEN @Aggregator LIKE '%_POS' THEN Val ELSE -Val END;
            
            -- FIX 1: Normalisation
            SET @ResolvedValue = dbo.fn_NormalizeNumericResult(@ResolvedValue);
        END
    END
END;
GO

PRINT '   OK';
GO

-- =========================================================================
-- FIX 4: PROCEDURE sp_ExecuteRule AVEC NORMALISATION
-- =========================================================================
PRINT '-- Fix 4: sp_ExecuteRule (normalisation resultats) --';

IF OBJECT_ID('dbo.sp_ExecuteRule','P') IS NOT NULL 
    DROP PROCEDURE dbo.sp_ExecuteRule;
GO

CREATE PROCEDURE dbo.sp_ExecuteRule
    @RuleCode NVARCHAR(200),
    @Result NVARCHAR(MAX) OUTPUT,
    @ErrorMessage NVARCHAR(500) OUTPUT
AS
BEGIN
    SET NOCOUNT ON;
    
    SET @Result = NULL;
    SET @ErrorMessage = NULL;
    
    DECLARE @Expression NVARCHAR(MAX), @NormalizedExpr NVARCHAR(MAX), @TokensJson NVARCHAR(MAX);
    DECLARE @StartTime DATETIME2 = SYSDATETIME();
    
    SELECT @Expression = Expression 
    FROM dbo.RuleDefinitions 
    WHERE RuleCode = @RuleCode AND IsActive = 1;
    
    IF @Expression IS NULL
    BEGIN
        SET @ErrorMessage = 'Rule not found or inactive';
        UPDATE #ThreadState SET State = 3, ErrorCategory = 'RULE', ErrorCode = 'NOT_FOUND'
        WHERE [Key] = @RuleCode AND IsRule = 1;
        RETURN;
    END
    
    UPDATE #ThreadState SET State = 1 WHERE [Key] = @RuleCode AND IsRule = 1;
    
    BEGIN TRY
        -- Recuperer depuis cache
        EXEC dbo.sp_GetCompiledExpression @RuleCode, @Expression, @NormalizedExpr OUTPUT, @TokensJson OUTPUT;
        
        -- Resolution set-based (pas de cursor)
        DECLARE @TokenResolutions TABLE (Token NVARCHAR(1000), ResolvedValue NVARCHAR(MAX), IsNumeric BIT);
        
        -- Resoudre tous les tokens
        INSERT INTO @TokenResolutions (Token, ResolvedValue, IsNumeric)
        SELECT 
            j.Token,
            CASE 
                -- Court-circuit variable simple
                WHEN j.IsRuleRef = 0 AND j.Pattern NOT LIKE '%*%' AND j.Pattern NOT LIKE '%:%'
                THEN (SELECT ScalarValue FROM #ThreadState 
                      WHERE [Key] = j.Pattern COLLATE SQL_Latin1_General_CP1_CI_AS AND State = 2)
                ELSE NULL
            END,
            0
        FROM OPENJSON(ISNULL(@TokensJson, '[]')) WITH (
            Token NVARCHAR(1000),
            Aggregator VARCHAR(20),
            IsRuleRef BIT,
            Pattern NVARCHAR(500)
        ) j;
        
        -- Resoudre tokens complexes NULL (delegation sp_ResolveToken)
        DECLARE @Token NVARCHAR(1000), @ResolvedValue NVARCHAR(MAX);
        
        WHILE EXISTS (SELECT 1 FROM @TokenResolutions WHERE ResolvedValue IS NULL)
        BEGIN
            SELECT TOP 1 @Token = Token FROM @TokenResolutions WHERE ResolvedValue IS NULL;
            
            EXEC dbo.sp_ResolveToken @Token, @ResolvedValue OUTPUT;
            
            UPDATE @TokenResolutions SET ResolvedValue = @ResolvedValue WHERE Token = @Token;
        END
        
        -- Verifier propagation NULL
        IF EXISTS (SELECT 1 FROM @TokenResolutions WHERE ResolvedValue IS NULL)
        BEGIN
            SET @Result = NULL;
            UPDATE #ThreadState SET State = 2, ScalarValue = NULL WHERE [Key] = @RuleCode AND IsRule = 1;
            RETURN;
        END
        
        -- Detection type numerique pour remplacement optimal
        UPDATE @TokenResolutions
        SET IsNumeric = CASE WHEN TRY_CAST(ResolvedValue AS NUMERIC(38,10)) IS NOT NULL THEN 1 ELSE 0 END;
        
        -- Remplacer tokens (set-based)
        DECLARE @CompiledSQL NVARCHAR(MAX) = @NormalizedExpr;
        
        SELECT @CompiledSQL = REPLACE(@CompiledSQL, tr.Token, 
            CASE WHEN tr.IsNumeric = 1 THEN tr.ResolvedValue 
                 ELSE '''' + REPLACE(tr.ResolvedValue, '''', '''''') + ''''
            END)
        FROM @TokenResolutions tr;
        
        -- Execution SQL
        DECLARE @SQL NVARCHAR(MAX) = N'SELECT @R = ' + @CompiledSQL;
        EXEC sp_executesql @SQL, N'@R NVARCHAR(MAX) OUTPUT', @Result OUTPUT;
        
        -- FIX 1: Normalisation resultat
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

PRINT '   OK';
GO

-- =========================================================================
-- FIX 5: PROCEDURE sp_EvaluateSimpleRules AVEC NORMALISATION
-- =========================================================================
PRINT '-- Fix 5: sp_EvaluateSimpleRules (normalisation) --';

IF OBJECT_ID('dbo.sp_EvaluateSimpleRules','P') IS NOT NULL 
    DROP PROCEDURE dbo.sp_EvaluateSimpleRules;
GO

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
            
            -- FIX 1: Normalisation resultat
            SET @Result = dbo.fn_NormalizeNumericResult(@Result);
            
            UPDATE #ThreadState SET State = 2, ScalarValue = @Result WHERE [Key] = @RuleCode AND IsRule = 1;
        END TRY
        BEGIN CATCH
            UPDATE #ThreadState SET State = 3, ScalarValue = NULL, ErrorCategory = 'SQL', ErrorCode = 'SQL_ERROR'
            WHERE [Key] = @RuleCode AND IsRule = 1;
        END CATCH
    END
END;
GO

PRINT '   OK';
GO

PRINT '';
PRINT '======================================================================';
PRINT '                   PATCH APPLIQUE AVEC SUCCES                        ';
PRINT '======================================================================';
PRINT '';
PRINT '   CORRECTIONS APPLIQUEES:';
PRINT '   ? Fix 1: Normalisation numerique complete (15 au lieu de 15.0000)';
PRINT '   ? Fix 2: CONCAT sans separateur (AB au lieu de A,B)';
PRINT '   ? Fix 3: JSONIFY avec normalisation numerique';
PRINT '   ? Fix 4: sp_ExecuteRule avec normalisation';
PRINT '   ? Fix 5: sp_EvaluateSimpleRules avec normalisation';
PRINT '';
PRINT '   RE-EXECUTER LES TESTS DE CONFORMITE:';
PRINT '   - Tous les tests devraient maintenant passer (PASS)';
PRINT '   - Si T16 echoue encore, verifier regles TEST_R1/R2/R3';
PRINT '';
PRINT '======================================================================';
GO
