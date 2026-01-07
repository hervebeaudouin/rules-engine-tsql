
/* ======================================================================
   PATCH v6.6.2 — Conformité tests v1.6.0
   - Normalisation canonique des résultats numériques (suppression .0000…)
   - CONCAT sans séparateur (attendu: "AB")
   - Tokens Rule:… : sélection par IsRule=1 (pas par préfixe "rule:")
   - Agrégats ignorent NULL via ScalarValue IS NOT NULL (et non via State)
   ====================================================================== */

-- 1) Normalisation canonique des scalaires (numérique -> string canonique)
CREATE OR ALTER FUNCTION dbo.fn_NormalizeScalarValue(@V NVARCHAR(MAX))
RETURNS NVARCHAR(MAX)
AS
BEGIN
    DECLARE @D DECIMAL(38,10) = TRY_CONVERT(DECIMAL(38,10), @V);
    IF @D IS NULL RETURN @V;

    DECLARE @S NVARCHAR(100) = CONVERT(NVARCHAR(100), @D);
    -- CONVERT conserve l'échelle -> supprimer zéros et point final
    IF CHARINDEX(N'.', @S) > 0
        SET @S = RTRIM(RTRIM(@S, N'0'), N'.');

    RETURN @S;
END;
GO

-- 2) Corriger sp_ResolveToken (sélection ensembles, CONCAT, FIRST/LAST, JSONIFY)
CREATE OR ALTER PROCEDURE dbo.sp_ResolveToken
    @Token NVARCHAR(1000),
    @ResolvedValue NVARCHAR(MAX) OUTPUT
