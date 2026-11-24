
-- База даних для стрімінгового відеосервісу (MySQL 8.0+, InnoDB, utf8mb4)
-- Містить: створення БД, 11 таблиць, індекси, обмеження, 15 тригерів.


DROP DATABASE IF EXISTS streaming_service;
CREATE DATABASE streaming_service
    CHARACTER SET utf8mb4
    COLLATE utf8mb4_0900_as_ci;
-- utf8mb4_0900_as_ci: правила Unicode 9.0, без урахування регістру, але З урахуванням
-- діакритики. Для української мови це важливо: «і» та «ї», «е» та «є», «г» та «ґ»
-- вважаються різними літерами (у колаціях *_ai_ci і unicode_ci вони збігаються).
USE streaming_service;

-- Загальне правило для зовнішніх ключів: ON UPDATE RESTRICT.
-- Первинні ключі сурогатні (AUTO_INCREMENT) і ніколи не змінюються,
-- тому каскадне оновлення не потрібне.


-- 1. users - зареєстровані користувачі
-- 3НФ: усі атрибути залежать лише від user_id; тарифи та перегляди винесені в окремі таблиці.
-- Користувача не видаляють, а деактивують (is_active = FALSE): його підписки є
-- фінансовою історією, тому FK з user_subscriptions має RESTRICT.
CREATE TABLE users (
    user_id        INT UNSIGNED NOT NULL AUTO_INCREMENT COMMENT 'Первинний ключ',
    email          VARCHAR(255) NOT NULL COMMENT 'Електронна пошта (логін), унікальна',
    password_hash  VARCHAR(255) NOT NULL COMMENT 'Хеш пароля у форматі pbkdf2$сіль$хеш (пароль у відкритому вигляді не зберігається)',
    display_name   VARCHAR(100) NOT NULL COMMENT 'Відображуване імʼя',
    birth_date     DATE NULL COMMENT 'Дата народження (для перевірки вікового рейтингу)',
    country_code   CHAR(2) NOT NULL DEFAULT 'UA' COMMENT 'Код країни ISO 3166-1 alpha-2',
    registered_at  DATETIME NOT NULL DEFAULT CURRENT_TIMESTAMP COMMENT 'Дата й час реєстрації',
    is_active      BOOLEAN NOT NULL DEFAULT TRUE COMMENT 'Чи активний обліковий запис',
    PRIMARY KEY (user_id),
    UNIQUE KEY uq_users_email (email),
    CONSTRAINT chk_users_email CHECK (email LIKE '%_@_%._%'),
    -- Нижня межа перевіряється CHECK; "не в майбутньому" - тригером,
    -- бо CHECK у MySQL не допускає недетермінованих функцій (CURDATE).
    CONSTRAINT chk_users_birth CHECK (birth_date IS NULL OR birth_date >= '1900-01-01')
) ENGINE = InnoDB COMMENT = 'Користувачі сервісу';

-- 2. subscription_plans - тарифні плани
-- 3НФ: параметри тарифу залежать лише від plan_id.
-- max_quality та вікові обмеження перевіряє sp_start_playback;
-- max_screens і has_ads процедура повертає клієнту (див. design.md, розділ 10).

CREATE TABLE subscription_plans (
    plan_id          INT UNSIGNED NOT NULL AUTO_INCREMENT COMMENT 'Первинний ключ',
    name             VARCHAR(100) NOT NULL COMMENT 'Назва тарифу, унікальна',
    price_per_month  DECIMAL(8,2) NOT NULL COMMENT 'Ціна за місяць, грн',
    max_quality      ENUM('480p','720p','1080p','4K') NOT NULL COMMENT 'Максимальна якість відео',
    max_screens      TINYINT UNSIGNED NOT NULL DEFAULT 1 COMMENT 'Кількість одночасних екранів',
    has_ads          BOOLEAN NOT NULL DEFAULT FALSE COMMENT 'Чи показується реклама',
    PRIMARY KEY (plan_id),
    UNIQUE KEY uq_plans_name (name),
    CONSTRAINT chk_plans_price CHECK (price_per_month >= 0),
    CONSTRAINT chk_plans_screens CHECK (max_screens > 0)
) ENGINE = InnoDB COMMENT = 'Тарифні плани';


