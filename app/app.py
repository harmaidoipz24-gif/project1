# -*- coding: utf-8 -*-
"""
Демонстраційний інтерфейс стрімінгового відеосервісу (Python 3 + Streamlit + MySQL).
Параметри підключення беруться з файлу .env.
Усі запити до БД параметризовані; логіка доступу до відео виконується в БД
(процедури sp_start_playback, sp_update_progress, sp_subscribe).
"""
import hashlib
import hmac
import inspect
import math
import os
import secrets
from datetime import date
from pathlib import Path

import mysql.connector
import pandas as pd
import streamlit as st
from dotenv import load_dotenv

# Налаштування
APP_DIR = Path(__file__).resolve().parent
PROJECT_ROOT = APP_DIR.parent
load_dotenv(APP_DIR / ".env")
load_dotenv(PROJECT_ROOT / ".env")

DB_CONFIG = {
    "host": os.getenv("DB_HOST", "127.0.0.1"),
    "port": int(os.getenv("DB_PORT", "3306")),
    "user": os.getenv("DB_USER", "root"),
    "password": os.getenv("DB_PASSWORD", ""),
    "database": os.getenv("DB_NAME", "streaming_service"),
    "charset": "utf8mb4",
    "connection_timeout": 5,
}
QUALITIES = ["480p", "720p", "1080p", "4K"]

st.set_page_config(page_title="Стрімінговий відеосервіс", page_icon="🎬", layout="wide")


def _width_kwargs(func):
    """Параметр розтягування кнопки залежить від версії Streamlit: width='stretch' або use_container_width."""
    try:
        if "width" in inspect.signature(func).parameters:
            return {"width": "stretch"}
    except (TypeError, ValueError):
        pass
    return {"use_container_width": True}


BTN_KW = _width_kwargs(st.button)
FORM_BTN_KW = _width_kwargs(st.form_submit_button)
NAV_PAGES = ["Каталог", "Продовжити перегляд", "Звіти", "Мій акаунт"]


# Доступ до даних
def get_connection():
    """Нове підключення до MySQL (на кожну операцію, щоб уникнути застарілих зʼєднань)."""
    return mysql.connector.connect(**DB_CONFIG)


def run_query(sql, params=None):
    """SELECT: повертає список словників. Параметри передаються окремо від SQL."""
    conn = get_connection()
    try:
        cur = conn.cursor(dictionary=True)
        cur.execute(sql, params if params else None)
        rows = cur.fetchall()
        cur.close()
        return rows
    finally:
        conn.close()


def run_write(sql, params=None):
    """INSERT/UPDATE/DELETE з підтвердженням транзакції. Повертає lastrowid."""
    conn = get_connection()
    try:
        cur = conn.cursor()
        cur.execute(sql, params if params else None)
        conn.commit()
        last_id = cur.lastrowid
        cur.close()
        return last_id
    except mysql.connector.Error:
        conn.rollback()
        raise
    finally:
        conn.close()


def call_procedure(name, args):
    """Виклик збереженої процедури. Повертає список словників з першого набору результатів."""
    conn = get_connection()
    try:
        cur = conn.cursor()
        cur.callproc(name, args)
        result = []
        for res in cur.stored_results():
            cols = res.column_names
            result = [dict(zip(cols, row)) for row in res.fetchall()]
            break
        conn.commit()
        cur.close()
        return result
    except mysql.connector.Error:
        conn.rollback()
        raise
    finally:
        conn.close()


def check_connection():
    """Перевірка підключення; повертає (успіх, повідомлення)."""
    try:
        conn = get_connection()
        cur = conn.cursor()
        cur.execute("SELECT COUNT(*) FROM users")
        cur.fetchone()
        cur.close()
        conn.close()
        return True, ""
    except mysql.connector.Error as err:
        return False, str(err)


def get_user_by_email(email):
    rows = run_query(
        """SELECT user_id, email, password_hash, display_name, birth_date, country_code, registered_at, is_active
           FROM users WHERE email = %s""",
        (email,),
    )
    return rows[0] if rows else None


def get_user_by_id(user_id):
    rows = run_query(
        """SELECT user_id, email, display_name, birth_date, country_code, registered_at, is_active
           FROM users WHERE user_id = %s""",
        (user_id,),
    )
    return rows[0] if rows else None


def get_account_stats(user_id):
    rows = run_query(
        """SELECT COUNT(*) AS views,
                  CAST(COALESCE(SUM(completed), 0) AS UNSIGNED) AS completed_views,
                  CAST(COALESCE(SUM(last_position_sec), 0) AS UNSIGNED) AS total_sec
           FROM watch_history WHERE user_id = %s""",
        (user_id,),
    )
    return rows[0]


