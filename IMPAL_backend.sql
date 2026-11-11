
-- =====================================================================
-- SCHOLARSEEK - International Education Finder
-- PostgreSQL database schema (public schema) (based on SKPL / SRS by Group "underrated")
-- Tested on PostgreSQL 16
--
-- Usage:
--   createdb scholarseek
--   psql -d scholarseek -f scholarseek_schema.sql
-- =====================================================================

-- Re-runnable: wipe the old copy (including the old 'scholarseek' schema) and rebuild.
-- Everything is created in the PUBLIC schema so pgAdmin shows it under
-- Schemas > public > Tables.
DROP SCHEMA IF EXISTS scholarseek CASCADE;

DROP VIEW IF EXISTS v_university_rating, v_university_detail, v_available_consultants CASCADE;

DROP TABLE IF EXISTS
    ai_chat_messages, ai_chat_sessions, ai_knowledge_base,
    video_call_requests, consulting_messages, consulting_sessions,
    university_reviews, comparison_items, comparison_lists,
    search_results, search_history,
    scholarships, programs, universities, countries,
    preferences, consultants, students, users
CASCADE;

DROP FUNCTION IF EXISTS register_user, login_user, search_universities, recommend_universities,
    request_consulting, respond_consulting, respond_video_call, submit_review,
    trg_check_student_role, trg_check_consultant_role, trg_touch_preference,
    trg_check_session_active, add_university CASCADE;

DROP TYPE IF EXISTS user_role, session_status, session_channel,
    message_sender, message_type, video_status CASCADE;

CREATE EXTENSION IF NOT EXISTS pgcrypto;   -- password hashing (NFR-SE1)
CREATE EXTENSION IF NOT EXISTS citext;     -- case-insensitive email

-- ---------------------------------------------------------------------
-- ENUM TYPES
-- ---------------------------------------------------------------------
CREATE TYPE user_role        AS ENUM ('student', 'consultant', 'admin');
CREATE TYPE session_status   AS ENUM ('pending', 'active', 'declined', 'timeout', 'ended');
CREATE TYPE session_channel  AS ENUM ('chat', 'video');
CREATE TYPE video_status     AS ENUM ('requested', 'accepted', 'declined');
CREATE TYPE message_sender   AS ENUM ('student', 'consultant', 'ai');
CREATE TYPE message_type     AS ENUM ('text', 'voice_note', 'image');

-- =====================================================================
-- 1. USERS  (class User -> generalised into Student / Consultant; Admin has no subtype table)
--    FR-M2 Login / Sign Up, NFR-SE1 hashed credentials
-- =====================================================================
CREATE TABLE users (
    user_id        BIGINT GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    name           VARCHAR(100) NOT NULL,
    username       VARCHAR(50)  NOT NULL UNIQUE,
    email          CITEXT       NOT NULL UNIQUE,
    password_hash  TEXT         NOT NULL,          -- bcrypt via crypt(), never plain text
    role           user_role    NOT NULL,           -- "Position" in the class diagram
    auth_provider  VARCHAR(20)  NOT NULL DEFAULT 'local',  -- 'local' / 'google' (sign up with other accounts)
    is_active      BOOLEAN      NOT NULL DEFAULT TRUE,
    created_at     TIMESTAMPTZ  NOT NULL DEFAULT now(),
    last_login_at  TIMESTAMPTZ,
    CONSTRAINT chk_email_format CHECK (email ~* '^[^@\s]+@[^@\s]+\.[^@\s]+$')
);

-- For API database
CREATE TABLE IF NOT EXISTS opportunities (
    opportunity_id BIGSERIAL PRIMARY KEY,
    external_id    VARCHAR(100) NOT NULL UNIQUE,
    title          VARCHAR(300) NOT NULL,
    organization   VARCHAR(200),
    category       VARCHAR(100),
    location       VARCHAR(200),
    description    TEXT,
    deadline       DATE,
    url            VARCHAR(500),
    raw            JSONB,
    synced_at      TIMESTAMPTZ NOT NULL DEFAULT now()
);
CREATE INDEX IF NOT EXISTS idx_opportunities_deadline ON opportunities (deadline);

-- Student (subclass)
CREATE TABLE students (
    student_id       BIGINT PRIMARY KEY REFERENCES users(user_id) ON DELETE CASCADE,
    current_school   VARCHAR(150),                 -- "University" attribute in class diagram
    enrollment_year  SMALLINT CHECK (enrollment_year BETWEEN 1990 AND 2100)
);

-- Consultant (subclass)
CREATE TABLE consultants (
    consultant_id  BIGINT PRIMARY KEY REFERENCES users(user_id) ON DELETE CASCADE,
    description    TEXT,
    rating         NUMERIC(3,2) NOT NULL DEFAULT 0 CHECK (rating BETWEEN 0 AND 5),
    review_count   INTEGER      NOT NULL DEFAULT 0,
    is_available   BOOLEAN      NOT NULL DEFAULT FALSE   -- "consultant must be online"
);

