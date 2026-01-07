# Rules Engine T-SQL

**Moteur de règles déclaratif pour SQL Server**

Version actuelle : **V6.9** (Conforme Spécification v1.7.1)  
Date : 2026-01-07

---

## 📖 À Propos

Le Rules Engine T-SQL est un moteur de règles métier déclaratif permettant d'évaluer des expressions SQL de manière dynamique et performante.

### Principe Cardinal

> **« Le moteur orchestre ; SQL Server calcule. »**

Le moteur délègue 100% des calculs à SQL Server, garantissant :
- ✅ Performance maximale (exécution native SQL)
- ✅ Déterminisme complet (comportement SQL Server)
- ✅ Puissance totale (accès à toutes les fonctionnalités SQL)

### Fonctionnalités Clés

- **Évaluation paresseuse** : Les règles ne sont évaluées que si nécessaire
- **Gestion de dépendances** : Résolution automatique de l'ordre d'évaluation
- **Agrégateurs riches** : SUM, AVG, MIN, MAX, COUNT, FIRST, LAST, CONCAT, JSONIFY
- **Gestion d'erreurs robuste** : Les erreurs n'interrompent jamais l'exécution
- **Mode DEBUG** : Visibilité complète pour diagnostic
- **API JSON** : Interface simple et standard

---

## 🗂️ Structure du Projet

```
rules-engine-tsql/
│
├── README.md                    # Ce fichier
├── CHANGELOG.md                 # Historique des versions
│
├── src/
│   └── MOTEUR_REGLES.sql        # Moteur V6.9 (version actuelle)
│
├── tests/
│   ├── TESTS_NORMATIFS.sql      # Tests normatifs
│   ├── TESTS_CONFORMITE.sql     # Tests de conformité v1.6.0
│   ├── BENCHMARK.sql            # Benchmarks de performance
│   └── JEU_ESSAI.sql            # Jeu d'essai complet
│
├── docs/
│   ├── SPECIFICATION.md         # Spécification canonique v1.7.1
│   ├── REFERENCE.md             # Référence consolidée
│   ├── GUIDE_MIGRATION.md       # Guide de migration v6.4 → v6.5
│   └── adr/                     # Architecture Decision Records
│       ├── README.md            # Index des ADR
│       ├── 0001-principe-delegation-sql-server.md
│       ├── 0002-semantique-null-unifiee.md
│       ├── 0003-modele-donnees-atomique.md
│       ├── 0004-grammaire-tokens.md
│       └── 0005-gestion-erreurs-non-bloquante.md
│
├── migrations/                  # Scripts de migration entre versions
│
└── archive/                     # Versions historiques (référence uniquement)
    ├── README.md                # Explication du dossier archive
    └── ...                      # Anciennes versions du moteur et docs
```

---

## 🚀 Démarrage Rapide

### Installation (5 minutes)

```sql
-- 1. Backup de votre base de données (IMPORTANT)
BACKUP DATABASE [VotreBase] TO DISK = 'C:\Backup\Pre_RulesEngine.bak'

-- 2. Installer le moteur
:r src/MOTEUR_REGLES.sql

-- 3. Vérifier l'installation
SELECT 
    name, type_desc, modify_date 
FROM sys.objects 
WHERE name LIKE '%Rule%' 
  AND modify_date > DATEADD(MINUTE, -5, GETDATE())
```

### Premier Test

```sql
-- Test simple
DECLARE @Out NVARCHAR(MAX)
EXEC dbo.sp_RunRulesEngine N'{
    "variables": [
        {"key": "price", "value": "100"},
        {"key": "quantity", "value": "5"}
    ],
    "rules": [
        {"key": "total", "expression": "{price} * {quantity}"}
    ]
}', @Out OUTPUT

SELECT @Out
-- Résultat : {"status":"SUCCESS","total":"500",...}
```

### Exécuter les Tests

```sql
-- Tests normatifs
:r tests/TESTS_NORMATIFS.sql

-- Tests de conformité
:r tests/TESTS_CONFORMITE.sql

-- Tous les tests doivent passer (PASS)
```

---

## 📚 Documentation

### Documentation Essentielle

| Document | Description |
|----------|-------------|
| [SPECIFICATION.md](docs/SPECIFICATION.md) | Spécification canonique v1.7.1 (référence normative) |
| [REFERENCE.md](docs/REFERENCE.md) | Référence consolidée des fonctionnalités |
| [CHANGELOG.md](CHANGELOG.md) | Historique complet des versions |
| [ADR Index](docs/adr/README.md) | Architecture Decision Records |

### ADR (Architecture Decision Records)

Les décisions architecturales majeures sont documentées dans `docs/adr/` :

