-- sql/05_procedures.sql - збережені процедури
--   sp_start_playback       - початок / продовження відтворення з перевіркою доступу
--   sp_update_progress      - збереження позиції перегляду
--   sp_subscribe            - оформлення, продовження або зміна підписки в транзакції
--   sp_expire_subscriptions - службова: позначити прострочені підписки
--   ev_expire_subscriptions - подія планувальника: щодня виконує ту саму дію
-- Виконувати після 01_schema.sql та 02_seed.sql.
-- Порядок якостей: 480p < 720p < 1080p < 4K (визначається функцією FIELD).
USE streaming_service;

DELIMITER $$

DROP PROCEDURE IF EXISTS sp_start_playback$$
CREATE PROCEDURE sp_start_playback(
    IN p_user_id    INT UNSIGNED,
    IN p_movie_id   INT UNSIGNED,
    IN p_episode_id INT UNSIGNED,
    IN p_quality    VARCHAR(5)
)
BEGIN
    DECLARE v_user_active    BOOLEAN DEFAULT NULL;
    DECLARE v_birth_date     DATE DEFAULT NULL;
    DECLARE v_plan_id        INT UNSIGNED DEFAULT NULL;
    DECLARE v_max_quality    VARCHAR(5) DEFAULT NULL;
    DECLARE v_has_ads        BOOLEAN DEFAULT FALSE;
    DECLARE v_max_screens    TINYINT UNSIGNED DEFAULT 1;
    DECLARE v_max_idx        INT DEFAULT 0;
    DECLARE v_req_idx        INT DEFAULT 0;
    DECLARE v_age_rating     VARCHAR(3) DEFAULT NULL;
    DECLARE v_min_age        INT DEFAULT 0;
    DECLARE v_user_age       INT DEFAULT NULL;
    DECLARE v_file_id        INT UNSIGNED DEFAULT NULL;
    DECLARE v_file_duration  INT UNSIGNED DEFAULT 0;
    DECLARE v_pos            INT UNSIGNED DEFAULT 0;
    DECLARE v_prev_duration  INT UNSIGNED DEFAULT NULL;
    DECLARE v_cnt            INT DEFAULT 0;
    DECLARE v_msg            VARCHAR(255);

    -- 1. Коректність параметрів: рівно один об'єкт
    IF (p_movie_id IS NULL AND p_episode_id IS NULL)
       OR (p_movie_id IS NOT NULL AND p_episode_id IS NOT NULL) THEN
        SIGNAL SQLSTATE '45000'
            SET MESSAGE_TEXT = 'Потрібно вказати рівно одне значення: movie_id або episode_id';
    END IF;

    -- 2. Користувач
    SELECT is_active, birth_date INTO v_user_active, v_birth_date
      FROM users WHERE user_id = p_user_id;
    IF v_user_active IS NULL THEN
        SIGNAL SQLSTATE '45000' SET MESSAGE_TEXT = 'Користувача не знайдено';
    ELSEIF v_user_active = FALSE THEN
        SIGNAL SQLSTATE '45000' SET MESSAGE_TEXT = 'Обліковий запис користувача деактивовано';
    END IF;

    -- 3. Активна підписка, чинна сьогодні (період включає обидві дати)
    SELECT us.plan_id, sp.max_quality, sp.has_ads, sp.max_screens
      INTO v_plan_id, v_max_quality, v_has_ads, v_max_screens
      FROM user_subscriptions us
      JOIN subscription_plans sp ON sp.plan_id = us.plan_id
     WHERE us.user_id = p_user_id
       AND us.status = 'active'
       AND CURDATE() BETWEEN us.start_date AND us.end_date
     ORDER BY us.end_date DESC
     LIMIT 1;

    IF v_plan_id IS NULL THEN
        SELECT COUNT(*) INTO v_cnt FROM user_subscriptions WHERE user_id = p_user_id;
        IF v_cnt = 0 THEN
            SIGNAL SQLSTATE '45000'
                SET MESSAGE_TEXT = 'Немає підписки: оформіть тариф, щоб дивитися контент';
        ELSE
            SIGNAL SQLSTATE '45000'
                SET MESSAGE_TEXT = 'Підписка прострочена або скасована: продовжіть тариф, щоб дивитися контент';
        END IF;
    END IF;

    -- 4. Обмеження якості за тарифом
    SET v_max_idx = FIELD(v_max_quality, '480p', '720p', '1080p', '4K');
    IF p_quality IS NULL THEN
        SET v_req_idx = v_max_idx;
    ELSE
        SET v_req_idx = FIELD(p_quality, '480p', '720p', '1080p', '4K');
        IF v_req_idx = 0 THEN
            SIGNAL SQLSTATE '45000'
                SET MESSAGE_TEXT = 'Невідома якість: допустимі значення 480p, 720p, 1080p, 4K';
        END IF;
        IF v_req_idx > v_max_idx THEN
            SET v_msg = CONCAT('Якість ', p_quality, ' недоступна на вашому тарифі (максимум ', v_max_quality, ')');
            SIGNAL SQLSTATE '45000' SET MESSAGE_TEXT = v_msg;
        END IF;
    END IF;

    -- 5. Контент існує; віковий рейтинг фільму або серіалу, до якого належить епізод
    IF p_movie_id IS NOT NULL THEN
        SELECT age_rating INTO v_age_rating FROM movies WHERE movie_id = p_movie_id;
    ELSE
        SELECT s.age_rating INTO v_age_rating
          FROM episodes e
          JOIN tv_series s ON s.series_id = e.series_id
         WHERE e.episode_id = p_episode_id;
    END IF;
    IF v_age_rating IS NULL THEN
        SIGNAL SQLSTATE '45000' SET MESSAGE_TEXT = 'Фільм або епізод не знайдено';
    END IF;

    -- 6. Перевірка вікового рейтингу ('12+' -> 12)
    SET v_min_age = CAST(REPLACE(v_age_rating, '+', '') AS UNSIGNED);
    IF v_min_age > 0 THEN
        IF v_birth_date IS NULL THEN
            IF v_min_age >= 18 THEN
                SIGNAL SQLSTATE '45000'
                    SET MESSAGE_TEXT = 'Контент 18+: вкажіть дату народження в профілі, щоб підтвердити вік';
            END IF;
        ELSE
            SET v_user_age = TIMESTAMPDIFF(YEAR, v_birth_date, CURDATE());
            IF v_user_age < v_min_age THEN
                SET v_msg = CONCAT('Контент має віковий рейтинг ', v_age_rating,
                                   ' і недоступний для вашого віку (', v_user_age, ')');
                SIGNAL SQLSTATE '45000' SET MESSAGE_TEXT = v_msg;
            END IF;
        END IF;
    END IF;

    -- 7. Вибір файлу: активний, у межах тарифу, найближча нижча якість
    --    (якщо нижчої немає, береться найближча вища, але не вища за тариф)
    SELECT vf.video_file_id, vf.duration_sec
      INTO v_file_id, v_file_duration
      FROM video_files vf
     WHERE vf.is_active = TRUE
       AND ((p_movie_id IS NOT NULL AND vf.movie_id = p_movie_id)
         OR (p_episode_id IS NOT NULL AND vf.episode_id = p_episode_id))
       AND FIELD(vf.quality, '480p', '720p', '1080p', '4K') <= v_max_idx
     ORDER BY (FIELD(vf.quality, '480p', '720p', '1080p', '4K') > v_req_idx),
              ABS(FIELD(vf.quality, '480p', '720p', '1080p', '4K') - v_req_idx),
              vf.video_file_id
     LIMIT 1;

    IF v_file_id IS NULL THEN
        SIGNAL SQLSTATE '45000'
            SET MESSAGE_TEXT = 'Для цього контенту немає доступного відеофайлу в межах вашого тарифу';
    END IF;

    -- 8. Позиція продовження: останній перегляд цього контенту в будь-якій якості.
    --    updated_at має точність до мілісекунд; history_id - додатковий критерій
    --    на випадок повного збігу часу, щоб результат був однозначним.
    SELECT wh.last_position_sec, vf2.duration_sec
      INTO v_pos, v_prev_duration
      FROM watch_history wh
      JOIN video_files vf2 ON vf2.video_file_id = wh.video_file_id
     WHERE wh.user_id = p_user_id
       AND ((p_movie_id IS NOT NULL AND vf2.movie_id = p_movie_id)
         OR (p_episode_id IS NOT NULL AND vf2.episode_id = p_episode_id))
     ORDER BY wh.updated_at DESC, wh.history_id DESC
     LIMIT 1;

    IF v_prev_duration IS NOT NULL AND v_pos > 0.9 * v_prev_duration THEN
        SET v_pos = 0;           -- минулого разу додивились до кінця: починаємо спочатку
    END IF;
    IF v_pos > v_file_duration THEN
        SET v_pos = v_file_duration;
    END IF;

    -- 9. Створення або оновлення запису історії (UNIQUE користувач + файл).
    --    completed не змінюється: факт завершення попереднього перегляду зберігається.
    INSERT INTO watch_history (user_id, video_file_id, last_position_sec, completed)
    VALUES (p_user_id, v_file_id, v_pos, FALSE)
    ON DUPLICATE KEY UPDATE
        last_position_sec = v_pos,
        updated_at = NOW(3);

    -- 10. Результат (has_ads і max_screens - для плеєра: показ реклами
    --     та контроль кількості одночасних потоків на боці стрімінгового сервера)
    SELECT vf.video_file_id,
           vf.file_url,
           vf.quality,
           vf.`format`,
           vf.duration_sec,
           vf.audio_language,
           v_pos AS last_position_sec,
           v_age_rating AS age_rating,
           v_has_ads AS has_ads,
           v_max_screens AS max_screens
      FROM video_files vf
     WHERE vf.video_file_id = v_file_id;