-- 3. user_subscriptions - підписки користувачів (історія оформлень)
-- 3НФ: price_paid - фактично сплачена сума, credit_applied - зарахування за невикористані
--      дні попередньої підписки; price_paid + credit_applied = ціна тарифу на момент
--      оформлення * кількість місяців. Обидва стовпці - історичні факти, а не копія ціни тарифу.
-- Скасування не змінює період: start_date і end_date зберігають початкові умови,
--      а момент скасування записується в cancelled_at.
-- Період [start_date; end_date] включає обидві дати.
-- status - контрольована надлишковість: 'active' з минулою end_date переводить
--      у 'expired' процедура sp_expire_subscriptions; перевірки доступу завжди
--      дивляться і на статус, і на дати.
-- FK user_id: RESTRICT (підписки - фінансова історія, користувача деактивують, а не видаляють);
-- FK plan_id: RESTRICT (тариф, на який є підписки, видаляти не можна).

CREATE TABLE user_subscriptions (
    subscription_id  INT UNSIGNED NOT NULL AUTO_INCREMENT COMMENT 'Первинний ключ',
    user_id          INT UNSIGNED NOT NULL COMMENT 'Користувач',
    plan_id          INT UNSIGNED NOT NULL COMMENT 'Тариф',
    start_date       DATE NOT NULL COMMENT 'Дата початку (включно)',
    end_date         DATE NOT NULL COMMENT 'Дата закінчення (включно)',
    status           ENUM('active','expired','cancelled') NOT NULL DEFAULT 'active' COMMENT 'Статус підписки',
    price_paid       DECIMAL(8,2) NOT NULL COMMENT 'Фактично сплачена сума за період, грн (без значення за замовчуванням)',
    credit_applied   DECIMAL(8,2) NOT NULL DEFAULT 0.00 COMMENT 'Зараховано за невикористані дні попередньої підписки, грн',
    cancelled_at     DATETIME NULL COMMENT 'Коли підписку скасовано (лише для status = cancelled)',
    created_at       DATETIME NOT NULL DEFAULT CURRENT_TIMESTAMP COMMENT 'Коли створено запис',
    PRIMARY KEY (subscription_id),
    KEY idx_us_user_status (user_id, status, end_date),
    KEY idx_us_status_end (status, end_date),
    KEY idx_us_plan_start (plan_id, start_date),
    CONSTRAINT fk_us_user FOREIGN KEY (user_id) REFERENCES users (user_id)
        ON DELETE RESTRICT ON UPDATE RESTRICT,
    CONSTRAINT fk_us_plan FOREIGN KEY (plan_id) REFERENCES subscription_plans (plan_id)
        ON DELETE RESTRICT ON UPDATE RESTRICT,
    CONSTRAINT chk_us_dates CHECK (end_date >= start_date),
    CONSTRAINT chk_us_price CHECK (price_paid >= 0),
    CONSTRAINT chk_us_credit CHECK (credit_applied >= 0),
    CONSTRAINT chk_us_cancelled CHECK ((status = 'cancelled') = (cancelled_at IS NOT NULL))
) ENGINE = InnoDB COMMENT = 'Підписки користувачів';


-- 4. genres - довідник жанрів
CREATE TABLE genres (
    genre_id     INT UNSIGNED NOT NULL AUTO_INCREMENT COMMENT 'Первинний ключ',
    name         VARCHAR(100) NOT NULL COMMENT 'Назва жанру, унікальна',
    description  VARCHAR(255) NULL COMMENT 'Короткий опис жанру',
    PRIMARY KEY (genre_id),
    UNIQUE KEY uq_genres_name (name)
) ENGINE = InnoDB COMMENT = 'Жанри';