def get_subscription_history(user_id):
    return run_query(
        """SELECT sp.name AS plan_name, us.start_date, us.end_date, us.status, us.price_paid, us.credit_applied
           FROM user_subscriptions us
           JOIN subscription_plans sp ON sp.plan_id = us.plan_id
           WHERE us.user_id = %s
           ORDER BY us.start_date DESC""",
        (user_id,),
    )


def get_current_subscription(user_id):
    """Остання за датою закінчення підписка користувача (активна має пріоритет)."""
    rows = run_query(
        """
        SELECT sp.name AS plan_name, sp.max_quality, sp.max_screens, sp.has_ads,
               us.start_date, us.end_date, us.status,
               DATEDIFF(us.end_date, CURDATE()) AS days_left,
               (us.status = 'active' AND CURDATE() BETWEEN us.start_date AND us.end_date) AS is_valid
        FROM user_subscriptions us
        JOIN subscription_plans sp ON sp.plan_id = us.plan_id
        WHERE us.user_id = %s
        ORDER BY is_valid DESC, us.end_date DESC
        LIMIT 1
        """,
        (user_id,),
    )
    return rows[0] if rows else None


def get_genres():
    return run_query("SELECT genre_id, name FROM genres ORDER BY name")


def get_catalog(search, genre_id, content_type):
    """Каталог фільмів і серіалів з пошуком за назвою та фільтром за жанром."""
    like = f"%{search.strip()}%"
    parts = []
    params = []
    if content_type in ("Усе", "Фільми"):
        parts.append(
            """
            SELECT 'movie' AS content_type, m.movie_id AS content_id, m.title, m.release_year AS year,
                   m.rating, m.age_rating
            FROM movies m
            WHERE m.title LIKE %s
              AND (%s IS NULL OR EXISTS (
                    SELECT 1 FROM media_genres mg WHERE mg.movie_id = m.movie_id AND mg.genre_id = %s))
            """
        )
        params += [like, genre_id, genre_id]
    if content_type in ("Усе", "Серіали"):
        parts.append(
            """
            SELECT 'series' AS content_type, s.series_id AS content_id, s.title, s.start_year AS year,
                   s.rating, s.age_rating
            FROM tv_series s
            WHERE s.title LIKE %s
              AND (%s IS NULL OR EXISTS (
                    SELECT 1 FROM media_genres mg WHERE mg.series_id = s.series_id AND mg.genre_id = %s))
            """
        )
        params += [like, genre_id, genre_id]
    sql = " UNION ALL ".join(parts) + " ORDER BY title"
    return run_query(sql, tuple(params))


def get_movie(movie_id):
    rows = run_query(
        """SELECT movie_id, title, description, release_year AS year, duration_min, age_rating, rating,
                  trailer_url
           FROM movies WHERE movie_id = %s""",
        (movie_id,),
    )
    return rows[0] if rows else None


def get_series(series_id):
    rows = run_query(
        """SELECT series_id, title, description, start_year AS year, seasons_count, age_rating, rating
           FROM tv_series WHERE series_id = %s""",
        (series_id,),
    )
    return rows[0] if rows else None


def get_episodes(series_id):
    return run_query(
        """SELECT episode_id, season_number, episode_number, title, duration_min, description
           FROM episodes WHERE series_id = %s ORDER BY season_number, episode_number""",
        (series_id,),
    )


def get_title_genres(content_type, content_id):
    column = "movie_id" if content_type == "movie" else "series_id"
    # Назва стовпця береться лише з двох фіксованих значень, тому ін'єкція неможлива.
    rows = run_query(
        f"""SELECT g.name FROM media_genres mg JOIN genres g ON g.genre_id = mg.genre_id
            WHERE mg.{column} = %s ORDER BY g.name""",
        (content_id,),
    )
    return [r["name"] for r in rows]


def get_available_qualities(movie_id, episode_id):
    rows = run_query(
        """SELECT DISTINCT quality FROM video_files
           WHERE is_active = TRUE AND ((%s IS NOT NULL AND movie_id = %s) OR (%s IS NOT NULL AND episode_id = %s))""",
        (movie_id, movie_id, episode_id, episode_id),
    )
    return [r["quality"] for r in rows]


