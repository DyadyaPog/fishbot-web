// Конфигурация страницы кабинета игрока.
// Значения ниже — публичные (anon key безопасно класть в статику, если RLS настроен).
// Пока поля пустые, работает только демо-режим.
//
// Канал здесь не указывается: после входа страница сама получает список каналов,
// на которых у игрока есть данные, и позволяет переключаться между ними.
window.FISHBOT_CONFIG = {
    supabaseUrl: '',
    supabaseAnonKey: '',
    // Адрес Edge Function, которая ведёт авторизацию бота для channel:bot:
    // https://<project-ref>.supabase.co/functions/v1/twitch-badge.
    // Публичный адрес: client_secret и service_role живут в Supabase secrets.
    twitchBadgeUrl: '',
    // Ник бота в Twitch (логин), который показывается в кабинете.
    // Задаётся repository variable TWITCH_BOT_LOGIN в GitHub (инжектится в CI).
    botLogin: '',
    // Версия схемы данных: 7 — авторизация бота и значок (badge_at, шаг 46).
    schemaVersion: 7,
    // Общая версия набора картинок рыб: при обновлении изображений поднимайте это число.
    imagesVersion: 5
};
