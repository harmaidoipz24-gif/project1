-- =====================================================================
-- sql/04_queries.sql - представлення (VIEW) та складні аналітичні запити
-- Виконувати після 01_schema.sql та 02_seed.sql.
-- "Перегляд" у звітах = пара користувач + фільм або користувач + епізод,
-- незалежно від того, у скількох якостях (файлах) його дивились.
-- Тому зміна якості під час перегляду не подвоює статистику.
-- =====================================================================
USE streaming_service;

-- ---------------------------------------------------------------------
-- VIEW 0 (допоміжне): v_watch_facts - перегляди з назвою контенту.
-- Для фільму заповнено movie_id, для епізоду - series_id та episode_id.
-- ---------------------------------------------------------------------
CREATE OR REPLACE VIEW v_watch_facts AS
SELECT wh.history_id,
       wh.user_id,
       wh.video_file_id,
       wh.started_at,
       wh.updated_at,
       wh.last_position_sec,
       wh.completed,
       vf.quality,
       vf.duration_sec,
       CASE WHEN vf.movie_id IS NOT NULL THEN 'movie' ELSE 'series' END AS content_type,
       m.movie_id,
       s.series_id,
       e.episode_id,
       e.season_number,
       e.episode_number,
       COALESCE(m.title, s.title) AS title
FROM watch_history wh
JOIN video_files vf ON vf.video_file_id = wh.video_file_id
LEFT JOIN movies m ON m.movie_id = vf.movie_id
LEFT JOIN episodes e ON e.episode_id = vf.episode_id
LEFT JOIN tv_series s ON s.series_id = e.series_id;

-- ---------------------------------------------------------------------
-- VIEW 0а (допоміжне): v_content_views - один рядок на пару користувач + контент
-- (фільм або епізод). Записи watch_history різних якостей одного контенту
-- обʼєднуються: completed = 1, якщо хоча б один файл переглянуто понад 90%;
-- progress_pct = 100 для завершених, інакше найбільший досягнутий відсоток.
-- ---------------------------------------------------------------------
CREATE OR REPLACE VIEW v_content_views AS
SELECT f.user_id,
       f.content_type,
       f.movie_id,
       f.series_id,
       f.episode_id,
       f.title,
       MAX(f.completed) AS completed,
       CASE WHEN MAX(f.completed) = 1 THEN 100.0
            ELSE MAX(ROUND(100 * f.last_position_sec / f.duration_sec, 1))
       END AS progress_pct,
       COUNT(*) AS files_used,
       MIN(f.started_at) AS first_started_at,
       MAX(f.updated_at) AS last_updated_at
FROM v_watch_facts f
GROUP BY f.user_id, f.content_type, f.movie_id, f.series_id, f.episode_id, f.title;

-- ---------------------------------------------------------------------
-- VIEW 1: v_subscription_overview - поточний стан кожної підписки.
-- Бізнес-завдання: служба підтримки та маркетинг бачать, хто активний,
-- у кого підписка прострочена або скоро спливає.
-- ---------------------------------------------------------------------
CREATE OR REPLACE VIEW v_subscription_overview AS
SELECT us.subscription_id,
       u.user_id,
       u.email,
       u.display_name,
       sp.name AS plan_name,
       sp.max_quality,
       us.start_date,
       us.end_date,
       us.status,
       us.price_paid,
       DATEDIFF(us.end_date, CURDATE()) AS days_left,
       CASE
           WHEN us.status = 'cancelled' THEN 'Скасована'
           WHEN us.status = 'expired' OR us.end_date < CURDATE() THEN 'Прострочена'
           WHEN DATEDIFF(us.end_date, CURDATE()) <= 7 THEN 'Спливає протягом 7 днів'
           ELSE 'Активна'
       END AS state_label
FROM user_subscriptions us
JOIN users u ON u.user_id = us.user_id
JOIN subscription_plans sp ON sp.plan_id = us.plan_id;

-- ---------------------------------------------------------------------
-- VIEW 2: v_title_stats - статистика переглядів за тайтлами (фільми та серіали).
-- Бізнес-завдання: контент-менеджер оцінює популярність та завершуваність.
-- ---------------------------------------------------------------------
CREATE OR REPLACE VIEW v_title_stats AS
-- Для фільму views = viewers (один перегляд на користувача), для серіалу
-- views - кількість пар користувач + епізод.
SELECT cv.content_type,
       COALESCE(cv.movie_id, cv.series_id) AS content_id,
       cv.title,
       COUNT(*) AS views,
       COUNT(DISTINCT cv.user_id) AS viewers,
       SUM(cv.completed) AS completed_views,
       ROUND(AVG(cv.progress_pct), 1) AS avg_progress_pct
FROM v_content_views cv
GROUP BY cv.content_type, cv.movie_id, cv.series_id, cv.title;

