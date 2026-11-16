/* Кабинет игрока — заготовка интерфейса.
 * Данные пока демонстрационные. Точки подключения Supabase помечены TODO.
 */
(function () {
    const CONFIG = window.FISHBOT_CONFIG || {};
    const SUPABASE_READY = Boolean(CONFIG.supabaseUrl && CONFIG.supabaseAnonKey);

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

    const DEMO_PLAYER = {
        userId: '00000000',
        username: 'DemoFisher',
        balance: 1250,
        level: 7,
        xp: 2450,
        xpForNext: 3600,
        fishCaught: 312
    };

    const DEMO_INVENTORY = [
        { item_id: 'rod_rare_1', item_type: 'ROD', name: 'Удочка «Прилив»', rarity: 'rare', quantity: 1, is_equipped: true, meta: 'Прочность 82 / 100' },
        { item_id: 'rod_common_1', item_type: 'ROD', name: 'Бамбуковая удочка', rarity: 'common', quantity: 1, is_equipped: false, meta: 'Прочность 45 / 100' },
        { item_id: 'line_epic_1', item_type: 'LINE', name: 'Леска «Бездна»', rarity: 'epic', quantity: 1, is_equipped: true, meta: 'Прочность 96 / 100' },
        { item_id: 'hook_legendary_1', item_type: 'HOOK', name: 'Крючок Посейдона', rarity: 'legendary', quantity: 1, is_equipped: false, meta: 'Прочность 74 / 100' },
        { item_id: 'bait_common_1', item_type: 'BAIT', name: 'Червь', rarity: 'common', quantity: 24, is_equipped: true, meta: 'Расходуется при забросе' },
        { item_id: 'bait_rare_1', item_type: 'BAIT', name: 'Светящаяся приманка', rarity: 'rare', quantity: 5, is_equipped: false, meta: 'Повышает шанс редкой рыбы' },
        { item_id: 'artifact_lucky_1', item_type: 'ARTIFACT', name: 'Амулет удачи', rarity: 'epic', quantity: 1, is_equipped: false, meta: '+12% к шансу сокровищ · не проклят' },
        { item_id: 'fish_mythic_1', item_type: 'FISH', name: 'Лунный карп', rarity: 'mythic', quantity: 1, is_equipped: false, meta: 'Цена продажи: 4200 💰' },
        { item_id: 'fish_trash_1', item_type: 'FISH', name: 'Старый сапог', rarity: 'trash', quantity: 3, is_equipped: false, meta: 'Цена продажи: 3 💰' },
        { item_id: 'fish_treasure_1', item_type: 'FISH', name: 'Затонувший сундук', rarity: 'treasure', quantity: 1, is_equipped: false, meta: 'Цена продажи: 900 💰' },
        { item_id: 'consumable_repair_1', item_type: 'CONSUMABLE', name: 'Ремонтный набор', rarity: 'uncommon', quantity: 2, is_equipped: false, meta: 'Восстанавливает прочность снаряжения' }
    ];

    const DEMO_CATCHES = [
        { name: 'Лунный карп', rarity: 'mythic', price: 4200, at: '2 минуты назад' },
        { name: 'Полосатый окунь', rarity: 'common', price: 18, at: '6 минут назад' },
        { name: 'Старый сапог', rarity: 'trash', price: 3, at: '11 минут назад' },
        { name: 'Сундук с монетами', rarity: 'treasure', price: 900, at: '18 минут назад' }
    ];

    const DEMO_RANKING = [
        { username: 'night_angler', value: '18 400 💰' },
        { username: 'DemoFisher', value: '1 250 💰' },
        { username: 'quiet_pike', value: '980 💰' }
    ];

    const state = {
        tab: 'profile',
        player: null,
        inventory: [],
        demo: false,
        filters: { type: 'all', rarity: 'all', q: '' }
    };

    const TITLES = {
        profile: 'Профиль',
        inventory: 'Инвентарь',
        loadout: 'Экипировка',
        rankings: 'Рейтинг'
    };

    const el = (id) => document.getElementById(id);

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

    function showTab(name) {
        if (!state.player) {
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

    function renderChip() {
        const chip = el('user-chip');
        const name = el('user-chip-name');
        const avatar = el('user-chip-avatar');

        if (state.player) {
            chip.hidden = false;
            name.textContent = state.player.username;
            avatar.textContent = state.demo ? '🧪' : '🟣';
        } else {
            chip.hidden = true;
        }

        const login = el('btn-login');
        login.textContent = state.player ? 'Выйти' : 'Войти через Twitch';
        el('btn-demo').textContent = state.player ? 'Сбросить' : 'Демо-режим';
    }

    function renderProfile() {
        const player = state.player;
        if (!player) return;

        el('stat-balance').textContent = `${Number(player.balance || 0).toLocaleString('ru-RU')} 💰`;
        el('stat-level').textContent = player.level;
        el('stat-fish').textContent = Number(player.fishCaught || 0).toLocaleString('ru-RU');

        const next = Number(player.xpForNext) || 1;
        const percent = Math.max(0, Math.min(100, (Number(player.xp) / next) * 100));
        el('xp-fill').style.width = `${percent.toFixed(1)}%`;
        el('xp-current').textContent = `${Number(player.xp).toLocaleString('ru-RU')} XP`;
        el('xp-next').textContent = `до ${Number(next).toLocaleString('ru-RU')} XP`;

        el('recent-catches').innerHTML = DEMO_CATCHES.map((c) => {
            const rarity = RARITY[c.rarity] || RARITY.empty;
            return `
                <div class="admin-event-row">
                    <div class="grow">
                        <div class="item-name">${rarity.icon} ${c.name}</div>
                        <div class="item-meta">${c.at}</div>
                    </div>
                    <div class="item-details" style="color:${rarity.color}">${c.price} 💰</div>
                </div>
            `;
        }).join('');
    }

    function renderLoadout() {
        const slots = ['ROD', 'LINE', 'HOOK', 'BAIT'];
        el('slot-grid').innerHTML = slots.map((type) => {
            const meta = ITEM_TYPES[type];
            const item = state.inventory.find((entry) => entry.item_type === type && entry.is_equipped);
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
                    <div class="slot-name">${item.name}</div>
                    <div class="slot-rarity" style="color:${rarity.color}">${item.rarity}</div>
                </div>
            `;
        }).join('');
    }

    function filteredInventory() {
        const { type, rarity, q } = state.filters;
        const needle = q.trim().toLowerCase();

        return state.inventory.filter((item) => {
            if (type !== 'all' && item.item_type !== type) return false;
            if (rarity !== 'all' && item.rarity !== rarity) return false;
            if (needle && !item.name.toLowerCase().includes(needle)) return false;
            return true;
        });
    }

    function renderInventory() {
        const grid = el('inventory-grid');
        const items = filteredInventory();

        el('inventory-counter').textContent = `${items.length} из ${state.inventory.length}`;

        if (items.length === 0) {
            grid.innerHTML = '<div class="empty-state">По фильтрам ничего не найдено</div>';
            return;
        }

        grid.innerHTML = items.map((item) => {
            const meta = ITEM_TYPES[item.item_type] || { label: item.item_type, icon: '❔', equippable: false };
            const rarity = RARITY[item.rarity] || RARITY.empty;
            const id = `${item.item_id}|${item.item_type}`;

            const action = meta.equippable
                ? (item.is_equipped
                    ? `<button class="btn-admin" data-action="unequip" data-id="${id}">Снять</button>`
                    : `<button class="btn-admin primary" data-action="equip" data-id="${id}">Экипировать</button>`)
                : '';

            const secondary = item.item_type === 'CONSUMABLE'
                ? '<button class="btn-admin" disabled title="Появится вместе с логикой расходников">Использовать</button>'
                : (item.item_type === 'FISH'
                    ? '<button class="btn-admin" disabled title="Появится вместе с логикой продажи">Продать</button>'
                    : '');

            return `
                <div class="inv-item${item.is_equipped ? ' equipped' : ''}" style="border-left-color:${rarity.color}">
                    <div class="inv-head">
                        <div class="inv-icon">${rarity.icon}</div>
                        <div class="inv-title">
                            <div class="inv-name">${item.name}</div>
                            <div class="inv-rarity" style="color:${rarity.color}">${item.rarity} · ${meta.label}</div>
                        </div>
                        ${item.quantity > 1 ? `<div class="inv-qty">×${item.quantity}</div>` : ''}
                    </div>
                    <div class="inv-meta">${item.meta || ''}</div>
                    <div class="inv-actions">
                        ${action}
                        ${secondary}
                        ${item.is_equipped ? '<span class="inv-meta">надето</span>' : ''}
                    </div>
                </div>
            `;
        }).join('');
    }

    function renderRankings() {
        el('ranking-list').innerHTML = DEMO_RANKING.map((row, index) => `
            <div class="ranking-item">
                <span class="rank">#${index + 1}</span>
                <span class="name">${row.username}</span>
                <span class="value">${row.value}</span>
            </div>
        `).join('');
    }

    function renderAll() {
        renderChip();
        renderProfile();
        renderInventory();
        renderLoadout();
        renderRankings();
    }

    function setFilter(key, value) {
        state.filters[key] = value;
        renderInventory();
    }

    /* TODO(Supabase): вместо локального флага — RPC equip_item / unequip_item,
       которые проверяют, что строка принадлежит текущему Twitch-пользователю. */
    function changeEquipment(action, rawId) {
        if (!state.player) return;

        const [itemId, itemType] = String(rawId).split('|');
        const item = state.inventory.find((entry) => entry.item_id === itemId && entry.item_type === itemType);
        if (!item) return;

        if (action === 'equip') {
            state.inventory.forEach((entry) => {
                if (entry.item_type === itemType) entry.is_equipped = false;
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

    function toggleDemo() {
        if (state.player) {
            state.player = null;
            state.inventory = [];
            state.demo = false;
            setStatus('Гостевой режим', false);
            renderAuthOnly();
            renderChip();
            return;
        }

        state.demo = true;
        state.player = { ...DEMO_PLAYER };
        state.inventory = DEMO_INVENTORY.map((item) => ({ ...item }));
        setStatus('Демо-данные', true);
        renderAll();
        showTab('profile');
        toast('Демо-режим: данные ненастоящие');
    }

    function handleLogin() {
        if (state.player) {
            toggleDemo();
            return;
        }

        if (!SUPABASE_READY) {
            el('setup-notice').hidden = false;
            toast('Сначала укажите Supabase URL и anon key в config.js');
            return;
        }

        /* TODO(Supabase): supabase.auth.signInWithOAuth({ provider: 'twitch',
           options: { redirectTo: window.location.origin + window.location.pathname } }) */
        toast('OAuth-вход ещё не подключён: нужен клиент supabase-js и провайдер Twitch');
    }

    function bind() {
        el('inventory-grid').addEventListener('click', (event) => {
            const button = event.target.closest('[data-action]');
            if (!button || button.disabled) return;
            changeEquipment(button.dataset.action, button.dataset.id);
        });

        if (!SUPABASE_READY) el('setup-notice').hidden = false;
    }

    // Inline-обработчики в index.html вызывают эти функции из глобальной области.
    window.showTab = showTab;
    window.toggleDemo = toggleDemo;
    window.handleLogin = handleLogin;
    window.setFilter = setFilter;

    document.addEventListener('DOMContentLoaded', () => {
        bind();
        renderRankings();
        setStatus('Гостевой режим', false);
        renderAuthOnly();
    });
})();
