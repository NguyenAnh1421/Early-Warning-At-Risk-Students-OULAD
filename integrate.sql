-- Tích hợp dữ liệu OULAD (dùng 5 trong 7 bảng) thành bảng phân tích df_raw (DuckDB, đọc thẳng CSV).
-- 1 dòng = 1 sinh viên × 1 lớp học phần. Mọi đặc trưng chỉ dùng dữ liệu TRƯỚC cutoff_day.

-- 0. Đọc 5 bảng CSV cần dùng ('?' = NULL); courses và vle không cần cho bài toán
CREATE OR REPLACE VIEW assessments         AS SELECT * FROM read_csv('data/raw/assessments.csv',         nullstr = '?');
CREATE OR REPLACE VIEW studentInfo         AS SELECT * FROM read_csv('data/raw/studentInfo.csv',         nullstr = '?');
CREATE OR REPLACE VIEW studentRegistration AS SELECT * FROM read_csv('data/raw/studentRegistration.csv', nullstr = '?');
CREATE OR REPLACE VIEW studentAssessment   AS SELECT * FROM read_csv('data/raw/studentAssessment.csv',   nullstr = '?');
CREATE OR REPLACE VIEW studentVle          AS SELECT * FROM read_csv('data/raw/studentVle.csv',          nullstr = '?');

-- 1. cutoff_day: ngày đến hạn đầu tiên mà tổng trọng số tích luỹ >= 40%
CREATE OR REPLACE TABLE module_cutoff AS
SELECT code_module, code_presentation, MIN(date) AS cutoff_day
FROM (
    SELECT *, SUM(weight) OVER (PARTITION BY code_module, code_presentation
                                ORDER BY date ROWS UNBOUNDED PRECEDING) AS cum_weight
    FROM assessments
    WHERE date IS NOT NULL AND weight > 0
)
WHERE cum_weight >= 40
GROUP BY code_module, code_presentation;

-- 2. Các bài kiểm tra đến hạn trước cutoff
CREATE OR REPLACE TABLE assess_due AS
SELECT a.*
FROM assessments a
JOIN module_cutoff c USING (code_module, code_presentation)
WHERE a.date < c.cutoff_day AND a.weight > 0;

-- 3. Hành vi VLE trước cutoff
CREATE OR REPLACE TABLE vle_agg AS
SELECT v.code_module, v.code_presentation, v.id_student,
       SUM(v.sum_click)                                AS total_clicks,
       COUNT(DISTINCT v.date)                          AS active_days,
       COUNT(DISTINCT v.id_site)                       AS n_resources,
       SUM(CASE WHEN v.date < 0 THEN v.sum_click ELSE 0 END) AS clicks_before_start
FROM studentVle v
JOIN module_cutoff c USING (code_module, code_presentation)
WHERE v.date < c.cutoff_day
GROUP BY ALL;

-- 4. Nộp bài trước cutoff
CREATE OR REPLACE TABLE assess_agg AS
SELECT d.code_module, d.code_presentation, s.id_student,
       COUNT(*)                                  AS n_submitted,
       AVG(s.score)                              AS avg_score,
       SUM(CASE WHEN s.date_submitted > d.date THEN 1 ELSE 0 END) AS n_late
FROM studentAssessment s
JOIN assess_due d USING (id_assessment)
JOIN module_cutoff c USING (code_module, code_presentation)
WHERE s.date_submitted < c.cutoff_day
GROUP BY ALL;

-- 5. Bảng phân tích cuối: LEFT JOIN để giữ cả SV không hoạt động.
--    Bỏ biến nhân khẩu học (công bằng). Giữ date_unregistration và toàn bộ SV:
--    xử lý rò rỉ dữ liệu (bỏ date_unregistration, loại SV rút trước cutoff / đăng ký
--    sau cutoff) được làm ở bước làm sạch, phần 3.2 của notebook.
CREATE OR REPLACE TABLE df_raw AS
SELECT si.code_module, si.code_presentation, si.id_student,
       si.num_of_prev_attempts, si.studied_credits, sr.date_registration,
       sr.date_unregistration, c.cutoff_day,
       COALESCE(v.total_clicks, 0)        AS total_clicks,
       COALESCE(v.active_days, 0)         AS active_days,
       COALESCE(v.n_resources, 0)         AS n_resources,
       COALESCE(v.clicks_before_start, 0) AS clicks_before_start,
       (SELECT COUNT(*) FROM assess_due d
         WHERE d.code_module = si.code_module
           AND d.code_presentation = si.code_presentation) AS n_assess_due,
       COALESCE(a.n_submitted, 0)         AS n_submitted,
       a.avg_score,
       COALESCE(a.n_late, 0)              AS n_late,
       si.final_result,
       CASE WHEN si.final_result IN ('Fail', 'Withdrawn') THEN 1 ELSE 0 END AS at_risk
FROM studentInfo si
JOIN studentRegistration sr USING (code_module, code_presentation, id_student)
JOIN module_cutoff c        USING (code_module, code_presentation)
LEFT JOIN vle_agg v         USING (code_module, code_presentation, id_student)
LEFT JOIN assess_agg a      USING (code_module, code_presentation, id_student)
ORDER BY si.code_module, si.code_presentation, si.id_student;
