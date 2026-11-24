
USE streaming_service;
-- Workbench за замовчуванням вмикає safe updates; розділ Z видаляє рядки без WHERE.
SET SQL_SAFE_UPDATES = 0;

-- A. Структура та кількість рядків
SHOW TABLES;

SELECT 'users' AS table_name, COUNT(*) AS row_count FROM users
UNION ALL SELECT 'subscription_plans', COUNT(*) FROM subscription_plans
UNION ALL SELECT 'user_subscriptions', COUNT(*) FROM user_subscriptions
UNION ALL SELECT 'genres', COUNT(*) FROM genres
UNION ALL SELECT 'movies', COUNT(*) FROM movies
UNION ALL SELECT 'tv_series', COUNT(*) FROM tv_series
UNION ALL SELECT 'episodes', COUNT(*) FROM episodes
UNION ALL SELECT 'media_genres', COUNT(*) FROM media_genres
UNION ALL SELECT 'video_files', COUNT(*) FROM video_files
UNION ALL SELECT 'subtitles', COUNT(*) FROM subtitles
UNION ALL SELECT 'watch_history', COUNT(*) FROM watch_history;

-- B. Узгодженість даних (кожен запит має повернути 0 рядків)
-- B1. Файли, привʼязані не рівно до одного обʼєкта
SELECT video_file_id FROM video_files
WHERE (movie_id IS NULL) = (episode_id IS NULL);

-- B2. Файли, тривалість яких відрізняється від тривалості контенту більш ніж на 60 с
SELECT vf.video_file_id, vf.duration_sec
FROM video_files vf
LEFT JOIN movies m ON m.movie_id = vf.movie_id
LEFT JOIN episodes e ON e.episode_id = vf.episode_id
WHERE ABS(CAST(vf.duration_sec AS SIGNED)
          - CAST(COALESCE(m.duration_min, e.duration_min) AS SIGNED) * 60) > 60;

-- B3. Позиції перегляду, що перевищують тривалість файлу
SELECT wh.history_id FROM watch_history wh
JOIN video_files vf ON vf.video_file_id = wh.video_file_id
WHERE wh.last_position_sec > vf.duration_sec;

-- B4. Позиція понад 90%, але ознака completed не встановлена
--     (зворотне допустиме: completed = TRUE і мала позиція - це повторний перегляд)
SELECT wh.history_id FROM watch_history wh
JOIN video_files vf ON vf.video_file_id = wh.video_file_id
WHERE wh.completed = FALSE AND wh.last_position_sec > 0.9 * vf.duration_sec;

-- B5. Кількість сезонів серіалу не збігається з максимальним номером сезону епізодів
--     (серіал без епізодів має мати 0 сезонів)
SELECT s.series_id, s.seasons_count, COALESCE(x.mx, 0) AS expected
FROM tv_series s
LEFT JOIN (SELECT series_id, MAX(season_number) AS mx FROM episodes GROUP BY series_id) x
       ON x.series_id = s.series_id
WHERE s.seasons_count <> COALESCE(x.mx, 0);

-- B6. Підписки з некоректними датами
SELECT subscription_id FROM user_subscriptions WHERE end_date < start_date;

-- B7. Активні підписки одного користувача, періоди яких перетинаються
--     (кілька активних без перетину допустимі: це продовження, див. sp_subscribe)
SELECT a.user_id, a.subscription_id, b.subscription_id
FROM user_subscriptions a
JOIN user_subscriptions b
  ON b.user_id = a.user_id AND b.subscription_id > a.subscription_id
WHERE a.status = 'active' AND b.status = 'active'
  AND a.start_date <= b.end_date AND a.end_date >= b.start_date;

-- ---------------------------------------------------------------------
-- C. Навмисні порушення обмежень (кожен оператор ОЧІКУЄТЬСЯ ПОМИЛКА)
-- ---------------------------------------------------------------------
-- C1. Дубль email (UNIQUE)                                    ОЧІКУЄТЬСЯ ПОМИЛКА 1062
INSERT INTO users (email, password_hash, display_name)
VALUES ('olena.kovalenko@example.com', 'x', 'Дубль');

