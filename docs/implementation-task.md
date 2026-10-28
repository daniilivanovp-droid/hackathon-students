# Marketplace analytics implementation task

Implement a reproducible typed model for the Capibara marketplace on top of
the existing `raw` schema. The model must be rebuildable from scratch on a
clean PostgreSQL database and must answer the five reports in `docs/tasks.md`.

## Required deliverables

- Normalize every shell script to LF and add `.gitattributes` with
  `*.sh text eol=lf`.
- Make `scripts/setup.sh` work from Git Bash on Windows, including Python's
  `py -3` launcher, and provide actionable Docker daemon diagnostics.
- Add `model/01_build_core.sql` with typed core tables for customers, sellers,
  categories, products, orders, order items, payments, and reviews, plus the
  `mart` views `order_financials`, `monthly_sales`, `seller_sales`,
  `customer_orders`, and `category_sales`.
- Add `model/02_answers.sql` for the five required reports.
- Add `model/03_quality_checks.sql` with hard failures for the 24-month
  report, total revenue `13221498.11`, duplicate/orphan controls, and source
  row counts.
- Add `model/run.sh` to build, validate, and print the reports.
- Document model execution and revenue semantics in `README.md`.

## Acceptance criteria

1. A clean database can run the setup script, model build, quality checks, and
   answers without manual SQL edits.
2. The monthly report has exactly 24 rows for September 2016 through August
   2018 and delivered product-price revenue totals `13221498.11`.
3. Revenue reports use product price only. Average order value includes
   freight and is calculated at order grain.
4. Customer repeat analysis uses `customer_unique_id`.
5. Portuguese category names and untranslated/missing categories remain
   distinguishable rather than being silently dropped or merged.
6. Duplicate keys, orphan relationships, and unexpected source row counts
   fail loudly.
7. Shell scripts have LF line endings and the README gives Windows and Docker
   troubleshooting guidance.
