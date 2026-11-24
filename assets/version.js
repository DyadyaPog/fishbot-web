/* Показывает версию кабинета из config.js (window.FISHBOT_CONFIG.appVersion). */
(function () {
    var config = window.FISHBOT_CONFIG || {};
    var version = config.appVersion || '1.0.0';
    var stage = config.appStage || 'beta';
    var label = 'player cabinet · ' + stage + ' · v' + version;

    var nodes = document.querySelectorAll('[data-app-version]');
    for (var i = 0; i < nodes.length; i += 1) {
        nodes[i].textContent = label;
    }
})();
