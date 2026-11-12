-- =====================================================================
--  INTEGRATE.SQL - PIPELINE TÍCH HỢP OULAD
--  Project: ADY201m - Group 6 - Early at-risk student prediction
-- ---------------------------------------------------------------------
--  MỤC TIÊU:
--    Tích hợp 7 bảng OULAD gốc thành 1 bảng phân tích `df_raw` (dạng
--    long: 1 dòng = 1 SV × 1 lớp học phần tại MỐC CẢNH BÁO SỚM).
--
--  NGUYÊN TẮC "KHÔNG NHÌN TƯƠNG LAI":
--    Mọi aggregation chỉ nhìn dữ liệu TRƯỚC ngày `cutoff_day` của module
--    - là ngày đã tích luỹ >= 40% trọng số điểm thành phần.
--    Lý do: mô phỏng đúng tình huống production - tại mốc dự đoán nhà
--    trường chỉ có dữ liệu đến thời điểm đó, không thể "nhìn" điểm cuối kỳ.
--
--  CHẠY:
--    - SQL IntelliView: Mở G6/oulad.db  →  Run entire file
--    - Hoặc notebook tự chạy qua sqlite3.executescript(open(...).read())
--
--  OUTPUT:
--    View `df_raw_v`  →  notebook export sang Intergrated_data.csv
-- =====================================================================


-- ---------------------------------------------------------------------
-- CTE 1: module_cutoff
--   Ngày cutoff cho từng (code_module, code_presentation).
--   LOGIC: Sắp các assessment theo ngày đến hạn (`date`), tính cumulative
--   weight. cutoff_day = ngày của assessment đầu tiên làm cumulative >= 40.
--   LÝ DO động theo module: mỗi module có lịch TMA/CMA khác nhau, cutoff
--   cố định (vd ngày 35) sẽ bất công giữa module có bài sớm vs bài muộn.
-- ---------------------------------------------------------------------
DROP VIEW IF EXISTS df_raw_v;
DROP TABLE IF EXISTS module_cutoff;
DROP TABLE IF EXISTS vle_agg;
DROP TABLE IF EXISTS assess_agg;
DROP TABLE IF EXISTS due_agg;

CREATE TABLE module_cutoff AS
WITH ranked AS (
    -- Chỉ lấy assessment có ngày đến hạn CÓ GIÁ TRỊ SỐ (loại empty string, loại NULL,
    -- loại Exam cuối kỳ với date NULL) và weight > 0 (không tính bài weight 0).
    -- Note: cột date/weight trong SQLite là TEXT (vì CSV header có quote) - phải lọc
    -- bằng typeof() + length() trước khi CAST để không bị CAST("") = 0.
    SELECT
        code_module,
        code_presentation,
        CAST("date"   AS INTEGER) AS due_date,
        CAST(weight   AS REAL)    AS w,
        -- Cumulative weight theo thứ tự ngày đến hạn
        SUM(CAST(weight AS REAL)) OVER (
            PARTITION BY code_module, code_presentation
            ORDER BY CAST("date" AS INTEGER)
            ROWS UNBOUNDED PRECEDING
        ) AS cum_weight
    FROM assessments
    WHERE "date" IS NOT NULL
      AND TRIM("date")   != ''
      AND TRIM(weight)   != ''
      AND CAST(weight AS REAL) > 0
)
SELECT
    code_module,
    code_presentation,
    MIN(due_date) AS cutoff_day        -- Ngày sớm nhất mà cum_weight >= 40
FROM ranked
WHERE cum_weight >= 40
GROUP BY code_module, code_presentation;


-- ---------------------------------------------------------------------
-- CTE 2: vle_agg
--   Tổng hợp hành vi VLE của mỗi SV TRƯỚC cutoff_day.
--   Biến tạo: total_clicks, active_days, n_resources, clicks_before_start
--   LÝ DO LEFT JOIN cutoff: giữ nguyên hành vi cho tới mốc 40% weight
--   - không dùng toàn bộ chuỗi click vì sẽ leak dữ liệu tương lai.
-- ---------------------------------------------------------------------
CREATE TABLE vle_agg AS
SELECT
    sv.code_module,
    sv.code_presentation,
    sv.id_student,
    SUM(sv.sum_click)                                     AS total_clicks,
    COUNT(DISTINCT sv.date)                               AS active_days,
    COUNT(DISTINCT sv.id_site)                            AS n_resources,
    -- Click trước ngày khai giảng (date < 0) = SV chuẩn bị sớm, tín hiệu tích cực
    SUM(CASE WHEN sv.date < 0 THEN sv.sum_click ELSE 0 END) AS clicks_before_start
FROM studentVle sv
JOIN module_cutoff mc
  ON mc.code_module       = sv.code_module
 AND mc.code_presentation = sv.code_presentation
WHERE sv.date < mc.cutoff_day                              -- CHỈ click trước cutoff
GROUP BY sv.code_module, sv.code_presentation, sv.id_student;


-- ---------------------------------------------------------------------
-- CTE 3: due_agg
--   Số assessment đến hạn TRƯỚC cutoff của mỗi lớp (không phụ thuộc SV).
--   LÝ DO: cần biết "lớp này đã có bao nhiêu bài phải nộp tại mốc cảnh báo"
--   để tính submission_rate = n_submitted / n_assess_due cho mỗi SV.
-- ---------------------------------------------------------------------
CREATE TABLE due_agg AS
SELECT
    a.code_module,
    a.code_presentation,
    COUNT(*) AS n_assess_due
FROM assessments a
JOIN module_cutoff mc
  ON mc.code_module       = a.code_module
 AND mc.code_presentation = a.code_presentation
