-- sql/02_seed.sql - тестові дані (генерується узгодженим набором, дати відносно CURDATE()/NOW())
-- Фільми: відкриті проєкти Blender Foundation / Blender Studio (ліцензії CC-BY).
-- Серіали та користувачі: вигадані демонстраційні дані.
-- Паролі: PBKDF2-SHA256 (100 000 ітерацій) у тому ж форматі pbkdf2$сіль$хеш, що й у застосунку
--   (app.py, hash_password). Відкриті паролі: Demo#Pass1 ... Demo#Pass10.
USE streaming_service;

-- Користувачі
INSERT INTO users (user_id, email, password_hash, display_name, birth_date, country_code, registered_at, is_active) VALUES
(1, 'olena.kovalenko@example.com', 'pbkdf2$demo01salt01$0e0e092db0b196f84d6a8f49d9f03316bececda18494adda12eb1b8c71b549fa', 'Олена Коваленко', '1995-03-14', 'UA', DATE_SUB(NOW(), INTERVAL 400 DAY), TRUE),
(2, 'andrii.shevchenko@example.com', 'pbkdf2$demo02salt02$f7e5800bb1aaa7097be127bab04bb040572ff8aa19974e9bc51dcb619ae4f434', 'Андрій Шевченко', '1990-07-21', 'UA', DATE_SUB(NOW(), INTERVAL 300 DAY), TRUE),
(3, 'maria.boyko@example.com', 'pbkdf2$demo03salt03$fc05a88051e4e1ee8c41b2241cf951725a9f667dfe2aea1aba9a4ab7d99810dc', 'Марія Бойко', '2001-11-02', 'UA', DATE_SUB(NOW(), INTERVAL 250 DAY), TRUE),
(4, 'ivan.melnyk@example.com', 'pbkdf2$demo04salt04$597fecc383655291c8f3869c021940a8169deebf4f5760c2a73f4fddb1aeb236', 'Іван Мельник', '1998-05-30', 'UA', DATE_SUB(NOW(), INTERVAL 220 DAY), TRUE),
(5, 'sofia.tkachenko@example.com', 'pbkdf2$demo05salt05$591f7dfd6759907f574c89f6e71a75e77558af2606dc02e5a22b38f4eb322a33', 'Софія Ткаченко', '1993-09-18', 'UA', DATE_SUB(NOW(), INTERVAL 200 DAY), TRUE),
(6, 'dmytro.kravchuk@example.com', 'pbkdf2$demo06salt06$a3b3949629d3563ff7562035b5c0ed5b55681328764e2266b80271283af9588a', 'Дмитро Кравчук', '1985-01-25', 'UA', DATE_SUB(NOW(), INTERVAL 330 DAY), TRUE),
(7, 'anna.oliynyk@example.com', 'pbkdf2$demo07salt07$bbeca2085a377e126583f890269843149eee74c3b8d79009d292c3fae0bd591f', 'Анна Олійник', '2003-06-09', 'UA', DATE_SUB(NOW(), INTERVAL 180 DAY), TRUE),
(8, 'bohdan.lysenko@example.com', 'pbkdf2$demo08salt08$bab21b84257546f9273f102718c828a6e4d0fc96bdcd55e7e636735773ac4b19', 'Богдан Лисенко', '1988-12-12', 'UA', DATE_SUB(NOW(), INTERVAL 450 DAY), TRUE),
(9, 'kateryna.moroz@example.com', 'pbkdf2$demo09salt09$6ea57c15215d77d9e1e4247be9100c53d41787ce44a1a226b2f8649a02d628ce', 'Катерина Мороз', '1999-08-27', 'UA', DATE_SUB(NOW(), INTERVAL 260 DAY), TRUE),
(10, 'taras.honchar@example.com', 'pbkdf2$demo10salt10$569cbb9c20d346cd559000b052f2e0cab6f7cbfaa104f962114bc75ffbcc270a', 'Тарас Гончар', '1996-02-05', 'UA', DATE_SUB(NOW(), INTERVAL 20 DAY), TRUE);

-- Тарифи (ціни в гривнях за місяць)
INSERT INTO subscription_plans (plan_id, name, price_per_month, max_quality, max_screens, has_ads) VALUES
(1, 'Безкоштовний', 0.00, '480p', 1, TRUE),
(2, 'Мобільний', 79.00, '720p', 1, TRUE),
(3, 'Базовий з рекламою', 99.00, '720p', 1, TRUE),
(4, 'Базовий', 149.00, '720p', 1, FALSE),
(5, 'Стандарт з рекламою', 169.00, '1080p', 2, TRUE),
(6, 'Стандарт', 229.00, '1080p', 2, FALSE),
(7, 'Преміум', 329.00, '4K', 4, FALSE),
(8, 'Сімейний 4K', 449.00, '4K', 6, FALSE);