END$$

-- ---------------------------------------------------------------------
-- sp_update_progress(user_id, video_file_id, position_sec)
-- Зберігає позицію; completed стає TRUE, якщо позиція перевищує 90% тривалості файлу.
-- Раніше встановлена ознака completed не скидається.
-- Прогрес зберігається лише для активного користувача з чинною підпискою
-- (ті самі умови доступу, що й у sp_start_playback).
-- ---------------------------------------------------------------------
DROP PROCEDURE IF EXISTS sp_update_progress$$
CREATE PROCEDURE sp_update_progress(
    IN p_user_id       INT UNSIGNED,
    IN p_video_file_id INT UNSIGNED,
    IN p_position_sec  INT
)
BEGIN
    DECLARE v_duration INT UNSIGNED DEFAULT NULL;
    DECLARE v_cnt      INT DEFAULT 0;

    SELECT COUNT(*) INTO v_cnt
      FROM users u
      JOIN user_subscriptions us ON us.user_id = u.user_id
     WHERE u.user_id = p_user_id
       AND u.is_active = TRUE
       AND us.status = 'active'
       AND CURDATE() BETWEEN us.start_date AND us.end_date;
    IF v_cnt = 0 THEN
        SIGNAL SQLSTATE '45000'
            SET MESSAGE_TEXT = 'Немає чинної підписки або обліковий запис деактивовано: прогрес не збережено';
    END IF;

    SELECT COUNT(*) INTO v_cnt
      FROM watch_history
     WHERE user_id = p_user_id AND video_file_id = p_video_file_id;
    IF v_cnt = 0 THEN
        SIGNAL SQLSTATE '45000'
            SET MESSAGE_TEXT = 'Перегляд не розпочато: спочатку викличте sp_start_playback';
    END IF;

    SELECT duration_sec INTO v_duration FROM video_files WHERE video_file_id = p_video_file_id;

    IF p_position_sec IS NULL OR p_position_sec < 0 OR p_position_sec > v_duration THEN
        SIGNAL SQLSTATE '45000'
            SET MESSAGE_TEXT = 'Позиція має бути в межах від 0 до тривалості відеофайлу';
    END IF;

    UPDATE watch_history
       SET last_position_sec = p_position_sec,
           completed = (completed = TRUE OR p_position_sec > 0.9 * v_duration),
           updated_at = NOW(3)
     WHERE user_id = p_user_id AND video_file_id = p_video_file_id;

    SELECT last_position_sec,
           completed,
           ROUND(100 * last_position_sec / v_duration, 1) AS progress_pct
      FROM watch_history
     WHERE user_id = p_user_id AND video_file_id = p_video_file_id;