def get_continue_watching(user_id):
    """Незавершені перегляди користувача, від найновіших.

    Для кожного фільму чи епізоду береться лише останній за часом запис (у будь-якій якості).
    Незавершений = позиція не далі 90% тривалості. Ознака completed для цього не підходить:
    вона не скидається при повторному перегляді.
    """
    return run_query(
        """
        SELECT x.video_file_id, x.movie_id, x.episode_id, x.quality, x.last_position_sec,
               x.duration_sec, x.progress_pct, x.updated_at, x.title
        FROM (
            SELECT wh.video_file_id, vf.movie_id, vf.episode_id, vf.quality, wh.last_position_sec,
                   vf.duration_sec,
                   ROUND(100 * wh.last_position_sec / vf.duration_sec, 1) AS progress_pct,
                   wh.updated_at,
                   COALESCE(m.title,
                            CONCAT(s.title, ' S', LPAD(e.season_number, 2, '0'), 'E', LPAD(e.episode_number, 2, '0'),
                                   ' - ', e.title)) AS title,
                   ROW_NUMBER() OVER (PARTITION BY vf.movie_id, vf.episode_id
                                      ORDER BY wh.updated_at DESC, wh.history_id DESC) AS rn
            FROM watch_history wh
            JOIN video_files vf ON vf.video_file_id = wh.video_file_id
            LEFT JOIN movies m ON m.movie_id = vf.movie_id
            LEFT JOIN episodes e ON e.episode_id = vf.episode_id
            LEFT JOIN tv_series s ON s.series_id = e.series_id
            WHERE wh.user_id = %s
        ) AS x
        WHERE x.rn = 1 AND x.last_position_sec <= 0.9 * x.duration_sec
        ORDER BY x.updated_at DESC
        LIMIT 10
        """,
        (user_id,),
    )


def get_plans():
    return run_query(
        """SELECT plan_id, name, price_per_month, max_quality, max_screens, has_ads
           FROM subscription_plans ORDER BY price_per_month"""
    )


def hash_password(password):
    """Демонстраційне хешування PBKDF2-SHA256 із випадковою сіллю."""
    salt = secrets.token_hex(8)
    digest = hashlib.pbkdf2_hmac("sha256", password.encode("utf-8"), salt.encode("utf-8"), 100_000).hex()
    return f"pbkdf2${salt}${digest}"


def verify_password(password, stored):
    """Перевіряє пароль у форматі pbkdf2$сіль$хеш (так зберігаються і тестові, і нові користувачі).
    Порівняння виконується hmac.compare_digest - за сталий час, без витоку інформації через час відповіді.
    Гілка для SHA2-256 залишена для сумісності зі старими демонстраційними даними."""
    if stored.startswith("pbkdf2$"):
        try:
            _, salt, digest = stored.split("$")
        except ValueError:
            return False
        calc = hashlib.pbkdf2_hmac("sha256", password.encode("utf-8"), salt.encode("utf-8"), 100_000).hex()
        return hmac.compare_digest(calc, digest)
    calc = hashlib.sha256(password.encode("utf-8")).hexdigest()
    return hmac.compare_digest(calc, stored.lower())


def register_user(email, display_name, password, birth_date):
    return run_write(
        "INSERT INTO users (email, password_hash, display_name, birth_date) VALUES (%s, %s, %s, %s)",
        (email, hash_password(password), display_name, birth_date),
    )



# Допоміжні функції інтерфейсу
def show_db_error(err, prefix="Помилка бази даних"):
    msg = getattr(err, "msg", None) or str(err)
    st.error(f"{prefix}: {msg}")


def resolve_media(path_or_url):
    """Повертає (джерело, помилка): URL залишається, відносний шлях перевіряється на диску."""
    if not path_or_url:
        return None, "Посилання на файл відсутнє"
    if path_or_url.startswith(("http://", "https://")):
        return path_or_url, None
    full = (PROJECT_ROOT / path_or_url).resolve()
    if full.is_file():
        return str(full), None
    return None, f"Файл не знайдено: {path_or_url}."


def fmt_min(sec):
    """Секунди у вигляді хвилин: 754 -> '12.6 хв'."""
    return f"{int(sec) / 60:.1f} хв"


def set_page(name):
    st.session_state["page"] = name


def set_auth_mode(mode):
    st.session_state["auth_mode"] = mode


def open_title(content_type, content_id):
    st.session_state["selected"] = (content_type, content_id)
    st.session_state["page"] = "Тайтл"


def logout():
    for key in ("user_id", "playback", "selected", "flash"):
        st.session_state.pop(key, None)
    st.session_state["page"] = "Каталог"
    st.session_state["auth_mode"] = "login"


def login_user(user_id, page="Каталог"):
    st.session_state["user_id"] = user_id
    st.session_state["page"] = page
    st.session_state.pop("playback", None)