-- =====================================================================
-- ЗАПИТ А. Топ-10 найпопулярніших фільмів і серіалів за переглядами
-- Бізнес-завдання: визначити контент, який варто просувати на головній сторінці.
-- Перегляд фільму = користувач + фільм; перегляд серіалу = користувач + епізод
-- (перегляди всіх епізодів серіалу сумуються). Кілька якостей одного контенту
-- одним користувачем рахуються як один перегляд (COUNT DISTINCT).
-- Техніки: JOIN, GROUP BY, COUNT(DISTINCT ...), UNION ALL, ORDER BY, LIMIT.
-- =====================================================================
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
LIMIT 10;

-- =====================================================================
-- ЗАПИТ Б. Стан підписок: активні, прострочені, такі що спливають за 7 днів
-- Бізнес-завдання: розсилка нагадань про продовження та облік відтоку.
-- Техніки: JOIN, CASE, DATEDIFF.
-- =====================================================================
SELECT u.user_id,
       u.display_name,
       sp.name AS plan_name,
       us.start_date,
       us.end_date,
       us.status,
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
ORDER BY FIELD(
             CASE
                 WHEN us.status = 'cancelled' THEN 'Скасована'
                 WHEN us.status = 'expired' OR us.end_date < CURDATE() THEN 'Прострочена'
                 WHEN DATEDIFF(us.end_date, CURDATE()) <= 7 THEN 'Спливає протягом 7 днів'
                 ELSE 'Активна'
             END,
             'Спливає протягом 7 днів', 'Активна', 'Прострочена', 'Скасована'),
         days_left;

-- Зведення за станами (на основі VIEW)
SELECT state_label, COUNT(*) AS subscriptions
FROM v_subscription_overview
GROUP BY state_label
ORDER BY subscriptions DESC;

-- =====================================================================
-- ЗАПИТ В. Популярність жанрів у відсотках від усіх переглядів
-- Бізнес-завдання: зрозуміти, які жанри купувати або знімати.
-- Контент може мати кілька жанрів, тому сума відсотків може перевищувати 100.
-- Звʼязок з жанрами зроблено двома окремими JOIN (для фільмів і для серіалів) через
-- UNION ALL замість одного JOIN ... ON a OR b: так кожна частина використовує свій
-- індекс (uq_mg_movie_genre / uq_mg_series_genre).
-- Техніки: JOIN, UNION ALL у похідній таблиці, GROUP BY, скалярний підзапит, RANK().
-- =====================================================================
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
ORDER BY views DESC, g.name;

-- =====================================================================
-- ЗАПИТ Г. Прогрес перегляду серіалу кожним користувачем у відсотках
-- Бізнес-завдання: персональні рекомендації "Дивитися далі" та виявлення
-- користувачів, які покинули серіал. Прогрес = завершені епізоди / усі епізоди серіалу.
-- Техніки: CTE, GROUP BY, HAVING (враховуються користувачі, які почали щонайменше 2 епізоди).
-- =====================================================================
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
ORDER BY progress_pct DESC, u.display_name;

-- =====================================================================
-- ЗАПИТ Д. Дохід за тарифами по місяцях з підсумками
-- Бізнес-завдання: фінансовий звіт. Дохід відносимо до місяця початку підписки
-- (за сумою price_paid - фактично сплаченою сумою; підписки не видаляються разом
-- з користувачем, тому звіт за минулі місяці не змінюється заднім числом). Рядки 'Усі тарифи' - підсумок за місяць,
-- рядок 'ВСЬОГО' - загальний підсумок.
-- Техніки: SUM, GROUP BY ... WITH ROLLUP, GROUPING().
-- =====================================================================
SELECT r.month_label, r.plan_label, r.revenue, r.purchases
FROM (
    SELECT IF(GROUPING(t.ym) = 1, 'ВСЬОГО', t.ym) AS month_label,
           IF(GROUPING(t.plan_name) = 1, 'Усі тарифи', t.plan_name) AS plan_label,
           SUM(t.price_paid) AS revenue,
           COUNT(*) AS purchases
    FROM (
        SELECT DATE_FORMAT(us.start_date, '%Y-%m') AS ym,
               sp.name AS plan_name,
               us.price_paid
        FROM user_subscriptions us
        JOIN subscription_plans sp ON sp.plan_id = us.plan_id
    ) AS t
    GROUP BY t.ym, t.plan_name WITH ROLLUP
) AS r
ORDER BY (r.month_label = 'ВСЬОГО'), r.month_label, (r.plan_label = 'Усі тарифи'), r.plan_label;

-- Додатковий варіант запиту Д: накопичувальний дохід за місяцями (віконні функції)
SELECT m.ym AS month_label,
       m.revenue,
       SUM(m.revenue) OVER (ORDER BY m.ym) AS cumulative_revenue
FROM (
    SELECT DATE_FORMAT(start_date, '%Y-%m') AS ym, SUM(price_paid) AS revenue
    FROM user_subscriptions
    GROUP BY DATE_FORMAT(start_date, '%Y-%m')
) AS m
ORDER BY m.ym;