-- Жанри
INSERT INTO genres (genre_id, name, description) VALUES
(1, 'Анімація', 'Мультиплікаційні фільми та серіали'),
(2, 'Фантастика', 'Науково-фантастичні історії'),
(3, 'Комедія', 'Гумористичний контент'),
(4, 'Пригоди', 'Динамічні історії з подорожами та пошуками'),
(5, 'Фентезі', 'Магія та вигадані світи'),
(6, 'Драма', 'Серйозні сюжети про людей і стосунки'),
(7, 'Короткометражний', 'Фільми тривалістю до 20 хвилин'),
(8, 'Документальний', 'Науково-популярний та документальний контент'),
(9, 'Трилер', 'Напружені сюжети'),
(10, 'Сімейний', 'Контент для перегляду всією родиною');

-- Підписки. Період включає обидві дати і відповідає правилу процедури sp_subscribe:
--   end_date = start_date + N місяців - 1 день. Дату закінчення задано відносно поточної дати,
--   тому кількість днів до закінчення (5, 15, 20 ...) не залежить від дня запуску сценарію,
--   а дата початку обчислюється від неї. Є активні, прострочені, скасована підписки та такі,
--   що спливають за 5 днів. Скасована підписка зберігає початковий період і час скасування.
INSERT INTO user_subscriptions (user_id, plan_id, start_date, end_date, status, price_paid, cancelled_at) VALUES
(1, 6, DATE_ADD(DATE_SUB(DATE_ADD(CURDATE(), INTERVAL 20 DAY), INTERVAL 2 MONTH), INTERVAL 1 DAY), DATE_ADD(CURDATE(), INTERVAL 20 DAY), 'active', 458.00, NULL),
(1, 4, DATE_ADD(DATE_SUB(DATE_SUB(CURDATE(), INTERVAL 100 DAY), INTERVAL 2 MONTH), INTERVAL 1 DAY), DATE_SUB(CURDATE(), INTERVAL 100 DAY), 'expired', 298.00, NULL),
(2, 7, DATE_ADD(DATE_SUB(DATE_ADD(CURDATE(), INTERVAL 20 DAY), INTERVAL 1 MONTH), INTERVAL 1 DAY), DATE_ADD(CURDATE(), INTERVAL 20 DAY), 'active', 329.00, NULL),
(2, 6, DATE_ADD(DATE_SUB(DATE_SUB(CURDATE(), INTERVAL 70 DAY), INTERVAL 1 MONTH), INTERVAL 1 DAY), DATE_SUB(CURDATE(), INTERVAL 70 DAY), 'cancelled', 229.00, DATE_SUB(NOW(), INTERVAL 75 DAY)),
(3, 4, DATE_ADD(DATE_SUB(DATE_SUB(CURDATE(), INTERVAL 10 DAY), INTERVAL 3 MONTH), INTERVAL 1 DAY), DATE_SUB(CURDATE(), INTERVAL 10 DAY), 'expired', 447.00, NULL),
(4, 3, DATE_ADD(DATE_SUB(DATE_ADD(CURDATE(), INTERVAL 5 DAY), INTERVAL 1 MONTH), INTERVAL 1 DAY), DATE_ADD(CURDATE(), INTERVAL 5 DAY), 'active', 99.00, NULL),
(5, 5, DATE_ADD(DATE_SUB(DATE_ADD(CURDATE(), INTERVAL 5 DAY), INTERVAL 2 MONTH), INTERVAL 1 DAY), DATE_ADD(CURDATE(), INTERVAL 5 DAY), 'active', 338.00, NULL),
(5, 4, DATE_ADD(DATE_SUB(DATE_SUB(CURDATE(), INTERVAL 60 DAY), INTERVAL 2 MONTH), INTERVAL 1 DAY), DATE_SUB(CURDATE(), INTERVAL 60 DAY), 'expired', 298.00, NULL),
(6, 8, DATE_ADD(DATE_SUB(DATE_ADD(CURDATE(), INTERVAL 15 DAY), INTERVAL 1 MONTH), INTERVAL 1 DAY), DATE_ADD(CURDATE(), INTERVAL 15 DAY), 'active', 449.00, NULL),
(6, 6, DATE_ADD(DATE_SUB(DATE_SUB(CURDATE(), INTERVAL 60 DAY), INTERVAL 1 MONTH), INTERVAL 1 DAY), DATE_SUB(CURDATE(), INTERVAL 60 DAY), 'expired', 229.00, NULL),
(7, 2, DATE_ADD(DATE_SUB(DATE_SUB(CURDATE(), INTERVAL 40 DAY), INTERVAL 1 MONTH), INTERVAL 1 DAY), DATE_SUB(CURDATE(), INTERVAL 40 DAY), 'expired', 79.00, NULL),
(8, 6, DATE_ADD(DATE_SUB(DATE_ADD(CURDATE(), INTERVAL 50 DAY), INTERVAL 6 MONTH), INTERVAL 1 DAY), DATE_ADD(CURDATE(), INTERVAL 50 DAY), 'active', 1374.00, NULL),
(9, 1, DATE_ADD(DATE_SUB(DATE_ADD(CURDATE(), INTERVAL 165 DAY), INTERVAL 12 MONTH), INTERVAL 1 DAY), DATE_ADD(CURDATE(), INTERVAL 165 DAY), 'active', 0.00, NULL);