def start_playback(user_id, movie_id, episode_id, quality):
    """Викликає sp_start_playback і зберігає результат у стані сеансу."""
    try:
        rows = call_procedure("sp_start_playback", (user_id, movie_id, episode_id, quality))
    except mysql.connector.Error as err:
        st.session_state.pop("playback", None)
        show_db_error(err, "Відтворення неможливе")
        return
    if not rows:
        st.error("Процедура не повернула файл для відтворення.")
        return
    info = rows[0]
    info["user_id"] = user_id
    info["movie_id"] = movie_id
    info["episode_id"] = episode_id
    st.session_state["playback"] = info


def render_player(movie_id=None, episode_id=None, only_matching=False):
    """Відтворення відео та збереження прогресу для поточного сеансу відтворення.

    only_matching=True показує плеєр лише тоді, коли він запущений для відкритого зараз тайтла/епізоду.
    """
    info = st.session_state.get("playback")
    if not info:
        return
    if only_matching and (info.get("movie_id") != movie_id or info.get("episode_id") != episode_id):
        return
    st.divider()
    st.subheader("Відтворення")
    st.write(
        f"Файл: `{info['file_url']}`, якість {info['quality']}, формат {info['format']}, "
        f"тривалість {fmt_min(info['duration_sec'])}, початок з {fmt_min(info['last_position_sec'])}."
    )
    if info.get("age_rating"):
        st.caption(
            f"Віковий рейтинг: {info['age_rating']}. Одночасних екранів за тарифом: {info.get('max_screens', '-')}."
        )
    if info.get("has_ads"):
        st.info("Ваш тариф передбачає рекламу: у робочій системі плеєр показав би рекламні вставки.")
    source, error = resolve_media(info["file_url"])
    if error:
        st.warning(error)
    else:
        mime = "video/webm" if info["format"] == "webm" else "video/mp4"
        st.video(source, format=mime, start_time=int(info["last_position_sec"]))

    
    st.markdown("**Зберегти прогрес**")
    duration_min = int(info["duration_sec"]) / 60
    max_min = math.ceil(duration_min * 10) / 10
    start_min = min(round(int(info["last_position_sec"]) / 60, 1), max_min)
    position_min = st.number_input(
        "Позиція, хвилини",
        min_value=0.0,
        max_value=float(max_min),
        value=float(start_min),
        step=0.5,
        format="%.1f",
        key=f"pos_{info['video_file_id']}_{int(info['last_position_sec'])}",
    )
    if st.button("Зберегти прогрес", key=f"save_{info['video_file_id']}"):
        seconds = min(int(round(position_min * 60)), int(info["duration_sec"]))
        try:
            res = call_procedure("sp_update_progress", (info["user_id"], info["video_file_id"], seconds))
            if res:
                done = "так" if res[0]["completed"] else "ні"
                st.success(
                    f"Прогрес збережено: {fmt_min(res[0]['last_position_sec'])} з {fmt_min(info['duration_sec'])} "
                    f"({res[0]['progress_pct']}%), переглянуто повністю: {done}."
                )
        except mysql.connector.Error as err:
            show_db_error(err, "Не вдалося зберегти прогрес")


# Вхід і реєстрація
def page_auth():
    mode = st.session_state.get("auth_mode", "login")
    left, middle, right = st.columns([1, 2, 1])
    with middle:
        if mode == "login":
            st.header("Вхід в акаунт")
            with st.form("login_form"):
                email = st.text_input("Email")
                password = st.text_input("Пароль", type="password")
                submitted = st.form_submit_button("Увійти", type="primary", **FORM_BTN_KW)
            if submitted:
                try:
                    row = get_user_by_email(email.strip()) if email.strip() else None
                except mysql.connector.Error as err:
                    show_db_error(err, "Не вдалося виконати вхід")
                    row = None
                    st.stop()
                if not row or not verify_password(password, row["password_hash"]):
                    st.error("Невірний email або пароль.")
                elif not row["is_active"]:
                    st.error("Обліковий запис деактивовано.")
                else:
                    login_user(row["user_id"])
                    st.rerun()
        else:
            st.header("Реєстрація")
            with st.form("register_form"):
                email = st.text_input("Email")
                name = st.text_input("Імʼя")
                password = st.text_input("Пароль (щонайменше 6 символів)", type="password")
                password2 = st.text_input("Повторіть пароль", type="password")
                birth = st.date_input(
                    "Дата народження", value=date(2000, 1, 1), min_value=date(1920, 1, 1), max_value=date.today()
                )
                submitted = st.form_submit_button("Зареєструватися", type="primary", **FORM_BTN_KW)
            if submitted:
                email = email.strip()
                if "@" not in email or "." not in email.split("@")[-1]:
                    st.error("Введіть коректний email.")
                elif not name.strip():
                    st.error("Введіть імʼя.")
                elif len(password) < 6:
                    st.error("Пароль має містити щонайменше 6 символів.")
                elif password != password2:
                    st.error("Паролі не збігаються.")
                else:
                    try:
                        new_id = register_user(email, name.strip(), password, birth)
                    except mysql.connector.Error as err:
                        if getattr(err, "errno", None) == 1062:
                            st.error("Користувач із таким email уже існує.")
                        else:
                            show_db_error(err, "Не вдалося зареєструвати користувача")
                    else:
                        login_user(new_id, page="Мій акаунт")
                        st.session_state["flash"] = "Реєстрацію завершено. Оберіть тариф, щоб почати перегляд."
                        st.rerun()