-- C2. Рейтинг 15 (CHECK 0-10)                                  ОЧІКУЄТЬСЯ ПОМИЛКА 3819
INSERT INTO movies (title, release_year, duration_min, rating) VALUES ('Помилковий рейтинг', 2020, 90, 15);

-- C3. Тривалість 0 (CHECK > 0)                                 ОЧІКУЄТЬСЯ ПОМИЛКА 3819
INSERT INTO movies (title, release_year, duration_min, rating) VALUES ('Нульова тривалість', 2020, 0, 5);

-- C4. Файл без movie_id і без episode_id (CHECK)               ОЧІКУЄТЬСЯ ПОМИЛКА 3819
INSERT INTO video_files (movie_id, episode_id, file_url, quality, duration_sec, file_size_mb)
VALUES (NULL, NULL, 'media/orphan.mp4', '720p', 600, 100);

-- C5. Файл і з movie_id, і з episode_id (CHECK)                ОЧІКУЄТЬСЯ ПОМИЛКА 3819
INSERT INTO video_files (movie_id, episode_id, file_url, quality, duration_sec, file_size_mb)
VALUES (1, 1, 'media/both.mp4', '720p', 600, 100);

-- C6. Кінець підписки раніше за початок (CHECK)                ОЧІКУЄТЬСЯ ПОМИЛКА 3819
INSERT INTO user_subscriptions (user_id, plan_id, start_date, end_date, status, price_paid)
VALUES (10, 1, CURDATE(), DATE_SUB(CURDATE(), INTERVAL 1 DAY), 'active', 0);

-- C7. Від'ємна ціна тарифу (CHECK >= 0)                        ОЧІКУЄТЬСЯ ПОМИЛКА 3819
INSERT INTO subscription_plans (name, price_per_month, max_quality, max_screens) VALUES ('Мінусовий', -1, '480p', 1);

-- C8. Неіснуючий користувач у історії (FK)                     ОЧІКУЄТЬСЯ ПОМИЛКА 1452
INSERT INTO watch_history (user_id, video_file_id) VALUES (9999, 1);

-- C9. Дубль пари користувач + файл (UNIQUE)                    ОЧІКУЄТЬСЯ ПОМИЛКА 1062
INSERT INTO watch_history (user_id, video_file_id) SELECT user_id, video_file_id FROM watch_history LIMIT 1;

-- C10. Позиція більша за тривалість (тригер)                   ОЧІКУЄТЬСЯ ПОМИЛКА 1644
UPDATE watch_history SET last_position_sec = 999999 WHERE history_id = 1;

-- C11. Друга активна підписка з перетином періодів (тригер)    ОЧІКУЄТЬСЯ ПОМИЛКА 1644
INSERT INTO user_subscriptions (user_id, plan_id, start_date, end_date, status, price_paid)
VALUES (2, 1, CURDATE(), DATE_ADD(CURDATE(), INTERVAL 5 DAY), 'active', 0);

-- C12. Видалення фільму з файлами (FK RESTRICT)                ОЧІКУЄТЬСЯ ПОМИЛКА 1451
DELETE FROM movies WHERE movie_id = 1;

-- C13. Видалення користувача з підписками (FK RESTRICT,
--      фінансова історія зберігається)                          ОЧІКУЄТЬСЯ ПОМИЛКА 1451
DELETE FROM users WHERE user_id = 1;

-- C14. Видалення відеофайлу, який уже переглядали (FK RESTRICT,
--      статистика зберігається)                                 ОЧІКУЄТЬСЯ ПОМИЛКА 1451
DELETE FROM video_files WHERE video_file_id = 3;

-- C15. Дата народження в майбутньому (тригер)                  ОЧІКУЄТЬСЯ ПОМИЛКА 1644
INSERT INTO users (email, password_hash, display_name, birth_date)
VALUES ('future.baby@example.com', 'x', 'Майбутній', DATE_ADD(CURDATE(), INTERVAL 1 YEAR));