END$$

-- ---------------------------------------------------------------------
-- sp_subscribe(user_id, plan_id, months)
-- Оформлення підписки в одній транзакції. Три сценарії:
--   1) немає чинної підписки        -> нова підписка з сьогодні;
--   2) чинна підписка на ТОЙ САМИЙ тариф -> ПРОДОВЖЕННЯ: нова підписка починається
--      наступного дня після закінчення останньої активної (оплачені дні не губляться);
--   3) чинна підписка на ІНШИЙ тариф -> ЗМІНА ТАРИФУ: стара отримує статус 'cancelled'
--      і час скасування cancelled_at (її період start_date..end_date не змінюється),
--      а вартість невикористаних днів (з сьогодні до end_date) зараховується в оплату нової:
--      price_paid = MAX(ціна * місяці - зарахування, 0); зарахування зберігається
--      в стовпці credit_applied нової підписки.
--      Залишок зарахування понад вартість нового тарифу не повертається (спрощення).
-- Період нової підписки: [start; start + months - 1 день] (обидві дати включно).
-- Рядок користувача блокується (SELECT ... FOR UPDATE), тому два паралельні виклики
-- для одного користувача виконуються по черзі й не створять дві активні підписки.
-- Тариф перевіряється вже після скасування старої підписки: якщо тариф не знайдено,
-- уся транзакція відкочується (сценарій F3 у 06_tests.sql демонструє атомарність).
-- ---------------------------------------------------------------------
DROP PROCEDURE IF EXISTS sp_subscribe$$
CREATE PROCEDURE sp_subscribe(
    IN p_user_id INT UNSIGNED,
    IN p_plan_id INT UNSIGNED,
    IN p_months  INT
)
BEGIN
    DECLARE v_user_active    BOOLEAN DEFAULT NULL;
    DECLARE v_price          DECIMAL(8,2) DEFAULT NULL;
    DECLARE v_credit         DECIMAL(8,2) DEFAULT 0.00;
    DECLARE v_same_plan_end  DATE DEFAULT NULL;
    DECLARE v_start          DATE DEFAULT NULL;
    DECLARE v_end            DATE DEFAULT NULL;
    DECLARE v_new_id         INT UNSIGNED DEFAULT NULL;

    DECLARE EXIT HANDLER FOR SQLEXCEPTION
    BEGIN
        ROLLBACK;
        RESIGNAL;
    END;

    IF p_months IS NULL OR p_months < 1 OR p_months > 12 THEN
        SIGNAL SQLSTATE '45000'
            SET MESSAGE_TEXT = 'Кількість місяців має бути від 1 до 12';
    END IF;

    START TRANSACTION;

    -- Блокуємо рядок користувача до кінця транзакції
    SELECT is_active INTO v_user_active FROM users WHERE user_id = p_user_id FOR UPDATE;
    IF v_user_active IS NULL OR v_user_active = FALSE THEN
        SIGNAL SQLSTATE '45000' SET MESSAGE_TEXT = 'Активного користувача не знайдено';
    END IF;

    -- Крок 0: активні підписки цього користувача з минулою датою -> 'expired'
    UPDATE user_subscriptions
       SET status = 'expired'
     WHERE user_id = p_user_id AND status = 'active' AND end_date < CURDATE();

    -- Крок 1: продовження того самого тарифу чи зміна тарифу
    SELECT MAX(end_date) INTO v_same_plan_end
      FROM user_subscriptions
     WHERE user_id = p_user_id AND status = 'active' AND plan_id = p_plan_id;

    IF v_same_plan_end IS NOT NULL THEN
        -- Продовження: нова підписка починається після закінчення чинної
        SET v_start = DATE_ADD(v_same_plan_end, INTERVAL 1 DAY);
    ELSE
        -- Зміна тарифу (або перша підписка): зарахування за невикористані дні
        SELECT COALESCE(SUM(ROUND(
                   price_paid
                   * (DATEDIFF(end_date, GREATEST(start_date, CURDATE())) + 1)
                   / (DATEDIFF(end_date, start_date) + 1), 2)), 0.00)
          INTO v_credit
          FROM user_subscriptions
         WHERE user_id = p_user_id AND status = 'active';

        UPDATE user_subscriptions
           SET status = 'cancelled',
               cancelled_at = NOW()
         WHERE user_id = p_user_id AND status = 'active';

        SET v_start = CURDATE();
    END IF;

    -- Крок 2: перевірити тариф і взяти поточну ціну
    SELECT price_per_month INTO v_price FROM subscription_plans WHERE plan_id = p_plan_id;
    IF v_price IS NULL THEN
        SIGNAL SQLSTATE '45000' SET MESSAGE_TEXT = 'Тариф не знайдено';
    END IF;

    -- Крок 3: створити нову підписку
    SET v_end = DATE_SUB(DATE_ADD(v_start, INTERVAL p_months MONTH), INTERVAL 1 DAY);
    -- Зарахування не може перевищити вартість нової підписки
    SET v_credit = LEAST(v_credit, v_price * p_months);
    INSERT INTO user_subscriptions (user_id, plan_id, start_date, end_date, status, price_paid, credit_applied)
    VALUES (p_user_id, p_plan_id, v_start, v_end, 'active',
            v_price * p_months - v_credit, v_credit);
    SET v_new_id = LAST_INSERT_ID();

    COMMIT;

    SELECT us.subscription_id, us.user_id, sp.name AS plan_name, us.start_date, us.end_date,
           us.status, us.price_paid, us.credit_applied
      FROM user_subscriptions us
      JOIN subscription_plans sp ON sp.plan_id = us.plan_id
     WHERE us.subscription_id = v_new_id;
