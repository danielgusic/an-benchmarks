-- Secondary "realistic usage" workload for the AN-encoding SQLite benchmark.
-- Runs against the real MySQL `employees` sample db (see setup_employees.sh),
-- a narrow OLTP HR schema. Point-lookup + join heavy, NOT bulk-aggregate
-- heavy -- the opposite shape from workload_i32/i64.sql. This is a sanity
-- check that AN-encoding holds up under realistic usage, not the primary
-- overhead measurement (see README).

PRAGMA journal_mode = DELETE;
PRAGMA synchronous  = NORMAL;

-- ---- READS ------------------------------------------------------------

-- R1: point lookup by primary key
SELECT 'R1', emp_no, first_name, last_name, gender, hire_date
FROM employees WHERE emp_no = 10001;

-- R2: current department for an employee (point lookup + 2-way join)
SELECT 'R2', e.emp_no, d.dept_name
FROM employees e
JOIN dept_emp de ON de.emp_no = e.emp_no AND de.to_date = '9999-01-01'
JOIN departments d ON d.dept_no = de.dept_no
WHERE e.emp_no = 10001;

-- R3: current salary for an employee (point lookup, most-recent row by from_date)
SELECT 'R3', emp_no, salary, from_date
FROM salaries
WHERE emp_no = 10001
ORDER BY from_date DESC LIMIT 1;

-- R4: avg current salary per department (aggregate across 3 joined tables)
SELECT 'R4', d.dept_name, count(*) cnt, avg(s.salary) avg_sal
FROM dept_emp de
JOIN departments d ON d.dept_no = de.dept_no
JOIN salaries s ON s.emp_no = de.emp_no AND s.to_date = '9999-01-01'
WHERE de.to_date = '9999-01-01'
GROUP BY d.dept_name ORDER BY avg_sal DESC;

-- R5: top earners by current salary (full sort, no index on salary)
SELECT 'R5', emp_no, salary FROM salaries
WHERE to_date = '9999-01-01'
ORDER BY salary DESC LIMIT 10;

-- R6: employee count per current title (group-by)
SELECT 'R6', title, count(*) cnt
FROM titles WHERE to_date = '9999-01-01'
GROUP BY title ORDER BY cnt DESC;

-- R7: employees hired in a date range (range filter, no index on hire_date)
SELECT 'R7', count(*) FROM employees
WHERE hire_date BETWEEN '1990-01-01' AND '1990-12-31';

-- ---- WRITES -------------------------------------------------------------

-- W1: onboard 5 new employees with department, title and starting salary
-- (deterministic values, outside the real emp_no range, so AN-off and
-- AN-on insert identical rows and the correctness diff stays meaningful).
BEGIN;
INSERT INTO employees(emp_no, birth_date, first_name, last_name, gender, hire_date) VALUES
  (600001,'1990-01-01','New1','Hire1','M','2026-01-05'),
  (600002,'1990-02-02','New2','Hire2','F','2026-01-05'),
  (600003,'1990-03-03','New3','Hire3','M','2026-01-05'),
  (600004,'1990-04-04','New4','Hire4','F','2026-01-05'),
  (600005,'1990-05-05','New5','Hire5','M','2026-01-05');
INSERT INTO dept_emp(emp_no, dept_no, from_date, to_date) VALUES
  (600001,'d005','2026-01-05','9999-01-01'),
  (600002,'d005','2026-01-05','9999-01-01'),
  (600003,'d006','2026-01-05','9999-01-01'),
  (600004,'d006','2026-01-05','9999-01-01'),
  (600005,'d007','2026-01-05','9999-01-01');
INSERT INTO titles(emp_no, title, from_date, to_date) VALUES
  (600001,'Engineer','2026-01-05','9999-01-01'),
  (600002,'Engineer','2026-01-05','9999-01-01'),
  (600003,'Engineer','2026-01-05','9999-01-01'),
  (600004,'Engineer','2026-01-05','9999-01-01'),
  (600005,'Engineer','2026-01-05','9999-01-01');
INSERT INTO salaries(emp_no, salary, from_date, to_date) VALUES
  (600001,55000,'2026-01-05','9999-01-01'),
  (600002,55000,'2026-01-05','9999-01-01'),
  (600003,55000,'2026-01-05','9999-01-01'),
  (600004,55000,'2026-01-05','9999-01-01'),
  (600005,55000,'2026-01-05','9999-01-01');
COMMIT;
SELECT 'W1_onboarded', changes();

-- W2: across-the-board raise for one department (full-scan-by-join UPDATE,
-- pure integer arithmetic -- no float multiply).
UPDATE salaries SET salary = salary + 1000
WHERE to_date = '9999-01-01'
  AND emp_no IN (SELECT emp_no FROM dept_emp WHERE dept_no = 'd005' AND to_date = '9999-01-01');
SELECT 'W2_raised', changes();

-- W3: promote a deterministic employee (close current title, open new one)
UPDATE titles SET to_date = '2026-01-05'
WHERE emp_no = 10001 AND to_date = '9999-01-01';
INSERT INTO titles(emp_no, title, from_date, to_date)
VALUES (10001, 'Senior Staff', '2026-01-05', '9999-01-01');
SELECT 'W3_promoted', changes();

-- W4: terminate the 5 new hires from W1 (DELETE across 4 tables, FK-style cascade by hand)
DELETE FROM salaries  WHERE emp_no BETWEEN 600001 AND 600005;
DELETE FROM titles    WHERE emp_no BETWEEN 600001 AND 600005;
DELETE FROM dept_emp  WHERE emp_no BETWEEN 600001 AND 600005;
DELETE FROM employees WHERE emp_no BETWEEN 600001 AND 600005;
SELECT 'W4_terminated', changes();

-- W5: create an index that isn't implied by a PRIMARY KEY (write-heavy: sorts + b-tree build)
CREATE INDEX idx_employees_hire_date ON employees(hire_date);
SELECT 'W5_indexed_rows', count(*) FROM employees;

-- W6: indexed range read after the index exists
SELECT 'W6', count(*) FROM employees
WHERE hire_date BETWEEN '1990-01-01' AND '1990-12-31';

-- W7: reclaim space / rewrite the whole file
VACUUM;
SELECT 'W7_vacuum_done', count(*) FROM employees;