-- =====================================================================
-- 2. STUDENT PREFERENCE  (composition: Student 1 --- 1 Preference)
--    interest (major, country), budget, capability (GPA, IELTS)
-- =====================================================================
CREATE TABLE preferences (
    preference_id   BIGINT GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    student_id      BIGINT NOT NULL UNIQUE REFERENCES students(student_id) ON DELETE CASCADE,
    budget          NUMERIC(12,2) CHECK (budget >= 0),   -- per year, USD
    country         VARCHAR(80),
    major           VARCHAR(120),
    gpa_score       NUMERIC(3,2)  CHECK (gpa_score BETWEEN 0 AND 4),
    ielts_score     NUMERIC(2,1)  CHECK (ielts_score BETWEEN 0 AND 9),
    updated_at      TIMESTAMPTZ NOT NULL DEFAULT now()
);

-- =====================================================================
-- 3. UNIVERSITY DATA
--    FR-M1 search, FR-S1 scholarships, FR-S4 living cost, FR-S6 partners
-- =====================================================================
CREATE TABLE countries (
    country_id            SMALLINT GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    name                  VARCHAR(80) NOT NULL UNIQUE,
    iso_code              CHAR(2)     NOT NULL UNIQUE,
    est_living_cost_year  NUMERIC(12,2) NOT NULL CHECK (est_living_cost_year >= 0)  -- FR-S4, USD/year
);

CREATE TABLE universities (
    university_id   BIGINT GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    name            VARCHAR(200) NOT NULL,
    country_id      SMALLINT NOT NULL REFERENCES countries(country_id),
    city            VARCHAR(100),
    description     TEXT,
    website_url     VARCHAR(300),
    is_partner      BOOLEAN NOT NULL DEFAULT FALSE,        -- FR-S6 partnership availability
    admission_notes TEXT,                                  -- administration procedures
    created_at      TIMESTAMPTZ NOT NULL DEFAULT now(),
    UNIQUE (name, country_id)
);

-- A university offers many programs (major + tuition + entry requirements)
CREATE TABLE programs (
    program_id       BIGINT GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    university_id    BIGINT NOT NULL REFERENCES universities(university_id) ON DELETE CASCADE,
    major            VARCHAR(120) NOT NULL,
    degree_level     VARCHAR(30)  NOT NULL DEFAULT 'Bachelor',
    tuition_per_year NUMERIC(12,2) NOT NULL CHECK (tuition_per_year >= 0),
    min_gpa          NUMERIC(3,2) CHECK (min_gpa BETWEEN 0 AND 4),
    min_ielts        NUMERIC(2,1) CHECK (min_ielts BETWEEN 0 AND 9),
    UNIQUE (university_id, major, degree_level)
);

-- FR-S1 scholarship availability
CREATE TABLE scholarships (
    scholarship_id  BIGINT GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    university_id   BIGINT NOT NULL REFERENCES universities(university_id) ON DELETE CASCADE,
    name            VARCHAR(200) NOT NULL,
    coverage        VARCHAR(100),                 -- e.g. 'Full tuition', '50% tuition'
    amount          NUMERIC(12,2),
    min_gpa         NUMERIC(3,2),
    deadline        DATE,
    details         TEXT
);

-- =====================================================================
-- 4. SEARCH HISTORY, COMPARISON, RECOMMENDATION
--    FR-M1, FR-S3, FR-D1
-- =====================================================================
CREATE TABLE search_history (
    search_id     BIGINT GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    student_id    BIGINT NOT NULL REFERENCES students(student_id) ON DELETE CASCADE,
    keyword       VARCHAR(200),
    major         VARCHAR(120),
    country       VARCHAR(80),
    budget        NUMERIC(12,2),
    gpa_score     NUMERIC(3,2),
    ielts_score   NUMERIC(2,1),
    result_count  INTEGER NOT NULL DEFAULT 0,
    searched_at   TIMESTAMPTZ NOT NULL DEFAULT now()
);

-- Which universities a student clicked from a search (feeds FR-D1)
CREATE TABLE search_results (
    search_id      BIGINT NOT NULL REFERENCES search_history(search_id) ON DELETE CASCADE,
    university_id  BIGINT NOT NULL REFERENCES universities(university_id) ON DELETE CASCADE,
    rank_position  INTEGER,
    was_viewed     BOOLEAN NOT NULL DEFAULT FALSE,
    PRIMARY KEY (search_id, university_id)
);

