import datetime
import json
import os
import traceback
import urllib.error
import urllib.request

import psycopg
from flask import Flask, jsonify, request, send_from_directory, session
from psycopg.rows import dict_row
from psycopg.types.json import Jsonb
from werkzeug.exceptions import HTTPException

app = Flask(__name__, static_folder=None)
app.secret_key = os.environ.get("SECRET_KEY", "dev-secret-change-me")
DSN = os.environ.get(
    "DATABASE_DSN",
    "host=localhost port=5432 dbname=scholarseek user=postgres password=password",
)

# ---- Edutu opportunities API ----
EDUTU_URL = os.environ.get("EDUTU_URL", "https://backend.edutu.org/v1/opportunities")
EDUTU_KEY = os.environ.get("EDUTU_API_KEY")  # only needed if the API requires one
EDUTU_PAGES = int(os.environ.get("EDUTU_PAGES", "1"))  # >1 = also request ?page=2,3,... until nothing new

DETAIL_SQL = """
SELECT d.university_id, d.name, d.country, d.city, d.is_partner, d.est_living_cost_year,
       d.avg_rating, d.review_count, u.description, u.website_url, u.admission_notes
FROM v_university_detail d
JOIN universities u ON u.university_id = d.university_id
WHERE d.university_id = %s
"""


def db():
    return psycopg.connect(DSN, row_factory=dict_row)


def fail(message, code=400):
    return jsonify(ok=False, error=message), code


def current_user():
    uid = session.get("uid")
    if uid is None:
        return None
    with db() as conn:
        return conn.execute(
            "SELECT user_id, name, role FROM users WHERE user_id = %s AND is_active", (uid,)
        ).fetchone()


def text(name):
    return request.args.get(name, "").strip()[:100] or None


def number(name, low, high):
    raw = request.args.get(name, "").strip()
    if not raw:
        return None
    value = float(raw)
    if not low <= value <= high:
        raise ValueError(name)
    return value


def clean_str(value, label, max_len, required=False):
    s = str(value or "").strip()
    if required and not s:
        raise ValueError(f"{label} is required.")
    return s[:max_len] or None


def clean_num(value, label, low, high, required=False):
    if value is None or str(value).strip() == "":
        if required:
            raise ValueError(f"{label} is required.")
        return None
    try:
        n = float(value)
    except (TypeError, ValueError):
        raise ValueError(f"{label} must be a number.")
    if not low <= n <= high:
        raise ValueError(f"{label} must be between {low:g} and {high:g}.")
    return n


def admin_user():
    user = current_user()
    if user and user["role"] == "admin":
        return user
    return None


def program_line(p):
    parts = [f"{p['major']} ({p['degree_level']})", f"${p['tuition_per_year']:,.0f}/yr"]
    if p["min_gpa"] is not None:
        parts.append(f"min GPA {p['min_gpa']}")
    if p["min_ielts"] is not None:
        parts.append(f"min IELTS {p['min_ielts']}")
    return " · ".join(parts)


def scholarship_line(s):
    parts = [s["name"]]
    if s["coverage"]:
        parts.append(s["coverage"])
    if s["amount"] is not None:
        parts.append(f"${s['amount']:,.0f}")
    if s["deadline"]:
        parts.append(f"deadline {s['deadline']}")
    return " · ".join(parts)

# =====================================================================
# Edutu opportunities: fetch -> save in PostgreSQL -> serve from our own API
# =====================================================================
class SyncError(Exception):
    """A problem talking to the Edutu API, with a message safe to show to users."""


def edutu_get(url):
    headers = {"Accept": "application/json", "User-Agent": "scholarseek/1.0"}
    if EDUTU_KEY:
        headers["Authorization"] = f"Bearer {EDUTU_KEY}"
    req = urllib.request.Request(url, headers=headers)
    try:
        with urllib.request.urlopen(req, timeout=15) as resp:
            return json.loads(resp.read().decode("utf-8"))
    except urllib.error.HTTPError as e:
        if e.code in (401, 403):
            raise SyncError(
                f"Edutu refused the request (HTTP {e.code}). The API probably needs a key: "
                "set the EDUTU_API_KEY environment variable and restart the server."
            )
        raise SyncError(f"Edutu API returned HTTP {e.code}.")
    except urllib.error.URLError as e:
        raise SyncError(f"Could not reach the Edutu API ({e.reason}). Check your internet connection.")
    except TimeoutError:
        raise SyncError("The Edutu API took too long to answer.")
    except (json.JSONDecodeError, UnicodeDecodeError):
        raise SyncError("The Edutu API did not return valid JSON.")