-- Фільми
INSERT INTO movies (movie_id, title, description, release_year, duration_min, age_rating, rating, poster_url, trailer_url) VALUES
(1, 'Big Buck Bunny', 'Добродушний гігантський кролик помщається трьом гризунам, які порушили його спокій.', 2008, 10, '0+', 7.2, 'https://placehold.co/300x450/png?text=Big+Buck+Bunny', 'https://www.youtube.com/watch?v=aqz-KE-bpKQ'),
(2, 'Sintel', 'Молода дівчина вирушає в небезпечну подорож, щоб знайти свого дракона Скейлз.', 2010, 15, '12+', 7.5, 'https://placehold.co/300x450/png?text=Sintel', 'https://www.youtube.com/watch?v=eRsGyueVLvQ'),
(3, 'Tears of Steel', 'Група вчених і воїнів намагається врятувати світ від роботів у постапокаліптичному Амстердамі.', 2012, 12, '12+', 6.6, 'https://placehold.co/300x450/png?text=Tears+of+Steel', 'https://www.youtube.com/watch?v=R6MlUcmOul8'),
(4, 'Elephants Dream', 'Двоє мандрівників досліджують дивну механічну споруду, де реальність поступається уяві.', 2006, 11, '6+', 6.2, 'https://placehold.co/300x450/png?text=Elephants+Dream', 'https://www.youtube.com/watch?v=TLkA0RELQ1g'),
(5, 'Cosmos Laundromat', 'Овечка Френк зустрічає дивного торговця, який пропонує йому безліч життів.', 2015, 12, '12+', 7.0, 'https://placehold.co/300x450/png?text=Cosmos+Laundromat', 'https://www.youtube.com/watch?v=Y-rmzh0PI3c'),
(6, 'Spring', 'Пастушка та її пес зустрічаються з духами природи під час весняного оновлення лісу.', 2019, 8, '6+', 7.9, 'https://placehold.co/300x450/png?text=Spring', 'https://www.youtube.com/watch?v=WhWc3b3KhnY'),
(7, 'Agent 327: Operation Barbershop', 'Секретний агент розслідує підозрілу перукарню, яка приховує небезпечну таємницю.', 2017, 4, '12+', 6.8, 'https://placehold.co/300x450/png?text=Agent+327%3A+Operation+Barbershop', NULL),
(8, 'Caminandes 3: Llamigos', 'Лама Коро намагається потрапити до смачної паші за огорожею, але втручається зухвалий пінгвін.', 2016, 3, '0+', 7.4, 'https://placehold.co/300x450/png?text=Caminandes+3%3A+Llamigos', NULL),
(9, 'Coffee Run', 'Дівчина вирушає по каву й опиняється в центрі неочікуваних подій у кав''ярні.', 2020, 3, '6+', 7.1, 'https://placehold.co/300x450/png?text=Coffee+Run', NULL);