-- C16. Підписка без суми оплати (price_paid без значення
--      за замовчуванням, строгий режим MySQL)                   ОЧІКУЄТЬСЯ ПОМИЛКА 1364
INSERT INTO user_subscriptions (user_id, plan_id, start_date, end_date, status)
VALUES (10, 1, CURDATE(), CURDATE(), 'active');

-- C17. Дубль посилання на файл субтитрів (UNIQUE)               ОЧІКУЄТЬСЯ ПОМИЛКА 1062
INSERT INTO subtitles (video_file_id, language_code, label, file_url)
VALUES (3, 'en', 'English', 'media/subtitles/big_buck_bunny_en.vtt');

-- C18. Тривалість фільму, що розходиться з його файлами
--      (Big Buck Bunny: файли по 596 с, нова тривалість 60 хв)   ОЧІКУЄТЬСЯ ПОМИЛКА 1644
UPDATE movies SET duration_min = 60 WHERE movie_id = 1;

-- C19. Те саме для епізоду (файли 2520 с, нова тривалість 10 хв) ОЧІКУЄТЬСЯ ПОМИЛКА 1644
UPDATE episodes SET duration_min = 10 WHERE episode_id = 1;

-- C20. Скасована підписка без часу скасування (CHECK)          ОЧІКУЄТЬСЯ ПОМИЛКА 3819
INSERT INTO user_subscriptions (user_id, plan_id, start_date, end_date, status, price_paid)
VALUES (10, 1, CURDATE(), CURDATE(), 'cancelled', 0);

-- C21. Ручна зміна кількості сезонів не застосовується: тригер BEFORE UPDATE
--      обчислює значення заново                                 -> seasons_count = 2
UPDATE tv_series SET seasons_count = 99 WHERE series_id = 1;
SELECT series_id, seasons_count FROM tv_series WHERE series_id = 1;

-- ---------------------------------------------------------------------
-- H. Контрольний перерахунок звітів (на початкових даних, до розділів D-F)
-- ---------------------------------------------------------------------
-- H1. Перегляди Big Buck Bunny, перераховані напряму (порівняти з запитом А):
--     кількість різних користувачів, незалежно від якості
SELECT COUNT(DISTINCT wh.user_id) AS bbb_views
FROM watch_history wh JOIN video_files vf ON vf.video_file_id = wh.video_file_id
WHERE vf.movie_id = 1;
-- H2. Дохід від тарифу "Стандарт" напряму (порівняти з запитом Д)
SELECT SUM(us.price_paid) AS standard_revenue
FROM user_subscriptions us JOIN subscription_plans sp ON sp.plan_id = us.plan_id
WHERE sp.name = 'Стандарт';
-- H3. Знаменник відсотків у запиті В: усі перегляди (користувач + фільм/епізод).
--     Сума відсотків може перевищувати 100 через кілька жанрів у контенту
SELECT COUNT(*) AS total_views FROM v_content_views;
-- H4. Перевірка, що зміна якості не подвоює перегляди: у v_content_views
--     немає дублів пари користувач + контент (має повернути 0 рядків)
SELECT user_id, movie_id, episode_id, COUNT(*) FROM v_content_views
GROUP BY user_id, movie_id, episode_id HAVING COUNT(*) > 1;

-- ---------------------------------------------------------------------
-- Копія даних, які змінюють розділи D-F (відновлюється в розділі Z)
-- ---------------------------------------------------------------------
DROP TEMPORARY TABLE IF EXISTS tmp_us_backup;
DROP TEMPORARY TABLE IF EXISTS tmp_wh_backup;
CREATE TEMPORARY TABLE tmp_us_backup AS SELECT * FROM user_subscriptions;
CREATE TEMPORARY TABLE tmp_wh_backup AS SELECT * FROM watch_history;

