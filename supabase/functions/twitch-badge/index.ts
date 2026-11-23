// Edge Function: авторизация бота для значка чат-бота (scope channel:bot).
//
// Зачем сервер: при implicit flow Twitch отдаёт access_token прямо в URL
// браузера. Здесь authorization code flow — Twitch возвращает только
// одноразовый code, а обмен на токен делает эта функция своим client_secret.
// Токен не покидает функцию: читаем scope, отзываем его и пишем в базу лишь
// факт разрешения.
//
// Маршруты (одна функция, режим по параметрам):
//   GET .../functions/v1/twitch-badge             → 302 на id.twitch.tv/oauth2/authorize
//   GET .../functions/v1/twitch-badge?code=...    → обмен кода, запись в channels, 302 в кабинет
//
// Секреты (supabase secrets set): TWITCH_CLIENT_ID, TWITCH_CLIENT_SECRET,
// CABINET_URL, BADGE_STATE_SECRET. В статику кабинета не попадает ничего,
// кроме адреса функции. SUPABASE_URL и SUPABASE_SERVICE_ROLE_KEY функция
// получает от платформы.
//
// Развёртывание: supabase functions deploy twitch-badge --no-verify-jwt
// (JWT не нужен: сюда приходит браузер по редиректу Twitch, а не кабинет).

const AUTHORIZE_URL = 'https://id.twitch.tv/oauth2/authorize';
const TOKEN_URL = 'https://id.twitch.tv/oauth2/token';
const REVOKE_URL = 'https://id.twitch.tv/oauth2/revoke';
const USERS_URL = 'https://api.twitch.tv/helix/users';
const SCOPE = 'channel:bot';
const STATE_TTL_MS = 10 * 60 * 1000;

const RATE_WINDOW_MS = 10 * 60 * 1000;
const RATE_MAX = 20;

const encoder = new TextEncoder();

type TokenResponse = {
    access_token?: string;
    refresh_token?: string;
    scope?: string[];
};

function env(name: string): string {
    return String(Deno.env.get(name) || '').trim();
}

function noStore(status: number, body: string): Response {
    return new Response(body, {
        status,
        headers: { 'Content-Type': 'text/plain; charset=utf-8', 'Cache-Control': 'no-store' }
    });
}

function redirect(target: string): Response {
    return new Response(null, {
        status: 302,
        headers: {
            Location: target,
            'Cache-Control': 'no-store',
            'Referrer-Policy': 'no-referrer'
        }
    });
}

