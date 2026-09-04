/*
================================================================================
00_reference_data.sql — Reference/Lookup Tables for MDM Pipeline
================================================================================

Creates and populates the two reference lookup tables used by P01 to enrich
raw provider records with human-readable type and specialty descriptions.

RUN AFTER: 00_setup.sql
RUN BEFORE: P01_provider_cleaning.sql

TABLES CREATED:
  MDM.RAW.FFS_PROVIDER_TYPE_REF       — 87 rows (provider type codes → descriptions)
  MDM.RAW.FFS_PROVIDER_SPECIALTY_REF  — 72 rows (specialty codes → descriptions)
================================================================================
*/

USE WAREHOUSE COMPUTE_WH;
USE DATABASE MDM;
USE SCHEMA RAW;

-- ══════════════════════════════════════════════════════════════════════════════
-- PROVIDER TYPE REFERENCE (87 rows)
-- Maps FI_Provider_Type_CD → human-readable description
-- ══════════════════════════════════════════════════════════════════════════════

CREATE OR REPLACE TABLE MDM.RAW.FFS_PROVIDER_TYPE_REF (
    PROVIDER_TYPE_CD VARCHAR(10),
    PROVIDER_TYPE_DESC VARCHAR(200)
);

INSERT INTO MDM.RAW.FFS_PROVIDER_TYPE_REF (PROVIDER_TYPE_CD, PROVIDER_TYPE_DESC) VALUES
('001','ADULT DAY HEALTH CARE CENTERS'),
('002','ASSISTIVE DEVICE AND SICK ROOM SUPPLY DEALERS'),
('003','AUDIOLOGISTS'),
('004','BLOOD BANKS'),
('005','CERTIFIED NURSE MIDWIFE'),
('006','CHIROPRACTORS'),
('007','CERTIFIED NURSE PRACTIONER'),
('008','CHRISTIAN SCIENCE PRACTIONER'),
('009','CLINICAL LABORATORIES'),
('010','GROUP CERTIFIED NURSE PRACTITIONER'),
('011','FABRICATING OPTICAL LABORATORY'),
('012','DISPENSING OPTICIANS'),
('013','HEARING AID DISPENSERS'),
('014','HOME HEALTH AGENCIES'),
('015','COMMUNITY OUTPATIENT HOSPITAL'),
('016','COMMUNITY INPATIENT HOSPITAL'),
('017','LONG TERM CARE FACILITY'),
('018','NURSE ANESTHETISTS'),
('019','OCCUPATIONAL THERAPISTS'),
('020','OPTOMETRISTS'),
('021','ORTHOTISTS'),
('022','PHYSICIANS GROUP'),
('023','GROUP OPTOMETRISTS'),
('024','PHARMACIES/PHARMACISTS'),
('025','PHYSICAL THERAPISTS'),
('026','PHYSICIANS'),
('027','PODIATRISTS'),
('028','PORTABLE X-RAY'),
('029','PROSTHETISTS'),
('030','GROUND MEDICAL TRANSPORTATION'),
('031','PSYCHOLOGISTS'),
('032','CERTIFIED ACUPUNCTURIST'),
('033','GENETIC DISEASE TESTING'),
('034','MEDICARE CROSSOVER PROVIDER ONLY'),
('035','RURAL HEALTH CLINICS/FEDERALLY QUALIFIED HEALTH CENTER'),
('037','SPEECH THERAPISTS'),
('038','AIR AMBULANCE TRANSPORTATION SERVICES'),
('039','CERTIFIED HOSPICE'),
('040','FREE CLINIC'),
('041','COMMUNITY CLINIC'),
('042','CHRONIC DIALYSIS CLINIC'),
('043','MULTISPECIALTY CLINIC'),
('044','SURGICAL CLINIC'),
('045','CLINIC EXEMP FROM LICENSURE'),
('046','REHABILITATION CLINIC'),
('048','COUNTY CLINICS NOT ASSOCIATED WITH HOSPITAL'),
('049','BIRTHING CENTER SERVICES'),
('050','OTHERWISE UNDESIGNATED CLINIC'),
('051','OUTPATIENT HEROIN DETOX CENTER'),
('052','ALTERNATIVE BIRTH CENTERS - SPECIALTY CLINIC'),
('053','EVERY WOMAN COUNTS'),
('054','EXPANDED ACCESS TO PRIMARY CARE'),
('055','LOCAL EDUCATION AGENCY'),
('056','RESPIRATORY CARE PRACTITIONER'),
('057','Early and Periodic Screening, Diagnosis, and Treatment Supplemental Services Provider'),
('058','HEALTH ACCESS PROGRAM'),
('059','HOME AND COMMUNITY BASED SERVICES NURSING FACILITY'),
('060','COUNTY HOSPITAL INPATIENT'),
('061','COUNTY HOSPITAL OUTPATIENT'),
('062','GROUP RESPIRATORY CARE PRACTITIONERS'),
('063','LICENCED BUILDING CONTRACTORS'),
('064','EMPLOYMENT AGENCY'),
('065','PEDIATRIC SUBACUTE CARE/LTC'),
('066','PERSONAL CARE AGENCY'),
('067','RVNS INDIVIDUAL NURSE PROVIDERS'),
('068','HCBC BENEFIT PROVIDER'),
('069','PROFESSIONAL CORPORATION'),
('070','LICENSED CLINICAL SOCIAL WORKER INDIVIDUAL'),
('071','LICENSED CLINICAL SOCIAL WORKER GROUP'),
('072','MENTAL HEALTH INPATIENT SERVICES'),
('073','AIDS WAIVER SERVICES'),
('074','MULTIPURPOSE SENIOR SERVICES PROGRAM'),
('075','INDIAN HEALTH SERVICES/MEMORANDUM OF AGREEMENT'),
('076','DRUG MEDI-CAL'),
('077','MARRIAGE AND FAMILY THERAPIST INDIVIDUAL'),
('078','MARRIAGE AND FAMILY THERAPIST GROUP'),
('080','CA Children''s Services/Genetically Handicapped Persons Program Non-Institutional'),
('081','CA Children''s Services/Genetically Handicapped Persons Program Institutional'),
('084','INDEPENDENT DIAGNOSTIC TESTING FACILITY XOVER PROV ONLY'),
('085','CLINICAL NURSE SPECIALIST X-OVER PROVIDER ONLY'),
('086','MEDICAL DIRECTORS'),
('087','LICENSED PROFESSIONALS'),
('089','ELECTRONIC HEALTH RECORD INCENTIVE PROGRAM'),
('090','OUT OF STATE'),
('092','RESIDENTIAL CARE FACILITIES FOR THE ELDERLY (RCFE)'),
('093','CARE COORDINATOR (CCA)'),
('095','PRIVATE NON-PROFIT PROPRIETARY AGENCY');