-- FR-S3 compare universities side-by-side
CREATE TABLE comparison_lists (
    comparison_id  BIGINT GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    student_id     BIGINT NOT NULL REFERENCES students(student_id) ON DELETE CASCADE,
    created_at     TIMESTAMPTZ NOT NULL DEFAULT now()
);

CREATE TABLE comparison_items (
    comparison_id  BIGINT NOT NULL REFERENCES comparison_lists(comparison_id) ON DELETE CASCADE,
    university_id  BIGINT NOT NULL REFERENCES universities(university_id) ON DELETE CASCADE,
    added_at       TIMESTAMPTZ NOT NULL DEFAULT now(),
    PRIMARY KEY (comparison_id, university_id)
);

-- =====================================================================
-- 5. REVIEW AND RATING  (FR-D2)
-- =====================================================================
CREATE TABLE university_reviews (
    review_id      BIGINT GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    university_id  BIGINT NOT NULL REFERENCES universities(university_id) ON DELETE CASCADE,
    student_id     BIGINT NOT NULL REFERENCES students(student_id) ON DELETE CASCADE,
    rating         SMALLINT NOT NULL CHECK (rating BETWEEN 1 AND 5),
    comment        TEXT,
    created_at     TIMESTAMPTZ NOT NULL DEFAULT now(),
    UNIQUE (university_id, student_id)           -- one review per student per university
);

-- =====================================================================
-- 6. LIVE CONSULTING  (FR-S5 chat, FR-S7 video call)
--    Student 0..1 --- 1 Consultant per session
-- =====================================================================
CREATE TABLE consulting_sessions (
    session_id      BIGINT GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    student_id      BIGINT NOT NULL REFERENCES students(student_id)       ON DELETE CASCADE,
    consultant_id   BIGINT NOT NULL REFERENCES consultants(consultant_id) ON DELETE CASCADE,
    status          session_status NOT NULL DEFAULT 'pending',  -- consultant accepts / declines / timeout
    requested_at    TIMESTAMPTZ NOT NULL DEFAULT now(),
    started_at      TIMESTAMPTZ,
    ended_at        TIMESTAMPTZ,
    CONSTRAINT chk_session_times CHECK (ended_at IS NULL OR started_at IS NULL OR ended_at >= started_at)
);

CREATE TABLE consulting_messages (
    message_id   BIGINT GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    session_id   BIGINT NOT NULL REFERENCES consulting_sessions(session_id) ON DELETE CASCADE,
    sender_id    BIGINT NOT NULL REFERENCES users(user_id),
    msg_type     message_type NOT NULL DEFAULT 'text',
    content      TEXT NOT NULL,
    sent_at      TIMESTAMPTZ NOT NULL DEFAULT now()
);

-- Video call request is an extension of a chat session ("Request Zoom Meet?")
CREATE TABLE video_call_requests (
    video_id       BIGINT GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    session_id     BIGINT NOT NULL REFERENCES consulting_sessions(session_id) ON DELETE CASCADE,
    status         video_status NOT NULL DEFAULT 'requested',
    meeting_url    VARCHAR(500),                  -- unique Zoom link generated by the API
    requested_at   TIMESTAMPTZ NOT NULL DEFAULT now(),
    responded_at   TIMESTAMPTZ,
    CONSTRAINT chk_link_when_accepted CHECK (status <> 'accepted' OR meeting_url IS NOT NULL)
);

-- =====================================================================
-- 7. AI CHATBOT  (FR-S2)  - classes AI Chatbot + Data
-- =====================================================================
CREATE TABLE ai_knowledge_base (                  -- "Knowledge Base / Data"
    kb_id          BIGINT GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    topic          VARCHAR(150) NOT NULL,
    question       TEXT,
    answer         TEXT NOT NULL,
    university_id  BIGINT REFERENCES universities(university_id) ON DELETE SET NULL,
    updated_at     TIMESTAMPTZ NOT NULL DEFAULT now()
);

CREATE TABLE ai_chat_sessions (
    ai_session_id  BIGINT GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    student_id     BIGINT NOT NULL REFERENCES students(student_id) ON DELETE CASCADE,
    started_at     TIMESTAMPTZ NOT NULL DEFAULT now(),
    ended_at       TIMESTAMPTZ
);

CREATE TABLE ai_chat_messages (                   -- class "Data": Chat, Chat Date, AI Respond, Generate Image
    ai_message_id  BIGINT GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    ai_session_id  BIGINT NOT NULL REFERENCES ai_chat_sessions(ai_session_id) ON DELETE CASCADE,
    sender         message_sender NOT NULL CHECK (sender IN ('student', 'ai')),
    msg_type       message_type NOT NULL DEFAULT 'text',
    content        TEXT NOT NULL,
    answer_found   BOOLEAN,                       -- FALSE -> "AI cannot answer" apology message
    image_url      VARCHAR(500),                  -- "Generate Image"
    sent_at        TIMESTAMPTZ NOT NULL DEFAULT now()   -- "Chat Date"
);