-- 5. movies - фільми
-- 3НФ: усі атрибути описують фільм і залежать лише від movie_id.
CREATE TABLE movies (
    movie_id      INT UNSIGNED NOT NULL AUTO_INCREMENT COMMENT 'Первинний ключ',
    title         VARCHAR(200) NOT NULL COMMENT 'Назва',
    description   TEXT NULL COMMENT 'Опис',
    release_year  SMALLINT UNSIGNED NOT NULL COMMENT 'Рік виходу',
    duration_min  SMALLINT UNSIGNED NOT NULL COMMENT 'Тривалість, хвилини',
    age_rating    ENUM('0+','6+','12+','16+','18+') NOT NULL DEFAULT '0+' COMMENT 'Віковий рейтинг',
    rating        DECIMAL(3,1) NULL COMMENT 'Рейтинг 0-10',
    poster_url    VARCHAR(500) NULL COMMENT 'Посилання на постер',
    trailer_url   VARCHAR(500) NULL COMMENT 'Посилання на трейлер',
    created_at    DATETIME NOT NULL DEFAULT CURRENT_TIMESTAMP COMMENT 'Додано в каталог',
    PRIMARY KEY (movie_id),
    KEY idx_movies_title (title),
    KEY idx_movies_year (release_year),
    CONSTRAINT chk_movies_year CHECK (release_year BETWEEN 1888 AND 2100),
    CONSTRAINT chk_movies_duration CHECK (duration_min > 0),
    CONSTRAINT chk_movies_rating CHECK (rating IS NULL OR rating BETWEEN 0 AND 10)
) ENGINE = InnoDB COMMENT = 'Фільми';

-- 6. tv_series - серіали
-- seasons_count - контрольована надлишковість, яку вимагає завдання.
--   Значення завжди дорівнює MAX(season_number) епізодів серіалу (0, якщо епізодів немає)
--   і підтримується тригерами: trg_tv_series_bi (новий серіал = 0 сезонів),
--   trg_tv_series_bu (ручна зміна значення замінюється обчисленим),
--   trg_episodes_ai / trg_episodes_au / trg_episodes_ad (перерахунок після змін епізодів).
CREATE TABLE tv_series (
    series_id      INT UNSIGNED NOT NULL AUTO_INCREMENT COMMENT 'Первинний ключ',
    title          VARCHAR(200) NOT NULL COMMENT 'Назва',
    description    TEXT NULL COMMENT 'Опис',
    start_year     SMALLINT UNSIGNED NOT NULL COMMENT 'Рік початку показу',
    seasons_count  TINYINT UNSIGNED NOT NULL DEFAULT 0 COMMENT 'Кількість сезонів (обчислюється тригерами)',
    age_rating     ENUM('0+','6+','12+','16+','18+') NOT NULL DEFAULT '0+' COMMENT 'Віковий рейтинг',
    rating         DECIMAL(3,1) NULL COMMENT 'Рейтинг 0-10',
    poster_url     VARCHAR(500) NULL COMMENT 'Посилання на постер',
    created_at     DATETIME NOT NULL DEFAULT CURRENT_TIMESTAMP COMMENT 'Додано в каталог',
    PRIMARY KEY (series_id),
    KEY idx_series_title (title),
    CONSTRAINT chk_series_year CHECK (start_year BETWEEN 1888 AND 2100),
    CONSTRAINT chk_series_rating CHECK (rating IS NULL OR rating BETWEEN 0 AND 10)
) ENGINE = InnoDB COMMENT = 'Серіали';

-- 7. episodes - епізоди серіалів
-- 3НФ: епізод ідентифікується ключем episode_id; альтернативний ключ
--      (series_id, season_number, episode_number) унікальний.
-- FK series_id: CASCADE (видалення серіалу видаляє його епізоди; якщо до епізодів
--      привʼязані відеофайли, видалення блокується RESTRICT у video_files).
CREATE TABLE episodes (
    episode_id      INT UNSIGNED NOT NULL AUTO_INCREMENT COMMENT 'Первинний ключ',
    series_id       INT UNSIGNED NOT NULL COMMENT 'Серіал',
    season_number   TINYINT UNSIGNED NOT NULL COMMENT 'Номер сезону',
    episode_number  SMALLINT UNSIGNED NOT NULL COMMENT 'Номер епізоду в сезоні',
    title           VARCHAR(200) NOT NULL COMMENT 'Назва епізоду',
    duration_min    SMALLINT UNSIGNED NOT NULL COMMENT 'Тривалість, хвилини',
    description     TEXT NULL COMMENT 'Опис',
    PRIMARY KEY (episode_id),
    UNIQUE KEY uq_episodes_position (series_id, season_number, episode_number),
    CONSTRAINT fk_episodes_series FOREIGN KEY (series_id) REFERENCES tv_series (series_id)
        ON DELETE CASCADE ON UPDATE RESTRICT,
    CONSTRAINT chk_episodes_season CHECK (season_number > 0),
    CONSTRAINT chk_episodes_number CHECK (episode_number > 0),
    CONSTRAINT chk_episodes_duration CHECK (duration_min > 0)
) ENGINE = InnoDB COMMENT = 'Епізоди серіалів';