# Сторінки
def page_catalog():
    st.header("Каталог")
    col1, col2, col3 = st.columns([3, 2, 2])
    search = col1.text_input("Пошук за назвою", "")
    genres = get_genres()
    genre_names = ["Усі жанри"] + [g["name"] for g in genres]
    genre_choice = col2.selectbox("Жанр", genre_names)
    content_type = col3.selectbox("Тип", ["Усе", "Фільми", "Серіали"])
    genre_id = None
    if genre_choice != "Усі жанри":
        genre_id = next(g["genre_id"] for g in genres if g["name"] == genre_choice)

    items = get_catalog(search, genre_id, content_type)
    if not items:
        st.info("Нічого не знайдено за цими умовами.")
        return
    st.caption(f"Знайдено: {len(items)}")
    per_row = 3
    for start in range(0, len(items), per_row):
        cols = st.columns(per_row)
        for col, item in zip(cols, items[start:start + per_row]):
            with col:
                with st.container(border=True):
                    kind = "Фільм" if item["content_type"] == "movie" else "Серіал"
                    rating = item["rating"] if item["rating"] is not None else "-"
                    st.markdown(f"**{item['title']}**")
                    st.caption(f"{kind}, {item['year']}, {item['age_rating']}, рейтинг {rating}")
                    st.button(
                        "Відкрити",
                        key=f"open_{item['content_type']}_{item['content_id']}",
                        on_click=open_title,
                        args=(item["content_type"], item["content_id"]),
                        **BTN_KW,
                    )


def page_title(user):
    st.button("Назад до каталогу", key="back_to_catalog", on_click=set_page, args=("Каталог",))
    selected = st.session_state.get("selected")
    if not selected:
        st.info("Оберіть фільм або серіал у каталозі.")
        return
    content_type, content_id = selected
    data = get_movie(content_id) if content_type == "movie" else get_series(content_id)
    if not data:
        st.error("Тайтл не знайдено.")
        return

    st.header(data["title"])
    genres = ", ".join(get_title_genres(content_type, content_id)) or "-"
    rating = data["rating"] if data["rating"] is not None else "-"
    if content_type == "movie":
        st.write(f"Фільм, {data['year']}, {data['duration_min']} хв, {data['age_rating']}, рейтинг {rating}")
    else:
        st.write(f"Серіал, з {data['year']} року, сезонів: {data['seasons_count']}, {data['age_rating']}, рейтинг {rating}")
    st.write(f"Жанри: {genres}")
    st.write(data["description"] or "")
    if content_type == "movie" and data.get("trailer_url"):
        st.markdown(f"[Трейлер]({data['trailer_url']})")

    movie_id = None
    episode_id = None
    if content_type == "movie":
        movie_id = content_id
    else:
        episodes = get_episodes(content_id)
        if not episodes:
            st.warning("Для цього серіалу ще немає епізодів.")
            return
        seasons = sorted({e["season_number"] for e in episodes})
        season = st.selectbox("Сезон", seasons)
        season_eps = [e for e in episodes if e["season_number"] == season]
        labels = [f"E{e['episode_number']:02d} - {e['title']} ({e['duration_min']} хв)" for e in season_eps]
        choice = st.selectbox("Епізод", labels)
        episode = season_eps[labels.index(choice)]
        st.caption(episode["description"] or "")
        episode_id = episode["episode_id"]

    available = get_available_qualities(movie_id, episode_id)
    st.caption("Доступні якості файлів: " + (", ".join(q for q in QUALITIES if q in available) or "немає"))
    sub = get_current_subscription(user["user_id"])
    default_quality = sub["max_quality"] if sub and sub["is_valid"] and sub["max_quality"] in QUALITIES else "720p"
    quality = st.selectbox("Якість", QUALITIES, index=QUALITIES.index(default_quality))

    if st.button("Дивитися", type="primary", key="watch_button"):
        start_playback(user["user_id"], movie_id, episode_id, quality)
    render_player(movie_id, episode_id, only_matching=True)