-- =====================================================================
-- 8. INDEXES  (NFR-PE1: search results in <= 3 s, NFR-PE2: 1,000 concurrent users)
-- =====================================================================
CREATE INDEX idx_universities_country   ON universities(country_id);
CREATE INDEX idx_universities_partner   ON universities(is_partner) WHERE is_partner;
CREATE INDEX idx_programs_major         ON programs(lower(major));
CREATE INDEX idx_programs_university    ON programs(university_id);
CREATE INDEX idx_programs_tuition       ON programs(tuition_per_year);
CREATE INDEX idx_scholarships_uni       ON scholarships(university_id);
CREATE INDEX idx_search_history_student ON search_history(student_id, searched_at DESC);
CREATE INDEX idx_reviews_university     ON university_reviews(university_id);
CREATE INDEX idx_sessions_student       ON consulting_sessions(student_id);
CREATE INDEX idx_sessions_consultant    ON consulting_sessions(consultant_id, status);
CREATE INDEX idx_cmsg_session           ON consulting_messages(session_id, sent_at);
CREATE INDEX idx_aimsg_session          ON ai_chat_messages(ai_session_id, sent_at);
CREATE INDEX idx_users_role             ON users(role);

-- =====================================================================
-- 9. TRIGGERS
-- =====================================================================

-- Make sure a user's role matches the subtype table they are inserted into
CREATE FUNCTION trg_check_student_role() RETURNS trigger AS $$
BEGIN
    IF (SELECT role FROM users WHERE user_id = NEW.student_id) <> 'student' THEN
        RAISE EXCEPTION 'User % is not a student', NEW.student_id;
    END IF;
    RETURN NEW;
END $$ LANGUAGE plpgsql;

CREATE TRIGGER check_student_role BEFORE INSERT ON students
    FOR EACH ROW EXECUTE FUNCTION trg_check_student_role();

CREATE FUNCTION trg_check_consultant_role() RETURNS trigger AS $$
BEGIN
    IF (SELECT role FROM users WHERE user_id = NEW.consultant_id) <> 'consultant' THEN
        RAISE EXCEPTION 'User % is not a consultant', NEW.consultant_id;
    END IF;
    RETURN NEW;
END $$ LANGUAGE plpgsql;

CREATE TRIGGER check_consultant_role BEFORE INSERT ON consultants
    FOR EACH ROW EXECUTE FUNCTION trg_check_consultant_role();

-- Keep preference.updated_at fresh
CREATE FUNCTION trg_touch_preference() RETURNS trigger AS $$
BEGIN
    NEW.updated_at := now();
    RETURN NEW;
END $$ LANGUAGE plpgsql;

CREATE TRIGGER touch_preference BEFORE UPDATE ON preferences
    FOR EACH ROW EXECUTE FUNCTION trg_touch_preference();

-- Chat messages only allowed while a session is active
CREATE FUNCTION trg_check_session_active() RETURNS trigger AS $$
BEGIN
    IF (SELECT status FROM consulting_sessions WHERE session_id = NEW.session_id) <> 'active' THEN
        RAISE EXCEPTION 'Session % is not active', NEW.session_id;
    END IF;
    RETURN NEW;
END $$ LANGUAGE plpgsql;

CREATE TRIGGER check_session_active BEFORE INSERT ON consulting_messages
    FOR EACH ROW EXECUTE FUNCTION trg_check_session_active();

-- Recalculate consultant rating is out of scope (reviews are for universities),
-- but the university average is exposed through a view below.

-- =====================================================================
-- 10. VIEWS
-- =====================================================================

-- FR-D2: average rating per university
CREATE VIEW v_university_rating AS
SELECT u.university_id,
       u.name,
       COUNT(r.review_id)                     AS review_count,
       ROUND(AVG(r.rating)::numeric, 2)       AS avg_rating
FROM universities u
LEFT JOIN university_reviews r USING (university_id)
GROUP BY u.university_id, u.name;

-- FR-S1 / FR-S3 / FR-S4 / FR-S6: one-stop university detail page
CREATE VIEW v_university_detail AS
SELECT u.university_id,
       u.name,
       c.name                      AS country,
       u.city,
       u.is_partner,
       c.est_living_cost_year,
       (SELECT MIN(p.tuition_per_year) FROM programs p WHERE p.university_id = u.university_id) AS min_tuition_year,
       EXISTS (SELECT 1 FROM scholarships s WHERE s.university_id = u.university_id)            AS has_scholarship,
       COALESCE(v.avg_rating, 0)   AS avg_rating,
       COALESCE(v.review_count, 0) AS review_count
FROM universities u
JOIN countries c USING (country_id)
LEFT JOIN v_university_rating v USING (university_id);

