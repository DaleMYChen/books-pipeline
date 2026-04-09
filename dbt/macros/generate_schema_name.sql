-- Without this macro, dbt generates schema names like "STAGING_STAGING" or "PUBLIC_MARTS".
-- This override makes +schema: STAGING resolve to exactly BOOKS_WAREHOUSE.STAGING.
{% macro generate_schema_name(custom_schema_name, node) -%}
    {%- if custom_schema_name is none -%}
        {{ target.schema }}
    {%- else -%}
        {%- if target.name == 'ci' -%}
            {{ custom_schema_name | trim }}_CI
        {%- else -%}
            {{ custom_schema_name | trim }}
        {%- endif -%}
    {%- endif -%}
{%- endmacro %}
{#
  Schema routing by target:
    dev  → STAGING,    MARTS       (local development via Docker Airflow)
    ci   → STAGING_CI, MARTS_CI   (GitHub Actions PR validation, isolated)
    prod → STAGING,    MARTS       (GitHub Actions CD on merge to main)
#}