/* Кабинет игрока — статическая страница поверх Supabase.
 * Вход через Twitch (Supabase Auth), данные — строки игрока из Postgres.
 * Канал не задаётся в конфиге: после входа список приходит из view my_channels.
 * Без Supabase-конфига и сети остаётся демо-режим.
 */
(function () {
    const CONFIG = window.FISHBOT_CONFIG || {};
    const SUPABASE_URL = String(CONFIG.supabaseUrl || '').replace(/\/+$/, '');
    const SUPABASE_ANON_KEY = String(CONFIG.supabaseAnonKey || '');
    const HAS_SDK = Boolean(window.supabase && typeof window.supabase.createClient === 'function');
    const SUPABASE_READY = Boolean(SUPABASE_URL && SUPABASE_ANON_KEY && HAS_SDK);
    /* PKCE: токены не приходят в URL-фрагменте, обмен идёт по коду.
       Redirect URL в Supabase остаётся тем же, что и для implicit. */
    const client = SUPABASE_READY
        ? window.supabase.createClient(SUPABASE_URL, SUPABASE_ANON_KEY, {
            auth: { flowType: 'pkce', detectSessionInUrl: true }
        })
        : null;
    const STORAGE_KEY = 'fishbot.channel';
    const ITEMS_CACHE_KEY = 'fishbot.items.catalog';
    const ITEMS_CACHE_AT_KEY = 'fishbot.items.catalog.at';
    const ITEMS_CACHE_TTL = 60 * 60 * 1000;
    const MAX_CATCHES = 10;
    const MAX_RANKING = 25;

    /* Типы предметов в базе строчные (enum item_kind), в интерфейсе — заглавные. */
    const ITEM_KIND_TO_TYPE = {
        rod: 'ROD', line: 'LINE', hook: 'HOOK', bait: 'BAIT',
        fish: 'FISH', trash: 'FISH', treasure: 'FISH',
        artifact: 'ARTIFACT', consumable: 'CONSUMABLE'
    };

    const uiType = (raw) => ITEM_KIND_TO_TYPE[String(raw || '').toLowerCase()]
        || String(raw || '').toUpperCase();

    function redirectUrl() {
        if (location.protocol === 'http:' || location.protocol === 'https:') {
            return `${location.origin}${location.pathname}`;
        }
        return location.href.split('#')[0];
    }

    function shortError(error) {
        return String((error && error.message) || error || 'неизвестная ошибка').slice(0, 160);
    }

    function inventoryLimitForLevel(level) {
        const safeLevel = Math.max(0, Number(level) || 0);
        const bonus = Math.floor(safeLevel / 5);
        return 10 + Math.min(10, bonus);
    }

    const RARITY = {
        common: { icon: '🐟', color: 'var(--rarity-common)' },
        uncommon: { icon: '✨', color: 'var(--rarity-uncommon)' },
        rare: { icon: '💎', color: 'var(--rarity-rare)' },
        epic: { icon: '🔮', color: 'var(--rarity-epic)' },
        legendary: { icon: '👑', color: 'var(--rarity-legendary)' },
        mythic: { icon: '🌌', color: 'var(--rarity-mythic)' },
        trash: { icon: '🗑️', color: 'var(--rarity-trash)' },
        treasure: { icon: '💰', color: 'var(--rarity-treasure)' },
        empty: { icon: '💨', color: 'var(--rarity-empty)' }
    };

    /* Эмодзи редкости в свойствах артефактов совпадают с RARITY_DETAILS бота. */
    const RARITY_EFFECT_ICONS = {
        common: '⚪️',
        uncommon: '🟢',
        rare: '🔵',
        epic: '🟣',
        legendary: '🟡',
        mythic: '🔴'
    };

    /* Типы артефактов совпадают с ARTIFACT_TYPE_DETAILS бота. */
    const ARTIFACT_TYPES = {
        catch: { label: 'Улов', emoji: '🎣' },
        treasure: { label: 'Клад', emoji: '🪎' },
        luck: { label: 'Удача', emoji: '🍀' },
        gold: { label: 'Доход', emoji: '💰' },
        comfort: { label: 'Удобство', emoji: '🧰' },
        mystic: { label: 'Мистика', emoji: '🌀' }
    };

    /* Подписи шансов совпадают с LOOT_DETAILS / RARITY_DETAILS бота: проценты
       считает бот и складывает в player_chances, кабинет их только рисует. */
    const LOOT_LABELS = {
        fish: { label: 'Рыба', icon: '🐟', color: '#38bdf8' },
        trash: { label: 'Мусор', icon: '🟤', color: '#94a3b8' },
        treasure: { label: 'Сокровище', icon: '🪎', color: '#fbbf24' },
        empty: { label: 'Пустота', icon: '💨', color: '#64748b' }
    };

    const RARITY_LABELS = {
        common: 'Обычная',
        uncommon: 'Необычная',
        rare: 'Редкая',
        epic: 'Эпическая',
        legendary: 'Легендарная',
        mythic: 'Мифическая'
    };

    const ITEM_TYPES = {
        ROD: { label: 'Удочка', icon: '🎣', equippable: true },
        LINE: { label: 'Леска', icon: '🧵', equippable: true },
        HOOK: { label: 'Крючок', icon: '🪝', equippable: true },
        BAIT: { label: 'Наживка', icon: '🪱', equippable: true },
        FISH: { label: 'Рыба', icon: '🐟', equippable: false },
        ARTIFACT: { label: 'Артефакт', icon: '🔮', equippable: false },
        CONSUMABLE: { label: 'Расходник', icon: '🧪', equippable: false }
    };

    /* Демо: один игрок рыбачил на двух каналах — статистика и инвентарь у каждого свои. */
    const DEMO_CHANNELS = [
        {
            id: 'dyadyapog',
            login: 'dyadyapog',
            displayName: 'DyadyaPog',
            player: {
                userId: '00000001',
                username: 'DemoFisher',
                balance: 1250,
                level: 7,
                xp: 150,
                xpForCurrent: 132,
                xpForNext: 167,
                fishCaught: 312
            },
            inventory: [
                { item_id: 'rod_rare_1', item_type: 'ROD', name: 'Удочка «Прилив»', rarity: 'rare', quantity: 1, is_equipped: true, meta: 'Прочность 82 / 100' },
                { item_id: 'rod_common_1', item_type: 'ROD', name: 'Бамбуковая удочка', rarity: 'common', quantity: 1, is_equipped: false, meta: 'Прочность 45 / 100' },
                { item_id: 'line_epic_1', item_type: 'LINE', name: 'Леска «Бездна»', rarity: 'epic', quantity: 1, is_equipped: true, meta: 'Прочность 96 / 100' },
                { item_id: 'hook_legendary_1', item_type: 'HOOK', name: 'Крючок Посейдона', rarity: 'legendary', quantity: 1, is_equipped: false, meta: 'Прочность 74 / 100' },
                { item_id: 'bait_common_1', item_type: 'BAIT', name: 'Червь', rarity: 'common', quantity: 24, is_equipped: true, meta: 'Расходуется при забросе' },
                { item_id: 'bait_rare_1', item_type: 'BAIT', name: 'Светящаяся приманка', rarity: 'rare', quantity: 5, is_equipped: false, meta: 'Повышает шанс редкой рыбы' },
                { item_id: 'artifact_lucky_1', item_type: 'ARTIFACT', artifactType: 'luck', name: 'Амулет удачи', rarity: 'epic', quantity: 1, is_equipped: false, meta: '+12% к шансу сокровищ · не проклят', description: 'Дырявый, но рыбу почему-то притягивает.', effects: [{ type: 'rarity_bonus', target: 'treasure', value: 12 }, { type: 'cooldown_modifier', value: 0.85 }], cursed: false },
                { item_id: 'fish_mythic_1', item_type: 'FISH', name: 'Лунный карп', rarity: 'mythic', quantity: 1, is_equipped: false, meta: 'Цена продажи: 4200 💰' },
                { item_id: 'fish_trash_1', item_type: 'FISH', name: 'Старый сапог', rarity: 'trash', quantity: 3, is_equipped: false, meta: 'Цена продажи: 3 💰' },
                { item_id: 'fish_treasure_1', item_type: 'FISH', name: 'Затонувший сундук', rarity: 'treasure', quantity: 1, is_equipped: false, meta: 'Цена продажи: 900 💰' },
                { item_id: 'consumable_repair_1', item_type: 'CONSUMABLE', name: 'Ремонтный набор', rarity: 'uncommon', quantity: 2, is_equipped: false, meta: 'Восстанавливает прочность снаряжения' }
            ],
            catches: [
                { name: 'Лунный карп', rarity: 'mythic', price: 4200, at: '2 минуты назад' },
                { name: 'Полосатый окунь', rarity: 'common', price: 18, at: '6 минут назад' },
                { name: 'Старый сапог', rarity: 'trash', price: 3, at: '11 минут назад' },
                { name: 'Сундук с монетами', rarity: 'treasure', price: 900, at: '18 минут назад' }
            ],
            ranking: [
                { username: 'night_angler', value: '18 400 💰' },
                { username: 'DemoFisher', value: '1 250 💰' },
                { username: 'quiet_pike', value: '980 💰' }
            ],
            chances: {
                types: { fish: '72.00%', trash: '10.00%', treasure: '8.00%', empty: '10.00%' },
                rarities_if_fish: {
                    common: '58.30%', uncommon: '29.40%', rare: '7.60%',
                    epic: '3.60%', legendary: '0.95%', mythic: '0.15%'
                }
            }
        },
        {
            id: 'night_angler',
            login: 'night_angler',
            displayName: 'Night Angler',
            player: {
                userId: '00000001',
                username: 'DemoFisher',
                balance: 340,
                level: 4,
                xp: 62,
                xpForCurrent: 53,
                xpForNext: 75,
                fishCaught: 87
            },
            inventory: [
                { item_id: 'rod_common_2', item_type: 'ROD', name: 'Бамбуковая удочка', rarity: 'common', quantity: 1, is_equipped: true, meta: 'Прочность 61 / 100' },
                { item_id: 'line_common_2', item_type: 'LINE', name: 'Леска новичка', rarity: 'common', quantity: 1, is_equipped: true, meta: 'Прочность 88 / 100' },
                { item_id: 'hook_common_2', item_type: 'HOOK', name: 'Крючок новичка', rarity: 'common', quantity: 1, is_equipped: true, meta: 'Прочность 92 / 100' },
                { item_id: 'bait_worm_2', item_type: 'BAIT', name: 'Червь', rarity: 'common', quantity: 7, is_equipped: true, meta: 'Расходуется при забросе' },
                { item_id: 'fish_rare_2', item_type: 'FISH', name: 'Зеркальный карп', rarity: 'rare', quantity: 1, is_equipped: false, meta: 'Цена продажи: 74 💰' },
                { item_id: 'fish_common_2', item_type: 'FISH', name: 'Окунь', rarity: 'common', quantity: 4, is_equipped: false, meta: 'Цена продажи: 9 💰' }
            ],
            catches: [
                { name: 'Зеркальный карп', rarity: 'rare', price: 74, at: 'минуту назад' },
                { name: 'Окунь', rarity: 'common', price: 9, at: '14 минут назад' },
                { name: 'Ржавая банка', rarity: 'trash', price: 0, at: '26 минут назад' }
            ],
            ranking: [
                { username: 'quiet_pike', value: '2 310 💰' },
                { username: 'night_angler', value: '1 870 💰' },
                { username: 'DemoFisher', value: '340 💰' }
            ],
            chances: {
                types: { fish: '69.50%', trash: '10.90%', treasure: '5.60%', empty: '14.00%' },
                rarities_if_fish: {
                    common: '63.20%', uncommon: '24.80%', rare: '8.10%',
                    epic: '2.90%', legendary: '0.85%', mythic: '0.15%'
                }
            }
        }
    ];

    const state = {
        tab: 'profile',
        channels: [],
        channelId: null,
        demo: false,
        /* Сессия Supabase есть, но профиль мог не загрузиться. */
        session: false,
        /* Профиль и каналы успешно прочитаны из базы. */
        loaded: false,
        userId: null,
        username: '',
        filters: { type: 'all', rarity: 'all', q: '' },
        /* Локальный кэш справочника items (имя/редкость/цена/тип/описание). */
        itemsCatalog: new Map(),
        itemsCatalogLoaded: false,
        /* Магазин: выбранная страница редкости и кэш витрины по редкости. */
        shopRarity: 'common',
        shopItemsByRarity: new Map(),
        /* Окно магазина артефактов по каналам: channelId → время закрытия (мс). */
        shopState: new Map(),
        /* Какие окна уже показаны в тосте: channelId → время закрытия. */
        shopAnnounced: new Map(),
        shopWasOpen: false,
        shopMinutes: 0,
        /* Realtime-канал shop_state: подписка живёт до выхода из аккаунта. */
        shopChannel: null
    };

    const TITLES = {
        profile: 'Профиль',
        inventory: 'Инвентарь',
        artifacts: 'Артефакты',
        shop: 'Магазин',
        loadout: 'Экипировка',
        rankings: 'Рейтинг'
    };

    /* Страницы магазина: те же шесть редкостей и тот же порядок, что в !shop бота. */
    const RARITY_PAGE_KEYS = ['common', 'uncommon', 'rare', 'epic', 'legendary', 'mythic'];

    /* Подписи и иконки товаров совпадают с EQUIPMENT_DETAILS / ARTIFACT_DETAILS бота. */
    const SHOP_KIND_DETAILS = {
        rod: { label: 'Удочка', icon: '🎣' },
        line: { label: 'Леска', icon: '🧵' },
        hook: { label: 'Крючок', icon: '🪝' },
        bait: { label: 'Наживка', icon: '🪱' },
        artifact: { label: 'Артефакт', icon: '🔮' }
    };

    /* Демо-витрина: те же поля, что отдаёт shop_items, но без сети. */
    const DEMO_SHOP = [
        { id: 'rod_common', name: 'Бамбуковая удочка', rarity: 'common', price: 900, levelRequired: 1, kind: 'rod', artifactType: null },
        { id: 'line_common', name: 'Обычная леска', rarity: 'common', price: 650, levelRequired: 1, kind: 'line', artifactType: null },
        { id: 'hook_common', name: 'Простой крючок', rarity: 'common', price: 450, levelRequired: 1, kind: 'hook', artifactType: null },
        { id: 'bait_worm', name: 'Червь', rarity: 'common', price: 60, levelRequired: 1, kind: 'bait', artifactType: null },
        { id: 'art_sock', name: 'Носок с дыркой', rarity: 'common', price: 3000, levelRequired: 1, kind: 'artifact', artifactType: 'catch', effects: [{ type: 'type_modifier', target: 'fish', min: 0.99, max: 1.06 }, { type: 'type_modifier', target: 'trash', min: 0.96, max: 1.03 }, { type: 'type_modifier', target: 'treasure', min: 0.99, max: 1.04 }, { type: 'gold_bonus', min: -1, max: 3 }], curseChance: 0.30 },
        { id: 'rod_uncommon', name: 'Карбоновая удочка', rarity: 'uncommon', price: 3600, levelRequired: 8, kind: 'rod', artifactType: null },
        { id: 'bait_dough', name: 'Тесто', rarity: 'uncommon', price: 160, levelRequired: 8, kind: 'bait', artifactType: null },
        { id: 'art_spoon', name: 'Позолоченная ложка деда', rarity: 'uncommon', price: 12000, levelRequired: 8, kind: 'artifact', artifactType: 'gold', effects: [{ type: 'gold_bonus', min: -1, max: 4 }, { type: 'type_modifier', target: 'fish', min: 0.97, max: 1.01 }], curseChance: 0.24 },
        { id: 'rod_rare', name: 'Удочка мастера', rarity: 'rare', price: 8500, levelRequired: 20, kind: 'rod', artifactType: null },
        { id: 'bait_spoon', name: 'Блесна', rarity: 'rare', price: 450, levelRequired: 22, kind: 'bait', artifactType: null },
        { id: 'art_glass_float', name: 'Стеклянный поплавок', rarity: 'rare', price: 35000, levelRequired: 20, kind: 'artifact', artifactType: 'comfort', effects: [{ type: 'bait_save_chance', min: 0, max: 0.08 }, { type: 'cooldown_modifier', min: 0.96, max: 1.02 }], curseChance: 0.20 },
        { id: 'rod_epic', name: 'Удочка глубин', rarity: 'epic', price: 15500, levelRequired: 30, kind: 'rod', artifactType: null },
        { id: 'rod_legendary', name: 'Посох Океана', rarity: 'legendary', price: 25800, levelRequired: 40, kind: 'rod', artifactType: null },
        { id: 'art_tide_crown', name: 'Корона Прилива', rarity: 'legendary', price: 180000, levelRequired: 40, kind: 'artifact', artifactType: 'treasure', effects: [{ type: 'type_modifier', target: 'treasure', min: 0.97, max: 1.1 }, { type: 'xp_multiplier', min: 0.98, max: 1.04 }, { type: 'type_modifier', target: 'empty', min: 0.99, max: 1.05 }], curseChance: 0.16 },
        { id: 'rod_mythic', name: 'Жезл Посейдона', rarity: 'mythic', price: 40000, levelRequired: 50, kind: 'rod', artifactType: null },
        { id: 'art_poseidon_seal', name: 'Печать Посейдона', rarity: 'mythic', price: 400000, levelRequired: 50, kind: 'artifact', artifactType: 'catch', effects: [{ type: 'type_modifier', target: 'fish', min: 0.96, max: 1.08 }, { type: 'type_modifier', target: 'treasure', min: 0.96, max: 1.08 }, { type: 'rarity_modifier', target: 'mythic', min: 0.97, max: 1.1 }, { type: 'cooldown_modifier', min: 0.99, max: 1.06 }], curseChance: 0.08 }
    ];

    const el = (id) => document.getElementById(id);

    const esc = (value) => String(value == null ? '' : value).replace(/[&<>"']/g, (ch) => ({
        '&': '&amp;', '<': '&lt;', '>': '&gt;', '"': '&quot;', "'": '&#39;'
    }[ch]));

    /* Русская форма числительного: 1 предмет, 2 предмета, 5 предметов. */
    function plural(count, one, few, many) {
        const value = Math.abs(Number(count) || 0) % 100;
        const last = value % 10;
        if (value > 10 && value < 20) return many;
        if (last === 1) return one;
        if (last >= 2 && last <= 4) return few;
        return many;
    }

    const clone = (value) => JSON.parse(JSON.stringify(value));

    const currentChannel = () => state.channels.find((channel) => channel.id === state.channelId)
        || state.channels[0]
        || null;

    const currentInventory = () => (currentChannel() || {}).inventory || [];

    /* Локальный кэш справочника items: загружается один раз при авторизации
       (и при ручном обновлении), хранится в localStorage с TTL 1 час.
       Описания и метаданные берутся отсюда, а не отдельными запросами. */
    async function loadItemsCatalog(force) {
        if (!SUPABASE_READY || state.demo) return;
        const now = Date.now();
        if (!force && state.itemsCatalogLoaded && state.itemsCatalog.size) {
            const at = Number(localStorage.getItem(ITEMS_CACHE_AT_KEY) || 0);
            if (now - at < ITEMS_CACHE_TTL) return;
        }
        if (!force) {
            try {
                const raw = localStorage.getItem(ITEMS_CACHE_KEY);
                const at = Number(localStorage.getItem(ITEMS_CACHE_AT_KEY) || 0);
                if (raw && now - at < ITEMS_CACHE_TTL) {
                    const arr = JSON.parse(raw);
                    state.itemsCatalog = new Map((arr || []).map((x) => [String(x.id), {
                        name: x.name, rarity: x.rarity, price: x.price, kind: x.kind, description: x.description
                    }]));
                    state.itemsCatalogLoaded = true;
                    return;
                }
            } catch (e) { /* повреждённый кэш — перезагрузим */ }
        }
        try {
            /* Таблица items закрыта для кабинета: читаем публичную вьюху
               (25_items_public.sql), где только витринные колонки. */
            const { data, error } = await client
                .from('items_public')
                .select('id,name,rarity,price,kind,description');
            if (error) throw error;
            state.itemsCatalog = new Map((data || []).map((x) => [String(x.id), {
                name: x.name, rarity: x.rarity, price: x.price, kind: x.kind, description: x.description
            }]));
            state.itemsCatalogLoaded = true;
            try {
                const arr = [...state.itemsCatalog.entries()].map(([id, v]) => ({ id, ...v }));
                localStorage.setItem(ITEMS_CACHE_KEY, JSON.stringify(arr));
                localStorage.setItem(ITEMS_CACHE_AT_KEY, String(Date.now()));
            } catch (e) { /* приватный режим */ }
        } catch (error) {
            console.warn('items catalog:', error.message);
        }
    }

    function clearItemsCache() {
        state.itemsCatalog = new Map();
        state.itemsCatalogLoaded = false;
        try { localStorage.removeItem(ITEMS_CACHE_KEY); localStorage.removeItem(ITEMS_CACHE_AT_KEY); } catch (e) {}
    }

    function itemMeta(id) {
        return state.itemsCatalog.get(String(id)) || null;
    }

    function toast(message) {
        const node = el('toast');
        node.textContent = message;
        node.classList.add('visible');
        clearTimeout(toast._timer);
        toast._timer = setTimeout(() => node.classList.remove('visible'), 2600);
    }

    function setStatus(text, online) {
        const node = el('auth-status');
        node.textContent = text;
        node.classList.toggle('online', Boolean(online));
        node.classList.toggle('offline', !online);
    }

    function rememberChannel(id) {
        try { localStorage.setItem(STORAGE_KEY, id); } catch (e) { /* приватный режим */ }
    }

    function savedChannel() {
        try { return localStorage.getItem(STORAGE_KEY); } catch (e) { return null; }
    }

    function formatMoney(value) {
        return `${Number(value || 0).toLocaleString('ru-RU')} 💰`;
    }

    function relativeTime(value) {
        const date = value ? new Date(value) : null;
        if (!date || Number.isNaN(date.getTime())) return '';
        const minutes = Math.floor((Date.now() - date.getTime()) / 60000);
        if (minutes < 1) return 'только что';
        if (minutes < 60) return `${minutes} мин назад`;
        const hours = Math.floor(minutes / 60);
        if (hours < 24) return `${hours} ч назад`;
        return `${Math.floor(hours / 24)} дн назад`;
    }

    function formatDateTime(value) {
        const date = value ? new Date(value) : null;
        if (!date || Number.isNaN(date.getTime())) return '';
        return date.toLocaleString('ru-RU', {
            day: '2-digit', month: '2-digit', hour: '2-digit', minute: '2-digit'
        });
    }

    /* В meta лежит только то, что меняется у экземпляра (прочность, вес, эффекты). */
    /* Только постоянные характеристики. Цену подставляет база (sell_price). */
    function inventoryMetaText(row) {
        const meta = row.meta && typeof row.meta === 'object' ? row.meta : {};
        const type = uiType(row.item_type);
        const parts = [];

        if (meta.uses != null && meta.max_uses != null) parts.push(`Прочность: ${meta.uses}/${meta.max_uses}`);
        else if (meta.max_uses != null) parts.push(`Прочность: ${meta.max_uses}`);
        if (meta.weight != null && Number.isFinite(Number(meta.weight))) {
            parts.push(`Вес: ${Number(meta.weight).toFixed(2)} кг`);
        }
        if (row.expires_at) parts.push(`Истекает: ${formatDateTime(row.expires_at)}`);
        if (!parts.length && ITEM_TYPES[type] && ITEM_TYPES[type].equippable) parts.push('Снаряжение');

        return parts.join(' · ');
    }

    function mapInventoryRow(row) {
        const item = itemMeta(row.item_id) || (row.items && typeof row.items === 'object' ? row.items : {});
        const rawMeta = row.meta && typeof row.meta === 'object' ? row.meta : {};
        return {
            id: String(row.id),
            item_id: row.item_id,
            item_type: uiType(row.item_type),
            name: item.name || row.item_id,
            rarity: item.rarity || 'common',
            /* Цену продажи ставит attachSellPrices() из RPC, а не браузер. */
            sell_price: null,
            quantity: Number(row.quantity) || 1,
            is_equipped: Boolean(row.is_equipped),
            meta: inventoryMetaText(row),
            /* Описание берётся из справочника items (бот синхронизирует его из
               конфигов); если в items пусто — fallback на meta.description
               (для старых строк и демо-данных). */
            description: (item.description != null && String(item.description).trim() !== '')
                ? String(item.description)
                : ((rawMeta.description != null && String(rawMeta.description).trim() !== '') ? String(rawMeta.description) : ''),
            /* Тип артефакта из meta (catch/treasure/luck/gold/comfort/mystic). */
            artifactType: rawMeta.type ? String(rawMeta.type) : null,
            effects: (row.meta && typeof row.meta === 'object' && Array.isArray(row.meta.effects)) ? row.meta.effects : [],
            cursed: (row.meta && typeof row.meta === 'object') ? Boolean(row.meta.cursed) : false
        };
    }

    /* Профили игрока: view my_channels уже отфильтрован по auth.uid() и RLS. */
    async function loadPlayer() {
        if (!SUPABASE_READY) return;

        setStatus('Загрузка…', true);

        try {
            const claim = await client.rpc('claim_profile');
            if (claim.error) throw claim.error;
            state.userId = claim.data == null ? null : String(claim.data);

            /* Справочник items обновляем при авторизации (триггер). */
            await loadItemsCatalog(true);

            const response = await client
                .from('my_channels')
                .select('channel_id,login,display_name,username,balance,xp,level,xp_for_current,xp_for_next,fish_caught')
                .order('login');
            if (response.error) throw response.error;

            const rows = response.data || [];
            state.session = true;
            state.loaded = true;
            state.demo = false;
            state.username = rows.length ? (rows[0].username || '') : '';
            state.channels = rows.map((row) => ({
                id: String(row.channel_id),
                login: row.login,
                displayName: row.display_name || row.login,
                player: {
                    userId: state.userId,
                    username: row.username || '',
                    balance: Number(row.balance) || 0,
                    level: Number(row.level) || 1,
                    xp: Number(row.xp) || 0,
                    xpForCurrent: Number(row.xp_for_current) || 0,
                    xpForNext: Number(row.xp_for_next) || 0,
                    fishCaught: Number(row.fish_caught) || 0
                },
                inventory: [],
                catches: [],
                ranking: []
            }));

            const saved = savedChannel();
            state.channelId = state.channels.some((channel) => channel.id === saved)
                ? saved
                : (state.channels[0] ? state.channels[0].id : null);

            if (state.channelId) await loadChannel(state.channelId);

            /* Магазин: окно артефактов из базы + подписка на его открытие. */
            await loadShopState();
            subscribeShopState();
            startShopTicker();

            setStatus(state.username ? `Twitch · ${state.username}` : 'Вход выполнен', true);
            renderAll();
            if (state.channels.length) showTab(state.tab || 'profile');
            else renderAuthOnly();
        } catch (error) {
            console.error(error);
            state.loaded = false;
            setStatus('Ошибка загрузки', false);
            toast(`Не удалось загрузить данные: ${shortError(error)}`);
            renderChip();
            if (state.channels.length === 0) renderAuthOnly();
        }
    }

    let refundTimer = null;

    /* Цены продажи приходят из базы: те же числа, что начислит sell_item. */
    async function attachSellPrices(channel, channelId) {
        if (!client || !Number.isFinite(Number(channelId))) return;

        const { data, error } = await client.rpc('inventory_sell_prices', {
            p_channel_id: Number(channelId)
        });
        if (error) {
            console.warn('inventory_sell_prices:', error.message);
            return;
        }

        channel.pricesFetchedAt = Date.now();

        const rows = new Map((data || []).map((row) => [String(row.inventory_id), row]));
        channel.inventory.forEach((item) => {
            const row = rows.get(item.id);
            const price = row ? Number(row.sell_price) : NaN;
            item.sell_price = Number.isFinite(price) ? price : null;

            /* Задержку до конца окна возврата считаем по времени базы, чтобы
               сдвинутые часы браузера не пересчитали цену раньше времени. */
            const endsAt = row && row.refund_ends_at ? new Date(row.refund_ends_at).getTime() : NaN;
            const serverNow = row && row.server_now ? new Date(row.server_now).getTime() : Date.now();
            const remaining = endsAt - serverNow;
            item.refund_ends_at = Number.isFinite(remaining) && remaining > 0 ? Date.now() + remaining : null;
        });

        scheduleRefundRefresh(channel);
    }

    /* Окно полного возврата (5 минут) кончается само по себе. Будим кабинет
       ровно в этот момент, чтобы подпись не разошлась с выплатой. */
    function scheduleRefundRefresh(channel) {
        if (refundTimer) {
            clearTimeout(refundTimer);
            refundTimer = null;
        }
        if (!channel) return;

        let next = Infinity;
        channel.inventory.forEach((item) => {
            if (!item.refund_ends_at) return;
            if (item.refund_ends_at > Date.now() && item.refund_ends_at < next) {
                next = item.refund_ends_at;
            }
        });
        if (next === Infinity) return;

        const delay = Math.max(500, next - Date.now() + 500);
        refundTimer = setTimeout(refreshSellPrices, delay);
    }

    /* Детали одного канала: инвентарь, последние уловы, рейтинг. */
    async function loadChannel(channelId) {
        const channel = state.channels.find((entry) => entry.id === String(channelId));
        if (!channel || !SUPABASE_READY || !state.userId) return;

        /* Справочник items нужен для имён/описаний; грузим его до маппинга. */
        await loadItemsCatalog();
        if (!state.itemsCatalogLoaded || !state.itemsCatalog.size) {
            toast('Не удалось загрузить справочник предметов');
        }

        const [inventory, catches, ranking, chances] = await Promise.all([
            /* Справочник items подгружается отдельно и кэшируется локально,
               поэтому здесь только данные игрока — без join и без дублирования
               метаданных. */
            client.from('inventory')
                .select('id,item_id,item_type,quantity,meta,is_equipped,expires_at')
                .eq('channel_id', channelId)
                .eq('user_id', state.userId)
                .order('item_type')
                .order('id'),
            client.from('catches')
                .select('item_id,price,caught_at')
                .eq('channel_id', channelId)
                .eq('user_id', state.userId)
                .order('caught_at', { ascending: false })
                .limit(MAX_CATCHES),
            client.from('channel_ranking')
                .select('username,balance,level,place')
                .eq('channel_id', channelId)
                .order('place', { ascending: true })
                .limit(MAX_RANKING),
            /* Шансы — снимок расчёта бота. Таблица может быть ещё не создана
               или строки ещё нет: это не повод ломать загрузку канала. */
            client.from('player_chances')
                .select('types,rarities_if_fish,updated_at')
                .eq('channel_id', channelId)
                .eq('user_id', state.userId)
                .maybeSingle()
        ]);

        const error = inventory.error || catches.error || ranking.error;
        if (error) {
            console.error(error);
            /* Сбрасываем данные канала: иначе интерфейс покажет чужой канал как текущий. */
            channel.inventory = [];
            channel.catches = [];
            channel.ranking = [];
            channel.loadError = shortError(error);
            toast(`Не удалось загрузить канал: ${shortError(error)}`);
            return;
        }

        channel.loadError = null;
        channel.inventory = (inventory.data || []).map(mapInventoryRow);

        if (chances.error) {
            console.warn('player_chances:', chances.error.message);
            channel.chances = null;
            channel.chancesUpdatedAt = null;
        } else {
            channel.chances = chances.data || null;
            channel.chancesUpdatedAt = chances.data ? chances.data.updated_at : null;
        }

        await attachSellPrices(channel, channelId);
        channel.catches = (catches.data || []).map((row) => {
            const item = itemMeta(row.item_id) || (row.items && typeof row.items === 'object' ? row.items : {});
            return {
                name: item.name || row.item_id,
                rarity: item.rarity || 'common',
                description: item.description ? String(item.description) : '',
                price: Number(row.price) || 0,
                at: relativeTime(row.caught_at)
            };
        });
        channel.ranking = (ranking.data || []).map((row, index) => ({
            username: row.username || '—',
            place: Number(row.place) || index + 1,
            value: formatMoney(row.balance),
            level: Number(row.level) || 1
        }));
    }

    /* Общее обновление: сбрасывает кэш справочника items и перезагружает
       данные текущего канала. Триггер — кнопка «↻ Обновить» у ника. */
    async function refreshAllData() {
        if (!SUPABASE_READY || state.demo || !state.session) return;
        const button = el('btn-refresh-data');
        if (button) button.disabled = true;
        try {
            clearItemsCache();
            await loadItemsCatalog(true);
            const channel = currentChannel();
            if (channel) await loadChannel(channel.id);
            renderAll();
            toast('Данные обновлены.');
        } catch (error) {
            toast(`Не удалось обновить: ${shortError(error)}`);
        } finally {
            if (button) button.disabled = false;
        }
    }

    /* Обновляет цены без полной перезагрузки канала: окно полного возврата
       (5 минут) может закончиться, пока страница открыта. */
    async function refreshSellPrices(force) {
        const channel = currentChannel();
        if (!channel || state.demo || !channel.inventory.length) return;

        /* Не дёргаем RPC на каждое переключение вкладки/фокус: цены уже
           пришли с loadChannel, а окно возврата само разбудит таймер. */
        const last = Number(channel.pricesFetchedAt) || 0;
        const hasRefund = channel.inventory.some((item) => item.refund_ends_at);
        if (!force && !hasRefund && Date.now() - last < 30000) return;

        await attachSellPrices(channel, channel.id);
        renderInventory();
        renderArtifacts();
        renderLoadout();
    }

    function showTab(name) {
        if (state.channels.length === 0) {
            renderAuthOnly();
            toast('Сначала войдите через Twitch или включите демо-режим');
            return;
        }

        state.tab = name;
        document.querySelectorAll('.tab-content').forEach((section) => section.classList.remove('active'));
        const target = el(name);
        if (target) target.classList.add('active');
        if (name === 'profile') scheduleCatchesMinHeight();

        document.querySelectorAll('.nav-links button').forEach((button) => button.classList.remove('active'));
        const navButton = el(`btn-${name}`);
        if (navButton) navButton.classList.add('active');

        const title = el('page-title');
        if (title) title.textContent = TITLES[name] || 'Кабинет';

        if (name === 'shop') {
            openShopTab();
        } else if (name === 'inventory' || name === 'artifacts' || name === 'loadout') {
            refreshSellPrices();
        }
    }

    function renderAuthOnly() {
        document.querySelectorAll('.tab-content').forEach((section) => section.classList.remove('active'));
        el('guest').classList.add('active');
        document.querySelectorAll('.nav-links button').forEach((button) => button.classList.remove('active'));
        el('btn-profile').classList.add('active');
        el('page-title').textContent = 'Кабинет';
    }

    /* Список каналов появляется только когда есть данные: страница ничего не знает
       о канале заранее. Выбранный канал хранится в localStorage. */
    function renderChannels() {
        const picker = el('channel-picker');
        const select = el('channel-select');
        const hasChannels = state.channels.length > 0;

        picker.hidden = !hasChannels;
        if (!hasChannels) {
            select.innerHTML = '';
            return;
        }

        select.innerHTML = state.channels.map((channel) => {
            const label = `${channel.displayName} · @${channel.login}`;
            const selected = channel.id === state.channelId ? ' selected' : '';
            return `<option value="${esc(channel.id)}"${selected}>${esc(label)}</option>`;
        }).join('');
    }

    async function selectChannel(id) {
        if (!state.channels.some((channel) => channel.id === id)) return;

        state.channelId = id;
        rememberChannel(id);
        if (!state.demo) await loadChannel(id);

        /* У каждого канала своё окно магазина: сбрасываем прошлое состояние. */
        const channelForShop = currentChannel();
        state.shopWasOpen = Boolean(channelForShop && isArtifactShopOpen(channelForShop.id));
        state.shopMinutes = state.shopWasOpen ? shopMinutesLeft(channelForShop.id) : 0;

        renderAll();

        const channel = currentChannel();
        if (channel && !channel.loadError) toast(`Канал: ${channel.displayName}`);
    }

    function renderChip() {
        const chip = el('user-chip');
        const name = el('user-chip-name');
        const avatar = el('user-chip-avatar');

        const channel = currentChannel();
        const username = state.username || (channel && channel.player.username);

        if (username) {
            chip.hidden = false;
            name.textContent = username;
            avatar.textContent = state.demo ? '🧪' : '🟣';
        } else {
            chip.hidden = true;
        }

        const refreshItem = el('nav-refresh-data');
        if (refreshItem) refreshItem.hidden = !(state.session && !state.demo);

        const login = el('btn-login');
        if (state.demo || !state.session) {
            login.textContent = 'Войти через Twitch';
        } else {
            login.textContent = state.loaded ? 'Выйти' : 'Повторить';
        }
        el('btn-demo').textContent = state.demo
            ? 'Сбросить'
            : (state.session ? 'Обновить' : 'Демо-режим');
    }

    let catchHeightFrame = 0;

    function scheduleCatchesMinHeight() {
        cancelAnimationFrame(catchHeightFrame);
        catchHeightFrame = requestAnimationFrame(updateCatchesMinHeight);
    }

    /* Высота «Последних уловов» — ровно MAX_CATCHES реальных строк.
       Если строк меньше, берём самую высокую: текст в ней уже перенёсся. */
    function updateCatchesMinHeight() {
        const container = el('recent-catches');
        if (!container) return;

        const rows = Array.from(container.querySelectorAll('.admin-event-row'));
        if (!rows.length) {
            container.style.minHeight = '';
            return;
        }

        const heights = rows.map((row) => {
            const style = getComputedStyle(row);
            return row.getBoundingClientRect().height
                + (parseFloat(style.marginTop) || 0)
                + (parseFloat(style.marginBottom) || 0);
        }).filter((height) => height > 0);
        if (!heights.length) return;

        const rowsHeight = heights.length >= MAX_CATCHES
            ? heights.slice(0, MAX_CATCHES).reduce((sum, height) => sum + height, 0)
            : Math.max(...heights) * MAX_CATCHES;

        const style = getComputedStyle(container);
        const padding = (parseFloat(style.paddingTop) || 0) + (parseFloat(style.paddingBottom) || 0);
        const gap = parseFloat(style.rowGap) || 0;

        container.style.minHeight = `${Math.ceil(rowsHeight + padding + gap * (MAX_CATCHES - 1))}px`;
    }

    function renderProfile() {
        const channel = currentChannel();
        if (!channel) return;

        const player = channel.player;
        const catches = channel.catches || [];

        el('stat-balance').textContent = `${Number(player.balance || 0).toLocaleString('ru-RU')}`;
        el('stat-level').textContent = player.level;
        el('stat-fish').textContent = Number(player.fishCaught || 0).toLocaleString('ru-RU');

        const start = Number(player.xpForCurrent) || 0;
        const next = Number(player.xpForNext) || 0;
        const span = Math.max(1, next - start);
        const percent = Math.max(0, Math.min(100, ((Number(player.xp) - start) / span) * 100));
        el('xp-fill').style.width = `${percent.toFixed(1)}%`;
        el('xp-current').textContent = `${Number(player.xp).toLocaleString('ru-RU')} XP`;
        el('xp-next').textContent = `до ${Number(next).toLocaleString('ru-RU')} XP`;
        const xpPercent = el('xp-percent');
        if (xpPercent) xpPercent.textContent = `${percent.toFixed(0)}%`;

        if (channel.loadError) {
            el('recent-catches').innerHTML = '<div class="empty-state">Не удалось загрузить уловы</div>';
        } else {
            el('recent-catches').innerHTML = catches.map((catchItem) => {
            const rarity = RARITY[catchItem.rarity] || RARITY.empty;
            return `
                <div class="admin-event-row">
                    <div class="grow">
                        <div class="item-name">🐟 ${esc(catchItem.name)}</div>
                        ${catchItem.description ? `<div class="item-meta">${esc(catchItem.description)}</div>` : ''}
                        <div class="item-meta">${esc(catchItem.at)}</div>
                    </div>
                    <div class="item-details" style="color:${rarity.color}">${Number(catchItem.price) || 0} 💰</div>
                </div>
            `;
            }).join('');
        }

        scheduleCatchesMinHeight();
    }

    function renderLoadout() {
        const slots = ['ROD', 'LINE', 'HOOK', 'BAIT'];
        const inventory = currentInventory();

        const loadoutGrid = el('loadout-grid');
        if (loadoutGrid) {
            const equipmentItems = inventory.filter((item) => ITEM_TYPES[item.item_type] && ITEM_TYPES[item.item_type].equippable);
            loadoutGrid.innerHTML = equipmentItems.map(renderItemCard).join('');
        }

        renderChances();

        el('slot-grid').innerHTML = slots.map((type) => {
            const meta = ITEM_TYPES[type];
            const item = inventory.find((entry) => entry.item_type === type && entry.is_equipped);
            const rarity = item ? (RARITY[item.rarity] || RARITY.empty) : null;

            if (!item) {
                return `
                    <div class="slot-card">
                        <div class="slot-type">${meta.icon} ${meta.label}</div>
                        <div class="slot-name">Пусто</div>
                    </div>
                `;
            }

            return `
                <div class="slot-card filled">
                    <div class="slot-type">${meta.icon} ${meta.label}</div>
                    <div class="slot-name">${esc(item.name)}</div>
                    <div class="slot-rarity" style="color:${rarity.color}">${esc(item.rarity)}</div>
                </div>
            `;
        }).join('');
    }

    /* Шансы улова. Проценты приходят из player_chances: их считает бот
       (!шансы) с учётом экипировки, артефактов и ручных настроек канала,
       поэтому кабинет ничего не пересчитывает и не расходится с чатом. */
    function chancePercent(value) {
        const number = parseFloat(String(value == null ? '' : value).replace('%', '').replace(',', '.'));
        return Number.isFinite(number) ? number : 0;
    }

    function chanceRow(label, icon, color, value) {
        const percent = chancePercent(value);
        const width = Math.max(0, Math.min(100, percent));
        return `
            <div class="chance-row">
                <span class="chance-name"><span class="chance-icon">${icon}</span>${esc(label)}</span>
                <span class="chance-bar"><span class="chance-fill" style="width:${width.toFixed(2)}%;background:${color}"></span></span>
                <span class="chance-value">${percent.toFixed(2)}%</span>
            </div>
        `;
    }

    function renderChances() {
        const host = el('chances-panel');
        if (!host) return;

        const channel = currentChannel();
        const chances = channel && channel.chances;
        const types = chances && chances.types;
        const rarities = chances && chances.rarities_if_fish;

        const canRefresh = SUPABASE_READY && !state.demo && channel;
        const refreshButton = canRefresh
            ? `<button class="chances-refresh" data-action="refresh-chances" data-channel="${esc(channel.id)}" title="Попросить бота пересчитать шансы">↻ Обновить</button>`
            : '';
        const header = (caption) => `
            <div class="panel-header">
                <div class="panel-title"><span class="panel-icon">🎯</span> Шансы улова</div>
                <span class="chances-caption">${esc(caption)}</span>
                ${refreshButton}
            </div>
        `;

        if (!types || Object.keys(types).length === 0) {
            host.innerHTML = `
                <div class="dashboard-panel">
                    ${header('считает бот')}
                    <div class="chances-body">
                        <div class="empty-state">Шансы появятся после команды !шансы или первого заброса в чате</div>
                    </div>
                </div>
            `;
            return;
        }

        const typeRows = Object.keys(LOOT_LABELS)
            .filter((key) => types[key] !== undefined)
            .map((key) => {
                const info = LOOT_LABELS[key];
                return chanceRow(info.label, info.icon, info.color, types[key]);
            })
            .join('');

        const rarityRows = Object.keys(RARITY_LABELS)
            .filter((key) => rarities && rarities[key] !== undefined)
            .map((key) => {
                const info = RARITY[key] || RARITY.empty;
                return chanceRow(RARITY_LABELS[key], info.icon, info.color, rarities[key]);
            })
            .join('');

        host.innerHTML = `
            <div class="dashboard-panel">
                ${header('с учётом экипировки и артефактов')}
                <div class="chances-body">
                    <div class="chances-group">
                        <div class="chances-group-title">Тип улова</div>
                        ${typeRows}
                    </div>
                    <div class="chances-group">
                        <div class="chances-group-title">Редкость рыб и сокровищ</div>
                        ${rarityRows}
                    </div>
                </div>
            </div>
        `;
    }

    async function requestChancesRefresh(channelId) {
        if (!SUPABASE_READY || !client || state.demo || !channelId) return;
        const button = document.querySelector('[data-action="refresh-chances"]');
        if (button) button.disabled = true;
        try {
            const { error } = await client.rpc('request_chances_refresh', { p_channel_id: Number(channelId) });
            if (error) throw error;
            toast('Запрос отправлен. Бот пересчитает шансы в течение нескольких секунд.');
            const channel = currentChannel();
            const previous = channel ? channel.chancesUpdatedAt : null;
            // Опрашиваем player_chances до изменения updated_at (макс ~30 с).
            const started = Date.now();
            const timer = setInterval(async () => {
                if (Date.now() - started > 30000) { clearInterval(timer); if (button) button.disabled = false; return; }
                if (!state.channelId) { clearInterval(timer); if (button) button.disabled = false; return; }
                const { data } = await client
                    .from('player_chances')
                    .select('types,rarities_if_fish,updated_at')
                    .eq('channel_id', state.channelId)
                    .eq('user_id', state.userId)
                    .maybeSingle();
                if (data && data.updated_at && data.updated_at !== previous) {
                    clearInterval(timer);
                    const ch = currentChannel();
                    if (ch) { ch.chances = data; ch.chancesUpdatedAt = data.updated_at; }
                    renderChances();
                    toast('Шансы обновлены.');
                    if (button) button.disabled = false;
                }
            }, 2000);
        } catch (error) {
            toast(`Не удалось запросить пересчёт: ${shortError(error)}`);
            if (button) button.disabled = false;
        }
    }

    function filteredInventory() {
        const { type, rarity, q } = state.filters;
        const needle = q.trim().toLowerCase();

        return currentInventory().filter((item) => {
            if (type !== 'all' && item.item_type !== type) return false;
            if (rarity !== 'all' && item.rarity !== rarity) return false;
            if (needle && !String(item.name).toLowerCase().includes(needle)) return false;
            return true;
        });
    }

    function formatArtifactEffect(effect) {
        const value = Number(effect && effect.value);
        const percent = (v) => `${Math.round(Number(v) * 100)}%`;
        switch (effect && effect.type) {
            case 'type_modifier': {
                const emoji = { fish: ' Joel ', trash: '🟤', treasure: '🪎', empty: '💨' }[effect.target] || '';
                return `${emoji}×${percent(value)}`;
            }
            case 'rarity_modifier':
                return `${RARITY_EFFECT_ICONS[effect.target] || ''}×${percent(value)}`;
            case 'rarity_bonus':
                return `${RARITY_EFFECT_ICONS[effect.target] || ''}${value >= 0 ? '+' : ''}${value} к весу`;
            case 'gold_bonus':
                return `${value >= 0 ? '+' : ''}${value}💰/заброс`;
            case 'xp_multiplier':
                return `XP ×${percent(value)}`;
            case 'cooldown_modifier':
                return `кулдаун ×${percent(value)}`;
            case 'bait_save_chance':
                return `наживка цела: ${percent(value)}`;
            case 'double_catch_chance':
                return `двойной улов: ${percent(value)}`;
            case 'inventory_bonus':
                return `${value >= 0 ? '+' : ''}${value} слота`;
            default:
                return String(effect && effect.type || '');
        }
    }

    function formatArtifactEffects(effects) {
        if (!Array.isArray(effects) || effects.length === 0) return 'без эффектов';
        return effects.map(formatArtifactEffect).join(', ');
    }

    /* Диапазоны возможных статов артефакта до покупки (как !help у бота,
       но в процентном виде, чтобы совпадать с чипами купленных артефактов). */
    function formatArtifactEffectRange(effect) {
        const min = Number(effect && effect.min);
        const max = Number(effect && effect.max);
        const isRange = Number.isFinite(min) && Number.isFinite(max) && min !== max;
        const percent = (v) => `${Math.round(Number(v) * 100)}%`;
        const rangeOf = (fmt) => isRange ? `${fmt(min)}…${fmt(max)}` : fmt(min);
        switch (effect && effect.type) {
            case 'type_modifier': {
                const emoji = { fish: ' Joel ', trash: '🟤', treasure: '🪎', empty: '💨' }[effect.target] || '';
                return `${emoji}×${rangeOf(percent)}`;
            }
            case 'rarity_modifier': {
                const icon = RARITY_EFFECT_ICONS[effect.target] || '';
                return `${icon}×${rangeOf(percent)}`;
            }
            case 'rarity_bonus': {
                const icon = RARITY_EFFECT_ICONS[effect.target] || '';
                const fmt = (v) => `${v >= 0 ? '+' : ''}${v}`;
                return `${icon}${rangeOf(fmt)} к весу`;
            }
            case 'gold_bonus': {
                const fmt = (v) => `${v >= 0 ? '+' : ''}${v}`;
                return `${rangeOf(fmt)}💰/заброс`;
            }
            case 'xp_multiplier':
                return `XP ×${rangeOf(percent)}`;
            case 'cooldown_modifier':
                return `кулдаун ×${rangeOf(percent)}`;
            case 'bait_save_chance':
                return `наживка цела: ${rangeOf(percent)}`;
            case 'double_catch_chance':
                return `двойной улов: ${rangeOf(percent)}`;
            case 'inventory_bonus': {
                const fmt = (v) => `${v >= 0 ? '+' : ''}${v}`;
                return `${rangeOf(fmt)} слота`;
            }
            default:
                return String(effect && effect.type || '');
        }
    }

    /* Понятное описание стата для тултипа (русский). range=true — диапазон возможных значений. */
    function artifactEffectTooltip(effect, range) {
        const typeTarget = (t) => ({ fish: 'рыбы', trash: 'мусора', treasure: 'сокровищ', empty: 'пустоты' }[t] || t);
        const rarityTarget = (r) => RARITY_LABELS[r] || (LOOT_LABELS[r] && LOOT_LABELS[r].label) || r;
        const pct = (v) => `${Math.round(Number(v) * 100)}%`;
        const num = (v) => `${Number(v) >= 0 ? '+' : ''}${v}`;
        if (range) {
            const min = Number(effect.min), max = Number(effect.max);
            const rngPct = min !== max ? `от ${pct(min)} до ${pct(max)}` : pct(min);
            const rngNum = min !== max ? `от ${num(min)} до ${num(max)}` : num(min);
            switch (effect.type) {
                case 'type_modifier': return `Умножает шанс выпадения «${typeTarget(effect.target)}»: ${rngPct}`;
                case 'rarity_modifier': return `Умножает шанс редкости «${rarityTarget(effect.target)}»: ${rngPct}`;
                case 'rarity_bonus': return `Добавляет к весу редкости «${rarityTarget(effect.target)}»: ${rngNum}`;
                case 'gold_bonus': return `Золото за заброс: ${rngNum} 💰`;
                case 'xp_multiplier': return `Умножает получаемый опыт: ${rngPct}`;
                case 'cooldown_modifier': return `Умножает кулдаун заброса: ${rngPct}`;
                case 'bait_save_chance': return `Шанс не потратить наживку: ${rngPct}`;
                case 'double_catch_chance': return `Шанс поймать двойной улов: ${rngPct}`;
                case 'inventory_bonus': return `Слоты инвентаря: ${rngNum}`;
                default: return String(effect.type);
            }
        }
        const v = Number(effect.value);
        switch (effect.type) {
            case 'type_modifier': return `Умножает шанс выпадения «${typeTarget(effect.target)}» на ${pct(v)}`;
            case 'rarity_modifier': return `Умножает шанс редкости «${rarityTarget(effect.target)}» на ${pct(v)}`;
            case 'rarity_bonus': return `Добавляет ${num(v)} к весу редкости «${rarityTarget(effect.target)}»`;
            case 'gold_bonus': return `${num(v)} 💰 за каждый заброс`;
            case 'xp_multiplier': return `Умножает получаемый опыт на ${pct(v)}`;
            case 'cooldown_modifier': return `Умножает кулдаун заброса на ${pct(v)}`;
            case 'bait_save_chance': return `${pct(v)} шанс не потратить наживку`;
            case 'double_catch_chance': return `${pct(v)} шанс поймать двойной улов`;
            case 'inventory_bonus': return `${num(v)} слотов инвентаря`;
            default: return String(effect.type);
        }
    }

    function renderItemCard(item) {
        const meta = ITEM_TYPES[item.item_type] || { label: item.item_type, icon: '❔', equippable: false };
        const rarity = RARITY[item.rarity] || RARITY.empty;
        const id = String(item.id);

        const action = meta.equippable
            ? (item.is_equipped
                ? `<button class="btn-admin" data-action="unequip" data-id="${esc(id)}">Снять</button>`
                : `<button class="btn-admin primary" data-action="equip" data-id="${esc(id)}">Экипировать</button>`)
            : '';

        const sellTitle = item.is_equipped
            ? 'Сначала снимите предмет'
            : (item.cursed ? 'Проклятый артефакт продать нельзя' : 'Продать предмет');
        const sellButton = `<button class="btn-admin" data-action="sell" data-id="${esc(id)}"${item.is_equipped || item.cursed ? ' disabled' : ''} title="${sellTitle}">Продать</button>`;
        const cleanseButton = item.item_type === 'ARTIFACT' && item.cursed
            ? `<button class="btn-admin primary" data-action="cleanse" data-id="${esc(id)}" title="Снять проклятие: свиток очищения или гадалка за монеты">Очистить</button>`
            : '';
        const secondary = item.item_type === 'CONSUMABLE'
            ? '<button class="btn-admin" disabled title="Появится вместе с логикой расходников">Использовать</button>' + sellButton
            : cleanseButton + sellButton;

        /* Цена — из RPC inventory_sell_prices, то есть ровно та, что выплатит sell_item. */
        const hasSellPrice = item.sell_price != null && Number.isFinite(Number(item.sell_price));
        const priceLabel = item.item_type === 'FISH' ? 'Цена' : 'Цена продажи';
        const priceBlock = hasSellPrice
            ? `<div class="inv-info-block">${esc(`${priceLabel}: ${formatMoney(item.sell_price)}`)}</div>`
            : '';

        const artifactDetails = item.item_type === 'ARTIFACT' ? ARTIFACT_TYPES[item.artifactType] : null;
        const artifactTypeBlock = item.item_type === 'ARTIFACT' && item.artifactType
            ? `<div class="inv-info-block">${esc(`Тип: ${artifactDetails ? `${artifactDetails.emoji} ${artifactDetails.label}` : item.artifactType}`)}</div>`
            : '';

                    return `
                <div class="inv-item${item.is_equipped ? ' equipped' : ''}" style="--rarity-color:${rarity.color}; border-left-color:${rarity.color}">
                <div class="inv-head">
                                            <div class="inv-icon">${meta.icon}</div>
                    <div class="inv-title">
                        <div class="inv-name">${esc(item.name)}</div>
                        <div class="inv-rarity" style="color:${rarity.color}">${esc(item.rarity)} · ${meta.label}</div>
                    </div>
                    ${item.quantity > 1 ? `<div class="inv-qty">×${Number(item.quantity)}</div>` : ''}
                </div>
                ${(item.item_type === 'FISH' || (ITEM_TYPES[item.item_type] && ITEM_TYPES[item.item_type].equippable)) && item.meta
                    ? item.meta.split(' · ').filter(Boolean).map((part) => `<div class="inv-info-block">${esc(part)}</div>`).join('')
                    : `<div class="inv-meta">${esc(item.meta || '')}</div>`}
                ${priceBlock}
                ${item.description ? `<div class="inv-description">${esc('📝 ' + item.description)}</div>` : ''}
                ${artifactTypeBlock}
                ${item.item_type === 'ARTIFACT' && Array.isArray(item.effects) && item.effects.length ? `<div class="inv-effects">${item.effects.map((effect) => `<span class="inv-effect-chip" title="${esc(artifactEffectTooltip(effect, false))}">${esc(formatArtifactEffect(effect))}</span>`).join('')}</div>` : ''}
                ${item.cursed ? '<div class="inv-cursed">☠️ проклят</div>' : ''}
                <div class="inv-actions">
                    ${action}
                    ${secondary}
                </div>
            </div>
        `;
    }

    function renderInventory() {
        const grid = el('inventory-grid');
        const items = filteredInventory().filter((item) => item.item_type !== 'ARTIFACT');
        const occupied = currentInventory().filter((item) => item.item_type !== 'ARTIFACT').length;
        const channel = currentChannel();
        const limit = inventoryLimitForLevel(channel && channel.player ? channel.player.level : 1);

        const counter = el('inventory-counter');
        if (counter) {
            counter.textContent = `занято ${occupied} из ${limit}`;
            counter.classList.toggle('full', occupied >= limit);
        }

        if (items.length === 0) {
            const message = channel && channel.loadError
                ? 'Не удалось загрузить инвентарь канала'
                : (occupied === 0 ? 'На этом канале инвентарь пуст' : 'По фильтрам ничего не найдено');
            grid.innerHTML = `<div class="empty-state">${message}</div>`;
            return;
        }

        grid.innerHTML = items.map(renderItemCard).join('');
    }

    function renderArtifacts() {
        const grid = el('artifacts-grid');
        if (!grid) return;
        const items = currentInventory().filter((item) => item.item_type === 'ARTIFACT');
        const counter = el('artifacts-counter');
        if (counter) counter.textContent = `${items.length} ${plural(items.length, 'артефакт', 'артефакта', 'артефактов')}`;

        if (items.length === 0) {
            grid.innerHTML = `
                <div class="artifacts-empty">
                    <div class="artifacts-empty-icon">🔮</div>
                    <div class="artifacts-empty-title">Артефактов пока нет</div>
                    <div class="artifacts-empty-text">Купите артефакт в боте — он сразу появится здесь и начнёт действовать.</div>
                </div>
            `;
            return;
        }

        grid.innerHTML = items.map(renderItemCard).join('');
    }

    function renderRankings() {
        const channel = currentChannel();
        const rows = (channel && channel.ranking) || [];
        const channelLabel = el('ranking-channel');
        if (channelLabel) channelLabel.textContent = channel ? `· ${channel.displayName}` : '';

        if (channel && channel.loadError) {
            el('ranking-list').innerHTML = '<div class="empty-state">Рейтинг недоступен: канал не загрузился</div>';
            return;
        }

        el('ranking-list').innerHTML = rows.map((row, index) => `
            <div class="ranking-item">
                <span class="rank">#${row.place || index + 1}</span>
                <span class="name">${esc(row.username)}</span>
                <span class="value">${esc(row.value)}</span>
            </div>
        `).join('');
    }

    /* ---------- Магазин ---------- */

    function artifactShopUntil(channelId) {
        return Number(state.shopState.get(String(channelId)) || 0);
    }

    function isArtifactShopOpen(channelId) {
        return artifactShopUntil(channelId) > Date.now();
    }

    function shopMinutesLeft(channelId) {
        return Math.max(1, Math.ceil((artifactShopUntil(channelId) - Date.now()) / 60000));
    }

    /* Окно магазина приходит из shop_state: его пишет только бот. */
    function applyShopState(rows) {
        const next = new Map();
        for (const row of rows || []) {
            const until = row.artifact_open_until ? new Date(row.artifact_open_until).getTime() : 0;
            next.set(String(row.channel_id), Number.isFinite(until) ? until : 0);
        }
        state.shopState = next;

        const channel = currentChannel();
        state.shopWasOpen = Boolean(channel && isArtifactShopOpen(channel.id));
        state.shopMinutes = channel && state.shopWasOpen ? shopMinutesLeft(channel.id) : 0;

        renderShopNav();
        renderShopAlert();
        renderArtifactShop();
    }

    /* Читаем окно только своих каналов: чужие магазины кабинету не нужны. */
    async function loadShopState() {
        if (!SUPABASE_READY || !client || state.demo) return;
        const ids = state.channels
            .map((channel) => Number(channel.id))
            .filter((id) => Number.isFinite(id));
        if (!ids.length) return;

        try {
            const { data, error } = await client
                .from('shop_state')
                .select('channel_id,artifact_open_until')
                .in('channel_id', ids);
            if (error) throw error;
            applyShopState(data || []);
        } catch (error) {
            console.warn('shop_state:', error.message);
        }
    }

    /* Realtime: открытие магазина приходит без обновления страницы. */
    function subscribeShopState() {
        if (!SUPABASE_READY || !client || state.demo || state.shopChannel) return;

        try {
            state.shopChannel = client
                .channel('shop-state')
                .on(
                    'postgres_changes',
                    { event: '*', schema: 'public', table: 'shop_state' },
                    (payload) => {
                        const row = payload.new && Object.keys(payload.new).length
                            ? payload.new
                            : payload.old;
                        if (!row || row.channel_id == null) {
                            loadShopState();
                            return;
                        }

                        const id = String(row.channel_id);
                        if (!state.channels.some((channel) => channel.id === id)) return;

                        const until = payload.eventType === 'DELETE' || !row.artifact_open_until
                            ? 0
                            : new Date(row.artifact_open_until).getTime();
                        state.shopState.set(id, Number.isFinite(until) ? until : 0);
                        handleShopStateChange(id);
                    }
                )
                .subscribe();
        } catch (error) {
            console.warn('shop_state realtime:', error.message);
        }
    }

    function unsubscribeShopState() {
        if (state.shopChannel && client) {
            try { client.removeChannel(state.shopChannel); } catch (e) { /* приватный режим */ }
        }
        state.shopChannel = null;
    }

    /* Открытие магазина: тост и подсветка, но только один раз на окно. */
    function handleShopStateChange(channelId) {
        const channel = state.channels.find((entry) => entry.id === channelId);
        const open = isArtifactShopOpen(channelId);
        const until = artifactShopUntil(channelId);

        if (open && state.shopAnnounced.get(channelId) !== until) {
            state.shopAnnounced.set(channelId, until);
            if (channelId === state.channelId) {
                toast(`🔮 Магазин артефактов открыт: ${shopMinutesLeft(channelId)} мин.`);
            } else if (channel) {
                toast(`🔔 Магазин артефактов открыт на канале ${channel.displayName}`);
            }
        }

        const current = currentChannel();
        state.shopWasOpen = Boolean(current && isArtifactShopOpen(current.id));
        state.shopMinutes = current && state.shopWasOpen ? shopMinutesLeft(current.id) : 0;

        renderShopNav();
        renderShopAlert();
        renderShop();
        renderArtifactShop();
    }

    /* Пункт «Магазин» подсвечивается, чтобы открытие не пропустили. */
    function renderShopNav() {
        const button = el('btn-shop');
        const badge = el('shop-badge');
        if (!button || !badge) return;

        const current = currentChannel();
        const anyOpen = state.channels.some((channel) => isArtifactShopOpen(channel.id));
        const currentOpen = Boolean(current && isArtifactShopOpen(current.id));

        button.classList.toggle('shop-hot', anyOpen);
        badge.hidden = !anyOpen;
        badge.textContent = currentOpen ? 'открыт' : 'другой канал';
    }

    /* Плашка видна с любой вкладки: открыт здесь — или на другом канале. */
    function renderShopAlert() {
        const node = el('shop-alert');
        if (!node) return;

        const current = currentChannel();
        if (!current) {
            node.hidden = true;
            return;
        }

        if (isArtifactShopOpen(current.id)) {
            node.className = 'notice notice-shop';
            node.innerHTML = `<span class="notice-shop-icon">🔮</span>
                <span class="grow">Магазин артефактов открыт — закрывается через ${shopMinutesLeft(current.id)} мин.</span>
                <button class="notice-shop-action" data-action="open-artifacts">К артефактам</button>`;
            node.hidden = false;
            return;
        }

        const other = state.channels.find((channel) =>
            channel.id !== current.id && isArtifactShopOpen(channel.id)
        );

        if (other) {
            node.className = 'notice notice-shop muted';
            node.innerHTML = `<span class="notice-shop-icon">🔔</span>
                <span class="grow">Магазин артефактов открыт на канале <b>${esc(other.displayName)}</b> — вы смотрите ${esc(current.displayName)}.</span>
                <button class="notice-shop-action" data-action="switch-shop-channel" data-channel="${esc(other.id)}">Перейти</button>`;
            node.hidden = false;
            return;
        }

        node.hidden = true;
    }

    function shopItemsFor(rarity) {
        return state.shopItemsByRarity.get(String(rarity)) || null;
    }

    function shopKindDetails(kind) {
        return SHOP_KIND_DETAILS[kind] || { label: kind || 'Предмет', icon: '❔' };
    }

    /* Типы артефактов, которые уже заняты: второй такой же не купить. */
    function ownedArtifactTypes() {
        const types = new Set();
        for (const item of currentInventory()) {
            if (item.item_type === 'ARTIFACT' && item.artifactType) types.add(item.artifactType);
        }
        return types;
    }

    /* Те же ограничения, что проверяет RPC: показываем их до нажатия. */
    function shopBlockReason(item) {
        const channel = currentChannel();
        if (!channel) return '';

        const level = Number(channel.player.level) || 1;
        const balance = Number(channel.player.balance) || 0;

        if (level < item.levelRequired) return `Нужен ${item.levelRequired} ур.`;
        if (item.kind === 'artifact' && !isArtifactShopOpen(channel.id)) return 'Магазин закрыт';
        if (item.kind === 'artifact' && ownedArtifactTypes().has(item.artifactType)) return 'Тип уже занят';
        if (balance < item.price) return 'Не хватает золота';
        return '';
    }

    function renderShopCard(item) {
        const rarity = RARITY[item.rarity] || RARITY.empty;
        const kind = shopKindDetails(item.kind);
        const reason = shopBlockReason(item);
        const artifactType = item.kind === 'artifact' && item.artifactType
            ? ARTIFACT_TYPES[item.artifactType]
            : null;
        const typeLabel = artifactType
            ? `${kind.label} · ${artifactType.emoji} ${artifactType.label}`
            : kind.label;

        const isArtifact = item.kind === 'artifact';
        const effectsBlock = isArtifact && Array.isArray(item.effects) && item.effects.length
            ? `<div class="inv-effects">${item.effects.map((effect) => `<span class="inv-effect-chip" title="${esc(artifactEffectTooltip(effect, true))}">${esc(formatArtifactEffectRange(effect))}</span>`).join('')}</div>`
            : '';
        const curseBlock = isArtifact && item.curseChance > 0
            ? `<div class="shop-curse">☠️ шанс проклятия: ${Math.round(item.curseChance * 100)}%</div>`
            : '';

        return `
            <div class="inv-item shop-item" style="--rarity-color:${rarity.color}; border-left-color:${rarity.color}">
                <div class="inv-head">
                    <div class="inv-icon">${kind.icon}</div>
                    <div class="inv-title">
                        <div class="inv-name">${esc(item.name)}</div>
                        <div class="inv-rarity" style="color:${rarity.color}">${esc(RARITY_LABELS[item.rarity] || item.rarity)} · ${esc(typeLabel)}</div>
                    </div>
                </div>
                <div class="inv-info-block">${esc(`Цена: ${formatMoney(item.price)}`)}</div>
                <div class="inv-info-block">${esc(`Минимальный уровень: ${item.levelRequired}`)}</div>
                ${effectsBlock}
                ${curseBlock}
                ${reason ? `<div class="shop-lock">${esc(reason)}</div>` : ''}
                <div class="inv-actions">
                    <button class="btn-admin primary" data-action="shop-buy" data-item="${esc(item.id)}" data-kind="${esc(item.kind)}"${reason ? ' disabled' : ''}>Купить</button>
                </div>
            </div>
        `;
    }

    function renderShopPages() {
        const host = el('shop-pages');
        if (!host) return;

        host.innerHTML = RARITY_PAGE_KEYS.map((key) => {
            const active = key === state.shopRarity ? ' active' : '';
            return `<button class="shop-page${active}" data-action="shop-rarity" data-rarity="${key}">
                <span class="shop-page-icon">${RARITY_EFFECT_ICONS[key] || '❔'}</span>${esc(RARITY_LABELS[key] || key)}
            </button>`;
        }).join('');
    }

    /* Витрина снаряжения: артефакты живут в отдельном магазине ниже. */
    function renderShop() {
        renderShopPages();
        renderShopNav();
        renderShopAlert();
        renderArtifactShop();

        const grid = el('shop-grid');
        const counter = el('shop-counter');
        if (!grid) return;

        if (!state.channels.length) {
            grid.innerHTML = '<div class="empty-state">Войдите через Twitch, чтобы увидеть магазин</div>';
            if (counter) counter.textContent = '—';
            return;
        }

        const items = state.demo
            ? DEMO_SHOP.filter((item) => item.rarity === state.shopRarity && item.kind !== 'artifact')
            : shopItemsFor(state.shopRarity);

        if (!items) {
            grid.innerHTML = '<div class="empty-state">Загрузка магазина…</div>';
            if (counter) counter.textContent = '—';
            ensureShopItems();
            return;
        }

        const equipment = items.filter((item) => item.kind !== 'artifact');
        if (counter) counter.textContent = `${equipment.length} ${plural(equipment.length, 'предмет', 'предмета', 'предметов')}`;
        grid.innerHTML = equipment.length
            ? equipment.map(renderShopCard).join('')
            : '<div class="empty-state">На этой странице магазина ничего нет</div>';
    }

    /* Магазин артефактов виден только когда бот открыл окно. */
    function renderArtifactShop() {
        const grid = el('artifact-shop-grid');
        const panel = el('artifact-shop-panel');
        const status = el('artifact-shop-status');
        if (!grid || !panel) return;

        const channel = currentChannel();
        const open = Boolean(channel && isArtifactShopOpen(channel.id));
        panel.classList.toggle('shop-open', open);

        if (status) {
            status.textContent = open
                ? `закрывается через ${shopMinutesLeft(channel.id)} мин`
                : 'закрыт';
        }

        if (!open) {
            grid.innerHTML = '<div class="empty-state">Магазин закрыт: бот открывает его ненадолго. Когда он откроется, пункт «Магазин» подсветится, а здесь появятся артефакты.</div>';
            return;
        }

        const items = state.demo
            ? DEMO_SHOP.filter((item) => item.rarity === state.shopRarity && item.kind === 'artifact')
            : shopItemsFor(state.shopRarity);

        if (!items) {
            grid.innerHTML = '<div class="empty-state">Загрузка магазина…</div>';
            return;
        }

        const artifacts = items.filter((item) => item.kind === 'artifact');
        grid.innerHTML = artifacts.length
            ? artifacts.map(renderShopCard).join('')
            : '<div class="empty-state">На этой странице артефактов нет</div>';
    }

    /* Витрину отдаёт shop_items: бот и кабинет читают один каталог. */
    async function loadShopItems(rarity, force) {
        if (!SUPABASE_READY || !client || state.demo) return null;

        const key = String(rarity);
        if (!force && state.shopItemsByRarity.has(key)) return state.shopItemsByRarity.get(key);

        const { data, error } = await client.rpc('shop_items', { p_rarity: key });
        if (error) {
            console.warn('shop_items:', error.message);
            state.shopItemsByRarity.set(key, []);
            toast('Не удалось загрузить магазин');
            return [];
        }

        const items = (data || []).map((row) => ({
            id: String(row.item_id),
            name: row.name,
            rarity: row.rarity,
            price: Number(row.price) || 0,
            levelRequired: Number(row.level_required) || 1,
            kind: row.kind,
            artifactType: row.artifact_type || null,
            effects: Array.isArray(row.effects) ? row.effects : [],
            curseEffects: Array.isArray(row.curse_effects) ? row.curse_effects : [],
            curseChance: Number(row.curse_chance) || 0
        }));

        state.shopItemsByRarity.set(key, items);
        return items;
    }

    let shopRequestInFlight = false;

    async function ensureShopItems(force) {
        if (shopRequestInFlight || state.demo || !SUPABASE_READY || !state.channels.length) return;

        const key = state.shopRarity;
        if (!force && state.shopItemsByRarity.has(key)) return;

        shopRequestInFlight = true;
        try {
            await loadShopItems(key, force);
        } finally {
            shopRequestInFlight = false;
            renderShop();
        }
    }

    async function openShopTab(options = {}) {
        renderShop();
        await loadShopState();
        await ensureShopItems(false);

        const panel = el('artifact-shop-panel');
        if (options.artifacts && panel && panel.scrollIntoView) {
            panel.scrollIntoView({ behavior: 'smooth', block: 'start' });
        }
    }

    /* Покупка: уровень, место, деньги, тип артефакта и окно магазина
       проверяет база (buy_item / buy_artifact), кабинет только показывает итог. */
    async function buyShopItem(rawId, rawKind) {
        const channel = currentChannel();
        if (!channel) return;

        const item = (shopItemsFor(state.shopRarity) || []).find((entry) => entry.id === rawId)
            || DEMO_SHOP.find((entry) => entry.id === rawId);
        if (!item) return;

        if (state.demo) {
            toast('Демо-режим: покупки недоступны');
            return;
        }
        if (!client) return;

        const reason = shopBlockReason(item);
        if (reason) {
            toast(reason);
            return;
        }

        if (!window.confirm(`Купить «${item.name}» за ${formatMoney(item.price)}?`)) return;

        const isArtifact = rawKind === 'artifact' || item.kind === 'artifact';
        const payload = {
            p_item_id: item.id,
            p_channel_id: Number(channel.id)
        };
        if (!isArtifact) payload.p_quantity = 1;

        const { data, error } = await client.rpc(isArtifact ? 'buy_artifact' : 'buy_item', payload);

        if (error) {
            console.error(error);
            toast(`Не удалось купить: ${shortError(error)}`);
            return;
        }

        if (!data || data.ok !== true) {
            toast((data && data.error) || 'Не удалось купить предмет');
            if (data && data.code === 'shop_closed') await loadShopState();
            renderShop();
            return;
        }

        if (data.balance != null) channel.player.balance = Number(data.balance) || 0;

        await reloadInventory(channel.id);
        await ensureShopItems(true);

        renderProfile();
        renderInventory();
        renderArtifacts();
        renderLoadout();
        renderShop();

        const curse = isArtifact && data.cursed ? ' — проклят ☠️' : '';
        toast(`Куплено: ${data.name || item.name}${curse}`);
    }

    /* Обратный отсчёт окна: секунды обновляют подписи, закрытие — перерисовку.
       Опрос раз в минуту страхует Realtime при обрыве связи. */
    let shopTicker = null;
    let shopPollAt = 0;

    function startShopTicker() {
        if (shopTicker) return;

        shopTicker = setInterval(() => {
            const channel = currentChannel();
            if (!channel || state.demo || !state.channels.length) return;

            const open = isArtifactShopOpen(channel.id);
            const minutes = open ? shopMinutesLeft(channel.id) : 0;

            if (open !== state.shopWasOpen) {
                handleShopStateChange(channel.id);
            } else if (open && minutes !== state.shopMinutes) {
                state.shopMinutes = minutes;
                renderShopAlert();
                renderArtifactShop();
            }

            if (Date.now() > shopPollAt) {
                shopPollAt = Date.now() + 60000;
                loadShopState();
            }
        }, 1000);
    }

    function renderAll() {
        renderChannels();
        renderChip();
        renderProfile();
        renderInventory();
        renderArtifacts();
        renderLoadout();
        renderRankings();
        renderShop();
    }

    function setFilter(key, value) {
        state.filters[key] = value;
        renderInventory();
    }

    /* В демо — локальный флаг, на живой базе — RPC с проверкой владельца строки. */
    async function changeEquipment(action, rawId) {
        const channel = currentChannel();
        if (!channel) return;

        const item = channel.inventory.find((entry) => String(entry.id) === String(rawId));
        if (!item) return;

        if (!state.demo) {
            if (!client) return;
            const method = action === 'equip' ? 'equip_item' : 'unequip_item';
            const { error } = await client.rpc(method, { p_inventory_id: Number(item.id) });
            if (error) {
                console.error(error);
                toast(`Не удалось изменить экипировку: ${shortError(error)}`);
                return;
            }
        }

        if (action === 'equip') {
            channel.inventory.forEach((entry) => {
                if (entry.item_type === item.item_type) entry.is_equipped = false;
            });
            item.is_equipped = true;
            toast(`Экипировано: ${item.name}`);
        } else {
            item.is_equipped = false;
            toast(`Снято: ${item.name}`);
        }

        renderInventory();
        renderLoadout();
    }

    /* После продажи меняются только инвентарь и баланс: не тянем уловы,
       рейтинг и шансы повторно. */
    async function reloadInventory(channelId) {
        const channel = state.channels.find((entry) => entry.id === String(channelId));
        if (!channel || !SUPABASE_READY || !state.userId) return;

        const { data, error } = await client
            .from('inventory')
            .select('id,item_id,item_type,quantity,meta,is_equipped,expires_at')
            .eq('channel_id', channelId)
            .eq('user_id', state.userId)
            .order('item_type')
            .order('id');
        if (error) {
            console.warn('inventory:', error.message);
            return;
        }

        channel.inventory = (data || []).map(mapInventoryRow);
        await attachSellPrices(channel, channelId);
    }

    /* Очистка артефакта: свиток или гадалка. Всю механику и ролл
       выполняет RPC cleanse_artifact, браузер только показывает результат. */
    async function cleanseCursedArtifact(rawId) {
        const channel = currentChannel();
        if (!channel) return;

        const item = channel.inventory.find((entry) => String(entry.id) === String(rawId));
        if (!item || item.item_type !== 'ARTIFACT' || !item.cursed) return;

        if (state.demo) {
            toast('Демо-режим: очистка артефактов недоступна');
            return;
        }
        if (!client) return;

        const hasScroll = channel.inventory.some((entry) =>
            entry.item_id === 'scroll_of_cleansing' && Number(entry.quantity) > 0
        );
        const hint = hasScroll
            ? 'Будет использован свиток очищения.'
            : 'Свитка нет: гадалка возьмёт монеты, и есть риск усилить проклятие.';
        if (!window.confirm(`Снять проклятие с «${item.name}»? ${hint}`)) return;

        const { data, error } = await client.rpc('cleanse_artifact', {
            p_inventory_id: Number(item.id)
        });

        if (error) {
            console.error(error);
            toast(`Не удалось очистить: ${shortError(error)}`);
            return;
        }
        if (!data || data.ok !== true) {
            toast((data && data.error) || 'Не удалось очистить артефакт');
            return;
        }

        if (data.balance != null) channel.player.balance = Number(data.balance) || 0;

        await reloadInventory(channel.id);
        renderProfile();
        renderInventory();
        renderArtifacts();
        renderLoadout();

        if (data.method === 'failed') {
            toast(`Гадалка не справилась: проклятие «${item.name}» усилено, потрачено ${formatMoney(data.cost)}`);
        } else if (data.method === 'scroll') {
            toast(`Свиток очищения сжёг проклятие: ${item.name}`);
        } else {
            toast(`Гадалка сняла проклятие с «${item.name}» за ${formatMoney(data.cost)}`);
        }
    }

    /* Продажа: владельца строки и цену проверяет и считает только база (RPC sell_item). */
    async function sellItem(rawId) {
        const channel = currentChannel();
        if (!channel) return;

        const item = channel.inventory.find((entry) => String(entry.id) === String(rawId));
        if (!item) return;

        if (item.is_equipped) {
            toast('Сначала снимите предмет');
            return;
        }
        if (item.cursed) {
            toast('Проклятый артефакт продать нельзя');
            return;
        }

        const priceLabel = item.sell_price != null ? ` за ${formatMoney(item.sell_price)}` : '';
        if (!window.confirm(`Продать «${item.name}»${priceLabel}?`)) return;

        if (state.demo) {
            toast(`Демо-режим: ${item.name} не продаётся`);
            return;
        }
        if (!client) return;

        /* Количество не передаём: sell_item с null продаёт всю строку. */
        const { data, error } = await client.rpc('sell_item', {
            p_inventory_id: Number(item.id),
            p_quantity: null
        });
        if (error) {
            console.error(error);
            toast(`Не удалось продать: ${shortError(error)}`);
            return;
        }

        if (data && data.balance != null) channel.player.balance = Number(data.balance) || 0;

        await reloadInventory(channel.id);
        renderProfile();
        renderInventory();
        renderArtifacts();
        renderLoadout();
        toast(`Продано: ${item.name} (+${formatMoney(data && data.gold)})`);
    }

    function startDemo() {
        state.demo = true;
        state.userId = null;
        state.channels = clone(DEMO_CHANNELS).map((channel) => ({
            ...channel,
            inventory: channel.inventory.map((item, index) => ({
                ...item,
                id: `${channel.id}-${index}`
            }))
        }));

        const saved = savedChannel();
        state.channelId = state.channels.some((channel) => channel.id === saved)
            ? saved
            : state.channels[0].id;
        state.username = state.channels[0].player.username;

        /* Демо: магазин артефактов открыт только на втором канале — так видно
           и уведомление про другой канал, и переход к артефактам. */
        state.shopState = new Map();
        state.shopAnnounced = new Map();
        if (state.channels[0]) state.shopState.set(state.channels[0].id, 0);
        if (state.channels[1]) state.shopState.set(state.channels[1].id, Date.now() + 8 * 60 * 1000);
        state.shopWasOpen = isArtifactShopOpen(state.channelId);

        setStatus('Демо-данные', true);
        renderAll();
        showTab('profile');
        toast('Демо-режим: два канала, данные ненастоящие');
    }

    function toggleDemo() {
        if (state.demo) {
            state.demo = false;
            state.channels = [];
            state.channelId = null;
            state.username = '';
            state.shopState = new Map();
            state.shopWasOpen = false;
            if (state.session) { loadPlayer(); return; }
            setStatus('Гостевой режим', false);
            renderShop();
            renderAuthOnly();
            renderChannels();
            renderChip();
            return;
        }

        if (state.session) { loadPlayer(); return; }
        startDemo();
    }

    /* Supabase хранит сессию под ключом sb-<project-ref>-auth-token.
       Если signOut не смог удалить её (офлайн/истёкший токен), чистим
       ключи вручную — иначе после перезагрузки пользователь снова войдёт. */
    function clearSupabaseSessionStorage() {
        let ref = '';
        try { ref = new URL(SUPABASE_URL).hostname.split('.')[0]; } catch (e) { return; }
        if (!ref) return;

        const keys = [`sb-${ref}-auth-token`, `sb-${ref}-auth-token-code-verifier`];
        for (const key of keys) {
            try { localStorage.removeItem(key); } catch (e) { /* приватный режим */ }
            try { sessionStorage.removeItem(key); } catch (e) { /* приватный режим */ }
        }
    }

    async function logout() {
        try {
            if (client) {
                /* Не ждём бесконечно: в офлайне signOut может зависнуть
                   на ретраях. Локальные ключи всё равно очистим ниже. */
                await Promise.race([
                    client.auth.signOut(),
                    new Promise((resolve) => setTimeout(resolve, 5000))
                ]);
            }
        } catch (error) {
            console.error(error);
        } finally {
            clearSupabaseSessionStorage();
        }

        unsubscribeShopState();

        state.session = false;
        state.loaded = false;
        state.demo = false;
        state.userId = null;
        state.channels = [];
        state.channelId = null;
        state.username = '';
        state.shopState = new Map();
        state.shopAnnounced = new Map();
        state.shopWasOpen = false;
        state.shopItemsByRarity = new Map();

        setStatus('Гостевой режим', false);
        renderAuthOnly();
        renderChannels();
        renderChip();
        renderProfile();
        renderInventory();
        renderArtifacts();
        renderLoadout();
        renderRankings();
        renderShop();
        toast('Вы вышли из аккаунта');
    }

    function handleLogin() {
        if (state.demo) {
            state.demo = false;
            state.channels = [];
            state.channelId = null;
            state.username = '';
            state.shopState = new Map();
            state.shopWasOpen = false;
            setStatus('Гостевой режим', false);
            renderShop();
            renderAuthOnly();
            renderChannels();
            renderChip();
        }

        /* Сессия уже есть: повторяем загрузку профиля, а не новый OAuth. */
        if (state.session) {
            if (state.loaded) logout();
            else loadPlayer();
            return;
        }

        if (!SUPABASE_READY) {
            el('setup-notice').hidden = false;
            toast('Сначала укажите Supabase URL и anon key в config.js');
            return;
        }

        client.auth.signInWithOAuth({
            provider: 'twitch',
            options: { redirectTo: redirectUrl() }
        }).then(({ error }) => {
            if (!error) return;
            console.error(error);
            toast(`Вход через Twitch не удался: ${shortError(error)}`);
        });
    }

    /* Сессию после redirect разбирает supabase-js; здесь только догружаем данные. */
    async function startSession() {
        if (!SUPABASE_READY) {
            document.body.classList.remove('auth-pending');
            setStatus('Гостевой режим', false);
            renderAuthOnly();
            return;
        }

        /* Страховка только на случай зависшего getSession. Как только сессия
           получена, таймер снимаем: loadPlayer может грузиться долго, и
           auth-pending должен держаться до конца загрузки профиля. */
        let sessionGuard = setTimeout(() => document.body.classList.remove('auth-pending'), 5000);

        try {
            const { data, error } = await client.auth.getSession();
            clearTimeout(sessionGuard);
            sessionGuard = null;
            if (error) throw error;
            if (!data.session) {
                document.body.classList.remove('auth-pending');
                setStatus('Гостевой режим', false);
                renderAuthOnly();
                return;
            }
            state.session = true;
            await loadPlayer();
        } catch (error) {
            console.error(error);
            setStatus('Гостевой режим', false);
            renderAuthOnly();
            toast(`Не удалось восстановить сессию: ${shortError(error)}`);
        } finally {
            if (sessionGuard) clearTimeout(sessionGuard);
            document.body.classList.remove('auth-pending');
        }
    }

    function bind() {
        /* Навигация, вход и смена канала висят здесь, а не в onclick:
           так страница открывается со строгой CSP без 'unsafe-inline'. */
        document.addEventListener('click', (event) => {
            const tab = event.target.closest('[data-tab]');
            if (tab) {
                showTab(tab.dataset.tab);
                return;
            }

            const action = event.target.closest('[data-action]');
            if (!action) return;

            if (action.dataset.action === 'login') handleLogin();
            else if (action.dataset.action === 'demo') toggleDemo();
            else if (action.dataset.action === 'refresh-all') refreshAllData();
        });

        const channelSelect = el('channel-select');
        if (channelSelect) {
            channelSelect.addEventListener('change', () => selectChannel(channelSelect.value));
        }

        document.querySelectorAll('[data-filter]').forEach((select) => {
            select.addEventListener('change', () => setFilter(select.dataset.filter, select.value));
        });
        el('inventory-grid').addEventListener('click', (event) => {
            const button = event.target.closest('[data-action="equip"], [data-action="unequip"]');
            if (!button || button.disabled) return;
            changeEquipment(button.dataset.action, button.dataset.id);
        });

        const loadoutGrid = el('loadout-grid');
        if (loadoutGrid) {
            loadoutGrid.addEventListener('click', (event) => {
                const button = event.target.closest('[data-action="equip"], [data-action="unequip"]');
                if (!button || button.disabled) return;
                changeEquipment(button.dataset.action, button.dataset.id);
            });
        }

        document.addEventListener('click', (event) => {
            const button = event.target.closest('[data-action="sell"]');
            if (!button || button.disabled) return;
            sellItem(button.dataset.id);
        });

        document.addEventListener('click', (event) => {
            const button = event.target.closest('[data-action="cleanse"]');
            if (!button || button.disabled) return;
            cleanseCursedArtifact(button.dataset.id);
        });

        document.addEventListener('click', (event) => {
            const button = event.target.closest('[data-action="refresh-chances"]');
            if (!button || button.disabled) return;
            requestChancesRefresh(button.dataset.channel);
        });

        document.addEventListener('click', (event) => {
            const page = event.target.closest('[data-action="shop-rarity"]');
            if (page) {
                state.shopRarity = page.dataset.rarity;
                renderShop();
                ensureShopItems();
                return;
            }

            const buy = event.target.closest('[data-action="shop-buy"]');
            if (buy && !buy.disabled) {
                buyShopItem(buy.dataset.item, buy.dataset.kind);
                return;
            }

            const artifacts = event.target.closest('[data-action="open-artifacts"]');
            if (artifacts) {
                showTab('shop');
                openShopTab({ artifacts: true });
                return;
            }

            const otherChannel = event.target.closest('[data-action="switch-shop-channel"]');
            if (otherChannel) {
                selectChannel(otherChannel.dataset.channel);
                showTab('shop');
            }
        });

        document.addEventListener('visibilitychange', () => {
            if (document.visibilityState !== 'visible') return;
            refreshSellPrices();
            loadShopState();
        });

        window.addEventListener('resize', scheduleCatchesMinHeight);
        if (document.fonts && document.fonts.ready) {
            document.fonts.ready.then(scheduleCatchesMinHeight);
        }

        if (!SUPABASE_READY) el('setup-notice').hidden = false;
    }

    // Inline-обработчики в index.html вызывают эти функции из глобальной области.
    window.showTab = showTab;
    window.toggleDemo = toggleDemo;
    window.handleLogin = handleLogin;
    window.setFilter = setFilter;
    window.selectChannel = selectChannel;
    window.refreshAllData = refreshAllData;

    document.addEventListener('DOMContentLoaded', () => {
        bind();
        renderChannels();
        renderRankings();
        /* Гостевой экран не показываем до проверки сессии. */
        setStatus('Проверка входа…', true);
        startSession();
    });
})();
