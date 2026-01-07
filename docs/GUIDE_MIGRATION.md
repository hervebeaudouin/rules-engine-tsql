# GUIDE DE MIGRATION v6.4 → v6.5
## Moteur de Règles - Conformité Spécification v1.6.0

Date: 2025-12-23  
Auteur: Équipe Moteur de Règles  
Version Cible: 6.5 (Spec v1.6.0)

---

## 1. RÉSUMÉ EXÉCUTIF

### Objectif
Migrer le moteur de règles de la version 6.4 (conforme v1.5.5) vers la version 6.5 (conforme v1.6.0) pour bénéficier d'une sémantique simplifiée et d'optimisations de performance.

### Changement Principal
```
AVANT: Gestion différenciée des NULL selon l'agrégat (complexe)
APRÈS: Tous les agrégats ignorent NULL (simple, unifié)
```

### Impact
- **Rétro-compatibilité:** ⚠️ Partielle (voir section 3)
- **Performance:** ✅ +10-50% selon cas d'usage
- **Maintenance:** ✅ Code plus simple et robuste
- **Évolutivité:** ✅ Base solide pour futures fonctionnalités

---

## 2. PRÉ-REQUIS

### 2.1 Environnement

✓ **SQL Server:** ≥ 2017 (Compatibility Level ≥ 140)  
✓ **Permissions:** CREATE PROCEDURE, CREATE FUNCTION, ALTER TABLE  
✓ **Espace disque:** Minimal (~50 KB pour scripts)  
✓ **Temps d'arrêt:** ~2-5 minutes pour déploiement  

### 2.2 Sauvegardes

**CRITIQUE:** Effectuer les sauvegardes suivantes AVANT migration:

```sql
-- 1. Backup base complète
BACKUP DATABASE [VotreBase] TO DISK = 'C:\Backup\Pre_Migration_V6_5.bak'

-- 2. Export règles existantes
SELECT * INTO RuleDefinitions_Backup_20251223
FROM dbo.RuleDefinitions

-- 3. Export résultats test baseline (si applicable)
-- Exécuter vos tests actuels et sauvegarder les résultats
```

### 2.3 Validation Actuelle

Avant migration, valider que v6.4 fonctionne correctement:

```sql
-- Test simple
DECLARE @Out NVARCHAR(MAX)
EXEC dbo.sp_RunRulesEngine N'{
    "variables": [{"key": "x", "value": "10"}],
    "rules": []
}', @Out OUTPUT
SELECT @Out
-- Doit retourner: {"status":"SUCCESS",...}
```

---

## 3. ANALYSE D'IMPACT

### 3.1 Changements Cassants (Breaking Changes)

#### 3.1.1 FIRST avec NULL

**Avant v6.4:**
```sql
-- Variables: v1=NULL, v2=10, v3=20
-- Règle: {FIRST(v*)}
-- Résultat: NULL (première valeur, même NULL)
```

**Après v6.5:**
```sql
-- Variables: v1=NULL, v2=10, v3=20
-- Règle: {FIRST(v*)}
-- Résultat: "10" (première valeur NON NULL)
```

**Impact:**
- Règles utilisant FIRST pour détecter absence de valeur changeront de comportement
- Vérifier toutes les règles avec pattern `{FIRST(*)}` ou `{FIRST_*(*)}`

#### 3.1.2 JSONIFY avec Erreurs

**Avant v6.4:**
```sql
-- Règles: R1=10, R2=erreur (NULL), R3=30
-- Agrégat: {JSONIFY(Rule:R*)}
-- Résultat: {"R1":10,"R2":null,"R3":30}
```

**Après v6.5:**
```sql
-- Règles: R1=10, R2=erreur (NULL), R3=30
-- Agrégat: {JSONIFY(Rule:R*)}
-- Résultat: {"R1":10,"R3":30}  -- R2 omis
```

**Impact:**
- Code consommateur attendant clés NULL dans JSON devra être adapté
- Vérifier parsing JSON côté application

### 3.2 Changements Non-Cassants

#### 3.2.1 Normalisation Décimaux

**Bénéfice automatique:**
```sql
-- Avant v6.4: "2,5 + 3,5" → ERREUR (si contexte US)
-- Après v6.5: "2,5 + 3,5" → "6" (normalisation automatique)
```

**Impact:** Positif, plus de flexibilité

#### 3.2.2 Agrégat LAST

**Nouvelle fonctionnalité:**
```sql
-- Variables: v1=5, v2=10, v3=20
-- Nouvelle règle possible: {LAST(v*)} → "20"
```

**Impact:** Aucun sur code existant, nouvelle capacité disponible

---

## 4. PROCÉDURE DE MIGRATION

### 4.1 Phase 1: Préparation (Jour J-7)