def extract_items(payload):
    """Find the list of opportunities inside whatever wrapper the API uses."""
    if isinstance(payload, list):
        return payload
    if not isinstance(payload, dict):
        return []
    keys = ("data", "opportunities", "items", "results", "records", "docs")
    for key in keys:
        value = payload.get(key)
        if isinstance(value, list):
            return value
        if isinstance(value, dict):  # e.g. {"data": {"opportunities": [...]}}
            for inner in keys:
                if isinstance(value.get(inner), list):
                    return value[inner]
    return []


def pick(item, *names):
    for n in names:
        v = item.get(n)
        if v not in (None, "", [], {}):
            return v
    return None


def as_text(value, max_len=None):
    """Turn any JSON value into clean text (or None)."""
    if value is None:
        return None
    if isinstance(value, dict):
        value = pick(value, "name", "title", "label") or json.dumps(value, ensure_ascii=False)
    elif isinstance(value, list):
        value = ", ".join(as_text(v) or "" for v in value)
    s = str(value).strip()
    if not s:
        return None
    return s[:max_len] if max_len else s


def parse_date(value):
    if not value:
        return None
    try:
        return datetime.date.fromisoformat(str(value).strip()[:10])
    except ValueError:
        return None


def fetch_edutu():
    items, seen = [], set()
    for page in range(1, max(EDUTU_PAGES, 1) + 1):
        url = EDUTU_URL
        if EDUTU_PAGES > 1:
            url += ("&" if "?" in url else "?") + f"page={page}"
        fresh = []
        for it in extract_items(edutu_get(url)):
            if not isinstance(it, dict):
                continue
            key = as_text(pick(it, "id", "_id", "uuid", "slug"))
            if key in seen:
                continue
            seen.add(key)
            fresh.append(it)
        if not fresh:
            break
        items.extend(fresh)
    return items


def sync_opportunities():
    """Download from Edutu and upsert into the opportunities table."""
    items = fetch_edutu()
    saved = skipped = 0
    with db() as conn:
        for it in items:
            ext_id = as_text(pick(it, "id", "_id", "uuid", "slug"), 100)
            title = as_text(pick(it, "title", "name"), 300)
            if not ext_id or not title:
                skipped += 1
                continue
            conn.execute(
                """
                INSERT INTO opportunities
                    (external_id, title, organization, category, location,
                     description, deadline, url, raw, synced_at)
                VALUES (%s, %s, %s, %s, %s, %s, %s, %s, %s, now())
                ON CONFLICT (external_id) DO UPDATE SET
                    title = EXCLUDED.title, organization = EXCLUDED.organization,
                    category = EXCLUDED.category, location = EXCLUDED.location,
                    description = EXCLUDED.description, deadline = EXCLUDED.deadline,
                    url = EXCLUDED.url, raw = EXCLUDED.raw, synced_at = now()
                """,
                (
                    ext_id,
                    title,
                    as_text(pick(it, "organization", "organisation", "provider", "company", "host"), 200),
                    as_text(pick(it, "category", "type", "categories"), 100),
                    as_text(pick(it, "location", "country", "countries"), 200),
                    as_text(pick(it, "description", "summary", "details", "overview")),
                    parse_date(pick(it, "deadline", "closing_date", "closingDate", "end_date", "endDate", "expires_at")),
                    as_text(pick(it, "url", "link", "apply_url", "applyUrl", "applicationLink", "application_link"), 500),
                    Jsonb(it),
                ),
            )
            saved += 1
    if items and saved == 0:
        raise SyncError(
            f"The API returned {len(items)} items but none had an id and a title. "
            "Send a sample item to your developer/assistant so the field names can be mapped."
        )
    return {"found": len(items), "saved": saved, "skipped": skipped}


@app.get("/")
def home():
    return send_from_directory(".", "index.html")


