-- ------------------------------------------------------------------
-- Title: Extract height and weight for ICUSTAY_IDs
-- Description: This query gets the first, minimum, and maximum weight and height
--        for a single ICUSTAY_ID. It extracts data from the CHARTEVENTS table.
-- MIMIC version: MIMIC-III v1.2
-- Created by: Erin Hong, Alistair Johnson
-- ------------------------------------------------------------------

DROP MATERIALIZED VIEW IF EXISTS heightweight CASCADE;
CREATE MATERIALIZED VIEW heightweight
AS
WITH FirstVRawData AS
  (SELECT c.charttime,
    c.itemid,c.subject_id,c.icustay_id,c.hadm_id,
    CASE
      WHEN c.itemid IN (762, 763, 3723, 3580, 3581, 3582, 226512)
        THEN 'WEIGHT'
      WHEN c.itemid IN (920, 1394, 4187, 3486, 3485, 4188, 226707)
        THEN 'HEIGHT'
    END AS parameter,
    -- Ensure that all weights are in kg and heights are in centimeters
    CASE
      WHEN c.itemid   IN (3581, 226531)
        THEN c.valuenum * 0.45359237
      WHEN c.itemid   IN (3582)
        THEN c.valuenum * 0.0283495231
      WHEN c.itemid   IN (920, 1394, 4187, 3486, 226707)
        THEN c.valuenum * 2.54
      ELSE c.valuenum
    END AS valuenum
  FROM chartevents c
  WHERE c.valuenum   IS NOT NULL
  -- exclude rows marked as error
  AND c.error IS DISTINCT FROM 1
  AND ( ( c.itemid  IN (762, 763, 3723, 3580, -- Weight Kg
    3581,                                     -- Weight lb
    3582,                                     -- Weight oz
    920, 1394, 4187, 3486,                    -- Height inches
    3485, 4188                                -- Height cm
    -- Metavision
    , 226707 -- Height (measured in inches)
    , 226512 -- Admission Weight (Kg)

    -- note we intentionally ignore the below ITEMIDs in metavision
    -- these are duplicate data in a different unit
    -- , 226531 -- Admission Weight (lbs.)
    -- , 226730 -- Height (cm)
    )
  AND c.valuenum <> 0 )
    ) )
  --)

  --select * from FirstVRawData
  --note itemid 3581 & 3582 are complementary measurements (weight in lb and oz)
  --to get total patient weight need to add valuenums together
, CombinedLbOz AS (SELECT f.charttime, f.subject_id,f.icustay_id,f.hadm_id,
          -- no readily available itemid defined for this parameter so we use the concat of 3158 and 3152
				 	35813582 itemid, 'WEIGHT' parameter, SUM(f.valuenum) valuenum 
					FROM FirstVRawData f WHERE f.itemid IN (3581,3582)
					GROUP BY f.charttime, f.subject_id,f.icustay_id,f.hadm_id)
  -- select out erroneous weight based on itemids and union in the corrected weight
, SecondVRawData AS (
          SELECT f.charttime, f.itemid,f.subject_id,f.icustay_id,f.hadm_id,f.parameter,f.valuenum
          FROM FirstVRawData f 
          WHERE f.itemid NOT IN (3581,3582)
          UNION 
          SELECT c.charttime, c.itemid,c.subject_id,c.icustay_id,c.hadm_id,c.parameter,c.valuenum 
          FROM CombinedLbOz c
 )
  --select * from SecondVRawData
, SingleParameters AS (
  SELECT DISTINCT subject_id,
         icustay_id,
         hadm_id,
         parameter,
         first_value(valuenum) over
            (partition BY subject_id, icustay_id, hadm_id, parameter
             order by charttime ROWS BETWEEN UNBOUNDED PRECEDING AND UNBOUNDED FOLLOWING)
             AS first_valuenum,
         MIN(valuenum) over
            (partition BY subject_id, icustay_id, hadm_id, parameter
            order by charttime ROWS BETWEEN UNBOUNDED PRECEDING AND UNBOUNDED FOLLOWING)
            AS min_valuenum,
         MAX(valuenum) over
            (partition BY subject_id, icustay_id, hadm_id, parameter
            order by charttime ROWS BETWEEN UNBOUNDED PRECEDING AND UNBOUNDED FOLLOWING)
            AS max_valuenum
    FROM SecondVRawData

--   ORDER BY subject_id,
--            icustay_id,
--            parameter
  )
--select * from SingleParameters
, PivotParameters AS (SELECT subject_id, icustay_id, hadm_id,
    MAX(case when parameter = 'HEIGHT' then first_valuenum else NULL end) AS height_first,
    MAX(case when parameter = 'HEIGHT' then min_valuenum else NULL end)   AS height_min,
    MAX(case when parameter = 'HEIGHT' then max_valuenum else NULL end)   AS height_max,
    MAX(case when parameter = 'WEIGHT' then first_valuenum else NULL end) AS weight_first,
    MAX(case when parameter = 'WEIGHT' then min_valuenum else NULL end)   AS weight_min,
    MAX(case when parameter = 'WEIGHT' then max_valuenum else NULL end)   AS weight_max
  FROM SingleParameters
  GROUP BY subject_id,
    icustay_id,
    hadm_id
  )
--select * from PivotParameters
SELECT f.icustay_id,
  f.subject_id,
  f.hadm_id,
  ROUND( cast(f.height_first as numeric), 2) AS height_first,
  ROUND(cast(f.height_min as numeric),2) AS height_min,
  ROUND(cast(f.height_max as numeric),2) AS height_max,
  ROUND(cast(f.weight_first as numeric), 2) AS weight_first,
  ROUND(cast(f.weight_min as numeric), 2)   AS weight_min,
  ROUND(cast(f.weight_max as numeric), 2)   AS weight_max

FROM PivotParameters f
ORDER BY subject_id, icustay_id,hadm_id;

--COMMENT ON MATERIALIZED VIEW icustay_detail IS
-- '
--   Expands the table "ICUSTAYEVENTS" to show:
-- ​
--      +  Each ICU stay is order by the column HOSPITAL_ICUSTAY_SEQ per
--         hospitalization
--      +  Each ICU stay is order by the column ICUSTAY_SEQ
--      +  The first and last ICU stays per hospitalization
--      +  First/last hospitalizations
--      +  The icu expiration flag is assigned to the last icu_stay in the last
--         hospitalization.
--  ';

--COMMENT ON COLUMN mimic2v26.icustay_detail.subject_id is 'Unique subject identifier';
--COMMENT ON COLUMN mimic2v26.icustay_detail.gender is 'Subject''s gender "M" or "F"';
--COMMENT ON COLUMN mimic2v26.icustay_detail.dob is 'Subject''s date of birth';
--COMMENT ON COLUMN mimic2v26.icustay_detail.icustay_id is 'Unique ICU stay identifier';
--COMMENT ON COLUMN mimic2v26.icustay_detail.height is 'The first entered height of the patient';
--COMMENT ON COLUMN mimic2v26.icustay_detail.weight_first is 'The first entered weight of the patient';
--COMMENT ON COLUMN mimic2v26.icustay_detail.weight_max is 'The maximum entered weight of the patient';
--COMMENT ON COLUMN mimic2v26.icustay_detail.weight_min is 'The minimum entered weight of the patient';


--execute DBMS_SNAPSHOT.REFRESH( 'icustay_detail','c');
--execute DBMS_SNAPSHOT.REFRESH( 'd_chartitems_detail','c');
--execute DBMS_SNAPSHOT.REFRESH( 'icustay_days','c');