-- Серіали
-- seasons_count не задається: його обчислюють тригери після додавання епізодів.
INSERT INTO tv_series (series_id, title, description, start_year, age_rating, rating, poster_url) VALUES
(1, 'Хроніки відкритого коду', 'Команда ентузіастів створює вільну операційну систему та протистоїть корпораціям.', 2022, '12+', 8.1, 'https://placehold.co/300x450/png?text=Open+Source+Chronicles'),
(2, 'Нічна зміна', 'Охоронець нічного музею розкриває таємниці, що оживають після закриття.', 2021, '16+', 7.8, 'https://placehold.co/300x450/png?text=Night+Shift'),
(3, 'Піксельна планета', 'Діти мандрують ретро-іграми та рятують віртуальні світи.', 2023, '6+', 7.0, 'https://placehold.co/300x450/png?text=Pixel+Planet'),
(4, 'Глибини океану', 'Науково-популярний цикл про життя в океані.', 2019, '0+', 8.3, 'https://placehold.co/300x450/png?text=Ocean+Depths'),
(5, 'Школа магії', 'Юні чаклуни опановують заклинання в старовинній академії.', 2020, '6+', 7.2, 'https://placehold.co/300x450/png?text=Magic+School'),
(6, 'Офісні будні', 'Комедія про колектив невеликої IT-компанії.', 2018, '12+', 7.5, 'https://placehold.co/300x450/png?text=Office+Days'),
(7, 'Останній рейс', 'Політ, під час якого екіпаж виявляє таємничий вантаж.', 2024, '16+', 7.6, 'https://placehold.co/300x450/png?text=Last+Flight'),
(8, 'Команда Альфа', 'Рятувальний загін виконує небезпечні місії в горах.', 2022, '12+', 7.4, 'https://placehold.co/300x450/png?text=Team+Alpha');

-- Епізоди
INSERT INTO episodes (episode_id, series_id, season_number, episode_number, title, duration_min, description) VALUES
(1, 1, 1, 1, 'Перший коміт', 42, 'Герої створюють перший прототип системи.'),
(2, 1, 1, 2, 'Гілка розбіжностей', 44, 'Команда розколюється через напрям розвитку проєкту.'),
(3, 1, 1, 3, 'Злиття', 41, 'Нова спільнота допомагає об''єднати зусилля.'),
(4, 1, 1, 4, 'Релізний кандидат', 47, 'Підготовка до першого публічного релізу.'),
(5, 1, 2, 1, 'Форк', 43, 'Конкуренти створюють власну версію системи.'),
(6, 1, 2, 2, 'Вразливість', 45, 'У коді знайдено критичну помилку безпеки.'),
(7, 1, 2, 3, 'Спільнота', 40, 'Волонтери з усього світу приєднуються до проєкту.'),
(8, 1, 2, 4, 'Версія 2.0', 49, 'Фінальний реліз та підсумки боротьби.'),
(9, 2, 1, 1, 'Прибуття', 38, 'Новий охоронець починає першу зміну.'),
(10, 2, 1, 2, 'Дзвінок', 36, 'Нічний дзвінок із закритої зали.'),
(11, 2, 1, 3, 'Тіні', 40, 'Експонати починають рухатися.'),
(12, 2, 2, 1, 'Повернення', 39, 'Охоронець повертається після відпустки.'),
(13, 2, 2, 2, 'Розв''язка', 41, 'Розкриття головної таємниці музею.'),
(14, 3, 1, 1, 'Пілот', 22, 'Діти потрапляють у першу гру.'),
(15, 4, 1, 1, 'Коралові ріфи', 48, 'Екосистема коралових ріфів.'),
(16, 5, 1, 1, 'Перший урок', 25, 'Початок навчання в академії.'),
(17, 6, 1, 1, 'Понеділок', 21, 'Тяжкий старт робочого тижня.'),
(18, 7, 1, 1, 'Посадка', 44, 'Екіпаж готується до рейсу.'),
(19, 8, 1, 1, 'Місія', 46, 'Перша рятувальна операція загону.');

-- Зв'язок жанрів з фільмами та серіалами (рівно одне з movie_id / series_id)
INSERT INTO media_genres (movie_id, series_id, genre_id) VALUES
(1, NULL, 1),
(1, NULL, 3),
(1, NULL, 10),
(2, NULL, 1),
(2, NULL, 4),
(2, NULL, 5),
(3, NULL, 2),
(3, NULL, 6),
(4, NULL, 1),
(4, NULL, 2),
(5, NULL, 1),
(5, NULL, 3),
(6, NULL, 1),
(6, NULL, 5),
(6, NULL, 7),
(7, NULL, 1),
(7, NULL, 3),
(7, NULL, 7),
(8, NULL, 1),
(8, NULL, 3),
(8, NULL, 7),
(8, NULL, 10),
(9, NULL, 1),
(9, NULL, 7),
(9, NULL, 3),
(NULL, 1, 2),
(NULL, 1, 4),
(NULL, 2, 6),
(NULL, 2, 9),
(NULL, 3, 1),
(NULL, 3, 10),
(NULL, 4, 8),
(NULL, 5, 5),
(NULL, 5, 10),
(NULL, 6, 3),
(NULL, 7, 9),
(NULL, 8, 4),
(NULL, 8, 6);

