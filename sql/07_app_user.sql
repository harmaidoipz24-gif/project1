-- =====================================================================
-- sql/07_app_user.sql - окремий обліковий запис MySQL для застосунку
-- Виконувати від імені адміністратора (root) після файлів 01-05.
-- Застосунок не повинен працювати як root: йому достатньо читати дані,
-- викликати процедури та реєструвати користувачів. Змінювати таблиці напряму
-- (UPDATE, DELETE) він не може - уся бізнес-логіка виконується процедурами,
-- які працюють з правами свого автора (SQL SECURITY DEFINER).
-- ПАРОЛЬ: замініть 'Stream#App2026' на власний і вкажіть його в app/.env.
-- =====================================================================
CREATE USER IF NOT EXISTS 'streaming_app'@'localhost' IDENTIFIED BY 'Stream#App2026';

-- Скидаємо попередні права, щоб повторний запуск давав той самий результат
REVOKE ALL PRIVILEGES, GRANT OPTION FROM 'streaming_app'@'localhost';

GRANT SELECT, EXECUTE ON streaming_service.* TO 'streaming_app'@'localhost';
GRANT INSERT ON streaming_service.users TO 'streaming_app'@'localhost';

SHOW GRANTS FOR 'streaming_app'@'localhost';