@app.get("/<name>.html")
def page(name):
    return send_from_directory(".", f"{name}.html")


@app.get("/api/me")
def me():
    user = current_user()
    if not user:
        return jsonify(loggedIn=False)
    return jsonify(loggedIn=True, user={"name": user["name"], "role": user["role"]})


@app.post("/api/login")
def login():
    email = request.form.get("email", "").strip()
    password = request.form.get("password", "")
    with db() as conn:
        uid = conn.execute(
            "SELECT login_user(%s::varchar, %s::text) AS uid", (email, password)
        ).fetchone()["uid"]
    if uid is None:
        return fail("Invalid email or password.", 401)
    session["uid"] = uid
    user = current_user()
    return jsonify(ok=True, user={"name": user["name"], "role": user["role"]})


@app.post("/api/signup")
def signup():
    f = request.form
    values = [f.get(k, "").strip() for k in ("name", "username", "email")]
    password = f.get("password", "")
    role = f.get("role", "student")
    if not all(values) or not password or role not in ("student", "consultant"):
        return fail("Please fill in all fields.")
    try:
        with db() as conn:
            uid = conn.execute(
                "SELECT register_user(%s::varchar, %s::varchar, %s::varchar, %s::text, %s::user_role) AS uid",
                (*values, password, role),
            ).fetchone()["uid"]
    except psycopg.Error as e:
        print("SIGNUP ERROR:", e)
        return fail(f"Could not create the account: {e}")
    session["uid"] = uid
    return jsonify(ok=True)


@app.post("/api/logout")
def logout():
    session.clear()
    return jsonify(ok=True)


@app.get("/api/admin/countries")
def admin_countries():
    if not admin_user():
        return fail("Admin login required.", 403)
    with db() as conn:
        rows = conn.execute(
            "SELECT name, est_living_cost_year FROM countries ORDER BY name"
        ).fetchall()
    return jsonify(
        ok=True,
        countries=[{"name": r["name"], "living": float(r["est_living_cost_year"])} for r in rows],
    )


@app.post("/api/admin/university")
def admin_add_university():
    admin = admin_user()
    if not admin:
        return fail("Admin login required.", 403)
    d = request.get_json(silent=True) or {}
    try:
        name = clean_str(d.get("name"), "University name", 200, True)
        country = clean_str(d.get("country"), "Country", 80, True)
        city = clean_str(d.get("city"), "City", 100)
        description = clean_str(d.get("description"), "Description", 5000)
        notes = clean_str(d.get("admissionNotes"), "Admission notes", 5000)
        website = clean_str(d.get("website"), "Website", 300)
        if website and not website.lower().startswith(("http://", "https://")):
            raise ValueError("Website must start with http:// or https://")
        iso = clean_str(d.get("isoCode"), "ISO code", 2)
        living = clean_num(d.get("livingCost"), "Living cost", 0, 1e7)

        programs = []
        for p in d.get("programs") or []:
            programs.append({
                "major": clean_str(p.get("major"), "Program major", 120, True),
                "degree_level": clean_str(p.get("degreeLevel"), "Degree level", 30) or "Bachelor",
                "tuition_per_year": clean_num(p.get("tuition"), "Tuition per year", 0, 1e7, True),
                "min_gpa": clean_num(p.get("minGpa"), "Minimum GPA", 0, 4),
                "min_ielts": clean_num(p.get("minIelts"), "Minimum IELTS", 0, 9),
            })
        if not programs:
            raise ValueError("Add at least one program (major and tuition per year).")

        scholarships = []
        for s in d.get("scholarships") or []:
            deadline = clean_str(s.get("deadline"), "Deadline", 10)
            if deadline:
                try:
                    datetime.date.fromisoformat(deadline)
                except ValueError:
                    raise ValueError("Scholarship deadline must be a valid date (YYYY-MM-DD).")
            scholarships.append({
                "name": clean_str(s.get("name"), "Scholarship name", 200, True),
                "coverage": clean_str(s.get("coverage"), "Coverage", 100),
                "amount": clean_num(s.get("amount"), "Scholarship amount", 0, 1e9),
                "min_gpa": clean_num(s.get("minGpa"), "Scholarship minimum GPA", 0, 4),
                "deadline": deadline,
                "details": clean_str(s.get("details"), "Scholarship details", 2000),
            })
    except ValueError as e:
        return fail(str(e))
    except AttributeError:
        return fail("Invalid data.")

    try:
        with db() as conn:
            uid = conn.execute(
                "SELECT add_university(%s::bigint, %s::varchar, %s::varchar, %s::varchar, %s::text, "
                "%s::varchar, %s::boolean, %s::text, %s::jsonb, %s::jsonb, %s::varchar, %s::numeric) AS uid",
                (
                    admin["user_id"], name, country, city, description, website,
                    bool(d.get("partner")), notes, Jsonb(programs), Jsonb(scholarships), iso, living,
                ),
            ).fetchone()["uid"]
    except psycopg.errors.RaiseException as e:
        return fail(e.diag.message_primary or "Could not save the university.")
    except psycopg.errors.UniqueViolation:
        return fail("That university already exists in this country, or the same program is listed twice.")
    except psycopg.Error as e:
        print("ADD UNIVERSITY ERROR:", e)
        return fail(f"Could not save the university: {e}")
    return jsonify(ok=True, id=uid)