-- ---------------------------------------------------------------------
-- D. Процедури: сценарії sp_start_playback
-- Користувачі базового набору: 1 (Стандарт, 1080p), 3 (підписка закінчилась),
-- 9 (Безкоштовний, 480p), 10 (без підписки).
-- ---------------------------------------------------------------------
-- D1. Успіх: користувач 1, фільм 2 (Sintel, 12+), якість 1080p   -> файл 1080p, позиція 488
CALL sp_start_playback(1, 2, NULL, '1080p');
-- D2. Повторний виклик: історія оновлюється, а не дублюється    -> той самий файл, та сама позиція
CALL sp_start_playback(1, 2, NULL, '1080p');
-- D3. Найближча нижча якість: Sintel не має 720p                 -> файл 480p
CALL sp_start_playback(1, 2, NULL, '720p');
-- D4. Без вказаної якості (NULL): найкраща в межах тарифу        -> 1080p
CALL sp_start_playback(1, 3, NULL, NULL);
-- D5. Епізод серіалу; минулого разу переглянуто 97%              -> файл 720p, позиція 0
CALL sp_start_playback(1, NULL, 1, '720p');
-- D6. Немає підписки (користувач 10)                             ОЧІКУЄТЬСЯ ПОМИЛКА 1644
CALL sp_start_playback(10, 1, NULL, '480p');
-- D7. Прострочена підписка (користувач 3)                        ОЧІКУЄТЬСЯ ПОМИЛКА 1644
CALL sp_start_playback(3, 1, NULL, '480p');
-- D8. Якість вища за тариф (користувач 9, 480p, просить 1080p)   ОЧІКУЄТЬСЯ ПОМИЛКА 1644
CALL sp_start_playback(9, 1, NULL, '1080p');
-- D9. Некоректні параметри (обидва ідентифікатори)               ОЧІКУЄТЬСЯ ПОМИЛКА 1644
CALL sp_start_playback(1, 1, 1, '720p');
-- D10. Неіснуючий користувач                                     ОЧІКУЄТЬСЯ ПОМИЛКА 1644
CALL sp_start_playback(9999, 1, NULL, '480p');
-- D11. Результат містить параметри тарифу для плеєра: користувач 9
--      (Безкоштовний) -> has_ads = 1, max_screens = 1
CALL sp_start_playback(9, 1, NULL, NULL);

-- ---------------------------------------------------------------------
-- E. Процедури: sp_update_progress
-- ---------------------------------------------------------------------
-- Для користувача 1 і фільму 2 перегляд існує (див. D1). Знаходимо файл 1080p.
SET @f_sintel_1080 = (SELECT video_file_id FROM video_files WHERE movie_id = 2 AND quality = '1080p');
SELECT duration_sec INTO @dur FROM video_files WHERE video_file_id = @f_sintel_1080;

-- E1. 50% тривалості: completed = FALSE
CALL sp_update_progress(1, @f_sintel_1080, FLOOR(@dur * 0.5));
-- E2. Рівно 90%: все ще FALSE (потрібно строго понад 90%)
CALL sp_update_progress(1, @f_sintel_1080, FLOOR(@dur * 0.9));
-- E3. 95%: completed = TRUE
CALL sp_update_progress(1, @f_sintel_1080, FLOOR(@dur * 0.95));
-- E4. Позиція більша за тривалість                               ОЧІКУЄТЬСЯ ПОМИЛКА 1644
CALL sp_update_progress(1, @f_sintel_1080, @dur + 100);
-- E5. Перегляд не розпочато: користувач 2 має чинну підписку, але Sintel 1080p
--     ще не дивився                                              ОЧІКУЄТЬСЯ ПОМИЛКА 1644
CALL sp_update_progress(2, @f_sintel_1080, 10);
-- E6. Після завершення наступний sp_start_playback починає з 0
CALL sp_start_playback(1, 2, NULL, '1080p');                       -- last_position_sec = 0
-- E7. Повторний перегляд не скидає ознаку завершення             -> completed = 1, позиція 0
SELECT last_position_sec, completed FROM watch_history
WHERE user_id = 1 AND video_file_id = @f_sintel_1080;
-- E8. Збереження прогресу без чинної підписки (користувач 3,
--     підписка закінчилась; запис історії для файлу 2 існує)     ОЧІКУЄТЬСЯ ПОМИЛКА 1644
CALL sp_update_progress(3, 2, 10);