#### Étape 1.1: Inventaire des Règles

```sql
-- Identifier règles utilisant FIRST
SELECT RuleCode, Expression
FROM dbo.RuleDefinitions
WHERE Expression LIKE '%{FIRST%'
  AND IsActive = 1
ORDER BY RuleCode

-- Identifier règles utilisant JSONIFY
SELECT RuleCode, Expression
FROM dbo.RuleDefinitions
WHERE Expression LIKE '%{JSONIFY%'
  AND IsActive = 1
ORDER BY RuleCode
```

**Actions:**
- Documenter les ~10-20 règles identifiées
- Analyser leur usage métier
- Prévoir tests de validation

#### Étape 1.2: Tests Baseline

```sql
-- Créer snapshot des résultats actuels
CREATE TABLE Test_Results_Baseline (
    TestId INT IDENTITY(1,1),
    TestName NVARCHAR(200),
    InputJson NVARCHAR(MAX),
    OutputJson NVARCHAR(MAX),
    ExecutedAt DATETIME2 DEFAULT SYSDATETIME()
)

-- Exécuter suite de tests actuelle
-- Sauvegarder tous les résultats
```

#### Étape 1.3: Environnement de Test

```sql
-- Cloner base vers environnement test
RESTORE DATABASE [VotreBase_Test] 
FROM DISK = 'C:\Backup\Production_Current.bak'
WITH MOVE 'Data' TO 'C:\Data\Test_Data.mdf',
     MOVE 'Log' TO 'C:\Data\Test_Log.ldf'
```

### 4.2 Phase 2: Déploiement Test (Jour J-3)

#### Étape 2.1: Installation v6.5

Sur l'environnement de test:

```sql
-- 1. Vérifier version actuelle
SELECT OBJECT_DEFINITION(OBJECT_ID('dbo.sp_RunRulesEngine'))
-- Chercher "VERSION 6.4"

-- 2. Exécuter script migration
-- Fichier: MOTEUR_REGLES_V6_5_CONFORME_1_6_0.sql
-- Durée: ~30 secondes
:r C:\Scripts\MOTEUR_REGLES_V6_5_CONFORME_1_6_0.sql

-- 3. Vérifier installation
SELECT OBJECT_DEFINITION(OBJECT_ID('dbo.sp_RunRulesEngine'))
-- Chercher "VERSION 6.5"

-- 4. Vérifier nouvelle fonction
SELECT OBJECT_DEFINITION(OBJECT_ID('dbo.fn_NormalizeLiteral'))
-- Doit retourner définition
```

#### Étape 2.2: Tests de Conformité

```sql
-- Exécuter suite de tests v1.6.0
-- Fichier: TESTS_CONFORMITE_V1_6_0.sql
:r C:\Scripts\TESTS_CONFORMITE_V1_6_0.sql

-- TOUS les tests doivent passer (PASS)
-- Si des tests échouent, investiguer avant de continuer
```

#### Étape 2.3: Tests de Régression

```sql
-- Re-exécuter tests baseline avec v6.5
-- Comparer résultats

-- Requête de comparaison
SELECT 
    b.TestName,
    b.OutputJson AS Baseline_V64,
    n.OutputJson AS New_V65,
    CASE 
        WHEN b.OutputJson = n.OutputJson THEN 'IDENTICAL'
        ELSE 'DIFFERENT'
    END AS Comparison
FROM Test_Results_Baseline b
LEFT JOIN Test_Results_New n ON n.TestName = b.TestName
WHERE b.OutputJson <> n.OutputJson
```

**Analyse des différences:**
- Différences attendues: FIRST avec NULL, JSONIFY avec erreurs
- Différences inattendues: investiguer et résoudre

### 4.3 Phase 3: Validation Métier (Jour J-1)

#### Étape 3.1: Tests Fonctionnels

Avec équipe métier, valider:

✓ Cas d'usage critiques (top 10 règles)  
✓ Scénarios de bout-en-bout  
✓ Gestion d'erreurs  
✓ Performance acceptable  

#### Étape 3.2: Documentation

Mettre à jour:
- Documentation utilisateur (comportement FIRST/JSONIFY)
- Documentation technique (agrégat LAST disponible)
- Procédures de rollback

### 4.4 Phase 4: Déploiement Production (Jour J)

#### Étape 4.1: Fenêtre de Maintenance

**Planning type (2h fenêtre):**

```
T-00:00  Début maintenance
T+00:05  Backup complet base
T+00:10  Stop services applicatifs
T+00:15  Vérification intégrité
T+00:20  Exécution script v6.5
T+00:25  Tests fumée (smoke tests)
T+00:35  Restart services applicatifs
T+00:40  Tests de validation
T+00:50  Monitoring initial
T+01:00  Fin maintenance nominale
T+01:00  Monitoring continu (1h)
```