def page_continue(user):
    st.header("Продовжити перегляд")
    items = get_continue_watching(user["user_id"])
    if not items:
        st.info("Немає незавершених переглядів.")
    for item in items:
        with st.container(border=True):
            c1, c2, c3 = st.columns([4, 3, 2])
            c1.markdown(f"**{item['title']}**")
            c2.caption(
                f"{item['quality']}, зупинка на {fmt_min(item['last_position_sec'])} "
                f"з {fmt_min(item['duration_sec'])} ({item['progress_pct']}%)"
            )
            if c3.button("Продовжити", key=f"continue_{item['video_file_id']}", **BTN_KW):
                start_playback(user["user_id"], item["movie_id"], item["episode_id"], item["quality"])
    render_player()


REPORT_TOP = """
SELECT t.content_type,
       t.title,
       t.views,
       t.viewers,
       t.completed_views
FROM (
    SELECT 'movie' AS content_type,
           m.title AS title,
           COUNT(DISTINCT wh.user_id) AS views,
           COUNT(DISTINCT wh.user_id) AS viewers,
           COUNT(DISTINCT CASE WHEN wh.completed = TRUE THEN wh.user_id END) AS completed_views
    FROM movies m
    JOIN video_files vf ON vf.movie_id = m.movie_id
    JOIN watch_history wh ON wh.video_file_id = vf.video_file_id
    GROUP BY m.movie_id, m.title
    UNION ALL
    SELECT 'series' AS content_type,
           s.title AS title,
           COUNT(DISTINCT wh.user_id, e.episode_id) AS views,
           COUNT(DISTINCT wh.user_id) AS viewers,
           COUNT(DISTINCT CASE WHEN wh.completed = TRUE THEN wh.user_id END,
                          CASE WHEN wh.completed = TRUE THEN e.episode_id END) AS completed_views
    FROM tv_series s
    JOIN episodes e ON e.series_id = s.series_id
    JOIN video_files vf ON vf.episode_id = e.episode_id
    JOIN watch_history wh ON wh.video_file_id = vf.video_file_id
    GROUP BY s.series_id, s.title
) AS t
ORDER BY t.views DESC, t.viewers DESC, t.title
LIMIT 10
"""

REPORT_SUBSCRIPTIONS = """
SELECT u.user_id, u.display_name, sp.name AS plan_name, us.start_date, us.end_date, us.status,
       DATEDIFF(us.end_date, CURDATE()) AS days_left,
       CASE
           WHEN us.status = 'cancelled' THEN 'Скасована'
           WHEN us.status = 'expired' OR us.end_date < CURDATE() THEN 'Прострочена'
           WHEN DATEDIFF(us.end_date, CURDATE()) <= 7 THEN 'Спливає протягом 7 днів'
           ELSE 'Активна'
       END AS state_label
FROM user_subscriptions us
JOIN users u ON u.user_id = us.user_id
JOIN subscription_plans sp ON sp.plan_id = us.plan_id
ORDER BY us.end_date DESC
"""

REPORT_GENRES = """
SELECT g.name AS genre,
       COUNT(*) AS views,
       ROUND(100 * COUNT(*) / (SELECT COUNT(*) FROM v_content_views), 2) AS percent_of_all_views,
       RANK() OVER (ORDER BY COUNT(*) DESC) AS popularity_rank
FROM (
    SELECT mg.genre_id
    FROM v_content_views cv
    JOIN media_genres mg ON mg.movie_id = cv.movie_id
    UNION ALL
    SELECT mg.genre_id
    FROM v_content_views cv
    JOIN media_genres mg ON mg.series_id = cv.series_id
) AS x
JOIN genres g ON g.genre_id = x.genre_id
GROUP BY g.genre_id, g.name
ORDER BY views DESC, g.name
"""

REPORT_PROGRESS = """
WITH episode_totals AS (
    SELECT series_id, COUNT(*) AS total_episodes
    FROM episodes
    GROUP BY series_id
),
user_series AS (
    SELECT cv.user_id,
           cv.series_id,
           COUNT(*) AS episodes_started,
           SUM(cv.completed) AS episodes_completed
    FROM v_content_views cv
    WHERE cv.content_type = 'series'
    GROUP BY cv.user_id, cv.series_id
    HAVING COUNT(*) >= 2
)
SELECT u.display_name,
       s.title AS series_title,
       us.episodes_started,
       us.episodes_completed,
       et.total_episodes,
       ROUND(100 * us.episodes_completed / et.total_episodes, 1) AS progress_pct
FROM user_series us
JOIN episode_totals et ON et.series_id = us.series_id
JOIN users u ON u.user_id = us.user_id
JOIN tv_series s ON s.series_id = us.series_id
ORDER BY progress_pct DESC, u.display_name
"""