-- 8. media_genres - звʼязок жанрів з фільмами АБО серіалами (M:N)
-- Рівно одне з movie_id / series_id заповнене (CHECK).
-- УВАГА: у MySQL не можна поєднувати CHECK зі стовпцями, що входять до FK з діями
--   CASCADE / SET NULL. Тому FK movie_id та series_id мають ON DELETE RESTRICT:
--   перед видаленням фільму чи серіалу слід видалити його звʼязки з жанрами.
--   FK genre_id у CHECK не бере участі, тому для нього застосовано ON DELETE CASCADE.
CREATE TABLE media_genres (
    media_genre_id  INT UNSIGNED NOT NULL AUTO_INCREMENT COMMENT 'Первинний ключ',
    movie_id        INT UNSIGNED NULL COMMENT 'Фільм (або NULL, якщо заповнено series_id)',
    series_id       INT UNSIGNED NULL COMMENT 'Серіал (або NULL, якщо заповнено movie_id)',
    genre_id        INT UNSIGNED NOT NULL COMMENT 'Жанр',
    PRIMARY KEY (media_genre_id),
    UNIQUE KEY uq_mg_movie_genre (movie_id, genre_id),
    UNIQUE KEY uq_mg_series_genre (series_id, genre_id),
    KEY idx_mg_genre (genre_id),
    CONSTRAINT fk_mg_movie FOREIGN KEY (movie_id) REFERENCES movies (movie_id)
        ON DELETE RESTRICT ON UPDATE RESTRICT,
    CONSTRAINT fk_mg_series FOREIGN KEY (series_id) REFERENCES tv_series (series_id)
        ON DELETE RESTRICT ON UPDATE RESTRICT,
    CONSTRAINT fk_mg_genre FOREIGN KEY (genre_id) REFERENCES genres (genre_id)
        ON DELETE CASCADE ON UPDATE RESTRICT,
    CONSTRAINT chk_mg_one_target CHECK (
        (movie_id IS NOT NULL AND series_id IS NULL) OR (movie_id IS NULL AND series_id IS NOT NULL)
    )
) ENGINE = InnoDB COMMENT = 'Жанри фільмів і серіалів';