-- Consultants a student can pick from (Live Consulting step 2)
CREATE VIEW v_available_consultants AS
SELECT c.consultant_id, u.name, c.description, c.rating, c.review_count
FROM consultants c
JOIN users u ON u.user_id = c.consultant_id
WHERE c.is_available AND u.is_active;

-- =====================================================================
-- 11. FUNCTIONS (business logic)
-- =====================================================================

-- FR-M2 Sign up: stores a bcrypt hash (NFR-SE1)
CREATE FUNCTION register_user(
    p_name VARCHAR, p_username VARCHAR, p_email VARCHAR, p_password TEXT,
    p_role user_role, p_provider VARCHAR DEFAULT 'local'
) RETURNS BIGINT AS $$
DECLARE
    new_id BIGINT;
BEGIN
    INSERT INTO users (name, username, email, password_hash, role, auth_provider)
    VALUES (p_name, p_username, p_email, crypt(p_password, gen_salt('bf', 10)), p_role, p_provider)
    RETURNING user_id INTO new_id;

    IF p_role = 'student' THEN
        INSERT INTO students (student_id) VALUES (new_id);
    ELSIF p_role = 'consultant' THEN
        INSERT INTO consultants (consultant_id) VALUES (new_id);
    END IF;   -- 'admin' needs no subtype row
    RETURN new_id;
END $$ LANGUAGE plpgsql;

-- FR-M2 Login: returns the user_id if credentials are valid, otherwise NULL
CREATE FUNCTION login_user(p_email VARCHAR, p_password TEXT) RETURNS BIGINT AS $$
DECLARE
    uid BIGINT;
BEGIN
    SELECT user_id INTO uid
    FROM users
    WHERE email = p_email
      AND is_active
      AND password_hash = crypt(p_password, password_hash);

    IF uid IS NOT NULL THEN
        UPDATE users SET last_login_at = now() WHERE user_id = uid;
    END IF;
    RETURN uid;
END $$ LANGUAGE plpgsql;

-- FR-M1 Search universities by interest, budget (tuition + living cost), capability.
-- Any parameter can be NULL to skip that filter. Also logs the search for FR-D1.
CREATE FUNCTION search_universities(
    p_student_id BIGINT,
    p_major      VARCHAR DEFAULT NULL,
    p_country    VARCHAR DEFAULT NULL,
    p_budget     NUMERIC DEFAULT NULL,
    p_gpa        NUMERIC DEFAULT NULL,
    p_ielts      NUMERIC DEFAULT NULL,
    p_keyword    VARCHAR DEFAULT NULL
) RETURNS TABLE (
    university_id BIGINT, university VARCHAR, country VARCHAR, major VARCHAR,
    tuition_per_year NUMERIC, living_cost_year NUMERIC, total_cost_year NUMERIC,
    has_scholarship BOOLEAN, is_partner BOOLEAN, avg_rating NUMERIC
) AS $$
DECLARE
    new_search BIGINT;
    n INTEGER;
BEGIN
    CREATE TEMP TABLE _res ON COMMIT DROP AS
    SELECT u.university_id, u.name::varchar AS university, c.name::varchar AS country,
           p.major::varchar, p.tuition_per_year, c.est_living_cost_year AS living_cost_year,
           (p.tuition_per_year + c.est_living_cost_year) AS total_cost_year,
           EXISTS (SELECT 1 FROM scholarships s WHERE s.university_id = u.university_id) AS has_scholarship,
           u.is_partner,
           COALESCE(rt.avg_rating, 0) AS avg_rating
    FROM universities u
    JOIN countries c  ON c.country_id = u.country_id
    JOIN programs  p  ON p.university_id = u.university_id
    LEFT JOIN v_university_rating rt ON rt.university_id = u.university_id
    WHERE (p_major   IS NULL OR p.major ILIKE '%' || p_major || '%')
      AND (p_country IS NULL OR c.name ILIKE p_country)
      AND (p_budget  IS NULL OR p.tuition_per_year + c.est_living_cost_year <= p_budget)
      AND (p_gpa     IS NULL OR p.min_gpa   IS NULL OR p.min_gpa   <= p_gpa)
      AND (p_ielts   IS NULL OR p.min_ielts IS NULL OR p.min_ielts <= p_ielts)
      AND (p_keyword IS NULL OR u.name ILIKE '%' || p_keyword || '%'
                             OR p.major ILIKE '%' || p_keyword || '%')
    ORDER BY total_cost_year ASC, avg_rating DESC;

    SELECT COUNT(*) INTO n FROM _res;

    INSERT INTO search_history (student_id, keyword, major, country, budget, gpa_score, ielts_score, result_count)
    VALUES (p_student_id, p_keyword, p_major, p_country, p_budget, p_gpa, p_ielts, n)
    RETURNING search_id INTO new_search;

    INSERT INTO search_results (search_id, university_id, rank_position)
    SELECT new_search, r.university_id, ROW_NUMBER() OVER ()
    FROM (SELECT DISTINCT ON (_res.university_id) _res.university_id FROM _res) r
    ON CONFLICT DO NOTHING;

    RETURN QUERY SELECT * FROM _res;   -- empty set => app shows the "apologizing message"