-- ---------------------------------------------------------------------
-- F. Процедури: sp_subscribe і відкат транзакції
-- ---------------------------------------------------------------------
-- F1. Успіх: користувач 10 оформлює тариф 4 на 2 місяці
--     -> start_date = сьогодні, end_date = сьогодні + 2 місяці - 1 день, price_paid = 298.00
CALL sp_subscribe(10, 4, 2);
-- F2. Після оформлення користувач 10 може дивитися
CALL sp_start_playback(10, 1, NULL, '720p');
-- F3. Відкат: користувач 1 має активну підписку. Виклик з неіснуючим тарифом 999 спершу
--     скасовує стару підписку, а потім падає; транзакція має повністю відкотитися.
SELECT COUNT(*) AS active_before FROM user_subscriptions WHERE user_id = 1 AND status = 'active';  -- 1
CALL sp_subscribe(1, 999, 1);                                     -- ОЧІКУЄТЬСЯ ПОМИЛКА 1644
SELECT COUNT(*) AS active_after  FROM user_subscriptions WHERE user_id = 1 AND status = 'active';  -- 1 (відкат)
-- F4. Некоректна кількість місяців                               ОЧІКУЄТЬСЯ ПОМИЛКА 1644
CALL sp_subscribe(1, 4, 0);
-- F5. Продовження того самого тарифу: користувач 10 ще раз бере тариф 4 на 1 місяць
--     -> нова підписка починається наступного дня після кінця підписки з F1,
--        price_paid = 149.00, credit_applied = 0.00; стара підписка лишається активною
CALL sp_subscribe(10, 4, 1);
SELECT subscription_id, plan_id, start_date, end_date, status, price_paid
FROM user_subscriptions WHERE user_id = 10 ORDER BY start_date;   -- дві активні, без перетину
-- F6. Зміна тарифу із зарахуванням. Щоб результат не залежав від довжини місяців,
--     період чинної підписки користувача 5 спершу задається явно: 61 день,
--     з них 6 днів (включно з сьогодні) не використано. Перехід на тариф 7 (329.00) на 1 місяць
--     -> credit_applied = ROUND(338 * 6 / 61, 2) = 33.25, price_paid = 329.00 - 33.25 = 295.75;
--        стара підписка: status = 'cancelled', cancelled_at заповнено, період не змінився
UPDATE user_subscriptions
   SET start_date = DATE_SUB(CURDATE(), INTERVAL 55 DAY), end_date = DATE_ADD(CURDATE(), INTERVAL 5 DAY)
 WHERE user_id = 5 AND status = 'active';
CALL sp_subscribe(5, 7, 1);
SELECT subscription_id, plan_id, start_date, end_date, status, price_paid, credit_applied,
       cancelled_at IS NOT NULL AS has_cancelled_at
FROM user_subscriptions WHERE user_id = 5 ORDER BY subscription_id;

-- ---------------------------------------------------------------------
-- G. Службова процедура: імітація прострочення та sp_expire_subscriptions
-- ---------------------------------------------------------------------
START TRANSACTION;
UPDATE user_subscriptions SET end_date = DATE_SUB(CURDATE(), INTERVAL 1 DAY), start_date = DATE_SUB(CURDATE(), INTERVAL 30 DAY)
 WHERE user_id = 4 AND status = 'active';
-- Статус 'active' із минулою датою: відтворення має бути заборонене
CALL sp_start_playback(4, 1, NULL, '480p');                        -- ОЧІКУЄТЬСЯ ПОМИЛКА 1644
ROLLBACK;

