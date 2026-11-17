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
    const client = SUPABASE_READY ? window.supabase.createClient(SUPABASE_URL, SUPABASE_ANON_KEY) : null;
    const STORAGE_KEY = 'fishbot.channel';
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
        filters: { type: 'all', rarity: 'all', q: '' }
    };

    const TITLES = {
        profile: 'Профиль',
        inventory: 'Инвентарь',
        artifacts: 'Артефакты',
        loadout: 'Экипировка',
        rankings: 'Рейтинг'
    };

    const el = (id) => document.getElementById(id);

    const esc = (value) => String(value == null ? '' : value).replace(/[&<>"']/g, (ch) => ({
        '&': '&amp;', '<': '&lt;', '>': '&gt;', '"': '&quot;', "'": '&#39;'
    }[ch]));

    const clone = (value) => JSON.parse(JSON.stringify(value));

    const currentChannel = () => state.channels.find((channel) => channel.id === state.channelId)
        || state.channels[0]
        || null;

    const currentInventory = () => (currentChannel() || {}).inventory || [];

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
        const item = row.items && typeof row.items === 'object' ? row.items : {};
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
            description: (row.meta && typeof row.meta === 'object' && row.meta.description) ? String(row.meta.description) : '',
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

        const [inventory, catches, ranking] = await Promise.all([
            client.from('inventory')
                .select('id,item_id,item_type,quantity,meta,is_equipped,expires_at,items(name,rarity,price,kind)')
                .eq('channel_id', channelId)
                .eq('user_id', state.userId)
                .order('item_type')
                .order('id'),
            client.from('catches')
                .select('item_id,price,caught_at,items(name,rarity)')
                .eq('channel_id', channelId)
                .eq('user_id', state.userId)
                .order('caught_at', { ascending: false })
                .limit(MAX_CATCHES),
            client.from('channel_ranking')
                .select('username,balance,level,place')
                .eq('channel_id', channelId)
                .order('place', { ascending: true })
                .limit(MAX_RANKING)
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

        /* Шансы — снимок расчёта бота. Таблица может быть ещё не создана
           или строки ещё нет: это не повод ломать загрузку канала. */
        const chances = await client
            .from('player_chances')
            .select('types,rarities_if_fish,updated_at')
            .eq('channel_id', channelId)
            .eq('user_id', state.userId)
            .maybeSingle();
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
            const item = row.items && typeof row.items === 'object' ? row.items : {};
            return {
                name: item.name || row.item_id,
                rarity: item.rarity || 'common',
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

    /* Обновляет цены без полной перезагрузки канала: окно полного возврата
       (5 минут) может закончиться, пока страница открыта. */
    async function refreshSellPrices() {
        const channel = currentChannel();
        if (!channel || state.demo || !channel.inventory.length) return;

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

        document.querySelectorAll('.nav-links button').forEach((button) => button.classList.remove('active'));
        const navButton = el(`btn-${name}`);
        if (navButton) navButton.classList.add('active');

        const title = el('page-title');
        if (title) title.textContent = TITLES[name] || 'Кабинет';

        if (name === 'inventory' || name === 'artifacts' || name === 'loadout') {
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

    function renderProfile() {
        const channel = currentChannel();
        if (!channel) return;

        const player = channel.player;
        const catches = channel.catches || [];

        el('stat-balance').textContent = `${Number(player.balance || 0).toLocaleString('ru-RU')} 💰`;
        el('stat-level').textContent = player.level;
        el('stat-fish').textContent = Number(player.fishCaught || 0).toLocaleString('ru-RU');

        const start = Number(player.xpForCurrent) || 0;
        const next = Number(player.xpForNext) || 0;
        const span = Math.max(1, next - start);
        const percent = Math.max(0, Math.min(100, ((Number(player.xp) - start) / span) * 100));
        el('xp-fill').style.width = `${percent.toFixed(1)}%`;
        el('xp-current').textContent = `${Number(player.xp).toLocaleString('ru-RU')} XP`;
        el('xp-next').textContent = `до ${Number(next).toLocaleString('ru-RU')} XP`;

        if (channel.loadError) {
            el('recent-catches').innerHTML = '<div class="empty-state">Не удалось загрузить уловы</div>';
        } else {
            el('recent-catches').innerHTML = catches.map((catchItem) => {
            const rarity = RARITY[catchItem.rarity] || RARITY.empty;
            return `
                <div class="admin-event-row">
                    <div class="grow">
                        <div class="item-name">🐟 ${esc(catchItem.name)}</div>
                        <div class="item-meta">${esc(catchItem.at)}</div>
                    </div>
                    <div class="item-details" style="color:${rarity.color}">${Number(catchItem.price) || 0} 💰</div>
                </div>
            `;
            }).join('');
        }
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
                        <div class="chances-group-title">Редкость, если клюнула рыба</div>
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
            case 'rarity_modifier': {
                const rarity = RARITY[effect.target];
                return `${rarity ? rarity.icon : ''}×${percent(value)}`;
            }
            case 'rarity_bonus': {
                const rarity = RARITY[effect.target];
                return `${rarity ? rarity.icon : ''}${value >= 0 ? '+' : ''}${value} к весу`;
            }
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
        const secondary = item.item_type === 'CONSUMABLE'
            ? '<button class="btn-admin" disabled title="Появится вместе с логикой расходников">Использовать</button>' + sellButton
            : sellButton;

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
                ${item.item_type === 'ARTIFACT' && Array.isArray(item.effects) && item.effects.length ? `<div class="inv-effects">${item.effects.map((effect) => `<span class="inv-effect-chip">${esc(formatArtifactEffect(effect))}</span>`).join('')}</div>` : ''}
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
        if (counter) counter.textContent = `${items.length} артефактов`;

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

    function renderAll() {
        renderChannels();
        renderChip();
        renderProfile();
        renderInventory();
        renderArtifacts();
        renderLoadout();
        renderRankings();
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

        if (state.demo) {
            toast(`Демо-режим: ${item.name} не продаётся`);
            return;
        }
        if (!client) return;

        const { data, error } = await client.rpc('sell_item', { p_inventory_id: Number(item.id) });
        if (error) {
            console.error(error);
            toast(`Не удалось продать: ${shortError(error)}`);
            return;
        }

        if (data && data.balance != null) channel.player.balance = Number(data.balance) || 0;

        await loadChannel(channel.id);
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
            if (state.session) { loadPlayer(); return; }
            setStatus('Гостевой режим', false);
            renderAuthOnly();
            renderChannels();
            renderChip();
            return;
        }

        if (state.session) { loadPlayer(); return; }
        startDemo();
    }

    async function logout() {
        try {
            if (client) await client.auth.signOut();
        } catch (error) {
            console.error(error);
        }

        state.session = false;
        state.loaded = false;
        state.demo = false;
        state.userId = null;
        state.channels = [];
        state.channelId = null;
        state.username = '';

        setStatus('Гостевой режим', false);
        renderAuthOnly();
        renderChannels();
        renderChip();
        renderProfile();
        renderInventory();
        renderArtifacts();
        renderLoadout();
        renderRankings();
        toast('Вы вышли из аккаунта');
    }

    function handleLogin() {
        if (state.demo) {
            state.demo = false;
            state.channels = [];
            state.channelId = null;
            state.username = '';
            setStatus('Гостевой режим', false);
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
        if (!SUPABASE_READY) return;

        try {
            const { data, error } = await client.auth.getSession();
            if (error) throw error;
            if (!data.session) return;
            state.session = true;
            await loadPlayer();
        } catch (error) {
            console.error(error);
            setStatus('Гостевой режим', false);
            toast(`Не удалось восстановить сессию: ${shortError(error)}`);
        }
    }

    function bind() {
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
            const button = event.target.closest('[data-action="refresh-chances"]');
            if (!button || button.disabled) return;
            requestChancesRefresh(button.dataset.channel);
        });

        document.addEventListener('visibilitychange', () => {
            if (document.visibilityState === 'visible') refreshSellPrices();
        });

        if (!SUPABASE_READY) el('setup-notice').hidden = false;
    }

    // Inline-обработчики в index.html вызывают эти функции из глобальной области.
    window.showTab = showTab;
    window.toggleDemo = toggleDemo;
    window.handleLogin = handleLogin;
    window.setFilter = setFilter;
    window.selectChannel = selectChannel;

    document.addEventListener('DOMContentLoaded', () => {
        bind();
        renderChannels();
        renderRankings();
        setStatus('Гостевой режим', false);
        renderAuthOnly();
        startSession();
    });
})();
