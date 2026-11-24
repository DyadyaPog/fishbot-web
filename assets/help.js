/* Кнопка «↑ В начало страницы» на странице справки.
 * Прокручивает наверх оба возможных контейнера: окно и .content
 * (на широких экранах прокручивается именно .content).
 * Обычный переход по якорю срабатывает только один раз: повторный клик
 * по тому же #page-title ничего не делает, поэтому обрабатываем клик сами.
 */
(function () {
    /* На узких экранах дерево разделов свёрнуто: иначе оно занимает почти весь
       первый экран. На широком — раскрыто в левой колонке. */
    var toc = document.getElementById('toc-box');
    var narrow = window.matchMedia ? window.matchMedia('(max-width: 900px)') : null;

    function syncToc() {
        if (toc && narrow) toc.open = !narrow.matches;
    }

    syncToc();
    if (narrow && narrow.addEventListener) narrow.addEventListener('change', syncToc);

    document.addEventListener('click', function (event) {
        var link = event.target.closest('.help-top');
        if (!link) return;

        event.preventDefault();

        var content = document.querySelector('.content');

        /* Прокручиваем сразу, без плавности: плавная прокрутка в некоторых
           браузерах игнорируется для вложенного контейнера .content. */
        if (content) content.scrollTop = 0;
        window.scrollTo(0, 0);

        if (window.history && window.history.replaceState) {
            window.history.replaceState(null, '', window.location.pathname + window.location.search);
        }
    });
})();