END $$ LANGUAGE plpgsql;

-- FR-D1 Recommendation based on the student's previous searches
CREATE FUNCTION recommend_universities(p_student_id BIGINT, p_limit INT DEFAULT 5)
RETURNS TABLE (university_id BIGINT, university VARCHAR, country VARCHAR, score BIGINT) AS $$
    WITH past AS (
        SELECT major, country FROM search_history
        WHERE student_id = p_student_id
        ORDER BY searched_at DESC
        LIMIT 20
    )
    SELECT u.university_id, u.name::varchar, c.name::varchar,
           COUNT(*)::bigint AS score
    FROM past
    JOIN countries c ON (past.country IS NULL OR c.name ILIKE past.country)
    JOIN universities u ON u.country_id = c.country_id
    JOIN programs p ON p.university_id = u.university_id
                   AND (past.major IS NULL OR p.major ILIKE '%' || past.major || '%')
    GROUP BY u.university_id, u.name, c.name
    ORDER BY score DESC, u.name
    LIMIT p_limit;
$$ LANGUAGE sql STABLE;

-- FR-S5 Student requests a live consulting session
CREATE FUNCTION request_consulting(p_student BIGINT, p_consultant BIGINT) RETURNS BIGINT AS $$
    INSERT INTO consulting_sessions (student_id, consultant_id)
    VALUES (p_student, p_consultant)
    RETURNING session_id;
$$ LANGUAGE sql;

-- Consultant accepts / declines (timeout handled by the app calling with 'timeout')
CREATE FUNCTION respond_consulting(p_session BIGINT, p_new_status session_status) RETURNS VOID AS $$
BEGIN
    IF p_new_status NOT IN ('active', 'declined', 'timeout') THEN
        RAISE EXCEPTION 'Invalid response status %', p_new_status;
    END IF;
    UPDATE consulting_sessions
       SET status = p_new_status,
           started_at = CASE WHEN p_new_status = 'active' THEN now() END
     WHERE session_id = p_session AND status = 'pending';
END $$ LANGUAGE plpgsql;

-- FR-S7 Consultant accepts a Zoom request -> store the generated link
CREATE FUNCTION respond_video_call(p_video BIGINT, p_accept BOOLEAN, p_url VARCHAR DEFAULT NULL)
RETURNS VOID AS $$
    UPDATE video_call_requests
       SET status = CASE WHEN p_accept THEN 'accepted'::video_status ELSE 'declined'::video_status END,
           meeting_url = CASE WHEN p_accept THEN p_url END,
           responded_at = now()
     WHERE video_id = p_video AND status = 'requested';
$$ LANGUAGE sql;

-- Leave/update a review (FR-D2): one per student per university, updated if it exists
CREATE FUNCTION submit_review(p_student BIGINT, p_university BIGINT, p_rating SMALLINT, p_comment TEXT)
RETURNS VOID AS $$
    INSERT INTO university_reviews (student_id, university_id, rating, comment)
    VALUES (p_student, p_university, p_rating, p_comment)
    ON CONFLICT (university_id, student_id)
    DO UPDATE SET rating = EXCLUDED.rating, comment = EXCLUDED.comment, created_at = now();
$$ LANGUAGE sql;

-- Admin: add a university with its programs and scholarships in ONE atomic step.
-- The country is reused if it already exists; a new country needs an ISO code + living cost.
-- p_programs / p_scholarships are JSON arrays, e.g.
--   '[{"major":"Computer Science","degree_level":"Bachelor","tuition_per_year":6500,"min_gpa":3.5,"min_ielts":6.0}]'
--   '[{"name":"MEXT Scholarship","coverage":"Full tuition","amount":null,"min_gpa":3.5,"deadline":"2026-05-30","details":null}]'
CREATE FUNCTION add_university(
    p_admin_id        BIGINT,
    p_name            VARCHAR,
    p_country         VARCHAR,
    p_city            VARCHAR,
    p_description     TEXT,
    p_website_url     VARCHAR,
    p_is_partner      BOOLEAN,
    p_admission_notes TEXT,
    p_programs        JSONB,
    p_scholarships    JSONB DEFAULT '[]'::jsonb,
    p_iso_code        VARCHAR DEFAULT NULL,
    p_living_cost     NUMERIC DEFAULT NULL
) RETURNS BIGINT AS $$
DECLARE
    v_country_id SMALLINT;
    v_uni_id     BIGINT;