REPORT_REVENUE = """
SELECT r.month_label, r.plan_label, r.revenue, r.purchases
FROM (
    SELECT IF(GROUPING(t.ym) = 1, 'ВСЬОГО', t.ym) AS month_label,
           IF(GROUPING(t.plan_name) = 1, 'Усі тарифи', t.plan_name) AS plan_label,
           SUM(t.price_paid) AS revenue, COUNT(*) AS purchases
    FROM (
        SELECT DATE_FORMAT(us.start_date, '%Y-%m') AS ym, sp.name AS plan_name, us.price_paid
        FROM user_subscriptions us
        JOIN subscription_plans sp ON sp.plan_id = us.plan_id
    ) AS t
    GROUP BY t.ym, t.plan_name WITH ROLLUP
) AS r
ORDER BY (r.month_label = 'ВСЬОГО'), r.month_label, (r.plan_label = 'Усі тарифи'), r.plan_label
"""


def to_frame(rows):
    df = pd.DataFrame(rows)
    for col in df.columns:
        if df[col].dtype == object:
            try:
                df[col] = pd.to_numeric(df[col])
            except (ValueError, TypeError):
                pass
    return df


def page_reports():
    st.header("Звіти")
    try:
        st.subheader("Топ-10 найпопулярніших фільмів і серіалів")
        top = to_frame(run_query(REPORT_TOP))
        st.dataframe(top, hide_index=True)
        if not top.empty:
            st.bar_chart(top.set_index("title")["views"])

        st.subheader("Стан підписок")
        st.dataframe(to_frame(run_query(REPORT_SUBSCRIPTIONS)), hide_index=True)

        st.subheader("Популярність жанрів, % від усіх переглядів")
        genres = to_frame(run_query(REPORT_GENRES))
        st.dataframe(genres, hide_index=True)
        if not genres.empty:
            st.bar_chart(genres.set_index("genre")["percent_of_all_views"])
        st.caption("Контент може мати кілька жанрів, тому сума відсотків може перевищувати 100.")

        st.subheader("Прогрес перегляду серіалів")
        st.dataframe(to_frame(run_query(REPORT_PROGRESS)), hide_index=True)

        st.subheader("Дохід за тарифами по місяцях")
        revenue = to_frame(run_query(REPORT_REVENUE))
        st.dataframe(revenue, hide_index=True)
        detail = revenue[(revenue["month_label"] != "ВСЬОГО") & (revenue["plan_label"] != "Усі тарифи")] if not revenue.empty else revenue
        if not detail.empty:
            pivot = detail.pivot_table(index="month_label", columns="plan_label", values="revenue", aggfunc="sum").fillna(0)
            st.bar_chart(pivot)
    except mysql.connector.Error as err:
        show_db_error(err, "Не вдалося побудувати звіт")