@app.get("/api/search")
def search():
    user = current_user()
    if not user or user["role"] != "student":
        return fail("Student login required.", 403)
    try:
        budget = number("budget", 0, 1e9)
        gpa = number("gpa", 0, 4)
        ielts = number("ielts", 0, 9)
    except ValueError:
        return fail("Budget, GPA or IELTS value is invalid.")
    with db() as conn:
        rows = conn.execute(
            "SELECT * FROM search_universities(%s::bigint, %s::varchar, %s::varchar, "
            "%s::numeric, %s::numeric, %s::numeric, %s::varchar) "
            "ORDER BY total_cost_year, avg_rating DESC",
            (user["user_id"], text("major"), text("country"), budget, gpa, ielts, text("keyword")),
        ).fetchall()
    results = [
        {
            "id": r["university_id"],
            "name": r["university"],
            "country": r["country"],
            "major": r["major"],
            "tuition": float(r["tuition_per_year"]),
            "total": float(r["total_cost_year"]),
            "partner": r["is_partner"],
            "scholarship": r["has_scholarship"],
            "rating": float(r["avg_rating"]),
        }
        for r in rows
    ]
    return jsonify(ok=True, results=results)


@app.get("/api/university")
def university():
    if not current_user():
        return fail("Please log in.", 401)
    try:
        uid = int(request.args.get("id", ""))
    except ValueError:
        return fail("Invalid university id.")
    with db() as conn:
        u = conn.execute(DETAIL_SQL, (uid,)).fetchone()
        if not u:
            return fail("University not found.", 404)
        programs = conn.execute(
            "SELECT major, degree_level, tuition_per_year, min_gpa, min_ielts "
            "FROM programs WHERE university_id = %s ORDER BY major",
            (uid,),
        ).fetchall()
        scholarships = conn.execute(
            "SELECT name, coverage, amount, deadline FROM scholarships WHERE university_id = %s ORDER BY name",
            (uid,),
        ).fetchall()
        reviews = conn.execute(
            "SELECT r.rating, r.comment, r.created_at, us.name AS author "
            "FROM university_reviews r JOIN users us ON us.user_id = r.student_id "
            "WHERE r.university_id = %s ORDER BY r.created_at DESC",
            (uid,),
        ).fetchall()
    return jsonify(
        ok=True,
        university={
            "id": u["university_id"],
            "name": u["name"],
            "city": u["city"],
            "country": u["country"],
            "partner": u["is_partner"],
            "description": u["description"],
            "website": u["website_url"] or "",
            "living": float(u["est_living_cost_year"]),
            "rating": float(u["avg_rating"]),
            "reviewCount": u["review_count"],
            "admissionNotes": u["admission_notes"],
        },
        programs=[program_line(p) for p in programs],
        scholarships=[scholarship_line(s) for s in scholarships],
        reviews=[
            {
                "rating": r["rating"],
                "author": r["author"],
                "date": r["created_at"].strftime("%Y-%m-%d"),
                "comment": r["comment"] or "",
            }
            for r in reviews
        ],
    )