BEGIN
    IF NOT EXISTS (SELECT 1 FROM users WHERE user_id = p_admin_id AND role = 'admin' AND is_active) THEN
        RAISE EXCEPTION 'Only admin accounts can add universities.';
    END IF;

    IF p_programs IS NULL OR jsonb_typeof(p_programs) <> 'array' OR jsonb_array_length(p_programs) = 0 THEN
        RAISE EXCEPTION 'Add at least one program (major and tuition per year).';
    END IF;

    SELECT country_id INTO v_country_id
    FROM countries WHERE lower(name) = lower(trim(p_country));

    IF v_country_id IS NULL THEN
        IF p_iso_code IS NULL OR p_living_cost IS NULL THEN
            RAISE EXCEPTION 'Country "%" is new: please provide its 2-letter ISO code and yearly living cost.', p_country;
        END IF;
        IF length(trim(p_iso_code)) <> 2 THEN
            RAISE EXCEPTION 'The ISO code must be exactly 2 letters (for example JP).';
        END IF;
        INSERT INTO countries (name, iso_code, est_living_cost_year)
        VALUES (trim(p_country), upper(trim(p_iso_code)), p_living_cost)
        RETURNING country_id INTO v_country_id;
    END IF;

    INSERT INTO universities (name, country_id, city, description, website_url, is_partner, admission_notes)
    VALUES (trim(p_name), v_country_id, p_city, p_description, p_website_url,
            COALESCE(p_is_partner, FALSE), p_admission_notes)
    RETURNING university_id INTO v_uni_id;

    INSERT INTO programs (university_id, major, degree_level, tuition_per_year, min_gpa, min_ielts)
    SELECT v_uni_id, trim(x.major), COALESCE(NULLIF(trim(x.degree_level), ''), 'Bachelor'),
           x.tuition_per_year, x.min_gpa, x.min_ielts
    FROM jsonb_to_recordset(p_programs)
         AS x(major text, degree_level text, tuition_per_year numeric, min_gpa numeric, min_ielts numeric);

    IF p_scholarships IS NOT NULL AND jsonb_typeof(p_scholarships) = 'array' THEN
        INSERT INTO scholarships (university_id, name, coverage, amount, min_gpa, deadline, details)
        SELECT v_uni_id, trim(s.name), s.coverage, s.amount, s.min_gpa,
               NULLIF(s.deadline, '')::date, s.details
        FROM jsonb_to_recordset(p_scholarships)
             AS s(name text, coverage text, amount numeric, min_gpa numeric, deadline text, details text);
    END IF;

    RETURN v_uni_id;
END $$ LANGUAGE plpgsql;

-- =====================================================================
-- 12. SAMPLE DATA (for testing - delete in production)
-- =====================================================================
INSERT INTO countries (name, iso_code, est_living_cost_year) VALUES
  ('Australia',      'AU', 21000),
  ('United Kingdom', 'GB', 15000),
  ('Japan',          'JP', 10000),
  ('Netherlands',    'NL', 12000),
  ('Malaysia',       'MY',  5500);

INSERT INTO universities (name, country_id, city, is_partner, description) VALUES
  ('Deakin University',            1, 'Melbourne',  TRUE,  'Large Australian university with strong IT programs.'),
  ('University of Melbourne',      1, 'Melbourne',  FALSE, 'Top-ranked research university.'),
  ('University of Manchester',     2, 'Manchester', FALSE, 'Russell Group university.'),
  ('University of Tokyo',          3, 'Tokyo',      FALSE, 'Japan''s leading national university.'),
  ('Delft University of Technology',4,'Delft',      TRUE,  'Leading technical university in the Netherlands.'),
  ('Universiti Malaya',            5, 'Kuala Lumpur',TRUE, 'Malaysia''s oldest university.');

INSERT INTO programs (university_id, major, tuition_per_year, min_gpa, min_ielts) VALUES
  (1, 'Informatics',      28000, 3.00, 6.5),
  (2, 'Informatics',      38000, 3.50, 6.5),
  (3, 'Computer Science', 30000, 3.40, 6.5),
  (4, 'Computer Science',  6500, 3.50, 6.0),
  (5, 'Computer Science', 15000, 3.30, 6.5),
  (6, 'Informatics',       4500, 2.80, 6.0),
  (6, 'Business',          4000, 2.70, 6.0),
  (1, 'Business',         27000, 3.00, 6.5);

INSERT INTO scholarships (university_id, name, coverage, amount, min_gpa, deadline) VALUES
  (1, 'Deakin Vice-Chancellor''s International Scholarship', '25% tuition', 7000, 3.50, '2026-12-01'),
  (4, 'MEXT Scholarship',                                    'Full tuition + stipend', NULL, 3.50, '2026-05-30'),
  (5, 'Justus & Louise van Effen Excellence Scholarship',    'Tuition + living',  NULL, 3.70, '2026-12-01');

