#!/usr/bin/env node
/* eslint-disable no-console */
/*
 * optimize-images.mjs
 *
 * Берёт изображения из assets/fish-images-full и сохраняет оптимизированные
 * копии под тем же именем в assets/fish-images.
 *
 * Зависимость: sharp
 *   npm install sharp
 *
 * Запуск из папки fishBot-web:
 *   node scripts/optimize-images.mjs
 *
 * Параметры оптимизации настраиваются константами ниже.
 */

import { readdir, mkdir, stat } from 'node:fs/promises';
import { join, extname, basename } from 'node:path';
import { fileURLToPath } from 'node:url';

const __dirname = fileURLToPath(new URL('.', import.meta.url));
const ROOT = join(__dirname, '..');
const SRC_DIR = join(ROOT, 'assets', 'fish-images-full');
const OUT_DIR = join(ROOT, 'assets', 'fish-images');

// --- настройки "очень сильной" оптимизации ---
const MAX_WIDTH = 512;          // максимальная ширина (px); высота пропорциональна
const WEBP_QUALITY = 55;        // качество webp (0-100), ниже = меньше размер
const WEBP_EFFORT = 6;          // усилие кодера (0-6), выше = меньше размер, медленнее
const STRIP_METADATA = true;     // удалить EXIF/ICC/и т.п.
const ALLOWED_EXT = new Set(['.webp']);

async function main() {
    let sharp;
    try {
        sharp = (await import('sharp')).default;
    } catch (e) {
        console.error('Не найден модуль "sharp". Установите его:');
        console.error('  npm install sharp');
        process.exit(1);
    }

    await mkdir(OUT_DIR, { recursive: true });

    const files = (await readdir(SRC_DIR)).filter((f) =>
        ALLOWED_EXT.has(extname(f).toLowerCase())
    );

    if (files.length === 0) {
        console.log(`В ${SRC_DIR} нет изображений для обработки.`);
        return;
    }

    console.log(`Найдено ${files.length} файлов. Оптимизация...`);

    let done = 0;
    let savedBytes = 0;
    for (const file of files) {
        const srcPath = join(SRC_DIR, file);
        const outPath = join(OUT_DIR, file);
        const before = (await stat(srcPath)).size;

        let pipeline = sharp(srcPath);
        if (STRIP_METADATA) pipeline = pipeline.rotate(); // авто-поворот по EXIF, затем метаданные сбросятся

        const info = await pipeline
            .resize({ width: MAX_WIDTH, withoutEnlargement: true })
            .webp({ quality: WEBP_QUALITY, effort: WEBP_EFFORT })
            .toFile(outPath);

        const after = info.size;
        savedBytes += Math.max(0, before - after);
        done++;
        console.log(
            `${done}/${files.length}  ${file}  ${(before / 1024).toFixed(1)}KB -> ${(after / 1024).toFixed(1)}KB`
        );
    }

    console.log(`\nГотово: ${done} файлов. Сэкономлено ~${(savedBytes / 1024).toFixed(1)} KB.`);
}

main().catch((err) => {
    console.error(err);
    process.exit(1);
});
