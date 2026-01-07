
# Rules Engine – Reference Specification
## Version 1.5.5

- Variables are atomic literals
- Model: (Key, ScalarValue NVARCHAR(MAX), ValueType)
- Key is unique (CI)
- Aggregation is performed via SQL LIKE on keys
- Preferred architecture: single Thread Root with #temp tables