1. [ADR-0001](docs/adr/0001-principe-delegation-sql-server.md) - **Principe de délégation SQL Server** (fondamental)
2. [ADR-0002](docs/adr/0002-semantique-null-unifiee.md) - Sémantique NULL unifiée (v1.6.0)
3. [ADR-0003](docs/adr/0003-modele-donnees-atomique.md) - Modèle de données atomique
4. [ADR-0004](docs/adr/0004-grammaire-tokens.md) - Grammaire des tokens
5. [ADR-0005](docs/adr/0005-gestion-erreurs-non-bloquante.md) - Gestion des erreurs non-bloquante

---

## 🔄 Migration

### Depuis Version Antérieure

Consultez le [CHANGELOG.md](CHANGELOG.md) pour identifier votre version actuelle et les changements.

**Migration v6.4 → v6.5+ (Breaking Changes)** :
- Lire [docs/GUIDE_MIGRATION.md](docs/GUIDE_MIGRATION.md)
- Exécuter [tests/TESTS_CONFORMITE.sql](tests/TESTS_CONFORMITE.sql)
- ⚠️ Attention : Changements cassants sur FIRST, CONCAT, JSONIFY

---

## 🎯 Exemples d'Utilisation

### Exemple 1 : Calcul Simple

```sql
DECLARE @Out NVARCHAR(MAX)
EXEC dbo.sp_RunRulesEngine N'{
    "variables": [
        {"key": "prix_ht", "value": "100"},
        {"key": "tva", "value": "0.20"}
    ],
    "rules": [
        {"key": "prix_ttc", "expression": "{prix_ht} * (1 + {tva})"}
    ]
}', @Out OUTPUT

SELECT JSON_VALUE(@Out, '$.prix_ttc')  -- "120"
```

### Exemple 2 : Agrégation

```sql
DECLARE @Out NVARCHAR(MAX)
EXEC dbo.sp_RunRulesEngine N'{
    "variables": [
        {"key": "item_1", "value": "10"},
        {"key": "item_2", "value": "20"},
        {"key": "item_3", "value": "30"}
    ],
    "rules": [
        {"key": "total", "expression": "{SUM(item_*)}"},
        {"key": "moyenne", "expression": "{AVG(item_*)}"},
        {"key": "count", "expression": "{COUNT(item_*)}"}
    ]
}', @Out OUTPUT

SELECT 
    JSON_VALUE(@Out, '$.total'),     -- "60"
    JSON_VALUE(@Out, '$.moyenne'),   -- "20"
    JSON_VALUE(@Out, '$.count')      -- "3"
```

### Exemple 3 : Logique Métier Complexe

```sql
DECLARE @Out NVARCHAR(MAX)
EXEC dbo.sp_RunRulesEngine N'{
    "variables": [
        {"key": "age", "value": "25"},
        {"key": "salaire", "value": "50000"}
    ],
    "rules": [
        {
            "key": "eligible_pret",
            "expression": "CASE WHEN {age} >= 18 AND {salaire} >= 30000 THEN ''OUI'' ELSE ''NON'' END"
        },
        {
            "key": "montant_max",
            "expression": "CASE WHEN {eligible_pret} = ''OUI'' THEN {salaire} * 3 ELSE 0 END"
        }
    ]
}', @Out OUTPUT

SELECT 
    JSON_VALUE(@Out, '$.eligible_pret'),  -- "OUI"
    JSON_VALUE(@Out, '$.montant_max')     -- "150000"
```

---

## 📊 Performance

### Benchmarks

Version actuelle (V6.9) par rapport à V6.4 :

| Cas d'Usage | Amélioration |
|-------------|--------------|
| Règles simples (sans tokens) | +10-20% |
| Règles avec NULL | +30-50% |
| Règles avec erreurs | +30-50% |
| Agrégations complexes | +5-15% |

Voir [tests/BENCHMARK.sql](tests/BENCHMARK.sql) pour détails.

---

## 🛠️ Configuration Requise

- **SQL Server** : ≥ 2017 (Compatibility Level ≥ 140)
- **Permissions** : CREATE PROCEDURE, CREATE FUNCTION, ALTER TABLE
- **Collation** : SQL_Latin1_General_CP1_CI_AS (Case-Insensitive)

---

## 🤝 Contribution

Les contributions sont les bienvenues ! Pour contribuer :

1. Consulter [docs/SPECIFICATION.md](docs/SPECIFICATION.md) pour les invariants
2. Consulter [docs/adr/](docs/adr/) pour les décisions architecturales
3. Ajouter des tests dans [tests/](tests/)
4. Mettre à jour [CHANGELOG.md](CHANGELOG.md)

---

## 📜 Licence

Ce projet est sous licence [indiquer la licence].

---

## 📞 Support

- **Documentation** : Consulter [docs/](docs/)
- **ADR** : Consulter [docs/adr/](docs/adr/) pour décisions architecturales
- **Versions Archivées** : Consulter [archive/](archive/) (référence uniquement)

---

**Version actuelle : V6.9 (Spécification v1.7.1)**  
**Dernière mise à jour : 2026-01-07**
