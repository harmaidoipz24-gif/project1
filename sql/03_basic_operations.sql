-- sql/03_basic_operations.sql - приклади базових операцій (INSERT, UPDATE, DELETE, SELECT)
-- Виконувати після 01_schema.sql та 02_seed.sql.
-- Усі тимчасові записи, створені в розділах INSERT, видаляються в розділі DELETE,
-- тому файл можна запускати повторно без зміни базового набору даних.
USE streaming_service;

-- MySQL Workbench за замовчуванням вмикає safe updates (UPDATE/DELETE лише за ключем).
-- Вимикаємо для цього сеансу, щоб демонстраційні оператори виконувались однаково всюди.
SET SQL_SAFE_UPDATES = 0;

-- INSERT

-- 1. Новий користувач
INSERT INTO users (email, password_hash, display_name, birth_date)
VALUES ('test.user@example.com',
        'pbkdf2$demotestsalt0000$4d7d3b158ec2f705a31c5bff85b3fa5443b49df0f9585f7f3fe698df779d24fb',
        'Тестовий Користувач', '2000-01-01');
SET @test_user_id = LAST_INSERT_ID();

-- 2. Нова підписка для цього користувача (тариф 4 "Базовий", 1 місяць).
--    Кінцева дата включна, тому місяць = від сьогодні до (сьогодні + 1 місяць - 1 день).
--    У застосунку підписку оформлюють процедурою sp_subscribe (05_procedures.sql).
INSERT INTO user_subscriptions (user_id, plan_id, start_date, end_date, status, price_paid)
VALUES (@test_user_id, 4, CURDATE(), DATE_SUB(DATE_ADD(CURDATE(), INTERVAL 1 MONTH), INTERVAL 1 DAY), 'active', 149.00);

-- 3. Новий жанр
INSERT INTO genres (name, description) VALUES ('Тестовий жанр', 'Тимчасовий жанр для демонстрації');
SET @test_genre_id = LAST_INSERT_ID();

-- 4. Новий фільм, його жанр і відеофайл (тривалість файлу 300 с = 5 хв)
INSERT INTO movies (title, description, release_year, duration_min, age_rating, rating, poster_url)
VALUES ('Тестовий фільм', 'Тимчасовий запис для демонстрації операцій', 2024, 5, '0+', 5.0,
        'https://placehold.co/300x450/png?text=Test');
SET @test_movie_id = LAST_INSERT_ID();

INSERT INTO media_genres (movie_id, series_id, genre_id) VALUES (@test_movie_id, NULL, @test_genre_id);

INSERT INTO video_files (movie_id, episode_id, file_url, quality, `format`, duration_sec, file_size_mb, audio_language)
VALUES (@test_movie_id, NULL, 'media/test_movie_720p.mp4', '720p', 'mp4', 300, 93.75, 'uk');

-- 5. Перегляд тестового файлу користувачем
INSERT INTO watch_history (user_id, video_file_id, last_position_sec)
VALUES (@test_user_id, LAST_INSERT_ID(), 120);

-- ---------------------------------------------------------------------
-- UPDATE
-- ---------------------------------------------------------------------

-- 6. Зміна рейтингу фільму
UPDATE movies SET rating = 6.5 WHERE movie_id = @test_movie_id;

-- 7. Зміна позиції перегляду та позначка про завершення
UPDATE watch_history
   SET last_position_sec = 290, completed = TRUE
 WHERE user_id = @test_user_id;

-- 8. Деактивація відеофайлу тестового фільму ("мʼяке видалення": файл зникає з відтворення,
--    але історія переглядів і статистика зберігаються)
UPDATE video_files SET is_active = FALSE WHERE movie_id = @test_movie_id;

-- 8а. Деактивація користувача: так "видаляють" користувача з підписками,
--     бо підписки є фінансовою історією (FK user_subscriptions.user_id - RESTRICT)
UPDATE users SET is_active = FALSE WHERE user_id = @test_user_id;

-- 9. Масове оновлення: позначити прострочені підписки (статус active, але дата закінчення минула).
--    У базовому наборі даних таких немає, тому оператор змінює 0 рядків.
UPDATE user_subscriptions
   SET status = 'expired'
 WHERE status = 'active' AND end_date < CURDATE();

-- ---------------------------------------------------------------------
-- DELETE (порядок важливий: FK у watch_history, video_files, media_genres і
-- user_subscriptions мають RESTRICT). У робочій системі фільми, файли та користувачів
-- деактивують (див. п. 8, 8а); фізичне видалення тут лише прибирає тестові записи.
-- ---------------------------------------------------------------------

-- 10. Видалення тестового фільму: спочатку залежні записи
DELETE FROM watch_history
 WHERE video_file_id IN (SELECT video_file_id FROM video_files WHERE movie_id = @test_movie_id);
DELETE FROM media_genres WHERE movie_id = @test_movie_id;
DELETE FROM video_files WHERE movie_id = @test_movie_id;
DELETE FROM movies WHERE movie_id = @test_movie_id;

-- 11. Видалення тестового жанру
DELETE FROM genres WHERE genre_id = @test_genre_id;

-- 12. Видалення тестового користувача: спочатку його тестова підписка (FK RESTRICT),
--     історія переглядів видаляється каскадом
DELETE FROM user_subscriptions WHERE user_id = @test_user_id;
DELETE FROM users WHERE user_id = @test_user_id;

-- ---------------------------------------------------------------------
-- SELECT з WHERE, ORDER BY, LIMIT
-- ---------------------------------------------------------------------

-- 13. П'ять фільмів з найвищим рейтингом
SELECT movie_id, title, release_year, rating
FROM movies
WHERE rating IS NOT NULL
ORDER BY rating DESC, title
LIMIT 5;

-- 14. Фільми, випущені з 2015 року, для дітей (віковий рейтинг 0+ або 6+)
SELECT title, release_year, duration_min, age_rating
FROM movies
WHERE release_year >= 2015 AND age_rating IN ('0+', '6+')
ORDER BY release_year DESC, title;

-- 15. Пошук фільмів за частиною назви
SELECT movie_id, title, release_year
FROM movies
WHERE title LIKE '%Buck%' OR title LIKE '%Sin%'
ORDER BY title;

-- 16. Епізоди другого сезону серіалу 1 за порядком
SELECT season_number, episode_number, title, duration_min
FROM episodes
WHERE series_id = 1 AND season_number = 2
ORDER BY episode_number;

-- 17. Тарифи з якістю не нижче 1080p, від найдешевшого
SELECT plan_id, name, price_per_month, max_quality, max_screens, has_ads
FROM subscription_plans
WHERE max_quality IN ('1080p', '4K')
ORDER BY price_per_month ASC;

-- 18. Три останні реєстрації користувачів
SELECT user_id, email, display_name, registered_at
FROM users
ORDER BY registered_at DESC
LIMIT 3;

-- 19. Останні 10 оновлень історії переглядів
SELECT history_id, user_id, video_file_id, last_position_sec, completed, updated_at
FROM watch_history
ORDER BY updated_at DESC
LIMIT 10;

-- 20. Активні відеофайли у якості 4K
SELECT video_file_id, file_url, quality, `format`, file_size_mb
FROM video_files
WHERE quality = '4K' AND is_active = TRUE
ORDER BY file_size_mb DESC;