WHERE a."date" IS NOT NULL
  AND TRIM(a."date") != ''
  AND TRIM(a.weight) != ''
  AND CAST(a."date" AS INTEGER) < mc.cutoff_day
  AND CAST(a.weight AS REAL) > 0
GROUP BY a.code_module, a.code_presentation;


-- ---------------------------------------------------------------------
-- CTE 4: assess_agg
--   Hành vi nộp bài của SV TRƯỚC cutoff.
--   Biến tạo: n_submitted, avg_score, n_late
--   LƯU Ý: score có thể NULL (SV đã nộp nhưng GV chưa chấm - 173 ca
--   trong studentAssessment). AVG tự bỏ qua NULL nên avg_score phản ánh
--   điểm trung bình của các bài ĐÃ được chấm.
-- ---------------------------------------------------------------------
CREATE TABLE assess_agg AS
SELECT
    a.code_module,
    a.code_presentation,
    sa.id_student,
    COUNT(*)                                                   AS n_submitted,
    AVG(sa.score)                                              AS avg_score,
    SUM(CASE WHEN sa.date_submitted > CAST(a."date" AS INTEGER)
             THEN 1 ELSE 0 END)                                AS n_late
FROM studentAssessment sa
JOIN assessments a
  ON a.id_assessment = sa.id_assessment
JOIN module_cutoff mc
  ON mc.code_module       = a.code_module
 AND mc.code_presentation = a.code_presentation
WHERE a."date" IS NOT NULL
  AND TRIM(a."date") != ''
  AND TRIM(a.weight) != ''
  AND CAST(a."date" AS INTEGER) < mc.cutoff_day                -- Bài đến hạn trước cutoff
  AND sa.date_submitted     < mc.cutoff_day                    -- Nộp trước cutoff
  AND CAST(a.weight AS REAL) > 0
GROUP BY a.code_module, a.code_presentation, sa.id_student;


-- ---------------------------------------------------------------------
-- VIEW CHÍNH: df_raw_v
--   Tích hợp cuối cùng: 1 dòng = 1 SV × 1 lớp tại mốc cảnh báo sớm.
--   CHỈ LẤY cột không nhạy cảm + không leak:
--     - BỎ demographic (gender, age_band, region, imd_band,
--       highest_education, disability) - fairness + feedback thầy §6.
--     - BỎ date_unregistration - là biến tương lai (SV rút học sau mốc 40%).
--   LEFT JOIN để GIỮ mọi SV trong studentInfo, kể cả SV không có hành vi
--   VLE / không nộp bài nào trước cutoff - đây chính là NHÓM NGUY CƠ CAO
--   nhất, INNER JOIN sẽ xoá họ khỏi mẫu.
-- ---------------------------------------------------------------------
-- Scope filter (nằm ngay trong view để lý do rõ):
--   1. Loại SV có `date_unregistration <= cutoff_day` - họ đã rút TRƯỚC mốc cảnh báo,
--      không còn đối tượng để can thiệp. Nếu giữ, model học pattern "đã rút = at_risk" là tautology.
--   2. Loại SV có `date_registration > cutoff_day` - họ chưa vào lớp tại mốc cảnh báo,
--      không có dữ liệu hành vi để dự đoán.
CREATE VIEW df_raw_v AS
SELECT
    si.code_module,
    si.code_presentation,
    si.id_student,
    si.num_of_prev_attempts,
    si.studied_credits,
    sr.date_registration,
    mc.cutoff_day,

    -- Hành vi VLE (NULL = SV không click gì trước cutoff → sẽ fillna(0) ở Python)
    COALESCE(v.total_clicks,        0) AS total_clicks,
    COALESCE(v.active_days,         0) AS active_days,
    COALESCE(v.n_resources,         0) AS n_resources,
    COALESCE(v.clicks_before_start, 0) AS clicks_before_start,

    -- Số bài đến hạn của lớp (cùng lớp thì giống nhau)
    COALESCE(d.n_assess_due, 0) AS n_assess_due,

    -- Hành vi nộp bài của SV
    COALESCE(aa.n_submitted, 0) AS n_submitted,
    aa.avg_score,                               -- GIỮ NULL để Python xử lý 3 nhánh
    COALESCE(aa.n_late,      0) AS n_late,

    -- Target
    si.final_result,
    CASE WHEN si.final_result IN ('Fail','Withdrawn') THEN 1 ELSE 0 END AS at_risk
FROM studentInfo si
JOIN studentRegistration sr
  ON sr.code_module       = si.code_module
 AND sr.code_presentation = si.code_presentation
 AND sr.id_student        = si.id_student
LEFT JOIN module_cutoff mc
  ON mc.code_module       = si.code_module
 AND mc.code_presentation = si.code_presentation
LEFT JOIN vle_agg v
  ON v.code_module       = si.code_module
 AND v.code_presentation = si.code_presentation
 AND v.id_student        = si.id_student
LEFT JOIN due_agg d
  ON d.code_module       = si.code_module
 AND d.code_presentation = si.code_presentation
LEFT JOIN assess_agg aa
  ON aa.code_module       = si.code_module
 AND aa.code_presentation = si.code_presentation
 AND aa.id_student        = si.id_student
WHERE mc.cutoff_day IS NOT NULL
  -- Loại SV rút trước cutoff: date_unregistration <= cutoff_day → rút rồi, không can thiệp được
  AND (sr.date_unregistration IS NULL
       OR sr.date_unregistration > mc.cutoff_day)
  -- Loại SV đăng ký sau cutoff: chưa vào lớp tại mốc cảnh báo
  AND (sr.date_registration IS NULL
       OR sr.date_registration <= mc.cutoff_day);

-- Kết quả kỳ vọng: ~27.000-28.000 dòng × 17 cột (sau scope filter).
-- Tiếp theo (trong Python): làm sạch + chuẩn hoá (Part 3 của notebook).