-- Відеофайли (у БД лише посилання; самі файли кладуть у папку media/)
INSERT INTO video_files (video_file_id, movie_id, episode_id, file_url, quality, `format`, duration_sec, file_size_mb, audio_language, is_active) VALUES
(1, 1, NULL, 'media/big_buck_bunny_480p.mp4', '480p', 'mp4', 596, 74.50, 'zxx', TRUE),
(2, 1, NULL, 'media/big_buck_bunny_720p.mp4', '720p', 'mp4', 596, 186.25, 'zxx', TRUE),
(3, 1, NULL, 'media/big_buck_bunny_1080p.mp4', '1080p', 'mp4', 596, 372.50, 'zxx', TRUE),
(4, 2, NULL, 'media/sintel_480p.mp4', '480p', 'mp4', 888, 111.00, 'en', TRUE),
(5, 2, NULL, 'media/sintel_1080p.mp4', '1080p', 'mp4', 888, 555.00, 'en', TRUE),
(6, 2, NULL, 'media/sintel_4k.mp4', '4K', 'mp4', 888, 1776.00, 'en', TRUE),
(7, 3, NULL, 'media/tears_of_steel_720p.mp4', '720p', 'mp4', 734, 229.38, 'en', TRUE),
(8, 3, NULL, 'media/tears_of_steel_1080p.mp4', '1080p', 'mp4', 734, 458.75, 'en', TRUE),
(9, 4, NULL, 'media/elephants_dream_480p.mp4', '480p', 'mp4', 654, 81.75, 'en', TRUE),
(10, 4, NULL, 'media/elephants_dream_720p.mp4', '720p', 'mp4', 654, 204.38, 'en', TRUE),
(11, 5, NULL, 'media/cosmos_laundromat_720p.mp4', '720p', 'mp4', 730, 228.12, 'en', TRUE),
(12, 5, NULL, 'media/cosmos_laundromat_1080p.mp4', '1080p', 'mp4', 730, 456.25, 'en', TRUE),
(13, 5, NULL, 'media/cosmos_laundromat_4k.mp4', '4K', 'mp4', 730, 1460.00, 'en', TRUE),
(14, 6, NULL, 'media/spring_480p.webm', '480p', 'webm', 464, 58.00, 'zxx', TRUE),
(15, 6, NULL, 'media/spring_1080p.mp4', '1080p', 'mp4', 464, 290.00, 'zxx', TRUE),
(16, 7, NULL, 'media/agent_327_720p.mp4', '720p', 'mp4', 231, 72.19, 'zxx', TRUE),
(17, 7, NULL, 'media/agent_327_1080p.mp4', '1080p', 'mp4', 231, 144.38, 'zxx', TRUE),
(18, 8, NULL, 'media/caminandes_llamigos_480p.mp4', '480p', 'mp4', 150, 18.75, 'zxx', TRUE),
(19, 8, NULL, 'media/caminandes_llamigos_720p.mp4', '720p', 'mp4', 150, 46.88, 'zxx', TRUE),
(20, 9, NULL, 'media/coffee_run_720p.mp4', '720p', 'mp4', 188, 58.75, 'zxx', TRUE),
(21, 9, NULL, 'media/coffee_run_1080p.mp4', '1080p', 'mp4', 188, 117.50, 'zxx', TRUE),
(22, NULL, 1, 'media/series/open_source_chronicles_s01e01_720p.mp4', '720p', 'mp4', 2520, 787.50, 'uk', TRUE),
(23, NULL, 1, 'media/series/open_source_chronicles_s01e01_1080p.mp4', '1080p', 'mp4', 2520, 1575.00, 'uk', TRUE),
(24, NULL, 2, 'media/series/open_source_chronicles_s01e02_720p.mp4', '720p', 'mp4', 2640, 825.00, 'uk', TRUE),
(25, NULL, 2, 'media/series/open_source_chronicles_s01e02_1080p.mp4', '1080p', 'mp4', 2640, 1650.00, 'uk', TRUE),
(26, NULL, 3, 'media/series/open_source_chronicles_s01e03_720p.mp4', '720p', 'mp4', 2460, 768.75, 'uk', TRUE),
(27, NULL, 3, 'media/series/open_source_chronicles_s01e03_1080p.mp4', '1080p', 'mp4', 2460, 1537.50, 'uk', TRUE),
(28, NULL, 4, 'media/series/open_source_chronicles_s01e04_720p.mp4', '720p', 'mp4', 2820, 881.25, 'uk', TRUE),
(29, NULL, 4, 'media/series/open_source_chronicles_s01e04_1080p.mp4', '1080p', 'mp4', 2820, 1762.50, 'uk', TRUE),
(30, NULL, 5, 'media/series/open_source_chronicles_s02e01_720p.mp4', '720p', 'mp4', 2580, 806.25, 'uk', TRUE),
(31, NULL, 5, 'media/series/open_source_chronicles_s02e01_1080p.mp4', '1080p', 'mp4', 2580, 1612.50, 'uk', TRUE),
(32, NULL, 6, 'media/series/open_source_chronicles_s02e02_720p.mp4', '720p', 'mp4', 2700, 843.75, 'uk', TRUE),
(33, NULL, 6, 'media/series/open_source_chronicles_s02e02_1080p.mp4', '1080p', 'mp4', 2700, 1687.50, 'uk', TRUE),
(34, NULL, 7, 'media/series/open_source_chronicles_s02e03_720p.mp4', '720p', 'mp4', 2400, 750.00, 'uk', TRUE),
(35, NULL, 7, 'media/series/open_source_chronicles_s02e03_1080p.mp4', '1080p', 'mp4', 2400, 1500.00, 'uk', TRUE),
(36, NULL, 8, 'media/series/open_source_chronicles_s02e04_720p.mp4', '720p', 'mp4', 2940, 918.75, 'uk', TRUE),
(37, NULL, 8, 'media/series/open_source_chronicles_s02e04_1080p.mp4', '1080p', 'mp4', 2940, 1837.50, 'uk', TRUE),
(38, NULL, 9, 'media/series/night_shift_s01e01_720p.mp4', '720p', 'mp4', 2280, 712.50, 'uk', TRUE),
(39, NULL, 10, 'media/series/night_shift_s01e02_720p.mp4', '720p', 'mp4', 2160, 675.00, 'uk', TRUE),
(40, NULL, 11, 'media/series/night_shift_s01e03_720p.mp4', '720p', 'mp4', 2400, 750.00, 'uk', TRUE),
(41, NULL, 12, 'media/series/night_shift_s02e01_720p.mp4', '720p', 'mp4', 2340, 731.25, 'uk', TRUE),
(42, NULL, 13, 'media/series/night_shift_s02e02_720p.mp4', '720p', 'mp4', 2460, 768.75, 'uk', TRUE),
(43, NULL, 14, 'media/series/pixel_planet_s01e01_720p.mp4', '720p', 'mp4', 1320, 412.50, 'uk', TRUE),
(44, NULL, 15, 'media/series/ocean_depths_s01e01_720p.mp4', '720p', 'mp4', 2880, 900.00, 'uk', TRUE),
(45, NULL, 16, 'media/series/magic_school_s01e01_720p.mp4', '720p', 'mp4', 1500, 468.75, 'uk', TRUE),
(46, NULL, 17, 'media/series/office_days_s01e01_720p.mp4', '720p', 'mp4', 1260, 393.75, 'uk', TRUE),
(47, NULL, 18, 'media/series/last_flight_s01e01_720p.mp4', '720p', 'mp4', 2640, 825.00, 'uk', TRUE),
(48, NULL, 19, 'media/series/team_alpha_s01e01_720p.mp4', '720p', 'mp4', 2760, 862.50, 'uk', TRUE);