#### Étape 4.2: Script de Déploiement

```sql
-- === DEPLOIEMENT PRODUCTION V6.5 ===
-- Date: [DATE]
-- Responsable: [NOM]

-- 1. BACKUP
BACKUP DATABASE [VotreBase] 
TO DISK = 'C:\Backup\Pre_V6_5_[TIMESTAMP].bak'
WITH COMPRESSION, CHECKSUM

-- 2. VERIFICATION BACKUP
RESTORE VERIFYONLY 
FROM DISK = 'C:\Backup\Pre_V6_5_[TIMESTAMP].bak'

-- 3. INSTALLATION V6.5
:r C:\Scripts\MOTEUR_REGLES_V6_5_CONFORME_1_6_0.sql

-- 4. VERIFICATION
SELECT 
    OBJECT_NAME(object_id) AS ObjectName,
    type_desc AS ObjectType,
    modify_date AS LastModified
FROM sys.objects
WHERE name LIKE '%Rule%'
  AND modify_date > DATEADD(MINUTE, -5, GETDATE())
ORDER BY modify_date DESC

-- 5. TESTS FUMEE
DECLARE @Out NVARCHAR(MAX)
EXEC dbo.sp_RunRulesEngine N'{
    "variables": [{"key": "test", "value": "OK"}],
    "rules": []
}', @Out OUTPUT
SELECT @Out  -- Doit retourner SUCCESS

-- 6. TEST NORMALISATION
DELETE FROM dbo.RuleDefinitions WHERE RuleCode = 'TEST_MIGRATION'
INSERT INTO dbo.RuleDefinitions (RuleCode, Expression) 
VALUES ('TEST_MIGRATION', '2,5 + 3,5')

EXEC dbo.sp_RunRulesEngine N'{
    "variables": [],
    "rules": ["TEST_MIGRATION"]
}', @Out OUTPUT
SELECT @Out  -- Doit retourner value: "6"

DELETE FROM dbo.RuleDefinitions WHERE RuleCode = 'TEST_MIGRATION'
```

#### Étape 4.3: Monitoring Post-Déploiement

```sql
-- Requête de monitoring (exécuter toutes les 5 min pendant 1h)
SELECT 
    DATEPART(HOUR, GETDATE()) AS Heure,
    DATEPART(MINUTE, GETDATE()) AS Minute,
    COUNT(*) AS NombreExecutions,
    AVG(CAST(JSON_VALUE(Output, '$.durationMs') AS INT)) AS DureeMoyenneMs,
    SUM(CASE WHEN JSON_VALUE(Output, '$.status') = 'ERROR' THEN 1 ELSE 0 END) AS NombreErreurs
FROM VotreTableLog  -- Adapter selon votre système
WHERE ExecutionTime > DATEADD(HOUR, -1, GETDATE())
GROUP BY DATEPART(HOUR, GETDATE()), DATEPART(MINUTE, GETDATE())
ORDER BY Heure DESC, Minute DESC
```

**Seuils d'alerte:**
- Durée moyenne > 2x baseline → Investiguer performance
- Nombre erreurs > 5% → Investiguer logs
- 0 exécutions pendant 10 min → Vérifier services

---

## 5. PLAN DE ROLLBACK

### 5.1 Critères de Rollback

Déclencher rollback si:
- ❌ Erreur critique bloquante
- ❌ Performance dégradée >50%
- ❌ Taux d'erreur >10%
- ❌ Données corrompues détectées

### 5.2 Procédure de Rollback

**Durée estimée: 10 minutes**

```sql
-- === ROLLBACK VERS V6.4 ===
-- ATTENTION: Exécuter uniquement en cas d'échec critique

-- 1. RESTORE BACKUP
RESTORE DATABASE [VotreBase]
FROM DISK = 'C:\Backup\Pre_V6_5_[TIMESTAMP].bak'
WITH REPLACE, RECOVERY

-- 2. VERIFICATION
SELECT @@VERSION
SELECT DB_NAME()

-- 3. TEST FONCTIONNEL
DECLARE @Out NVARCHAR(MAX)
EXEC dbo.sp_RunRulesEngine N'{
    "variables": [{"key": "test", "value": "OK"}],
    "rules": []
}', @Out OUTPUT
SELECT @Out

-- 4. NOTIFICATION
-- Informer équipes du rollback
-- Documenter incident
```

### 5.3 Post-Rollback

- Analyser logs d'erreur
- Identifier cause racine
- Corriger dans environnement test
- Re-planifier migration

---

## 6. ADAPTATION DES RÈGLES MÉTIER

### 6.1 Pattern FIRST avec NULL

**Scénario:** Règle utilise FIRST pour détecter absence