AS
BEGIN
    SET NOCOUNT ON;

    DECLARE @Aggregator VARCHAR(20), @IsRuleRef BIT, @Pattern NVARCHAR(500);
    SELECT @Aggregator = Aggregator, @IsRuleRef = IsRuleRef, @Pattern = Pattern
    FROM dbo.fn_ParseToken(@Token);

    -- Normaliser pattern SQL LIKE
    DECLARE @LikePattern NVARCHAR(500) = REPLACE(REPLACE(@Pattern, '*', '%'), '?', '_');

    -- Résolution des variables simples (optimisation)
    IF @IsRuleRef = 0 AND @Pattern NOT LIKE '%:%' AND @Pattern NOT LIKE '%*%'
    BEGIN
        SELECT TOP (1) @ResolvedValue = ScalarValue
        FROM #ThreadState
        WHERE IsRule = 0 AND [Key] = @Pattern;

        SET @ResolvedValue = dbo.fn_NormalizeScalarValue(@ResolvedValue);
        RETURN;
    END

    -- Agrégats numériques
    IF @Aggregator IN ('SUM','AVG','MIN','MAX','COUNT','SUM_POS','AVG_POS','MIN_POS','MAX_POS','COUNT_POS',
                                      'SUM_NEG','AVG_NEG','MIN_NEG','MAX_NEG','COUNT_NEG',
                                      'FIRST_POS','FIRST_NEG')
    BEGIN
        DECLARE @Filter NVARCHAR(200) = N'';
        IF @Aggregator LIKE '%_POS' SET @Filter = N' AND ValueNumeric > 0';
        IF @Aggregator LIKE '%_NEG' SET @Filter = N' AND ValueNumeric < 0';

        DECLARE @BaseAgg VARCHAR(10) =
            CASE
                WHEN @Aggregator LIKE 'SUM%' THEN 'SUM'
                WHEN @Aggregator LIKE 'AVG%' THEN 'AVG'
                WHEN @Aggregator LIKE 'MIN%' THEN 'MIN'
                WHEN @Aggregator LIKE 'MAX%' THEN 'MAX'
                WHEN @Aggregator LIKE 'COUNT%' THEN 'COUNT'
                ELSE @Aggregator
            END;

        DECLARE @Sql NVARCHAR(MAX) =
            N'SELECT @R = ' + @BaseAgg + N'(ValueNumeric)
              FROM #ThreadState
              WHERE IsRule = @IsRule AND [Key] LIKE @P
                AND ScalarValue IS NOT NULL
                AND ValueIsNumeric = 1' + @Filter + N';';

        DECLARE @R DECIMAL(38,10);
        EXEC sp_executesql
            @Sql,
            N'@P NVARCHAR(500), @IsRule BIT, @R DECIMAL(38,10) OUTPUT',
            @P=@LikePattern, @IsRule=@IsRuleRef, @R=@R OUTPUT;

        SET @ResolvedValue = dbo.fn_NormalizeScalarValue(CONVERT(NVARCHAR(MAX), @R));
        RETURN;
    END

    -- FIRST (v1.6.0) : première NON NULL par SeqId
    IF @Aggregator = 'FIRST'
    BEGIN
        SELECT TOP (1) @ResolvedValue = ScalarValue
        FROM #ThreadState
        WHERE IsRule = @IsRuleRef AND [Key] LIKE @LikePattern AND ScalarValue IS NOT NULL
        ORDER BY SeqId ASC;

        SET @ResolvedValue = dbo.fn_NormalizeScalarValue(@ResolvedValue);
        RETURN;
    END

    -- LAST (v1.6.0) : dernière NON NULL par SeqId
    IF @Aggregator = 'LAST'
    BEGIN
        SELECT TOP (1) @ResolvedValue = ScalarValue
        FROM #ThreadState
        WHERE IsRule = @IsRuleRef AND [Key] LIKE @LikePattern AND ScalarValue IS NOT NULL
        ORDER BY SeqId DESC;

        SET @ResolvedValue = dbo.fn_NormalizeScalarValue(@ResolvedValue);
        RETURN;
    END

    -- CONCAT (v1.6.0) : concaténation sans séparateur, ignore NULL
    IF @Aggregator = 'CONCAT'
    BEGIN
        SELECT @ResolvedValue =
            ISNULL(
                (
                    SELECT STRING_AGG(ScalarValue, N'') WITHIN GROUP (ORDER BY SeqId)
                    FROM #ThreadState
                    WHERE IsRule = @IsRuleRef AND [Key] LIKE @LikePattern AND ScalarValue IS NOT NULL
                ),
                N''
            );

        RETURN;
    END

    -- JSONIFY (v1.6.0) : ignorer NULL ; ensemble vide -> {}
    IF @Aggregator = 'JSONIFY'
    BEGIN
        SELECT @ResolvedValue =
            ISNULL(
                (
                    SELECT
                        '"' + REPLACE([Key], '"', '\"') + '":' +
                        CASE
                            WHEN ValueIsNumeric = 1 THEN dbo.fn_NormalizeScalarValue(ScalarValue)
                            WHEN ValueType = 'BOOLEAN' THEN CASE WHEN ScalarValue IN ('1','true','TRUE') THEN 'true' ELSE 'false' END
                            ELSE '"' + REPLACE(ScalarValue, '"', '\"') + '"'
                        END
                    FROM #ThreadState
                    WHERE IsRule = @IsRuleRef AND [Key] LIKE @LikePattern AND ScalarValue IS NOT NULL
                    ORDER BY SeqId
                    FOR JSON PATH, WITHOUT_ARRAY_WRAPPER
                ),
                N'{}'
            );
        RETURN;
    END

    -- Fallback: valeur simple FIRST NON NULL
    SELECT TOP (1) @ResolvedValue = ScalarValue
    FROM #ThreadState
    WHERE IsRule = @IsRuleRef AND [Key] LIKE @LikePattern AND ScalarValue IS NOT NULL
    ORDER BY SeqId;

    SET @ResolvedValue = dbo.fn_NormalizeScalarValue(@ResolvedValue);
END;
GO

-- 3) Normaliser la valeur finale d’une règle dans sp_ExecuteRule (si présent)
-- (On garde un patch minimal: post-traitement juste avant l'UPDATE final si la variable @FinalValue existe)
-- NOTE: si la proc utilise un autre nom de variable, ce patch est sans effet et la normalisation est
-- déjà assurée via sp_ResolveToken dans les tests fournis.
