-- =============================================================================
-- BOOKS PIPELINE — SNOWFLAKE SETUP SCRIPT
-- Run these blocks in order in a Snowflake worksheet as ACCOUNTADMIN.
-- This script is idempotent: safe to re-run if setup needs to be repeated.
-- =============================================================================


-- -----------------------------------------------------------------------------
-- BLOCK 1: Database and schemas
-- -----------------------------------------------------------------------------
CREATE DATABASE IF NOT EXISTS BOOKS_WAREHOUSE;
CREATE SCHEMA IF NOT EXISTS BOOKS_WAREHOUSE.RAW;       -- Airflow COPY INTO target
CREATE SCHEMA IF NOT EXISTS BOOKS_WAREHOUSE.STAGING;   -- dbt views
CREATE SCHEMA IF NOT EXISTS BOOKS_WAREHOUSE.MARTS;     -- dbt tables


-- -----------------------------------------------------------------------------
-- BLOCK 2: Service user
-- A dedicated non-interactive user for Airflow and dbt.
-- Never use ACCOUNTADMIN credentials in application config.
-- -----------------------------------------------------------------------------
CREATE USER IF NOT EXISTS BOOKS_PIPELINE_USER
    PASSWORD = 'ReplaceWithStrongPassword!'
    DEFAULT_ROLE = SYSADMIN
    DEFAULT_WAREHOUSE = COMPUTE_WH
    DEFAULT_NAMESPACE = BOOKS_WAREHOUSE.RAW
    MUST_CHANGE_PASSWORD = FALSE;

GRANT ROLE SYSADMIN TO USER BOOKS_PIPELINE_USER;
GRANT USAGE ON WAREHOUSE COMPUTE_WH TO ROLE SYSADMIN;


-- -----------------------------------------------------------------------------
-- BLOCK 3: Schema permissions for SYSADMIN
-- Schema-level GRANT ALL does not automatically cascade to stages in Snowflake,
-- so object-type grants are required explicitly.
-- -----------------------------------------------------------------------------
GRANT ALL ON DATABASE BOOKS_WAREHOUSE TO ROLE SYSADMIN;
GRANT ALL ON SCHEMA BOOKS_WAREHOUSE.RAW      TO ROLE SYSADMIN;
GRANT ALL ON SCHEMA BOOKS_WAREHOUSE.STAGING  TO ROLE SYSADMIN;
GRANT ALL ON SCHEMA BOOKS_WAREHOUSE.MARTS    TO ROLE SYSADMIN;

-- Stage-specific grants (required separately from schema-level grants)
GRANT ALL PRIVILEGES ON ALL STAGES IN SCHEMA BOOKS_WAREHOUSE.RAW TO ROLE SYSADMIN;


-- -----------------------------------------------------------------------------
-- BLOCK 4: MFA exemption for the service account
-- Snowflake trial accounts enforce MFA by default for all users.
-- Programmatic/service users must be exempted — they authenticate via password
-- from inside a Docker container with no browser or phone available.
-- NOTE: In production, replace password auth with key-pair authentication.
-- -----------------------------------------------------------------------------
USE DATABASE BOOKS_WAREHOUSE;

CREATE OR REPLACE AUTHENTICATION POLICY service_account_no_mfa
    MFA_ENROLLMENT = 'OPTIONAL';

ALTER USER BOOKS_PIPELINE_USER
    SET AUTHENTICATION POLICY service_account_no_mfa;


-- -----------------------------------------------------------------------------
-- BLOCK 5: S3 stage
-- Named pointer to the S3 bucket. FILE_FORMAT is inherited by all COPY INTO
-- commands that reference this stage — defines the parsing contract for CSVs.
-- Replace the URL and credentials with your real values before running.
-- -----------------------------------------------------------------------------
CREATE OR REPLACE STAGE BOOKS_WAREHOUSE.RAW.BOOKS_S3_STAGE
    URL = 's3://books-pipeline-data/raw/'
    CREDENTIALS = (
        AWS_KEY_ID     = 'YOUR_AWS_ACCESS_KEY_ID'
        AWS_SECRET_KEY = 'YOUR_AWS_SECRET_ACCESS_KEY'
    )
    FILE_FORMAT = (
        TYPE                      = CSV
        FIELD_OPTIONALLY_ENCLOSED_BY = '"'
        SKIP_HEADER               = 1
        NULL_IF                   = ('NULL', 'null', '')
        EMPTY_FIELD_AS_NULL       = TRUE
    );

-- Grant stage access to SYSADMIN (covers this stage and future stages in RAW)
GRANT ALL PRIVILEGES ON STAGE BOOKS_WAREHOUSE.RAW.BOOKS_S3_STAGE TO ROLE SYSADMIN;

-- Verify: should return zero rows on a fresh setup (no files in S3 yet)
LIST @BOOKS_WAREHOUSE.RAW.BOOKS_S3_STAGE;