-- 9. video_files - відеофайли (посилання на файл, а не сам файл)
-- РІШЕННЯ: відео в БД НЕ зберігається, лише file_url (шлях або URL).
--   Причини: (1) BLOB розміром у гігабайти роздуває БД, бекапи та реплікацію;
--   (2) СКБД не оптимізована для потокової віддачі та HTTP Range-запитів;
--   (3) файли зручно віддавати через файлову систему, CDN чи обʼєктне сховище;
--   (4) одне відео має кілька якостей, і метадані в БД легко індексувати.
-- Файл привʼязаний рівно до одного обʼєкта: movie_id АБО episode_id (CHECK).
-- Через CHECK обидва FK мають RESTRICT (див. пояснення у media_genres).
-- Файл, який уже переглядали, не видаляють, а вимикають (is_active = FALSE),
--   щоб не втратити історію переглядів і статистику.
-- 3НФ: усі атрибути описують конкретний файл. Звʼязок із тривалістю контенту
--   контролюється тригерами (допуск 60 с) з обох боків: при зміні файлу
--   (trg_video_files_bi/bu) і при зміні тривалості фільму чи епізоду (trg_movies_bu, trg_episodes_bu).
CREATE TABLE video_files (
    video_file_id   INT UNSIGNED NOT NULL AUTO_INCREMENT COMMENT 'Первинний ключ',
    movie_id        INT UNSIGNED NULL COMMENT 'Фільм (або NULL, якщо заповнено episode_id)',
    episode_id      INT UNSIGNED NULL COMMENT 'Епізод (або NULL, якщо заповнено movie_id)',
    file_url        VARCHAR(500) NOT NULL COMMENT 'Шлях або URL відеофайлу (відео в БД не зберігається)',
    quality         ENUM('480p','720p','1080p','4K') NOT NULL COMMENT 'Якість',
    `format`        ENUM('mp4','webm') NOT NULL DEFAULT 'mp4' COMMENT 'Формат контейнера',
    duration_sec    INT UNSIGNED NOT NULL COMMENT 'Тривалість файлу, секунди',
    file_size_mb    DECIMAL(10,2) NOT NULL COMMENT 'Розмір файлу, МБ',
    audio_language  VARCHAR(10) NOT NULL DEFAULT 'en' COMMENT 'Мова аудіодоріжки (ISO 639-1; zxx - без мовлення)',
    is_active       BOOLEAN NOT NULL DEFAULT TRUE COMMENT 'Чи доступний файл для відтворення',
    created_at      DATETIME NOT NULL DEFAULT CURRENT_TIMESTAMP COMMENT 'Коли додано',
    PRIMARY KEY (video_file_id),
    UNIQUE KEY uq_vf_url (file_url),
    KEY idx_vf_movie (movie_id, quality, is_active),
    KEY idx_vf_episode (episode_id, quality, is_active),
    CONSTRAINT fk_vf_movie FOREIGN KEY (movie_id) REFERENCES movies (movie_id)
        ON DELETE RESTRICT ON UPDATE RESTRICT,
    CONSTRAINT fk_vf_episode FOREIGN KEY (episode_id) REFERENCES episodes (episode_id)
        ON DELETE RESTRICT ON UPDATE RESTRICT,
    CONSTRAINT chk_vf_one_target CHECK (
        (movie_id IS NOT NULL AND episode_id IS NULL) OR (movie_id IS NULL AND episode_id IS NOT NULL)
    ),
    CONSTRAINT chk_vf_duration CHECK (duration_sec > 0),
    CONSTRAINT chk_vf_size CHECK (file_size_mb > 0)
) ENGINE = InnoDB COMMENT = 'Відеофайли (посилання)';

-- 10. subtitles - субтитри до відеофайлів
-- FK video_file_id: CASCADE (субтитри не існують без файлу).
-- file_url унікальний, як і у video_files: один файл субтитрів - один запис.
CREATE TABLE subtitles (
    subtitle_id    INT UNSIGNED NOT NULL AUTO_INCREMENT COMMENT 'Первинний ключ',
    video_file_id  INT UNSIGNED NOT NULL COMMENT 'Відеофайл',
    language_code  VARCHAR(10) NOT NULL COMMENT 'Мова субтитрів (ISO 639-1)',
    label          VARCHAR(50) NULL COMMENT 'Назва мови для відображення',
    file_url       VARCHAR(500) NOT NULL COMMENT 'Шлях або URL файлу субтитрів',
    PRIMARY KEY (subtitle_id),
    UNIQUE KEY uq_subtitles_file_lang (video_file_id, language_code),
    UNIQUE KEY uq_subtitles_url (file_url),
    CONSTRAINT fk_subtitles_file FOREIGN KEY (video_file_id) REFERENCES video_files (video_file_id)
        ON DELETE CASCADE ON UPDATE RESTRICT
) ENGINE = InnoDB COMMENT = 'Субтитри';