-- ══════════════════════════════════════════════════════════════════════════════
-- PROVIDER SPECIALTY REFERENCE (72 rows)
-- Maps FI_Provider_Specialty_CD → human-readable description
-- ══════════════════════════════════════════════════════════════════════════════

CREATE OR REPLACE TABLE MDM.RAW.FFS_PROVIDER_SPECIALTY_REF (
    PROVIDER_SPECIALTY_CD VARCHAR(10),
    PROVIDER_SPECIALTY_DESC VARCHAR(200)
);

INSERT INTO MDM.RAW.FFS_PROVIDER_SPECIALTY_REF (PROVIDER_SPECIALTY_CD, PROVIDER_SPECIALTY_DESC) VALUES
('','A blank cell indicates that no provider specialty data is reported'),
('-','A dash indicates that no specialty information is required'),
('00','General Practitioner (Dentists Only)'),
('01','General Practice'),
('02','General Surgery'),
('03','Allergy'),
('04','Otology, Laryngology, Rhinology'),
('05','Anesthesiology'),
('06','Cardiovascular Disease (M.D. only)'),
('07','Dermatology'),
('08','Family Practice'),
('09','Gynecology (D.O. only)'),
('10','Gastroenterology (M.D. only), Oral Surgeon (Dentists Only)'),
('11','Aviation (M.D. only)'),
('12','Manipulative Therapy (D.O. only)'),
('13','Neurology (M.D. only)'),
('14','Neurological Surgery'),
('15','Obstetrics (D.O. only), Endodontist (Dentists Only)'),
('16','Obstetrics-Gynecology (M.D. Only) Neonatal'),
('17','Ophthalmology, Otolaryngology, Rhinology (D.O.only)'),
('18','Ophthalmology'),
('19','Dentists (DMD)'),
('2','Nurse Practitioner (non-physician medical practitioner)'),
('20','Orthopedic Surgery, Orthodontist (Dentists Only)'),
('21','Pathologic Anatomy: Clinical Pathology (D.O. only)'),
('22','Pathology (M.D. only)'),
('23','Peripheral Vascular Disease or Surgery (D.O. only)'),
('24','Plastic Surgery'),
('25','Physical Medicine and Rehabilitation, Certified Orthodontist (Dentists Only)'),
('26','Psychiatry (child)'),
('27','Psychiatry Neurology (D.O. only)'),
('28','Proctology (colon and rectal)'),
('29','Pulmonary Diseases (M.D. only)'),
('3','Physician Assistant (non-physician medical practitioner)'),
('30','Radiology, Pedodontist (Dentists Only)'),
('31','Roentgenology, Radiology (M.D. only)'),
('32','Radiation Therapy (D.O. only)'),
('33','Thoracic Surgery'),
('34','Urology and Urological Surgery'),
('35','Pediatric Cardiology (M.D. only)'),
('36','Psychiatry'),
('38','Geriatrics'),
('39','Preventive (M.D. only)'),
('4','Nurse Midwife (non-physician medical practitioner)'),
('40','Pediatrics, Periodontist (Dentists Only)'),
('41','Internal Medicine'),
('42','Nuclear Medicine'),
('43','Pediatric Allergy'),
('44','Public Health'),
('45','Nephrology (Renal-Kidney)'),
('46','Hand Surgery'),
('47','Miscellaneous'),
('50','Prosthodontist (Dentists Only)'),
('60','Oral Pathologist (Dentists Only)'),
('66','Emergency Medicine (Urgent Care)'),
('67','Endocrinology'),
('68','Hematology'),
('70','Clinic (mixed specialty), Public Health (Dentists Only)'),
('77','Infectious Disease'),
('78','Neoplastic Diseases/Oncology'),
('79','Neurology-Child'),
('80','Full-Time Facility (Dentists Only)'),
('83','Rheumatology'),
('84','Surgery-Head and Neck'),
('85','Surgery-Pediatric'),
('89','Surgery-Traumatic'),
('90','Pathology-Forensic'),
('91','Pharmacology-Clinical'),
('93','Marriage, family and child counselor'),
('94','Licensed clinical social worker'),
('95','Registered nurse'),
('99','Unknown (on EDS claims)');


-- ══════════════════════════════════════════════════════════════════════════════
-- VERIFY
-- ══════════════════════════════════════════════════════════════════════════════

SELECT 'FFS_PROVIDER_TYPE_REF' AS TBL, COUNT(*) AS CNT FROM MDM.RAW.FFS_PROVIDER_TYPE_REF
UNION ALL SELECT 'FFS_PROVIDER_SPECIALTY_REF', COUNT(*) FROM MDM.RAW.FFS_PROVIDER_SPECIALTY_REF;