-- Users (passwords hashed through register_user)
SELECT register_user('Gavin',  'gavin',  'gavin@student.id',   'pass1234', 'student');
SELECT register_user('Abby', 'abby', 'abby@student.id',  'pass1234', 'student');
SELECT register_user('Dr. Olaza', 'olaza', 'olaza@scholarseek.id', 'consult123', 'consultant');
SELECT register_user('Randi (Expert)', 'randi_exp', 'randi@scholarseek.id', 'consult123', 'consultant');
-- Admin (user_id 5): can add university data. Change this password for real use!
SELECT register_user('Admin', 'admin', 'admin@scholarseek.id', 'admin12345', 'admin');

UPDATE students SET current_school = 'Telkom University', enrollment_year = 2023 WHERE student_id IN (1, 2);
UPDATE consultants SET is_available = TRUE, rating = 4.8, review_count = 12,
       description = 'International admissions consultant (AU / UK / NL).' WHERE consultant_id = 3;
UPDATE consultants SET is_available = FALSE, rating = 4.5, review_count = 7,
       description = 'Scholarship and visa specialist.' WHERE consultant_id = 4;

INSERT INTO preferences (student_id, budget, country, major, gpa_score, ielts_score)
VALUES (1, 30000, 'Netherlands', 'Computer Science', 3.5, 7.0);

SELECT submit_review(1, 1, 5::smallint, 'Great IT facilities and supportive lecturers.');
SELECT submit_review(2, 1, 4::smallint, 'Good, but living costs in Melbourne are high.');

-- Sample universities added through the admin function (admin = user_id 5)
-- 1) existing country (Japan): its living cost is reused
SELECT add_university(
    5, 'Kyoto University', 'Japan', 'Kyoto',
    'Renowned national research university in Japan''s old capital.',
    'https://www.kyoto-u.ac.jp', FALSE,
    'Apply through the university portal; IELTS or TOEFL and academic transcripts are required.',
    '[{"major":"Computer Science","degree_level":"Bachelor","tuition_per_year":6200,"min_gpa":3.5,"min_ielts":6.0},
      {"major":"Informatics","degree_level":"Master","tuition_per_year":6200,"min_gpa":3.3,"min_ielts":6.5}]'::jsonb,
    '[{"name":"MEXT Scholarship (Kyoto)","coverage":"Full tuition + stipend","amount":null,"min_gpa":3.5,"deadline":"2026-05-30","details":"Government scholarship for international students."}]'::jsonb
);
-- 2) NEW country (Singapore): needs ISO code + yearly living cost
SELECT add_university(
    5, 'National University of Singapore', 'Singapore', 'Singapore',
    'Leading global university in Asia.',
    'https://www.nus.edu.sg', TRUE,
    'Online application; SAT/ACT or equivalent and English test required.',
    '[{"major":"Computer Science","degree_level":"Bachelor","tuition_per_year":17500,"min_gpa":3.6,"min_ielts":6.5}]'::jsonb,
    '[]'::jsonb,
    'SG', 18000
);

INSERT INTO ai_knowledge_base (topic, question, answer, university_id) VALUES
  ('Admission', 'What IELTS score does Deakin require?', 'Most Deakin programs require an overall IELTS of 6.5.', 1),
  ('Scholarship', 'Which scholarships are available in Japan?', 'The MEXT scholarship covers full tuition plus a monthly stipend.', 4);

SELECT * FROM comparison_items;
SELECT * FROM comparison_lists;
SELECT * FROM consultants;
SELECT * FROM consulting_messages;
SELECT * FROM consulting_sessions;
SELECT * FROM countries;
-- =====================================================================
-- 13. EXAMPLE QUERIES
-- =====================================================================
-- Login:
SELECT login_user('gavin@student.id', 'pass1234');
-- Admin login:
SELECT login_user('admin@scholarseek.id', 'admin12345');
-- Search universities (student 1: Informatics/CS, budget 35,000/yr, GPA 3.5, IELTS 7.0):
SELECT * FROM search_universities(1, 'Computer', NULL, 35000, 3.5, 7.0);
-- Recommendations from previous searches:
SELECT * FROM recommend_universities(1);
-- University detail page:
SELECT * FROM v_university_detail WHERE country = 'Australia';
-- Available consultants:
SELECT * FROM v_available_consultants;
-- Live consulting flow:
SELECT request_consulting(1, 3);                 -- returns session_id
SELECT respond_consulting(1, 'active');          -- consultant accepts
INSERT INTO consulting_messages (session_id, sender_id, content) VALUES (1, 1, 'Hello!');