**Avant v6.4:**
```sql
-- Règle: validation_check = {FIRST(validation:*)}
-- Si aucune validation: NULL
-- Logique: IF validation_check IS NULL THEN 'PAS_VALIDE'
```

**Après v6.5:**
```sql
-- Règle: validation_check = {FIRST(validation:*)}
-- Si aucune validation: NULL (comportement identique)
-- Si validations avec NULL: ignore NULL, retourne première NON NULL
-- Logique métier: à valider cas par cas
```

**Actions:**
1. Identifier règles pattern `{FIRST(*)}` détectant NULL
2. Tester comportement avec NULL intercalés
3. Si besoin, utiliser `{COUNT(*)}` pour détecter absence

### 6.2 Pattern JSONIFY avec Erreurs

**Scénario:** Application parse JSON et attend clés NULL

**Avant v6.4:**
```javascript
// Côté application
const data = JSON.parse(result)
if (data.rule_error === null) {
    // Traiter erreur
}
```

**Après v6.5:**
```javascript
// Adapter code application
const data = JSON.parse(result)
if (!data.hasOwnProperty('rule_error')) {  // Clé absente au lieu de null
    // Traiter erreur
}
```

**Actions:**
1. Auditer code consommateur JSON
2. Adapter logique clés manquantes vs null
3. Tester tous les chemins d'erreur

---

## 7. OPTIMISATIONS DISPONIBLES

### 7.1 Nouvelle Fonctionnalité LAST

**Cas d'usage:**
```sql
-- Récupérer dernière valeur d'une série temporelle
-- Avant v6.4: impossible directement
-- Après v6.5:
INSERT INTO dbo.RuleDefinitions (RuleCode, Expression)
VALUES ('derniere_mesure', '{LAST(mesure:*)}')
```

### 7.2 Décimaux Français

**Avantage:**
```sql
-- Avant v6.4: devait écrire
'CAST(REPLACE(''2,5'', '','', ''.'') AS NUMERIC)'

-- Après v6.5: simplement
'2,5'
```

### 7.3 Performance

**Benchmarks attendus:**

| Scénario | v6.4 | v6.5 | Amélioration |
|----------|------|------|--------------|
| Règles simples (10) | 50ms | 40ms | +20% |
| Règles avec NULL (20) | 120ms | 80ms | +33% |
| Agrégats complexes (50) | 300ms | 250ms | +17% |
| Erreurs multiples (10) | 200ms | 130ms | +35% |

---

## 8. CHECKLIST FINALE

### Avant Migration

- [ ] Backup complet effectué et vérifié
- [ ] Environnement test configuré
- [ ] Tests conformité v1.6.0 passent tous
- [ ] Tests régression analysés
- [ ] Validation métier obtenue
- [ ] Plan rollback documenté
- [ ] Fenêtre maintenance planifiée
- [ ] Équipes notifiées

### Pendant Migration

- [ ] Services applicatifs arrêtés
- [ ] Script v6.5 exécuté sans erreur
- [ ] Tests fumée passent
- [ ] Vérification objets créés
- [ ] Services redémarrés
- [ ] Tests validation passent

### Après Migration

- [ ] Monitoring actif (1h minimum)
- [ ] Performance nominale
- [ ] Taux erreur <1%
- [ ] Documentation mise à jour
- [ ] Formation équipes si nécessaire
- [ ] Backup post-migration effectué

---

## 9. SUPPORT ET ESCALADE

### Contacts

**Équipe Technique:**
- Support L1: [email]
- Support L2: [email]
- Architecture: [email]

**Équipe Métier:**
- Product Owner: [email]
- Key Users: [liste]

### Logs et Diagnostic

```sql
-- Activer mode DEBUG pour investigation
DECLARE @Out NVARCHAR(MAX)
EXEC dbo.sp_RunRulesEngine N'{
    "mode": "DEBUG",
    "options": {
        "returnStateTable": true,
        "returnDebug": true
    },
    "variables": [...],
    "rules": [...]
}', @Out OUTPUT

SELECT 
    JSON_VALUE(@Out, '$.status') AS Status,
    JSON_QUERY(@Out, '$.debugLog') AS DebugLog

-- Analyser chaque étape d'évaluation
```

---

## 10. CONCLUSION

La migration vers v6.5 apporte:
✅ **Simplicité** sémantique unifiée  
✅ **Robustesse** gestion NULL cohérente  
✅ **Performance** optimisations compilation  
✅ **Évolutivité** base solide futures fonctionnalités  

**Effort estimé:**
- Préparation: 1-2 jours
- Tests: 2-3 jours  
- Déploiement: 2h fenêtre
- Total: ~1 semaine projet

**Risque:** 🟡 Modéré (changements cassants limités et identifiés)

**Recommandation:** Procéder à la migration en suivant ce guide étape par étape.