def page_account(user):
    st.header("Мій акаунт")
    flash = st.session_state.pop("flash", None)
    if flash:
        st.success(flash)

    sub = get_current_subscription(user["user_id"])
    stats = get_account_stats(user["user_id"])

    col_a, col_b = st.columns(2)
    with col_a:
        with st.container(border=True):
            st.subheader("Дані акаунта")
            birth = user["birth_date"].strftime("%d.%m.%Y") if user["birth_date"] else "не вказано"
            st.markdown(
                f"**Імʼя:** {user['display_name']}  \n"
                f"**Email:** {user['email']}  \n"
                f"**Дата народження:** {birth}  \n"
                f"**Країна:** {user['country_code']}  \n"
                f"**Зареєстровано:** {user['registered_at'].strftime('%d.%m.%Y %H:%M')}"
            )
    with col_b:
        with st.container(border=True):
            st.subheader("Поточна підписка")
            if not sub:
                st.warning("Підписки немає. Оберіть тариф нижче.")
            else:
                state = "активна" if sub["is_valid"] else "недійсна"
                st.markdown(
                    f"**Тариф:** {sub['plan_name']} ({state})  \n"
                    f"**Якість:** до {sub['max_quality']}, екранів: {sub['max_screens']}, "
                    f"реклама: {'так' if sub['has_ads'] else 'ні'}  \n"
                    f"**Період:** {sub['start_date'].strftime('%d.%m.%Y')} - {sub['end_date'].strftime('%d.%m.%Y')}  \n"
                    + (f"**Залишилось днів:** {sub['days_left']}" if sub["is_valid"] else f"**Статус:** {sub['status']}")
                )

    m1, m2, m3 = st.columns(3)
    m1.metric("Переглядів", int(stats["views"]))
    m2.metric("Переглянуто повністю", int(stats["completed_views"]))
    m3.metric("Загальний час перегляду, хв", round(int(stats["total_sec"]) / 60))

    history = get_subscription_history(user["user_id"])
    if history:
        with st.expander("Історія підписок"):
            df = pd.DataFrame(history).rename(
                columns={
                    "plan_name": "Тариф",
                    "start_date": "Початок",
                    "end_date": "Кінець",
                    "status": "Статус",
                    "price_paid": "Сплачено, грн",
                    "credit_applied": "Зараховано, грн",
                }
            )
            st.dataframe(df, hide_index=True)

    st.subheader("Оформити або змінити підписку")
    plans = get_plans()
    labels = [f"{p['name']} - {p['price_per_month']} грн/міс, до {p['max_quality']}" for p in plans]
    with st.form("subscribe_form"):
        choice = st.selectbox("Тариф", labels)
        months = st.number_input("Кількість місяців", min_value=1, max_value=12, value=1, step=1)
        submitted = st.form_submit_button("Оформити підписку", type="primary")
    if submitted:
        plan = plans[labels.index(choice)]
        try:
            res = call_procedure("sp_subscribe", (user["user_id"], plan["plan_id"], int(months)))
            if res:
                credit = res[0].get("credit_applied") or 0
                note = f" (зараховано {credit} грн за невикористані дні попередньої підписки)" if credit else ""
                st.session_state["flash"] = (
                    f"Підписку оформлено: {res[0]['plan_name']}, {res[0]['start_date']} - {res[0]['end_date']}, "
                    f"до сплати {res[0]['price_paid']} грн{note}."
                )
                st.rerun()
        except mysql.connector.Error as err:
            show_db_error(err, "Не вдалося оформити підписку")


# Бічна панель та головна функція
def current_user():
    user_id = st.session_state.get("user_id")
    if user_id is None:
        return None
    user = get_user_by_id(user_id)
    if not user or not user["is_active"]:
        logout()
        return None
    return user


def render_sidebar(user):
    if user is None:
        st.header("Вхід")
        mode = st.session_state.get("auth_mode", "login")
        st.button("Увійти", key="side_login", on_click=set_auth_mode, args=("login",),
                  type="primary" if mode == "login" else "secondary", **BTN_KW)
        st.button("Зареєструватися", key="side_register", on_click=set_auth_mode, args=("register",),
                  type="primary" if mode == "register" else "secondary", **BTN_KW)
        return

    st.subheader(user["display_name"])
    st.caption(user["email"])
    try:
        sub = get_current_subscription(user["user_id"])
    except mysql.connector.Error as err:
        show_db_error(err)
        sub = None
    if sub and sub["is_valid"]:
        st.success(f"Тариф: {sub['plan_name']} (до {sub['max_quality']})\n\nДіє до {sub['end_date']}, залишилось днів: {sub['days_left']}")
    elif sub:
        st.error(f"Підписка недійсна: {sub['plan_name']}, статус {sub['status']}, закінчилась {sub['end_date']}")
    else:
        st.warning("Підписки немає")

    st.divider()
    current = st.session_state.get("page", "Каталог")
    active = "Каталог" if current == "Тайтл" else current
    for name in NAV_PAGES:
        st.button(name, key=f"nav_{name}", on_click=set_page, args=(name,),
                  type="primary" if name == active else "secondary", **BTN_KW)
    st.divider()
    st.button("Вийти", key="logout_button", on_click=logout, **BTN_KW)


def main():
    st.title("🎬 Стрімінговий відеосервіс")

    ok, message = check_connection()
    if not ok:
        st.error(
            "Не вдалося підключитися до MySQL. Перевірте, що сервер запущено, виконано SQL-файли "
            "та налаштовано файл .env (див. app/.env.example)."
        )
        st.code(message)
        st.stop()

    try:
        user = current_user()
    except mysql.connector.Error as err:
        show_db_error(err, "Не вдалося завантажити користувача")
        st.stop()

    with st.sidebar:
        render_sidebar(user)

    if user is None:
        page_auth()
        return

    page = st.session_state.get("page", "Каталог")
    try:
        if page == "Каталог":
            page_catalog()
        elif page == "Тайтл":
            page_title(user)
        elif page == "Продовжити перегляд":
            page_continue(user)
        elif page == "Звіти":
            page_reports()
        else:
            page_account(user)
    except mysql.connector.Error as err:
        show_db_error(err)


main()
