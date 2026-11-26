Hyper-realistic underwater macro photograph of a single fish, side profile, floating in deep obsidian water, dark navy background #020617 with soft volumetric cyan and violet light beams, glass-like water surface reflections, ultra-detailed scales with micro-texture and iridescence, translucent fins with fine ray structure, subtle rim light in a color matching the fish's rarity, cinematic depth of field, bokeh particles, caustic light patterns on the body, professional studio lighting, 85mm lens, f/2.8, sharp focus on the eye, no text, no watermark, no humans, isolated subject, square composition, 8k, photorealistic, award-winning nature photography

Negative: cartoon, illustration, painting, anime, flat shading, low detail, plastic look, toy-like, deformed anatomy, extra fins, missing eye, text, watermark, logo, multiple fish, bright white background, harsh flash, overexposed, noisy, jpeg artifacts

Add a clean dark brown and black ink outline around the fish and its fins to match a 2D game art style, keeping the fish's colors, shape, and underwater background completely unchanged.
или
Enhance edge definition with bold dark line art contours around the entire silhouette and fin rays, crisp cel-shaded 2D illustration style, preserve exact pose and background.

## Оптимизация картинок
- Генерировать в 1024×1024 (или 512×512 для лёгких карточек).
- Конвертировать в WebP: качество 80–85, метод 6, без метаданных.
- Целевой размер файла: до ~40–60 КБ для 512px, до ~120 КБ для 1024px.
- Имя файла строго `{item_id}.webp` (например `perch.webp`).
- Путь: `fishBot-web/assets/fish-images/`.
- После замены файла менять имя/путь (или добавлять версию), чтобы сбросить кэш IndexedDB и браузера.
- Проверять CSP: изображения только same-origin (`assets/fish-images/...`).

### Пример конвертации (Pillow)
```python
from PIL import Image
img = Image.open('perch.png').convert('RGB')
img.save('assets/fish-images/perch.webp', 'WEBP', quality=82, method=6)
```