END$$

-- ---------------------------------------------------------------------
-- sp_expire_subscriptions() - службова процедура для ручного запуску:
-- переводить в статус 'expired' активні підписки з минулою датою закінчення
-- і повертає їх кількість. Використовує індекс idx_us_status_end (status, end_date).
-- Щоденний автоматичний запуск виконує подія ev_expire_subscriptions (нижче).
-- ---------------------------------------------------------------------
DROP PROCEDURE IF EXISTS sp_expire_subscriptions$$
CREATE PROCEDURE sp_expire_subscriptions()
BEGIN
    UPDATE user_subscriptions
       SET status = 'expired'
     WHERE status = 'active' AND end_date < CURDATE();
    SELECT ROW_COUNT() AS expired_count;
END$$

-- ---------------------------------------------------------------------
-- ev_expire_subscriptions - подія планувальника MySQL: щодня о 00:05 позначає
-- прострочені підписки. Тіло події не повертає набір рядків, тому замість
-- виклику процедури (яка повертає expired_count) виконується той самий UPDATE.
-- Планувальник має бути увімкнений: SET GLOBAL event_scheduler = ON
-- (у MySQL 8.0 він увімкнений за замовчуванням).
-- ---------------------------------------------------------------------
DROP EVENT IF EXISTS ev_expire_subscriptions$$
CREATE EVENT ev_expire_subscriptions
    ON SCHEDULE EVERY 1 DAY
    STARTS TIMESTAMP(CURDATE() + INTERVAL 1 DAY, '00:05:00')
    ON COMPLETION PRESERVE
    COMMENT 'Щоденне переведення прострочених підписок у статус expired'
    DO
        UPDATE user_subscriptions
           SET status = 'expired'
         WHERE status = 'active' AND end_date < CURDATE()$$

DELIMITER ;
