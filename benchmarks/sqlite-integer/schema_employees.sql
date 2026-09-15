-- SQLite-compatible schema for the real MySQL `employees` sample db
-- (https://github.com/datacharmer/test_db, pinned commit
-- e324b56193ca506ab7cc1ab143a9153d8c4535d7).
--
-- This is a 1:1 translation of the upstream employees.sql CREATE TABLE
-- statements: DATE -> TEXT (no DATE type in SQLite; values stay as
-- 'YYYY-MM-DD' strings, never touch REAL), VARCHAR/CHAR/ENUM -> TEXT,
-- INT -> INTEGER. No column types, constraints, or row data are altered.
-- The actual rows are loaded verbatim from upstream's load_*.dump files.

PRAGMA journal_mode = MEMORY;
PRAGMA synchronous  = OFF;

DROP TABLE IF EXISTS dept_emp;
DROP TABLE IF EXISTS dept_manager;
DROP TABLE IF EXISTS titles;
DROP TABLE IF EXISTS salaries;
DROP TABLE IF EXISTS employees;
DROP TABLE IF EXISTS departments;

CREATE TABLE employees (
    emp_no      INTEGER         NOT NULL,
    birth_date  TEXT            NOT NULL,
    first_name  TEXT            NOT NULL,
    last_name   TEXT            NOT NULL,
    gender      TEXT            NOT NULL,
    hire_date   TEXT            NOT NULL,
    PRIMARY KEY (emp_no)
);

CREATE TABLE departments (
    dept_no     TEXT            NOT NULL,
    dept_name   TEXT            NOT NULL,
    PRIMARY KEY (dept_no),
    UNIQUE (dept_name)
);

CREATE TABLE dept_manager (
   emp_no       INTEGER         NOT NULL,
   dept_no      TEXT            NOT NULL,
   from_date    TEXT            NOT NULL,
   to_date      TEXT            NOT NULL,
   FOREIGN KEY (emp_no)  REFERENCES employees (emp_no)    ON DELETE CASCADE,
   FOREIGN KEY (dept_no) REFERENCES departments (dept_no) ON DELETE CASCADE,
   PRIMARY KEY (emp_no, dept_no)
);

CREATE TABLE dept_emp (
    emp_no      INTEGER         NOT NULL,
    dept_no     TEXT            NOT NULL,
    from_date   TEXT            NOT NULL,
    to_date     TEXT            NOT NULL,
    FOREIGN KEY (emp_no)  REFERENCES employees   (emp_no)  ON DELETE CASCADE,
    FOREIGN KEY (dept_no) REFERENCES departments (dept_no) ON DELETE CASCADE,
    PRIMARY KEY (emp_no, dept_no)
);

CREATE TABLE titles (
    emp_no      INTEGER         NOT NULL,
    title       TEXT            NOT NULL,
    from_date   TEXT            NOT NULL,
    to_date     TEXT,
    FOREIGN KEY (emp_no) REFERENCES employees (emp_no) ON DELETE CASCADE,
    PRIMARY KEY (emp_no, title, from_date)
);

CREATE TABLE salaries (
    emp_no      INTEGER         NOT NULL,
    salary      INTEGER         NOT NULL,
    from_date   TEXT            NOT NULL,
    to_date     TEXT            NOT NULL,
    FOREIGN KEY (emp_no) REFERENCES employees (emp_no) ON DELETE CASCADE,
    PRIMARY KEY (emp_no, from_date)
);