## Как генерировать файл
1. Скопировать промпт выше.
2. Заменить "a single fish" на вид рыбы (например "a single perch fish").
3. Указать цвет редкости в "rim light in ..." (common: soft slate gray #94a3b8; uncommon: emerald green #22c55e; rare: electric blue #3b82f6; epic: violet #a855f7; legendary: golden #eab308; mythic: hot pink #f472b6).
4. Сгенерировать изображение 1024×1024.
5. Конвертировать в WebP и сохранить как `assets/fish-images/{item_id}.webp`.
6. Повторить для всех рыб из списка ниже.

## Список рыб (id — Название — редкость — описание)


Common (Обычная)

• carp — Карп: plump common carp with golden-bronze and olive-brown scales, thick fleshy lips with small barbels, and greyish-orange fins
• perch — Окунь: European perch with greenish-yellow scales, dark vertical tiger stripes, spiky first dorsal fin, and bright reddish-orange lower fins
• roach — Плотва: sleek common roach with bright silvery-blue scales, dark grey back, and vibrant orange-red eyes and fins
• crucian — Карась: deep high-backed crucian carp with rounded golden-bronze body, smooth scales, small mouth without barbels, and dark rounded fins
• bream — Лещ: tall flat-bodied freshwater bream with dark brownish-bronze back, silvery-grey sides, and long dark grey anal and tail fins
• gudgeon — Пескарь: small slender gudgeon with brownish-grey back, a row of dark spots along its pale sides, downward-pointing mouth with two barbels, and speckled fins
• ruff — Ёрш: small prickly Eurasian ruffe with mottled olive-brown and golden skin, oversized spiny dorsal fin with dark spots, and large glassy eyes
• bleak — Уклейка: slender streamlined common bleak with bright metallic silver scales, dark bluish-green back, upturned mouth, and pale translucent fins
• silver_bream — Густера: flat silver-sided white bream with bluish-grey back, large eyes, and reddish-tinged pectoral and pelvic fins
• rudd — Краснопёрка: deep-bodied common rudd with shimmering golden-silver scales, bright amber-red eyes, and vivid crimson-red fins
• tench — Линь: thick-bodied tench with smooth tiny scales, rich dark olive-green and golden-bronze skin, small red eyes, and thick rounded dark fins
• ide — Язь: stout-bodied ide with dark bluish-grey back, bright silvery sides, golden eyes, and reddish-pink lower fins
• chub — Голавль: cylindrical muscular European chub with large dark-edged scales, broad head, wide mouth, and bright orange-red anal and pelvic fins
• asp — Жерех: sleek predatory asp with elongated silvery body, dark bluish-grey back, protruding lower jaw, and large sharp dark-grey tail fin
• podust — Подуст: streamlined common nase with silvery scales, dark grey back, distinctive chisel-shaped underslung mouth, and reddish lower fins

Uncommon (Необычная)

• pike — Щука: elongated predatory northern pike with mottled olive-green body, pale yellow-white spots, flat duck-bill snout, and reddish-brown spotted fins
• zander — Судак: sleek predatory zander with elongated greenish-grey body, faint dark vertical bars, glassy reflective eyes, and two prominent spiky dorsal fins
• catfish — Сом: wels catfish with smooth scaleless dark grey-brown mottled skin, wide flat head, long sensory whiskers, and an extra-long anal fin
• carp_big — Крупный карп: massive trophy common carp with thick heavy body, large dark golden-bronze scales, prominent barbels, and weathered dark orange fins
• burbot — Налим: elongated eel-like freshwater burbot with mottled dark brown and yellowish-olive skin, single chin barbel, and long continuous dorsal and anal fins
• chub_big — Крупный голавль: heavy trophy European chub with broad thick body, large metallic bronze-silver scales with dark rims, and vivid crimson lower fins
• trout — Форель: streamlined rainbow trout with olive-green back, silvery sides, vibrant pink-red stripe along the lateral line, and small black spots across body and fins
• grayling — Хариус: elegant Arctic grayling with silvery-purple iridescent scales, dark spots on the flanks, and a huge sail-like colorful dorsal fin
• whitefish — Сиг: sleek freshwater whitefish with bright silvery scales, dark bluish-olive back, small subterminal mouth, and dark-tipped forked tail
• vendace — Ряпушка: small slender vendace with gleaming silver sides, dark blue-green back, slightly upturned lower jaw, and delicate translucent fins
• smelt — Корюшка: slender semi-translucent European smelt with silvery-green iridescent sides, large dark eyes, and a small adipose fin near the tail
• sabrefish — Чехонь: razor-thin knife-like sabrefish with straight back, deeply curved silver belly, upward-pointing mouth, and long wing-like pectoral fins
• bream_big — Крупный лещ: massive trophy bream with extremely deep hump-backed body, rich dark golden-bronze scales, and long dark sweeping fins
• tench_big — Крупный линь: huge trophy tench with heavy muscular body, deep emerald-olive and dark gold glossy skin, vivid red eyes, and thick rounded fins
• carp_koi — Зеркальный карп: striking mirror carp with smooth glossy olive-bronze skin and irregular rows of oversized gleaming metallic scales along its back and flanks

Rare (Редкая)

• salmon — Лосось: powerful Atlantic salmon with sleek silver-blue body, dark X-shaped spots above the lateral line, muscular tail, and subtle pinkish sheen
• sturgeon — Осётр: ancient armored sturgeon with elongated dark olive-grey body, rows of sharp bony scutes along its back and sides, pointed snout with four barbels, and shark-like tail
• sterlet — Стерлядь: slender freshwater sterlet sturgeon with narrow elongated pointed snout, fringed barbels, dark brownish-grey skin, and rows of pale bony scutes
• eel — Угорь: sinuous snake-like European eel with smooth glossy dark olive-brown skin, yellowish belly, small pectoral fins, and continuous ribbon-like dorsal and tail fin
• pike_big — Трофейная щука: massive monster northern pike with thick scarred olive-green body, bold golden-yellow tiger markings, fierce jaws, and large spotted fins
• catfish_big — Гигантский сом: colossal ancient wels catfish with massive heavy head, thick dark slate-brown marbled skin, extra-long whiskers, and broad sweeping tail
• zander_big — Трофейный судак: large trophy zander with heavily built silvery-grey body, dark vertical bands, sharp dorsal spines, and glowing glassy eyes
• trout_big — Крупная форель: massive trophy brown trout with thick golden-olive body, bold black and red haloed spots, hooked lower jaw, and broad spotted tail
• tuna — Тунец: torpedo-shaped muscular bluefin tuna with metallic dark blue back, gleaming silver belly, yellow finlets along the tail base, and crescent-shaped tail fin
• marlin — Марлин: sleek powerful blue marlin with cobalt-blue back, silvery-white belly with faint vertical stripes, long spear-like upper bill, and tall pointed dorsal fin
• swordfish — Меч-рыба: streamlined broadbill swordfish with dark metallic purplish-blue back, pale belly, long flat sword-like bill, and tall curved dorsal fin
• halibut — Палтус: large flat-bodied Atlantic halibut swimming slightly tilted to show its dark olive-brown upper side with pale mottling, white underside, and both eyes on the upper side
• cod — Треска: heavy-bodied Atlantic cod with greenish-brown speckled back, pale lateral line, prominent chin barbel, and three distinct rounded dorsal fins
• mackerel — Скумбрия: sleek fast-swimming Atlantic mackerel with iridescent blue-green back, wavy dark tiger stripes, metallic silver flanks, and tiny tail finlets
• herring — Сельдь: streamlined Atlantic herring with brilliant mirror-like silver scales, deep metallic blue-green back, and deeply forked translucent tail
• flounder — Камбала: flat oval European flounder swimming slightly angled, showing sandy-brown skin speckled with bright orange-red spots and continuous frilly fins
• sea_bass — Морской окунь: sleek silvery European sea bass with dark steel-grey back, large scales, spiny dorsal fin, and bold muscular profile
• mullet — Кефаль: torpedo-shaped grey mullet with metallic silver-grey scales, dark longitudinal stripes, blunt head, and two widely separated dorsal fins
• garfish — Сарган: needle-thin elongated garfish with iridescent blue-green back, bright silver sides, long beak-like jaws filled with tiny teeth, and greenish fins
• moonfish — Рыба-луна: bizarre disc-shaped ocean sunfish (mola mola) with rough leathery greyish-silver skin, no true tail, and oversized tall dorsal and anal fins

Epic (Эпическая)

• golden_fish — Золотая рыбка: ornate fantastical goldfish with plump gleaming metallic gold and fiery orange scales, large expressive eyes, and long flowing translucent veil-like fins and tail
• koi — Карп Кои: graceful Kohaku koi carp with porcelain-white skin, vivid crimson-red symmetrical markings, delicate barbels, and long flowing silk-like fins
• arapaima — Арапайма: massive prehistoric arapaima with long cylindrical olive-grey armored scales, flattened bony head, and glowing crimson-red edges on its rear scales and tail
• paddlefish — Веслонос: unusual prehistoric American paddlefish with smooth slate-grey shark-like body and an elongated flat paddle-shaped snout extending forward
• electric_eel — Электрический угорь: thick dark slate-grey electric eel with bright orange-yellow throat and subtle crackling arcs of pale blue bio-electricity glowing along its elongated body
• piranha — Пиранья: stocky aggressive red-bellied piranha with iridescent silver-grey scales, glowing red belly and throat, blunt bulldog-like jaw with visible razor-sharp teeth
• anglerfish — Рыба-удильщик: deep-sea black seadevil anglerfish with bulbous dark pitch-brown body, huge gaping jaws with needle-like translucent teeth, and a glowing bioluminescent lure dangling from its forehead
• oarfish — Сельдяной король: giant ribbon-like deep-sea oarfish with gleaming silver metallic body, dark blue speckles, and a vivid crimson-red crest and long continuous dorsal fin
• blobfish — Рыба-капля: gelatinous deep-sea blobfish with soft pinkish-grey sagging skin, bulbous droopy nose, sad expression, and delicate translucent pectoral fins
• fugu — Рыба Фугу: puffed-up spiky pufferfish (fugu) with round inflated body, dark olive-brown leopard spots on top, white prickly belly, and tiny fluttering fins
• coelacanth — Латимерия: prehistoric lobe-finned coelacanth with heavy dark sapphire-blue armored scales speckled with white spots, fleshy limb-like fins, and three-lobed tail
• beluga — Белуга: colossal ancient beluga sturgeon with massive dark slate-grey body, pale belly, rows of sharp ivory bony scutes, short pointed snout, and wide crescent mouth
• shark_small — Акула-нянька: sleek tawny nurse shark with smooth yellowish-brown leathery skin, small barbels near its mouth, rounded dorsal fins, and long sweeping upper tail lobe
• ray — Скат-хвостокол: graceful diamond-shaped stingray gliding in side-angle profile with dark olive-brown speckled skin, pale underside, undulating wing-like fins, and a long whip tail with a venomous barb
• moray — Мурена: sinuous green moray eel with thick muscular olive-green skin, continuous dorsal fin, fierce narrow head, and open jaws showing sharp glassy teeth
• barracuda — Барракуда: long razor-sleek great barracuda with metallic silver-grey scales, dark diagonal bars, pointed pike-like head, and fierce protruding lower jaw with fang-like teeth

Legendary (Легендарная)

• golden_carp — Золотой карп: majestic royal golden carp with mirror-polished 24-karat gold scales, radiant metallic sheen, regal flowing golden-amber fins, and long elegant barbels
• giant_octopus — Гигантский осьминог: massive deep-sea giant Pacific octopus suspended in profile with bulbous textured crimson-orange mantle, intelligent golden eyes, and eight thick curling tentacles lined with pale suction cups
• kraken — Кракен: colossal mythical deep-sea kraken with dark obsidian-purple armored mantle, glowing amber eyes, jagged beak, and massive swirling tentacles trailing faint bioluminescent mist
• leviathan — Левиафан: mythical ancient sea serpent leviathan with dark abyssal armored scales, glowing bioluminescent runes along its flanks, jagged dorsal spines, and fierce dragon-like jaws
• golden_sturgeon — Золотой осётр: royal golden sturgeon with gleaming liquid-gold skin, jewel-like ivory and gold bony scutes along its back, sleek armored snout, and radiant metallic fins
• mermaid_scale_fish — Рыба с чешуёй русалки: ethereal mythical fish covered in iridescent mother-of-pearl and opalescent pastel scales shifting between turquoise, lavender, and rose gold, with delicate translucent ribbon fins
• dragon_fish — Рыба-дракон: mythical Eastern dragon-fish with elongated crimson and gold armored scales, flowing whisker-like barbels, horned dragon-like head, and flame-shaped fin rays
• megalodon_teeth_fish — Акула-мегалодон (детёныш): prehistoric juvenile megalodon shark with massive thick slate-grey muscular body, battle-scarred skin, giant gill slits, and heavy jaws lined with serrated triangular teeth
• phoenix_fish — Рыба-феникс: mythical fiery phoenix fish with dark volcanic ember scales glowing with molten orange cracks, and long flowing feather-like fins resembling living golden-red flames
• celestial_koi — Небесный Кои: divine celestial koi carp with pearlescent alabaster-white scales, shimmering gold and sky-blue astral markings, and ultra-long flowing silk-like fins trailing stardust

Mythic (Мифическая)

• starry_ray — Звездный Скат: cosmic manta-like starry ray gliding gracefully with deep midnight-indigo skin patterned with glowing constellation lines and tiny sparkling stars, trailing faint stardust from its wingtips
• comet_eel — Хвост Кометы: ethereal celestial comet eel with sleek crystalline ice-blue and silver body, glowing core, and a long luminous tail fin dissolving into a bright shimmering comet trail
• nebula_jelly — Галактическая Медуза: mesmerizing cosmic jellyfish with a translucent glass-like dome enclosing swirling violet, magenta, and cyan nebula clouds and glowing stars, with long luminous trailing tentacles
• supernova_carp — Карп Сверхновой: radiant cosmic carp with dark obsidian scales cracked open with blinding white-gold and magenta starlight, glowing eyes, and incandescent plasma-like fins
• void_angler — Удильщик Бездны: eldritch abyssal void anglerfish with pitch-black shadow-like armored body, glowing violet eyes, and a miniature swirling black hole with a bright accretion ring suspended on its forehead lure
• first_leviathan — Перворожденный Левиафан: primordial titan leviathan with massive faceted diamond-hard obsidian and platinum scales, ancient glowing cyan energy veins, and majestic crown-like horns
• abyss_walker — Ходок Бездны: terrifying deep-trench abyss walker fish with pale translucent skeletal armor, exposed glowing bioluminescent organs, long spider-like sensory fin rays, and needle teeth
• primordial_sludge — Первородный Слизевик: amorphous living primordial ooze fish formed from translucent emerald and amber cellular protoplasm, with glowing DNA-like light filaments swirling inside its semi-liquid fish silhouette
• megalodon_heir — Наследник Мегалодона: ancient apex heir of the megalodon with scarred abyssal silver-black hide, glowing pale blue bio-luminescent scars, massive muscular frame, and menacing jaws
• epoch_fish — Рыба Эпох: mystical time-woven epoch fish whose body transitions seamlessly from fossilized stone and amber at the tail to shimmering futuristic crystal and gold at the head
• poseidon_messenger — Вестник Посейдона: divine herald fish sculpted from flowing liquid gold and sculpted sea-foam turquoise scales, adorned with ornate trident-shaped fin tips and glowing aquamarine eyes
• ocean_heart — Сердце Океана: ethereal crystalline ocean-heart fish with semi-translucent sapphire body housing a glowing pulsing aquamarine core inside its chest, with delicate water-current fins