-- 11. watch_history - історія переглядів і позиція зупинки
-- UNIQUE (user_id, video_file_id): один запис на пару користувач + файл,
--   що дозволяє продовжити перегляд (INSERT ... ON DUPLICATE KEY UPDATE).
-- completed - ознака "хоча б раз переглянуто понад 90%"; після встановлення не скидається
--   (повторний перегляд не стирає факт завершення).
-- started_at / updated_at мають точність до мілісекунд (DATETIME(3)), щоб
--   "останній перегляд" визначався однозначно навіть для дій в одну секунду.
-- FK user_id: CASCADE (особисті дані користувача; видалити можна лише користувача
--   без підписок, див. users). FK video_file_id: RESTRICT (статистику не можна
--   втратити видаленням файлу; файл вимикають через is_active).
-- 3НФ: усі атрибути описують перегляд конкретного файла конкретним користувачем.
CREATE TABLE watch_history (
    history_id         INT UNSIGNED NOT NULL AUTO_INCREMENT COMMENT 'Первинний ключ',
    user_id            INT UNSIGNED NOT NULL COMMENT 'Користувач',
    video_file_id      INT UNSIGNED NOT NULL COMMENT 'Переглядуваний файл',
    started_at         DATETIME(3) NOT NULL DEFAULT CURRENT_TIMESTAMP(3) COMMENT 'Початок першого перегляду',
    last_position_sec  INT UNSIGNED NOT NULL DEFAULT 0 COMMENT 'Остання позиція зупинки, секунди',
    completed          BOOLEAN NOT NULL DEFAULT FALSE COMMENT 'Хоча б раз переглянуто понад 90% (не скидається)',
    updated_at         DATETIME(3) NOT NULL DEFAULT CURRENT_TIMESTAMP(3) ON UPDATE CURRENT_TIMESTAMP(3) COMMENT 'Останнє оновлення',
    PRIMARY KEY (history_id),
    UNIQUE KEY uq_wh_user_file (user_id, video_file_id),
    KEY idx_wh_user_updated (user_id, updated_at),
    KEY idx_wh_updated (updated_at),
    KEY idx_wh_file (video_file_id),
    CONSTRAINT fk_wh_user FOREIGN KEY (user_id) REFERENCES users (user_id)
        ON DELETE CASCADE ON UPDATE RESTRICT,
    CONSTRAINT fk_wh_file FOREIGN KEY (video_file_id) REFERENCES video_files (video_file_id)
        ON DELETE RESTRICT ON UPDATE RESTRICT
) ENGINE = InnoDB COMMENT = 'Історія переглядів';

-- ТРИГЕРИ
DELIMITER $$

-- Дата народження не може бути в майбутньому
CREATE TRIGGER trg_users_bi BEFORE INSERT ON users
FOR EACH ROW
BEGIN
    IF NEW.birth_date IS NOT NULL AND NEW.birth_date > CURDATE() THEN
        SIGNAL SQLSTATE '45000' SET MESSAGE_TEXT = 'Дата народження не може бути в майбутньому';
    END IF;
END$$

CREATE TRIGGER trg_users_bu BEFORE UPDATE ON users
FOR EACH ROW
BEGIN
    IF NEW.birth_date IS NOT NULL AND NEW.birth_date > CURDATE() THEN
        SIGNAL SQLSTATE '45000' SET MESSAGE_TEXT = 'Дата народження не може бути в майбутньому';
    END IF;
END$$

-- Заборона двох активних підписок користувача з перетином періодів.
-- Спершу блокується рядок користувача (SELECT ... FOR UPDATE), тому дві одночасні
-- транзакції для одного користувача виконують перевірку по черзі: друга чекає завершення
-- першої і потім бачить її зафіксований рядок (без блокування обидві могли б пройти перевірку).
-- Блокуюче читання самої user_subscriptions у її тригері MySQL не дозволяє (помилка 1442),
-- тому підписки читаються звичайним читанням уже після отримання блокування.
CREATE TRIGGER trg_user_subscriptions_bi BEFORE INSERT ON user_subscriptions
FOR EACH ROW
BEGIN
    DECLARE v_lock INT DEFAULT NULL;
    DECLARE v_cnt  INT DEFAULT 0;
    IF NEW.status = 'active' THEN
        SELECT user_id INTO v_lock FROM users WHERE user_id = NEW.user_id FOR UPDATE;
        SELECT COUNT(*) INTO v_cnt
          FROM user_subscriptions us
         WHERE us.user_id = NEW.user_id
           AND us.status = 'active'
           AND us.start_date <= NEW.end_date
           AND us.end_date >= NEW.start_date;
        IF v_cnt > 0 THEN
            SIGNAL SQLSTATE '45000'
                SET MESSAGE_TEXT = 'У користувача вже є активна підписка, що перетинається за датами';
        END IF;
    END IF;