-- Субтитри
INSERT INTO subtitles (subtitle_id, video_file_id, language_code, label, file_url) VALUES
(1, 2, 'en', 'English', 'media/subtitles/big_buck_bunny_en.vtt'),
(2, 2, 'uk', 'Українська', 'media/subtitles/big_buck_bunny_uk.vtt'),
(3, 5, 'en', 'English', 'media/subtitles/sintel_en.vtt'),
(4, 5, 'uk', 'Українська', 'media/subtitles/sintel_uk.vtt'),
(5, 8, 'en', 'English', 'media/subtitles/tears_of_steel_en.vtt'),
(6, 8, 'uk', 'Українська', 'media/subtitles/tears_of_steel_uk.vtt'),
(7, 10, 'en', 'English', 'media/subtitles/elephants_dream_en.vtt'),
(8, 12, 'en', 'English', 'media/subtitles/cosmos_laundromat_en.vtt'),
(9, 12, 'uk', 'Українська', 'media/subtitles/cosmos_laundromat_uk.vtt'),
(10, 23, 'uk', 'Українська', 'media/subtitles/open_source_chronicles_s01e01_uk.vtt'),
(11, 23, 'en', 'English', 'media/subtitles/open_source_chronicles_s01e01_en.vtt'),
(12, 38, 'uk', 'Українська', 'media/subtitles/night_shift_s01e01_uk.vtt');

