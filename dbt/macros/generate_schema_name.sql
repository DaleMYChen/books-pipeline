-- Without this macro, dbt generates schema names like "STAGING_STAGING" or "PUBLIC_MARTS".
-- This override makes +schema: STAGING resolve to exactly BOOKS_WAREHOUSE.STAGING.
{% macro generate_schema_name(custom_schema_name, node) -%}
    {%- if custom_schema_name is none -%}
        {{ target.schema }}
    {%- else -%}
        {{ custom_schema_name | trim }}
    {%- endif -%}
{%- endmacro %}