END$$

CREATE TRIGGER trg_user_subscriptions_bu BEFORE UPDATE ON user_subscriptions
FOR EACH ROW
BEGIN
    DECLARE v_lock INT DEFAULT NULL;
    DECLARE v_cnt  INT DEFAULT 0;
    IF NEW.status = 'active' THEN
        SELECT user_id INTO v_lock FROM users WHERE user_id = NEW.user_id FOR UPDATE;
        SELECT COUNT(*) INTO v_cnt
          FROM user_subscriptions us
         WHERE us.user_id = NEW.user_id
           AND us.subscription_id <> NEW.subscription_id
           AND us.status = 'active'
           AND us.start_date <= NEW.end_date
           AND us.end_date >= NEW.start_date;
        IF v_cnt > 0 THEN
            SIGNAL SQLSTATE '45000'
                SET MESSAGE_TEXT = 'У користувача вже є активна підписка, що перетинається за датами';
        END IF;
    END IF;
END$$

-- seasons_count: новий серіал ще не має епізодів, тому 0 сезонів
-- (значення, передане в INSERT, ігнорується - кількість сезонів лише обчислюється)
CREATE TRIGGER trg_tv_series_bi BEFORE INSERT ON tv_series
FOR EACH ROW
BEGIN
    SET NEW.seasons_count = 0;
END$$

-- seasons_count: при будь-якому оновленні рядка серіалу значення обчислюється заново,
-- тому ручне UPDATE tv_series SET seasons_count = ... не може зробити його неправильним
CREATE TRIGGER trg_tv_series_bu BEFORE UPDATE ON tv_series
FOR EACH ROW
BEGIN
    SET NEW.seasons_count = (SELECT COALESCE(MAX(e.season_number), 0)
                               FROM episodes e WHERE e.series_id = NEW.series_id);
END$$

-- seasons_count: перерахунок після додавання, зміни та видалення епізодів.
-- Примітка: каскадне видалення епізодів разом із серіалом тригери не запускає,
-- але тоді й сам рядок серіалу видаляється, тож перерахунок не потрібен.
CREATE TRIGGER trg_episodes_ai AFTER INSERT ON episodes
FOR EACH ROW
BEGIN
    UPDATE tv_series
       SET seasons_count = (SELECT COALESCE(MAX(e.season_number), 0)
                              FROM episodes e WHERE e.series_id = NEW.series_id)
     WHERE series_id = NEW.series_id;
END$$

CREATE TRIGGER trg_episodes_au AFTER UPDATE ON episodes
FOR EACH ROW
BEGIN
    IF NEW.series_id <> OLD.series_id OR NEW.season_number <> OLD.season_number THEN
        UPDATE tv_series
           SET seasons_count = (SELECT COALESCE(MAX(e.season_number), 0)
                                  FROM episodes e WHERE e.series_id = NEW.series_id)
         WHERE series_id = NEW.series_id;
        IF NEW.series_id <> OLD.series_id THEN
            UPDATE tv_series
               SET seasons_count = (SELECT COALESCE(MAX(e.season_number), 0)
                                      FROM episodes e WHERE e.series_id = OLD.series_id)
             WHERE series_id = OLD.series_id;
        END IF;
    END IF;
END$$

CREATE TRIGGER trg_episodes_ad AFTER DELETE ON episodes
FOR EACH ROW
BEGIN
    UPDATE tv_series
       SET seasons_count = (SELECT COALESCE(MAX(e.season_number), 0)
                              FROM episodes e WHERE e.series_id = OLD.series_id)
     WHERE series_id = OLD.series_id;
END$$

-- Зміна тривалості фільму не повинна розходитися з тривалістю його файлів (допуск 60 с)
CREATE TRIGGER trg_movies_bu BEFORE UPDATE ON movies
FOR EACH ROW
BEGIN
    IF NEW.duration_min <> OLD.duration_min AND EXISTS (
        SELECT 1 FROM video_files vf
        WHERE vf.movie_id = NEW.movie_id
          AND ABS(CAST(vf.duration_sec AS SIGNED) - CAST(NEW.duration_min AS SIGNED) * 60) > 60
    ) THEN
        SIGNAL SQLSTATE '45000'
            SET MESSAGE_TEXT = 'Нова тривалість фільму суттєво відрізняється від тривалості його відеофайлів';
    END IF;
