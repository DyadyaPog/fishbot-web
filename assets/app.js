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
                { item_id: 'artifact_lucky_1', item_type: 'ARTIFACT', name: 'Амулет удачи', rarity: 'epic', quantity: 1, is_equipped: false, meta: '+12% к шансу сокровищ · не проклят', description: 'Дырявый, но рыбу почему-то притягивает.', effects: [{ type: 'rarity_bonus', target: 'treasure', value: 12 }, { type: 'cooldown_modifier', value: 0.85 }], cursed: false },
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
            ]
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
            ]
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
    function inventoryMetaText(row, item) {
        const meta = row.meta && typeof row.meta === 'object' ? row.meta : {};
        const parts = [];

        if (meta.uses != null && meta.max_uses != null) parts.push(`Прочность: ${meta.uses}/${meta.max_uses}`);
        else if (meta.max_uses != null) parts.push(`Прочность: ${meta.max_uses}`);
        if (meta.weight != null && Number.isFinite(Number(meta.weight))) {
            parts.push(`Вес: ${Number(meta.weight).toFixed(2)} кг`);
        }
        if (row.expires_at) parts.push(`Истекает: ${formatDateTime(row.expires_at)}`);
        if (uiType(row.item_type) === 'FISH' && item.price != null) parts.push(`Цена: ${formatMoney(item.price)}`);

        const type = uiType(row.item_type);
        if (ITEM_TYPES[type] && ITEM_TYPES[type].equippable && item.price != null) {
            const maxUses = Number(meta.max_uses);
            const uses = (meta.uses != null) ? Number(meta.uses) : maxUses;
            let sellPrice = item.price;
            if (Number.isFinite(maxUses) && maxUses > 0 && Number.isFinite(uses) && uses !== -1) {
                sellPrice = Math.round(item.price * 0.5 * (uses / maxUses));
            } else {
                sellPrice = Math.round(item.price * 0.5);
            }
            parts.push(`Цена продажи: ${formatMoney(sellPrice)}`);
        }

        if (!parts.length) {
            const type = uiType(row.item_type);
            if (ITEM_TYPES[type] && ITEM_TYPES[type].equippable) parts.push('Снаряжение');
            else if (item.price != null) parts.push(`Цена продажи: ${formatMoney(item.price)}`);
        }

        return parts.join(' · ');
    }

    function mapInventoryRow(row) {
        const item = row.items && typeof row.items === 'object' ? row.items : {};
        return {
            id: String(row.id),
            item_id: row.item_id,
            item_type: uiType(row.item_type),
            name: item.name || row.item_id,
            rarity: item.rarity || 'common',
            price: Number(item.price) || 0,
            quantity: Number(row.quantity) || 1,
            is_equipped: Boolean(row.is_equipped),
            meta: inventoryMetaText(row, item),
            description: (row.meta && typeof row.meta === 'object' && row.meta.description) ? String(row.meta.description) : '',
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

        const sellButton = '<button class="btn-admin" disabled title="Появится вместе с логикой продажи">Продать</button>';
        const secondary = item.item_type === 'CONSUMABLE'
            ? '<button class="btn-admin" disabled title="Появится вместе с логикой расходников">Использовать</button>' + sellButton
            : sellButton;

        return `
            <div class="inv-item${item.is_equipped ? ' equipped' : ''}" style="border-left-color:${rarity.color}">
                <div class="inv-head">
                                            <div class="inv-icon">${meta.icon}</div>
                    <div class="inv-title">
                        <div class="inv-name">${esc(item.name)}</div>
                        <div class="inv-rarity" style="color:${rarity.color}">${esc(item.rarity)} · ${meta.label}</div>
                    </div>
                    ${item.quantity > 1 ? `<div class="inv-qty">×${Number(item.quantity)}</div>` : ''}
                </div>
                ${item.item_type === 'FISH' && item.meta
                    ? item.meta.split(' · ').filter(Boolean).map((part) => `<div class="inv-info-block">${esc(part)}</div>`).join('')
                    : `<div class="inv-meta">${esc(item.meta || '')}</div>`}
                ${item.description ? `<div class="inv-description">${esc('📝 ' + item.description)}</div>` : ''}
                ${item.item_type === 'ARTIFACT' && Array.isArray(item.effects) && item.effects.length ? `<div class="inv-effects">${item.effects.map((effect) => `<span class="inv-effect-chip">${esc(formatArtifactEffect(effect))}</span>`).join('')}</div>` : ''}
                ${item.cursed ? '<div class="inv-cursed">☠️ проклят</div>' : ''}
                <div class="inv-actions">
                    ${action}
                    ${secondary}
                    ${item.is_equipped ? '<span class="inv-meta">надето</span>' : ''}
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

        el('inventory-counter').textContent = `занято ${occupied} из ${limit}`;

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
            grid.innerHTML = '<div class="empty-state">Артефактов нет</div>';
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
            const button = event.target.closest('[data-action]');
            if (!button || button.disabled) return;
            changeEquipment(button.dataset.action, button.dataset.id);
        });

        const loadoutGrid = el('loadout-grid');
        if (loadoutGrid) {
            loadoutGrid.addEventListener('click', (event) => {
                const button = event.target.closest('[data-action]');
                if (!button || button.disabled) return;
                changeEquipment(button.dataset.action, button.dataset.id);
            });
        }

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
