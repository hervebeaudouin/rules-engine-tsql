# SYNTHÈSE DES MODIFICATIONS V1.6.0
## Moteur de Règles - Migration de v6.4 vers v6.5

Date: 2025-12-23  
Conformité: Spécification REFERENCE v1.6.0 (Normative)

---

## 1. PRINCIPE FONDAMENTAL (CHANGEMENT MAJEUR)

### Avant (v1.5.5 / v6.4)
- Gestion différenciée des NULL selon l'agrégat
- Comportements spécifiques par agrégat (exceptions)
- Complexité sémantique élevée

### Après (v1.6.0 / v6.5)
```
RÈGLE GLOBALE: Tous les agrégats opèrent EXCLUSIVEMENT sur les valeurs NON NULL
```

**Impact:**
- Les valeurs NULL (y compris issues d'erreurs) sont conservées dans ThreadState
- Elles n'influencent JAMAIS les agrégats
- Simplifie considérablement la logique moteur
- Améliore la prévisibilité et la robustesse

---

## 2. MODIFICATIONS PAR AGRÉGAT

### 2.1 FIRST (MODIFIÉ)

**Avant:**
```sql
-- Pouvait potentiellement retourner NULL si c'était la première valeur
SELECT TOP 1 ScalarValue FROM @FilteredSet ORDER BY SeqId ASC
```

**Après:**
```sql
-- Retourne la première valeur NON NULL
SELECT TOP 1 ScalarValue 
FROM @FilteredSet 
WHERE ScalarValue IS NOT NULL  -- Filtrage explicite
ORDER BY SeqId ASC
```

**Comportement:**
- Ignore toutes les valeurs NULL
- Retourne la première valeur NON NULL selon SeqId croissant
- Si aucune valeur NON NULL: retourne NULL

### 2.2 LAST (NOUVEAU)

**Implémentation:**
```sql
SELECT TOP 1 ScalarValue 
FROM @FilteredSet 
WHERE ScalarValue IS NOT NULL
ORDER BY SeqId DESC
```

**Comportement:**
- Retourne la dernière valeur NON NULL selon SeqId décroissant
- Symétrique à FIRST
- Si aucune valeur NON NULL: retourne NULL

### 2.3 CONCAT (MODIFIÉ)

**Avant:**
```sql
-- Comportement non formalisé pour NULL
STRING_AGG(ScalarValue, '') WITHIN GROUP (ORDER BY SeqId)
```

**Après:**
```sql
-- Filtre explicite des NULL
SELECT @ResolvedValue = STRING_AGG(ScalarValue, '') WITHIN GROUP (ORDER BY SeqId)
FROM @FilteredSet
WHERE ScalarValue IS NOT NULL;
SET @ResolvedValue = ISNULL(@ResolvedValue, '');  -- Ensemble vide → ""
```

**Comportement:**
- Concatène uniquement valeurs NON NULL
- Ensemble vide → chaîne vide `""`
- Ordre préservé par SeqId

### 2.4 JSONIFY (MODIFIÉ)

**Avant:**
```sql
-- Pouvait inclure des clés avec valeur NULL
-- Comportement erreur non formalisé
```

**Après:**
```sql
-- Filtre explicite: uniquement clés avec valeurs NON NULL
SELECT @JsonPairs = @JsonPairs + 
    CASE WHEN LEN(@JsonPairs) > 0 THEN ',' ELSE '' END +
    '"' + REPLACE([Key], '"', '\"') + '":' + [value formatting]
FROM @FilteredSet
WHERE ScalarValue IS NOT NULL  -- Exclusion stricte
ORDER BY SeqId;

SET @ResolvedValue = '{' + ISNULL(@JsonPairs, '') + '}';  -- Ensemble vide → "{}"
```

**Comportement:**
- Agrège uniquement clés ayant valeur NON NULL
- Clés en erreur (NULL) sont ignorées
- Ensemble vide → objet JSON vide `{}`

### 2.5 Agrégats Mathématiques (INCHANGÉS mais formalisés)

**SUM, AVG, MIN, MAX, COUNT:**
- Comportement déjà conforme en v6.4
- Formalisation explicite du filtrage NULL
- Aucun changement de code nécessaire

---

## 3. NORMALISATION DES LITTÉRAUX (NOUVEAU)

### 3.1 Fonction de Normalisation

**Ajout:**
```sql
CREATE FUNCTION dbo.fn_NormalizeLiteral(@Literal NVARCHAR(MAX))
RETURNS NVARCHAR(MAX)
```

**Transformations:**

1. **Décimaux français:**
   ```
   2,5      →  2.5
   10,75    →  10.75
   0,001    →  0.001
   ```

2. **Quotes:**
   ```
   "texte"  →  'texte'
   ```

### 3.2 Points d'Application

La normalisation est appliquée dans:

1. **sp_ExecuteRule:** Avant résolution des tokens
2. **sp_EvaluateSimpleRules:** Avant évaluation SQL
3. **Systématique:** Pour toutes les expressions avant compilation

---

## 4. OPTIMISATIONS DE COMPILATION

### 4.1 Filtrage Systématique

**Avant:**
```sql
SELECT SeqId, [Key], ScalarValue
FROM #ThreadState
WHERE [Key] LIKE @LikePattern AND State = 2
```

**Après:**
```sql
SELECT SeqId, [Key], ScalarValue
FROM #ThreadState
WHERE [Key] LIKE @LikePattern 
  AND State = 2              -- EVALUATED uniquement
  AND ScalarValue IS NOT NULL  -- V1.6.0: Exclusion stricte NULL
ORDER BY SeqId
```

### 4.2 Normalisation des Résultats Numériques

**Ajout:**
```sql
-- Suppression des zéros inutiles
IF TRY_CAST(@Result AS NUMERIC(38,10)) IS NOT NULL
    SET @Result = CAST(CAST(@Result AS NUMERIC(38,10)) AS NVARCHAR(MAX));
```

**Effet:**
```
100.00   →  100
50.50    →  50.5
0.10     →  0.1
```

### 4.3 Propagation NULL Optimisée

**Ajout:**
```sql
-- Si résolution token retourne NULL, propager immédiatement
IF @ResolvedValue IS NULL
BEGIN
    SET @CompiledSQL = 'SELECT NULL';
    BREAK;
END
```

**Effet:**
- Court-circuite l'évaluation si dépendance NULL
- Évite calculs inutiles
- Améliore performance sur erreurs

---

## 5. GESTION DES ERREURS (INCHANGÉ mais clarifié)

**Principe maintenu:**
```
Une règle en erreur:
- State = 3 (ERROR)
- ScalarValue = NULL
- N'interrompt jamais le thread
- N'empêche pas évaluation des autres règles
```

**Interaction avec agrégats v1.6.0:**
- Les règles en erreur produisent NULL
- Les agrégats ignorent ces NULL
- Comportement cohérent et prévisible

---

## 6. TESTS NORMATIFS

### 6.1 Tests Supprimés (Obsolètes)

```
X01_FirstNull      - FIRST acceptait NULL en v1.5.5
X02_JsonifyError   - JSONIFY incluait erreurs en v1.5.5
```

### 6.2 Tests Ajoutés (Nouveaux)

```
T_FIRST_IGNORE_NULL    - FIRST ignore valeurs NULL
T_LAST_IGNORE_NULL     - LAST retourne dernière NON NULL
T_LAST_BASIC           - LAST fonctionnement de base
T_CONCAT_IGNORE_NULL   - CONCAT ignore valeurs NULL
T_CONCAT_EMPTY_SET     - CONCAT ensemble vide → ""
T_JSONIFY_IGNORE_NULL  - JSONIFY ignore clés NULL
T_JSONIFY_EMPTY_SET    - JSONIFY ensemble vide → "{}"
T_NORMALIZE_DECIMAL_FR - Normalisation décimaux français
```

---

## 7. IMPACT PERFORMANCE

### Améliorations Attendues

1. **Filtrage Précoce:**
   - Exclusion NULL dès la sélection
   - Réduction ensembles de données
   - Moins d'opérations SQL

2. **Court-Circuit NULL:**
   - Arrêt immédiat si dépendance NULL
   - Économie cycles CPU

3. **Normalisation Unique:**
   - Normalisation littéraux avant évaluation
   - Évite re-normalisation multiple

4. **Cache Expression:**
   - Expressions normalisées réutilisables
   - Réduction parsing SQL

**Estimation:**
- Cas simples: +10-20% performance
- Cas avec erreurs: +30-50% performance
- Cas complexes: +5-15% performance

---

## 8. COMPATIBILITÉ

### Rétro-Compatibilité

**NON COMPATIBLE sur certains cas:**
- Tests X01_FirstNull et X02_JsonifyError échouent
- Comportement FIRST/JSONIFY changé volontairement

**COMPATIBLE sur:**
- Agrégats mathématiques (SUM, AVG, etc.)
- Structure ThreadState
- API JSON entrée/sortie
- Gestion erreurs globale

### Migration Requise

**Actions nécessaires:**
1. Mettre à jour tests normatifs
2. Vérifier règles utilisant FIRST avec NULL
3. Vérifier règles utilisant JSONIFY avec erreurs
4. Documenter changement comportement

---

## 9. STRUCTURE CODE

### Fichiers Modifiés

```
fn_NormalizeLiteral()     - NOUVEAU
fn_ParseToken()           - Ajout LAST
sp_ResolveToken()         - Filtrage NULL strict
sp_ExecuteRule()          - Normalisation + NULL propagation
sp_EvaluateSimpleRules()  - Normalisation + normalisation résultats
```

### Complexité

**Avant v6.4:**
- ~800 lignes
- Logique agrégat dispersée
- Gestion NULL implicite

**Après v6.5:**
- ~850 lignes (+6%)
- Logique agrégat centralisée
- Gestion NULL explicite
- +1 fonction (normalisation)
- Code plus maintenable

---

## 10. VALIDATION

### Checklist Conformité v1.6.0

- [x] Tous agrégats filtrent NULL explicitement
- [x] FIRST ignore NULL
- [x] LAST implémenté (ignore NULL)
- [x] CONCAT ignore NULL, vide → ""
- [x] JSONIFY ignore NULL, vide → "{}"
- [x] Normalisation décimaux français (,→.)
- [x] Normalisation quotes ("→')
- [x] Normalisation résultats numériques
- [x] Propagation NULL optimisée
- [x] Gestion erreurs inchangée
- [x] ThreadState structure inchangée
- [x] API JSON inchangée

### Tests Recommandés

```sql
-- Test 1: FIRST ignore NULL
Variables: v1=NULL, v2=NULL, v3=10
Rule: R1 = {FIRST(v*)}
Expected: R1 = "10"

-- Test 2: LAST fonctionnel
Variables: v1=5, v2=NULL, v3=20
Rule: R1 = {LAST(v*)}
Expected: R1 = "20"

-- Test 3: JSONIFY ignore NULL
Variables: k1=10, k2=NULL, k3=30
Rule: R1 = {JSONIFY(k*)}
Expected: R1 = '{"k1":10,"k3":30}'

-- Test 4: Décimaux français
Rule: R1 = 2,5 + 3,5
Expected: R1 = "6"

-- Test 5: Ensemble vide
Variables: (aucune commençant par 'x')
Rule: R1 = {CONCAT(x*)}
Expected: R1 = ""
```

---

## 11. CONCLUSION

### Bénéfices v1.6.0

✅ **Simplicité:** Une règle universelle pour tous agrégats  
✅ **Robustesse:** Comportement prévisible en cas d'erreur  
✅ **Performance:** Optimisations compilation et évaluation  
✅ **Maintenabilité:** Code plus clair et documenté  
✅ **Évolutivité:** Base solide pour futures évolutions  

### Points d'Attention

⚠️ **Migration:** Tests obsolètes à mettre à jour  
⚠️ **Documentation:** Comportement FIRST/JSONIFY changé  
⚠️ **Validation:** Tests complets requis post-migration  

### Recommandations

1. **Déployer en environnement test** avec suite complète
2. **Valider tous tests normatifs** v1.6.0
3. **Documenter changements** pour utilisateurs
4. **Monitorer performance** post-déploiement
5. **Créer plan rollback** si nécessaire

---

**Version Moteur:** 6.5  
**Conformité Spec:** v1.6.0 (Normative)  
**Statut:** Prêt pour déploiement test