-- ---------------------------------------------------------------------
-- I. Віковий рейтинг (у транзакції, зміни скасовуються)
-- ---------------------------------------------------------------------
START TRANSACTION;
INSERT INTO users (email, password_hash, display_name, birth_date)
VALUES ('kid.test@example.com', 'x', 'Тестова Дитина', DATE_SUB(CURDATE(), INTERVAL 10 YEAR));
SET @kid_id = LAST_INSERT_ID();
INSERT INTO user_subscriptions (user_id, plan_id, start_date, end_date, status, price_paid)
VALUES (@kid_id, 4, CURDATE(), DATE_ADD(CURDATE(), INTERVAL 10 DAY), 'active', 149.00);
-- I1. 10 років, Sintel 12+                                       ОЧІКУЄТЬСЯ ПОМИЛКА 1644
CALL sp_start_playback(@kid_id, 2, NULL, '720p');
-- I2. 10 років, епізод серіалу "Нічна зміна" 16+                 ОЧІКУЄТЬСЯ ПОМИЛКА 1644
CALL sp_start_playback(@kid_id, NULL, 9, '720p');
-- I3. 10 років, Big Buck Bunny 0+                                -> успіх
CALL sp_start_playback(@kid_id, 1, NULL, '720p');
ROLLBACK;

-- ---------------------------------------------------------------------
-- J. Автоматичний перерахунок seasons_count (у транзакції, зміни скасовуються)
-- ---------------------------------------------------------------------
START TRANSACTION;
INSERT INTO tv_series (title, start_year, seasons_count) VALUES ('Тестовий серіал', 2024, 5);
SET @ts_id = LAST_INSERT_ID();
SELECT seasons_count FROM tv_series WHERE series_id = @ts_id;      -- J1: 0 (значення 5 ігнорується)
INSERT INTO episodes (series_id, season_number, episode_number, title, duration_min)
VALUES (@ts_id, 1, 1, 'С1Е1', 30), (@ts_id, 3, 1, 'С3Е1', 30);
SELECT seasons_count FROM tv_series WHERE series_id = @ts_id;      -- J2: 3
UPDATE episodes SET season_number = 2 WHERE series_id = @ts_id AND season_number = 3;
SELECT seasons_count FROM tv_series WHERE series_id = @ts_id;      -- J3: 2
DELETE FROM episodes WHERE series_id = @ts_id AND season_number = 2;
SELECT seasons_count FROM tv_series WHERE series_id = @ts_id;      -- J4: 1
DELETE FROM episodes WHERE series_id = @ts_id;
SELECT seasons_count FROM tv_series WHERE series_id = @ts_id;      -- J5: 0
ROLLBACK;

-- ---------------------------------------------------------------------
-- K. Подія планувальника та колація бази даних
-- ---------------------------------------------------------------------
-- K1. Подія ev_expire_subscriptions існує й увімкнена       -> ENABLED, щодня (1 DAY)
SELECT EVENT_NAME, STATUS, INTERVAL_VALUE, INTERVAL_FIELD
FROM information_schema.EVENTS WHERE EVENT_SCHEMA = 'streaming_service';
SHOW VARIABLES LIKE 'event_scheduler';                             -- K2: ON
-- K3. Колація бази враховує діакритику: «і» <> «ї», «е» <> «є», але регістр не важливий
SELECT DEFAULT_COLLATION_NAME FROM information_schema.SCHEMATA WHERE SCHEMA_NAME = 'streaming_service';
SELECT 'і' = 'ї' COLLATE utf8mb4_0900_as_ci AS i_eq_yi,           -- 0
       'е' = 'є' COLLATE utf8mb4_0900_as_ci AS e_eq_ye,           -- 0
       'Ї' = 'ї' COLLATE utf8mb4_0900_as_ci AS case_insensitive;  -- 1

-- ---------------------------------------------------------------------
-- Z. Відновлення даних після розділів D-F (файл можна запускати повторно)
-- ---------------------------------------------------------------------
DELETE FROM watch_history;
INSERT INTO watch_history SELECT * FROM tmp_wh_backup;
DELETE FROM user_subscriptions;
INSERT INTO user_subscriptions SELECT * FROM tmp_us_backup;
DROP TEMPORARY TABLE tmp_us_backup;
DROP TEMPORARY TABLE tmp_wh_backup;
-- Z1. Кількість рядків має збігатися з розділом A
SELECT (SELECT COUNT(*) FROM user_subscriptions) AS subscriptions,
       (SELECT COUNT(*) FROM watch_history) AS watch_rows;