@app.post("/api/review")
def review():
    user = current_user()
    if not user or user["role"] != "student":
        return fail("Only student accounts can leave reviews.", 403)
    try:
        university_id = int(request.form["university_id"])
        rating = int(request.form["rating"])
    except (KeyError, ValueError):
        return fail("Invalid review.")
    if not 1 <= rating <= 5:
        return fail("Rating must be between 1 and 5.")
    comment = request.form.get("comment", "").strip()[:1000] or None
    try:
        with db() as conn:
            conn.execute(
                "SELECT submit_review(%s::bigint, %s::bigint, %s::smallint, %s::text)",
                (user["user_id"], university_id, rating, comment),
            )
    except psycopg.Error:
        return fail("Could not save your review.")
    return jsonify(ok=True)


# =====================================================================
# Opportunities routes  (must stay ABOVE app.run)
# =====================================================================
@app.post("/api/admin/sync-opportunities")
def admin_sync_opportunities():
    if not admin_user():
        return fail("Admin login required.", 403)
    try:
        result = sync_opportunities()
    except SyncError as e:
        return fail(str(e), 502)
    return jsonify(ok=True, **result)


@app.get("/api/opportunities")
def opportunities():
    if not current_user():
        return fail("Please log in.", 401)
    q = text("q")
    category = text("category")
    try:
        page = max(int(request.args.get("page", 1)), 1)
    except ValueError:
        page = 1
    size = 12
    if q:  # treat % and _ typed by the user as plain characters
        q = q.replace("\\", "\\\\").replace("%", "\\%").replace("_", "\\_")

    sync_error = None
    with db() as conn:
        # first run: the table is empty, so fill it from Edutu automatically
        if conn.execute("SELECT 1 FROM opportunities LIMIT 1").fetchone() is None:
            try:
                sync_opportunities()
            except SyncError as e:
                sync_error = str(e)
                print("EDUTU SYNC ERROR:", sync_error)

        rows = conn.execute(
            """
            SELECT opportunity_id, title, organization, category, location,
                   description, deadline, url, COUNT(*) OVER() AS total
            FROM opportunities
            WHERE (%(q)s::text IS NULL OR title ILIKE '%%' || %(q)s || '%%'
                   OR organization ILIKE '%%' || %(q)s || '%%'
                   OR description ILIKE '%%' || %(q)s || '%%')
              AND (%(cat)s::text IS NULL OR category ILIKE %(cat)s)
            ORDER BY (deadline IS NULL), deadline, synced_at DESC
            LIMIT %(size)s OFFSET %(off)s
            """,
            {"q": q, "cat": category, "size": size, "off": (page - 1) * size},
        ).fetchall()
        categories = [
            r["category"]
            for r in conn.execute(
                "SELECT DISTINCT category FROM opportunities WHERE category IS NOT NULL ORDER BY category"
            ).fetchall()
        ]

    return jsonify(
        ok=True,
        page=page,
        pageSize=size,
        total=rows[0]["total"] if rows else 0,
        categories=categories,
        syncError=sync_error,
        results=[
            {
                "id": r["opportunity_id"],
                "title": r["title"],
                "organization": r["organization"],
                "category": r["category"],
                "location": r["location"],
                "description": r["description"],
                "deadline": r["deadline"].isoformat() if r["deadline"] else None,
                "url": r["url"],
            }
            for r in rows
        ],
    )


# =====================================================================
# Error handling: API routes always answer with JSON, so the pages can show
# the real problem instead of "Cannot reach the server."
# =====================================================================
@app.errorhandler(Exception)
def on_error(e):
    wants_json = request.path.startswith("/api/")
    if isinstance(e, HTTPException):
        return fail(e.description, e.code) if wants_json else e
    traceback.print_exc()  # full details stay in the terminal running server.py
    if not wants_json:
        return "Server error. Check the terminal running server.py.", 500
    if isinstance(e, psycopg.OperationalError):
        return fail("The database is not reachable. Is PostgreSQL running and is the password in DSN correct?", 503)
    if isinstance(e, psycopg.errors.UndefinedTable):
        return fail("A database table is missing. Re-run IMPAL_backend.sql in the scholarseek database.", 500)
    return fail(f"Server error ({type(e).__name__}). See the terminal running server.py.", 500)


if __name__ == "__main__":
    app.run(port=8080)