function base64url(bytes: Uint8Array): string {
    let binary = '';
    for (const byte of bytes) binary += String.fromCharCode(byte);
    return btoa(binary).replace(/\+/g, '-').replace(/\//g, '_').replace(/=+$/, '');
}

async function hmac(payload: string, secret: string): Promise<string> {
    const key = await crypto.subtle.importKey(
        'raw',
        encoder.encode(secret),
        { name: 'HMAC', hash: 'SHA-256' },
        false,
        ['sign']
    );
    const signature = await crypto.subtle.sign('HMAC', key, encoder.encode(payload));
    return base64url(new Uint8Array(signature));
}

/** state без хранения на сервере: срок + nonce + HMAC, чтобы нельзя было подделать. */
async function makeState(secret: string): Promise<string> {
    const nonce = crypto.randomUUID().replace(/-/g, '');
    const payload = `${Date.now() + STATE_TTL_MS}.${nonce}`;
    return `${payload}.${await hmac(payload, secret)}`;
}

async function verifyState(state: string, secret: string): Promise<boolean> {
    const parts = String(state || '').split('.');
    if (parts.length !== 3) return false;

    const [expires, nonce, signature] = parts;
    if (!/^\d+$/.test(expires) || !nonce || !signature) return false;
    if (Number(expires) < Date.now()) return false;

    const expected = await hmac(`${expires}.${nonce}`, secret);
    if (expected.length !== signature.length) return false;

    let diff = 0;
    for (let i = 0; i < expected.length; i += 1) {
        diff |= expected.charCodeAt(i) ^ signature.charCodeAt(i);
    }
    return diff === 0;
}

/* Грубый лимит на старт авторизации. Живёт в памяти изолята, поэтому это
   защита от потока случайных запросов, а не точный счётчик. */
const hits = new Map<string, number[]>();

function clientIp(request: Request): string {
    const forwarded = String(request.headers.get('x-forwarded-for') || '').split(',')[0].trim();
    return forwarded || String(request.headers.get('x-real-ip') || '').trim();
}

/* Ограничиваем только старт авторизации: успешный возврат с code тоже не
   должен тратить квоту. Без IP (прокси не прислал заголовок) не ограничиваем —
   иначе все посетители попали бы в один общий бакет. */
function rateLimited(ip: string): boolean {
    if (!ip) return false;

    const now = Date.now();
    const list = (hits.get(ip) || []).filter((at) => now - at < RATE_WINDOW_MS);
    list.push(now);
    hits.set(ip, list);
    if (hits.size > 5000) hits.clear();
    return list.length > RATE_MAX;
}

/** Возврат в кабинет: только код результата, без токена и без текста Twitch. */
function back(status: string): Response {
    const base = env('CABINET_URL');
    if (!base) return noStore(500, `badge: ${status}`);

    try {
        const target = new URL(base);
        target.searchParams.set('badge', status);
        target.hash = '';
        return redirect(target.toString());
    } catch {
        return noStore(500, `badge: ${status}`);
    }
}

/** Отзыв access-токена. Refresh не трогаем: он нам не нужен и мы его не храним,
    а разрешение channel:bot живёт в связке приложения с аккаунтом, не в токене.
    Если Twitch начнёт снимать разрешение после отзыва — BADGE_REVOKE_TOKEN=0. */
async function revoke(token: string, clientId: string): Promise<void> {
    if (env('BADGE_REVOKE_TOKEN') === '0' || !token) return;

    try {
        await fetch(REVOKE_URL, {
            method: 'POST',
            headers: { 'Content-Type': 'application/x-www-form-urlencoded' },
            body: new URLSearchParams({ client_id: clientId, token })
        });
    } catch (error) {
        console.warn('twitch-badge: отзыв токена не удался', error instanceof Error ? error.message : error);
    }
}

/**
 * Отметка в channels: только канал самого стримера и только подключённый.
 * Возвращает три разных исхода, чтобы стример не видел «подключите бота»,
 * когда канал подключён, а упала запись в базу.
 */
async function markRequested(broadcasterId: string): Promise<'ok' | 'nochannel' | 'error'> {
    const supabaseUrl = env('SUPABASE_URL');
    const serviceKey = env('SUPABASE_SERVICE_ROLE_KEY');
    if (!supabaseUrl || !serviceKey) return 'error';

    const target = new URL(`${supabaseUrl}/rest/v1/channels`);
    target.searchParams.set('id', `eq.${broadcasterId}`);
    target.searchParams.set('bot_status', 'in.(pending,active)');
    target.searchParams.set('bot_banned', 'eq.false');
    target.searchParams.set('select', 'id');

    const response = await fetch(target, {
        method: 'PATCH',
        headers: {
            apikey: serviceKey,
            Authorization: `Bearer ${serviceKey}`,
            'Content-Type': 'application/json',
            Prefer: 'return=representation'
        },
        body: JSON.stringify({
            bot_badge_requested_at: new Date().toISOString(),
            /* Старое подтверждение относилось к прежнему разрешению. */
            bot_badge_at: null
        })
    });

    if (!response.ok) return 'error';

    const rows = await response.json().catch(() => null);
    if (!Array.isArray(rows)) return 'error';

    return rows.length > 0 ? 'ok' : 'nochannel';
}

async function handle(request: Request): Promise<Response> {
    if (request.method !== 'GET') return noStore(405, 'method not allowed');

    const url = new URL(request.url);
    const clientId = env('TWITCH_CLIENT_ID');
    const clientSecret = env('TWITCH_CLIENT_SECRET');
    const stateSecret = env('BADGE_STATE_SECRET');
    const cabinet = env('CABINET_URL');

    if (!clientId || !clientSecret || !stateSecret || !cabinet) {
        console.error('twitch-badge: не заданы TWITCH_CLIENT_ID/SECRET, BADGE_STATE_SECRET или CABINET_URL');
        return noStore(500, 'badge: not configured');
    }

    const error = url.searchParams.get('error');
    if (error) {
        console.warn('twitch-badge: Twitch вернул отказ', error);
        return back(error === 'access_denied' ? 'denied' : 'error');
    }

    const code = url.searchParams.get('code');
    const state = String(url.searchParams.get('state') || '');
    if (!code || !state) {
        if (rateLimited(clientIp(request))) return back('ratelimited');

        const redirectUri = `${env('SUPABASE_URL')}/functions/v1/twitch-badge`;
        const authorize = new URL(AUTHORIZE_URL);
        authorize.searchParams.set('client_id', clientId);
        authorize.searchParams.set('redirect_uri', redirectUri);
        authorize.searchParams.set('response_type', 'code');
        authorize.searchParams.set('scope', SCOPE);
        authorize.searchParams.set('force_verify', 'true');
        authorize.searchParams.set('state', await makeState(stateSecret));
        return redirect(authorize.toString());
    }

    if (!(await verifyState(state, stateSecret))) return back('state');

    const redirectUri = `${env('SUPABASE_URL')}/functions/v1/twitch-badge`;
    const tokenResponse = await fetch(TOKEN_URL, {
        method: 'POST',
        headers: { 'Content-Type': 'application/x-www-form-urlencoded' },
        body: new URLSearchParams({
            client_id: clientId,
            client_secret: clientSecret,
            code,
            grant_type: 'authorization_code',
            redirect_uri: redirectUri
        })
    });

    if (!tokenResponse.ok) {
        /* Тело ответа не логируем: в нём бывают фрагменты токенов. */
        console.warn('twitch-badge: обмен кода не удался', tokenResponse.status);
        return back(tokenResponse.status === 400 ? 'expired' : 'error');
    }

    /* Битый JSON не должен бросать исключение: иначе токен останется
       неотозванным до истечения. */
    const token = (await tokenResponse.json().catch(() => null)) as TokenResponse | null;
    const accessToken = String(token?.access_token || '');
    if (!accessToken) return back('error');

    const scopes = Array.isArray(token?.scope) ? token.scope.map(String) : [];
    if (!scopes.includes(SCOPE)) {
        await revoke(accessToken, clientId);
        return back('scope');
    }

    let broadcasterId = '';
    try {
        const userResponse = await fetch(USERS_URL, {
            headers: { 'Client-Id': clientId, Authorization: `Bearer ${accessToken}` }
        });
        if (userResponse.ok) {
            const payload = (await userResponse.json()) as { data?: Array<{ id?: string }> };
            broadcasterId = String(payload?.data?.[0]?.id || '');
        }
    } catch (fetchError) {
        console.warn('twitch-badge: helix/users недоступен', fetchError instanceof Error ? fetchError.message : fetchError);
    }

    /* Helix не дал ID — это не «канал не подключён», а сбой проверки. */
    let result: 'ok' | 'nochannel' | 'error' = 'error';
    if (/^\d+$/.test(broadcasterId)) {
        try {
            result = await markRequested(broadcasterId);
        } catch (dbError) {
            console.error('twitch-badge: запись в channels не удалась', dbError instanceof Error ? dbError.message : dbError);
        }
    }

    /* Токен больше не нужен: отзываем до возврата в кабинет. */
    await revoke(accessToken, clientId);

    if (result !== 'ok') return back(result);
    console.log('twitch-badge: channel', broadcasterId, 'получил channel:bot');
    return back('ok');
}

Deno.serve(async (request: Request) => {
    try {
        return await handle(request);
    } catch (error) {
        console.error('twitch-badge: необработанная ошибка', error instanceof Error ? error.message : error);
        return back('error');
    }
});
