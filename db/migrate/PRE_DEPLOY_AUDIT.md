# Pre-Deploy Audit — Smart Links V1

Run these queries on the production database **before** deploying migrations
20260604000005, 20260604000006, and 20260604000007.

All queries must return zero rows. If any returns rows, fix the data first —
the migrations will abort with a clear error message if problems remain.

---

## 1. Organizations with blank or nil name

```sql
SELECT id, name
FROM organizations
WHERE name IS NULL OR TRIM(name) = '';
```

**Expected result:** 0 rows.

**If rows appear:** Update the organization name to a valid non-empty string.
The slug is generated from the name via `parameterize`; a blank name produces
a blank slug, which is invalid.

---

## 2. SmartLinks whose owner has no organization membership

```sql
SELECT sl.id, sl.user_id, sl.name
FROM smart_links sl
LEFT JOIN memberships m ON m.user_id = sl.user_id
WHERE m.id IS NULL;
```

**Expected result:** 0 rows.

**If rows appear:** Add the affected user to an organization
(`INSERT INTO memberships ...`) before deploying. The migration will assign
the smart_link to the user's first organization.

---

## 3. GeoProjects with no user

```sql
SELECT id, title
FROM geo_projects
WHERE user_id IS NULL;
```

**Expected result:** 0 rows.

**If rows appear:** Assign a `user_id` to each project, or directly set
`organization_id` via a manual SQL UPDATE before running the migration.

---

## 4. GeoProjects from users with no organization membership

```sql
SELECT gp.id, gp.title, gp.user_id
FROM geo_projects gp
LEFT JOIN memberships m ON m.user_id = gp.user_id
WHERE gp.user_id IS NOT NULL AND m.id IS NULL;
```

**Expected result:** 0 rows.

**If rows appear:** Add the affected user to an organization before deploying.

---

## 5. Summary count (run all checks at once)

```sql
SELECT
  (SELECT COUNT(*)
   FROM organizations
   WHERE name IS NULL OR TRIM(name) = '') AS orgs_blank_name,

  (SELECT COUNT(*)
   FROM smart_links sl
   LEFT JOIN memberships m ON m.user_id = sl.user_id
   WHERE m.id IS NULL) AS orphan_smart_links,

  (SELECT COUNT(*)
   FROM geo_projects
   WHERE user_id IS NULL) AS projects_no_user,

  (SELECT COUNT(*)
   FROM geo_projects gp
   LEFT JOIN memberships m ON m.user_id = gp.user_id
   WHERE gp.user_id IS NOT NULL AND m.id IS NULL) AS projects_no_org;
```

**Expected result:**

```
 orgs_blank_name | orphan_smart_links | projects_no_user | projects_no_org
-----------------+--------------------+------------------+-----------------
               0 |                  0 |                0 |               0
```

If every column is 0, the three migrations are safe to run.

---

## What happens if the deploy is blocked

Each migration raises an exception with:
- The count of affected records.
- The exact SQL to investigate them.
- Instructions on what to fix.

No data is deleted. The migration leaves the database in its original state
and exits with a non-zero code, which stops the deploy pipeline.

---

## Confirmation: no migration deletes data

| Migration | Destructive operation | Status |
|---|---|---|
| 20260604000005 add_slug_to_organizations | None | Safe |
| 20260604000006 update_smart_links_to_organization | None — aborts instead | Safe |
| 20260604000007 add_organization_to_geo_projects | None — aborts instead | Safe |