END$$

-- Те саме для епізоду
CREATE TRIGGER trg_episodes_bu BEFORE UPDATE ON episodes
FOR EACH ROW
BEGIN
    IF NEW.duration_min <> OLD.duration_min AND EXISTS (
        SELECT 1 FROM video_files vf
        WHERE vf.episode_id = NEW.episode_id
          AND ABS(CAST(vf.duration_sec AS SIGNED) - CAST(NEW.duration_min AS SIGNED) * 60) > 60
    ) THEN
        SIGNAL SQLSTATE '45000'
            SET MESSAGE_TEXT = 'Нова тривалість епізоду суттєво відрізняється від тривалості його відеофайлів';
    END IF;
END$$

-- Тривалість відеофайлу має відповідати тривалості фільму/епізоду (допуск 60 с)
CREATE TRIGGER trg_video_files_bi BEFORE INSERT ON video_files
FOR EACH ROW
BEGIN
    DECLARE v_expected BIGINT DEFAULT NULL;
    IF NEW.movie_id IS NOT NULL THEN
        SELECT duration_min * 60 INTO v_expected FROM movies WHERE movie_id = NEW.movie_id;
    ELSEIF NEW.episode_id IS NOT NULL THEN
        SELECT duration_min * 60 INTO v_expected FROM episodes WHERE episode_id = NEW.episode_id;
    END IF;
    IF v_expected IS NOT NULL
       AND ABS(CAST(NEW.duration_sec AS SIGNED) - CAST(v_expected AS SIGNED)) > 60 THEN
        SIGNAL SQLSTATE '45000'
            SET MESSAGE_TEXT = 'Тривалість файлу суттєво відрізняється від тривалості фільму або епізоду';
    END IF;
END$$

CREATE TRIGGER trg_video_files_bu BEFORE UPDATE ON video_files
FOR EACH ROW
BEGIN
    DECLARE v_expected BIGINT DEFAULT NULL;
    IF NEW.movie_id IS NOT NULL THEN
        SELECT duration_min * 60 INTO v_expected FROM movies WHERE movie_id = NEW.movie_id;
    ELSEIF NEW.episode_id IS NOT NULL THEN
        SELECT duration_min * 60 INTO v_expected FROM episodes WHERE episode_id = NEW.episode_id;
    END IF;
    IF v_expected IS NOT NULL
       AND ABS(CAST(NEW.duration_sec AS SIGNED) - CAST(v_expected AS SIGNED)) > 60 THEN
        SIGNAL SQLSTATE '45000'
            SET MESSAGE_TEXT = 'Тривалість файлу суттєво відрізняється від тривалості фільму або епізоду';
    END IF;
END$$

-- Позиція зупинки не може перевищувати тривалість файлу
CREATE TRIGGER trg_watch_history_bi BEFORE INSERT ON watch_history
FOR EACH ROW
BEGIN
    DECLARE v_duration INT UNSIGNED DEFAULT NULL;
    SELECT duration_sec INTO v_duration FROM video_files WHERE video_file_id = NEW.video_file_id;
    IF v_duration IS NOT NULL AND NEW.last_position_sec > v_duration THEN
        SIGNAL SQLSTATE '45000'
            SET MESSAGE_TEXT = 'Позиція перегляду перевищує тривалість відеофайлу';
    END IF;
END$$

CREATE TRIGGER trg_watch_history_bu BEFORE UPDATE ON watch_history
FOR EACH ROW
BEGIN
    DECLARE v_duration INT UNSIGNED DEFAULT NULL;
    SELECT duration_sec INTO v_duration FROM video_files WHERE video_file_id = NEW.video_file_id;
    IF v_duration IS NOT NULL AND NEW.last_position_sec > v_duration THEN
        SIGNAL SQLSTATE '45000'
            SET MESSAGE_TEXT = 'Позиція перегляду перевищує тривалість відеофайлу';
    END IF;
END$$

DELIMITER ;