-- Історія переглядів (completed = TRUE, якщо переглянуто понад 90% тривалості)
INSERT INTO watch_history (user_id, video_file_id, started_at, last_position_sec, completed, updated_at) VALUES
(1, 3, DATE_SUB(NOW(), INTERVAL 43230 MINUTE), 584, TRUE, DATE_SUB(NOW(), INTERVAL 43221 MINUTE)),
(1, 5, DATE_SUB(NOW(), INTERVAL 4350 MINUTE), 488, FALSE, DATE_SUB(NOW(), INTERVAL 4342 MINUTE)),
(1, 23, DATE_SUB(NOW(), INTERVAL 28830 MINUTE), 2444, TRUE, DATE_SUB(NOW(), INTERVAL 28790 MINUTE)),
(1, 25, DATE_SUB(NOW(), INTERVAL 25950 MINUTE), 2508, TRUE, DATE_SUB(NOW(), INTERVAL 25909 MINUTE)),
(1, 26, DATE_SUB(NOW(), INTERVAL 21630 MINUTE), 2337, TRUE, DATE_SUB(NOW(), INTERVAL 21592 MINUTE)),
(1, 29, DATE_SUB(NOW(), INTERVAL 2910 MINUTE), 1128, FALSE, DATE_SUB(NOW(), INTERVAL 2892 MINUTE)),
(1, 7, DATE_SUB(NOW(), INTERVAL 12990 MINUTE), 220, FALSE, DATE_SUB(NOW(), INTERVAL 12987 MINUTE)),
(2, 6, DATE_SUB(NOW(), INTERVAL 7230 MINUTE), 879, TRUE, DATE_SUB(NOW(), INTERVAL 7216 MINUTE)),
(2, 13, DATE_SUB(NOW(), INTERVAL 5790 MINUTE), 146, FALSE, DATE_SUB(NOW(), INTERVAL 5788 MINUTE)),
(2, 23, DATE_SUB(NOW(), INTERVAL 9360 MINUTE), 2419, TRUE, DATE_SUB(NOW(), INTERVAL 9320 MINUTE)),
(2, 25, DATE_SUB(NOW(), INTERVAL 4350 MINUTE), 1320, FALSE, DATE_SUB(NOW(), INTERVAL 4328 MINUTE)),
(2, 3, DATE_SUB(NOW(), INTERVAL 8670 MINUTE), 548, TRUE, DATE_SUB(NOW(), INTERVAL 8661 MINUTE)),
(2, 8, DATE_SUB(NOW(), INTERVAL 115230 MINUTE), 697, TRUE, DATE_SUB(NOW(), INTERVAL 115219 MINUTE)),
(3, 2, DATE_SUB(NOW(), INTERVAL 72030 MINUTE), 590, TRUE, DATE_SUB(NOW(), INTERVAL 72021 MINUTE)),
(3, 38, DATE_SUB(NOW(), INTERVAL 57630 MINUTE), 2211, TRUE, DATE_SUB(NOW(), INTERVAL 57594 MINUTE)),
(3, 39, DATE_SUB(NOW(), INTERVAL 50430 MINUTE), 1296, FALSE, DATE_SUB(NOW(), INTERVAL 50409 MINUTE)),
(3, 10, DATE_SUB(NOW(), INTERVAL 28830 MINUTE), 294, FALSE, DATE_SUB(NOW(), INTERVAL 28826 MINUTE)),
(4, 22, DATE_SUB(NOW(), INTERVAL 17310 MINUTE), 1260, FALSE, DATE_SUB(NOW(), INTERVAL 17289 MINUTE)),
(4, 24, DATE_SUB(NOW(), INTERVAL 7230 MINUTE), 264, FALSE, DATE_SUB(NOW(), INTERVAL 7226 MINUTE)),
(4, 19, DATE_SUB(NOW(), INTERVAL 10110 MINUTE), 148, TRUE, DATE_SUB(NOW(), INTERVAL 10108 MINUTE)),
(4, 20, DATE_SUB(NOW(), INTERVAL 2910 MINUTE), 150, FALSE, DATE_SUB(NOW(), INTERVAL 2908 MINUTE)),
(5, 8, DATE_SUB(NOW(), INTERVAL 43230 MINUTE), 704, TRUE, DATE_SUB(NOW(), INTERVAL 43219 MINUTE)),
(5, 41, DATE_SUB(NOW(), INTERVAL 20190 MINUTE), 2269, TRUE, DATE_SUB(NOW(), INTERVAL 20153 MINUTE)),
(5, 42, DATE_SUB(NOW(), INTERVAL 14430 MINUTE), 738, FALSE, DATE_SUB(NOW(), INTERVAL 14418 MINUTE)),
(5, 15, DATE_SUB(NOW(), INTERVAL 1470 MINUTE), 278, FALSE, DATE_SUB(NOW(), INTERVAL 1466 MINUTE)),
(6, 13, DATE_SUB(NOW(), INTERVAL 17310 MINUTE), 708, TRUE, DATE_SUB(NOW(), INTERVAL 17299 MINUTE)),
(6, 23, DATE_SUB(NOW(), INTERVAL 15870 MINUTE), 2494, TRUE, DATE_SUB(NOW(), INTERVAL 15829 MINUTE)),
(6, 43, DATE_SUB(NOW(), INTERVAL 11550 MINUTE), 1293, TRUE, DATE_SUB(NOW(), INTERVAL 11529 MINUTE)),
(6, 44, DATE_SUB(NOW(), INTERVAL 10110 MINUTE), 1440, FALSE, DATE_SUB(NOW(), INTERVAL 10086 MINUTE)),
(6, 6, DATE_SUB(NOW(), INTERVAL 4350 MINUTE), 266, FALSE, DATE_SUB(NOW(), INTERVAL 4346 MINUTE)),
(6, 17, DATE_SUB(NOW(), INTERVAL 100830 MINUTE), 219, TRUE, DATE_SUB(NOW(), INTERVAL 100827 MINUTE)),
(7, 20, DATE_SUB(NOW(), INTERVAL 79230 MINUTE), 186, TRUE, DATE_SUB(NOW(), INTERVAL 79227 MINUTE)),
(7, 18, DATE_SUB(NOW(), INTERVAL 86430 MINUTE), 105, FALSE, DATE_SUB(NOW(), INTERVAL 86429 MINUTE)),
(7, 45, DATE_SUB(NOW(), INTERVAL 72030 MINUTE), 600, FALSE, DATE_SUB(NOW(), INTERVAL 72020 MINUTE)),
(8, 8, DATE_SUB(NOW(), INTERVAL 28830 MINUTE), 367, FALSE, DATE_SUB(NOW(), INTERVAL 28824 MINUTE)),
(8, 46, DATE_SUB(NOW(), INTERVAL 14430 MINUTE), 1222, TRUE, DATE_SUB(NOW(), INTERVAL 14410 MINUTE)),
(8, 47, DATE_SUB(NOW(), INTERVAL 8670 MINUTE), 2244, FALSE, DATE_SUB(NOW(), INTERVAL 8633 MINUTE)),
(8, 3, DATE_SUB(NOW(), INTERVAL 57630 MINUTE), 590, TRUE, DATE_SUB(NOW(), INTERVAL 57621 MINUTE)),
(9, 1, DATE_SUB(NOW(), INTERVAL 43230 MINUTE), 578, TRUE, DATE_SUB(NOW(), INTERVAL 43221 MINUTE)),
(9, 14, DATE_SUB(NOW(), INTERVAL 17310 MINUTE), 185, FALSE, DATE_SUB(NOW(), INTERVAL 17307 MINUTE)),
(9, 9, DATE_SUB(NOW(), INTERVAL 129630 MINUTE), 647, TRUE, DATE_SUB(NOW(), INTERVAL 129620 MINUTE)),
(9, 18, DATE_SUB(NOW(), INTERVAL 4350 MINUTE), 30, FALSE, DATE_SUB(NOW(), INTERVAL 4349 MINUTE));
