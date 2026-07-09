#!/usr/bin/env python3
"""
One-shot localization filler for FreeTube/Localizable.xcstrings.

For every key in TRANSLATIONS, ensures each of en/es/ru/fr/de has an entry with
state=translated. Preserves any existing translated entry (the user's human-curated
translations win). Only adds where missing or where state is "new"/missing.

Placeholders (%@, %lld, %lld%%) are kept identical across languages so iOS's
string-format engine matches arguments to positions.
"""
import json
import sys
from pathlib import Path

CATALOG = Path(__file__).parent / "FreeTube" / "FreeTube" / "Localizable.xcstrings"

# Per-language translations. The dict key is the English source string (also the
# catalog key). The value is a dict with "es", "ru", "fr", "de" entries.
# "en" is always set to the source string itself (state translated).
T = {
    "“%@” will be permanently removed from your device.": {
        "es": "«%@» se eliminará permanentemente de tu dispositivo.",
        "ru": "«%@» будет окончательно удалён с устройства.",
        "fr": "« %@ » sera définitivement supprimé de votre appareil.",
        "de": "„%@“ wird endgültig von Ihrem Gerät entfernt.",
    },
    "%@ · %lld%%": {
        "es": "%@ · %lld%%",
        "ru": "%@ · %lld%%",
        "fr": "%@ · %lld%%",
        "de": "%@ · %lld%%",
    },
    "%@ · streaming…": {
        "es": "%@ · transmitiendo…",
        "ru": "%@ · потоковая передача…",
        "fr": "%@ · diffusion…",
        "de": "%@ · streamt…",
    },
    "%@ likes": {
        "es": "%@ Me gusta",
        "ru": "%@ лайков",
        "fr": "%@ J’aime",
        "de": "%@ „Gefällt mir“",
    },
    "%@ subscribers": {
        "es": "%@ suscriptores",
        "ru": "%@ подписчиков",
        "fr": "%@ abonnés",
        "de": "%@ Abonnenten",
    },
    "%@, %@": {
        "es": "%@, %@",
        "ru": "%@, %@",
        "fr": "%@, %@",
        "de": "%@, %@",
    },
    "%lld": {
        "es": "%lld",
        "ru": "%lld",
        "fr": "%lld",
        "de": "%lld",
    },
    "%lld %@ • %@": {
        "es": "%lld %@ • %@",
        "ru": "%lld %@ • %@",
        "fr": "%lld %@ • %@",
        "de": "%lld %@ • %@",
    },
    "%lld items": {
        "es": "%lld elementos",
        "ru": "%lld элементов",
        "fr": "%lld éléments",
        "de": "%lld Einträge",
    },
    "%lld selected": {
        "es": "%lld seleccionados",
        "ru": "Выбрано: %lld",
        "fr": "%lld sélectionné(s)",
        "de": "%lld ausgewählt",
    },
    "%lld subscribers": {
        "es": "%lld suscriptores",
        "ru": "%lld подписчиков",
        "fr": "%lld abonnés",
        "de": "%lld Abonnenten",
    },
    "%lld videos": {
        "es": "%lld vídeos",
        "ru": "%lld видео",
        "fr": "%lld vidéos",
        "de": "%lld Videos",
    },
    "%lld views": {
        "es": "%lld visualizaciones",
        "ru": "%lld просмотров",
        "fr": "%lld vues",
        "de": "%lld Aufrufe",
    },
    "%lld%%": {"es": "%lld%%", "ru": "%lld%%", "fr": "%lld%%", "de": "%lld%%"},
    "1 (sequential)": {
        "es": "1 (secuencial)",
        "ru": "1 (последовательно)",
        "fr": "1 (séquentiel)",
        "de": "1 (sequenziell)",
    },
    "About": {"es": "Acerca de", "ru": "О приложении", "fr": "À propos", "de": "Über"},
    "Account": {"es": "Cuenta", "ru": "Аккаунт", "fr": "Compte", "de": "Konto"},
    "Add to favorites": {
        "es": "Añadir a favoritos",
        "ru": "Добавить в избранное",
        "fr": "Ajouter aux favoris",
        "de": "Zu Favoriten hinzufügen",
    },
    "Add to playlist": {
        "es": "Añadir a la lista",
        "ru": "Добавить в плейлист",
        "fr": "Ajouter à la playlist",
        "de": "Zur Playlist hinzufügen",
    },
    "All videos": {
        "es": "Todos los vídeos",
        "ru": "Все видео",
        "fr": "Toutes les vidéos",
        "de": "Alle Videos",
    },
    "Allow cellular data": {
        "es": "Permitir datos móviles",
        "ru": "Использовать сотовые данные",
        "fr": "Autoriser les données cellulaires",
        "de": "Mobile Daten erlauben",
    },
    "Already at latest (%@)": {
        "es": "Ya estás en la última versión (%@)",
        "ru": "Установлена последняя версия (%@)",
        "fr": "Déjà à jour (%@)",
        "de": "Bereits aktuell (%@)",
    },
    "Autoplay next video": {
        "es": "Reproducir el siguiente vídeo automáticamente",
        "ru": "Автоматически воспроизводить следующее видео",
        "fr": "Lecture automatique de la vidéo suivante",
        "de": "Nächstes Video automatisch abspielen",
    },
    "Cache limit": {
        "es": "Límite de caché",
        "ru": "Лимит кэша",
        "fr": "Limite du cache",
        "de": "Cache-Limit",
    },
    "Cancel": {"es": "Cancelar", "ru": "Отмена", "fr": "Annuler", "de": "Abbrechen"},
    "Cancel selection": {
        "es": "Cancelar selección",
        "ru": "Отменить выбор",
        "fr": "Annuler la sélection",
        "de": "Auswahl abbrechen",
    },
    "Channel": {"es": "Canal", "ru": "Канал", "fr": "Chaîne", "de": "Kanal"},
    "Channels": {"es": "Canales", "ru": "Каналы", "fr": "Chaînes", "de": "Kanäle"},
    "Channels and videos you've watched": {
        "es": "Canales y vídeos que has visto",
        "ru": "Каналы и видео, которые вы смотрели",
        "fr": "Chaînes et vidéos que vous avez regardées",
        "de": "Kanäle und Videos, die du dir angesehen hast",
    },
    "Channels you follow": {
        "es": "Canales que sigues",
        "ru": "Каналы, на которые вы подписаны",
        "fr": "Chaînes que vous suivez",
        "de": "Kanäle, denen du folgst",
    },
    "Channels you subscribe to on YouTube will show up here.": {
        "es": "Los canales a los que te suscribas en YouTube aparecerán aquí.",
        "ru": "Здесь появятся каналы, на которые вы подпишетесь в YouTube.",
        "fr": "Les chaînes auxquelles vous êtes abonné sur YouTube apparaîtront ici.",
        "de": "Kanäle, die du auf YouTube abonnierst, erscheinen hier.",
    },
    "Clear": {"es": "Borrar", "ru": "Очистить", "fr": "Effacer", "de": "Löschen"},
    "Clear all": {
        "es": "Borrar todo",
        "ru": "Очистить всё",
        "fr": "Tout effacer",
        "de": "Alles löschen",
    },
    "Close": {"es": "Cerrar", "ru": "Закрыть", "fr": "Fermer", "de": "Schließen"},
    "Close full screen player": {
        "es": "Cerrar reproductor a pantalla completa",
        "ru": "Закрыть полноэкранный плеер",
        "fr": "Fermer le lecteur plein écran",
        "de": "Vollbild-Player schließen",
    },
    "Comments": {
        "es": "Comentarios",
        "ru": "Комментарии",
        "fr": "Commentaires",
        "de": "Kommentare",
    },
    "Completed": {
        "es": "Completado",
        "ru": "Завершено",
        "fr": "Terminé",
        "de": "Abgeschlossen",
    },
    "Convert": {"es": "Convertir", "ru": "Конвертировать", "fr": "Convertir", "de": "Konvertieren"},
    "Convert audio to MP3": {
        "es": "Convertir audio a MP3",
        "ru": "Конвертировать аудио в MP3",
        "fr": "Convertir l’audio en MP3",
        "de": "Audio in MP3 konvertieren",
    },
    "Convert video to H.264": {
        "es": "Convertir vídeo a H.264",
        "ru": "Конвертировать видео в H.264",
        "fr": "Convertir la vidéo en H.264",
        "de": "Video in H.264 konvertieren",
    },
    "Cookies are stored only in the Keychain.": {
        "es": "Las cookies se almacenan solo en el Llavero.",
        "ru": "Cookies хранятся только в Keychain.",
        "fr": "Les cookies sont stockés uniquement dans le Trousseau.",
        "de": "Cookies werden ausschließlich im Schlüsselbund gespeichert.",
    },
    "Copy URL": {
        "es": "Copiar URL",
        "ru": "Скопировать URL",
        "fr": "Copier l’URL",
        "de": "URL kopieren",
    },
    "Copy URL at current time": {
        "es": "Copiar URL en el momento actual",
        "ru": "Скопировать URL с текущим временем",
        "fr": "Copier l’URL à l’instant actuel",
        "de": "URL bei aktueller Zeit kopieren",
    },
    "Couldn't load video": {
        "es": "No se pudo cargar el vídeo",
        "ru": "Не удалось загрузить видео",
        "fr": "Impossible de charger la vidéo",
        "de": "Video konnte nicht geladen werden",
    },
    "Couldn't read this link": {
        "es": "No se pudo leer este enlace",
        "ru": "Не удалось прочитать ссылку",
        "fr": "Impossible de lire ce lien",
        "de": "Link konnte nicht gelesen werden",
    },
    "Create": {"es": "Crear", "ru": "Создать", "fr": "Créer", "de": "Erstellen"},
    "Create new playlist": {
        "es": "Crear nueva lista",
        "ru": "Создать новый плейлист",
        "fr": "Créer une nouvelle playlist",
        "de": "Neue Playlist erstellen",
    },
    "Creator": {"es": "Creador", "ru": "Автор", "fr": "Créateur", "de": "Ersteller"},
    "Currently using %@. When the cache exceeds the limit, the oldest downloads are removed to fit.\n\nParallel fragments controls how many HLS/DASH chunks yt-dlp fetches at once inside a single download — higher values are faster on good connections; values above 8 can trigger YouTube rate-limiting.": {
        "es": "Uso actual: %@. Cuando la caché supera el límite, se eliminan las descargas más antiguas para que quepan.\n\nFragmentos paralelos controla cuántos trozos HLS/DASH descarga yt-dlp a la vez dentro de una sola descarga — valores más altos son más rápidos con buena conexión; valores por encima de 8 pueden activar el límite de tasa de YouTube.",
        "ru": "Сейчас используется: %@. Когда кэш превышает лимит, самые старые загрузки удаляются.\n\nПараллельные фрагменты определяют, сколько чанков HLS/DASH yt-dlp скачивает одновременно в рамках одной загрузки — более высокие значения быстрее при хорошем соединении; значения выше 8 могут вызвать ограничение со стороны YouTube.",
        "fr": "Utilisation actuelle : %@. Lorsque le cache dépasse la limite, les téléchargements les plus anciens sont supprimés.\n\nFragments parallèles contrôle le nombre de morceaux HLS/DASH que yt-dlp récupère à la fois dans un même téléchargement — des valeurs élevées sont plus rapides sur de bonnes connexions ; au-delà de 8, YouTube peut limiter le débit.",
        "de": "Aktuelle Nutzung: %@. Wenn der Cache das Limit überschreitet, werden die ältesten Downloads entfernt.\n\n„Parallele Fragmente“ legt fest, wie viele HLS/DASH-Stücke yt-dlp in einem Download gleichzeitig abruft — höhere Werte sind bei guter Verbindung schneller; Werte über 8 können YouTube-Drosselung auslösen.",
    },
    "Currently using %@. When the cache exceeds the limit, the oldest downloads are removed to fit.\n\nPrefetch starts a background download of the next queued video as soon as the current one plays, so tapping Next is instant. Turn off to save bandwidth.\n\nParallel fragments controls how many HLS/DASH chunks yt-dlp fetches at once inside a single download — higher values are faster on good connections; values above 8 can trigger YouTube rate-limiting.": {
        "es": "Uso actual: %@. Cuando la caché supera el límite, se eliminan las descargas más antiguas para que quepan.\n\nLa precarga inicia una descarga en segundo plano del siguiente vídeo en cola en cuanto empieza a reproducirse el actual, para que tocar Siguiente sea instantáneo. Desactívala para ahorrar datos.\n\nFragmentos paralelos controla cuántos trozos HLS/DASH descarga yt-dlp a la vez dentro de una sola descarga — valores más altos son más rápidos con buena conexión; valores por encima de 8 pueden activar el límite de tasa de YouTube.",
        "ru": "Сейчас используется: %@. Когда кэш превышает лимит, самые старые загрузки удаляются.\n\nПредзагрузка начинает фоновую загрузку следующего видео в очереди сразу после начала воспроизведения текущего, чтобы нажатие «Далее» срабатывало мгновенно. Отключите для экономии трафика.\n\nПараллельные фрагменты определяют, сколько чанков HLS/DASH yt-dlp скачивает одновременно в рамках одной загрузки — более высокие значения быстрее при хорошем соединении; значения выше 8 могут вызвать ограничение со стороны YouTube.",
        "fr": "Utilisation actuelle : %@. Lorsque le cache dépasse la limite, les téléchargements les plus anciens sont supprimés.\n\nLe préchargement lance en arrière-plan le téléchargement de la prochaine vidéo de la file dès que la vidéo en cours démarre, pour que toucher Suivant soit instantané. Désactivez-le pour économiser de la bande passante.\n\nFragments parallèles contrôle le nombre de morceaux HLS/DASH que yt-dlp récupère à la fois dans un même téléchargement — des valeurs élevées sont plus rapides sur de bonnes connexions ; au-delà de 8, YouTube peut limiter le débit.",
        "de": "Aktuelle Nutzung: %@. Wenn der Cache das Limit überschreitet, werden die ältesten Downloads entfernt.\n\n„Vorab laden“ startet im Hintergrund den Download des nächsten Videos in der Warteschlange, sobald das aktuelle abgespielt wird — so erfolgt „Weiter“ sofort. Zum Sparen von Datenvolumen ausschalten.\n\n„Parallele Fragmente“ legt fest, wie viele HLS/DASH-Stücke yt-dlp in einem Download gleichzeitig abruft — höhere Werte sind bei guter Verbindung schneller; Werte über 8 können YouTube-Drosselung auslösen.",
    },
    "Date": {"es": "Fecha", "ru": "Дата", "fr": "Date", "de": "Datum"},
    "Date downloaded": {
        "es": "Fecha de descarga",
        "ru": "Дата загрузки",
        "fr": "Date de téléchargement",
        "de": "Downloaddatum",
    },
    "Delete": {"es": "Eliminar", "ru": "Удалить", "fr": "Supprimer", "de": "Löschen"},
    "Delete %lld %@?": {
        "es": "¿Eliminar %lld %@?",
        "ru": "Удалить %lld %@?",
        "fr": "Supprimer %lld %@ ?",
        "de": "%lld %@ löschen?",
    },
    "Delete from downloaded": {
        "es": "Eliminar de descargas",
        "ru": "Удалить из загрузок",
        "fr": "Supprimer des téléchargements",
        "de": "Aus Downloads entfernen",
    },
    "Delete this video?": {
        "es": "¿Eliminar este vídeo?",
        "ru": "Удалить это видео?",
        "fr": "Supprimer cette vidéo ?",
        "de": "Dieses Video löschen?",
    },
    "Description": {"es": "Descripción", "ru": "Описание", "fr": "Description", "de": "Beschreibung"},
    "Deselect all": {
        "es": "Deseleccionar todo",
        "ru": "Снять выделение",
        "fr": "Tout désélectionner",
        "de": "Auswahl aufheben",
    },
    "Done": {"es": "Listo", "ru": "Готово", "fr": "OK", "de": "Fertig"},
    "Download": {"es": "Descargar", "ru": "Загрузить", "fr": "Télécharger", "de": "Herunterladen"},
    "Downloading %@ %lld%%": {
        "es": "Descargando %@ %lld%%",
        "ru": "Загрузка %@ %lld%%",
        "fr": "Téléchargement de %@ %lld%%",
        "de": "Lade %@ %lld%%",
    },
    "Downloading %lld%%": {
        "es": "Descargando %lld%%",
        "ru": "Загрузка %lld%%",
        "fr": "Téléchargement %lld%%",
        "de": "Lade %lld%%",
    },
    "Downloading · see Downloads tab": {
        "es": "Descargando · ver pestaña Descargas",
        "ru": "Загрузка · см. вкладку «Загрузки»",
        "fr": "Téléchargement · voir l’onglet Téléchargements",
        "de": "Lade … · siehe Downloads-Tab",
    },
    "Downloads": {"es": "Descargas", "ru": "Загрузки", "fr": "Téléchargements", "de": "Downloads"},
    "Duration": {"es": "Duración", "ru": "Длительность", "fr": "Durée", "de": "Dauer"},
    "Error": {"es": "Error", "ru": "Ошибка", "fr": "Erreur", "de": "Fehler"},
    "Failed": {"es": "Falló", "ru": "Не удалось", "fr": "Échec", "de": "Fehlgeschlagen"},
    "Fetch": {"es": "Obtener", "ru": "Получить", "fr": "Récupérer", "de": "Abrufen"},
    "File size": {
        "es": "Tamaño del archivo",
        "ru": "Размер файла",
        "fr": "Taille du fichier",
        "de": "Dateigröße",
    },
    "Find videos, channels, and playlists.": {
        "es": "Encuentra vídeos, canales y listas.",
        "ru": "Найдите видео, каналы и плейлисты.",
        "fr": "Trouvez des vidéos, des chaînes et des playlists.",
        "de": "Finde Videos, Kanäle und Playlists.",
    },
    "Find…": {"es": "Buscar…", "ru": "Найти…", "fr": "Rechercher…", "de": "Suchen…"},
    "Finishing sign-in…": {
        "es": "Completando inicio de sesión…",
        "ru": "Завершение входа…",
        "fr": "Finalisation de la connexion…",
        "de": "Anmeldung wird abgeschlossen…",
    },
    "FreeTube is a personal/sideload-only YouTube client. It uses YouTubeKit (cookie-based, no Google API key) plus yt-dlp for downloads. YouTube can change its internal API at any time — please be patient when things break.": {
        "es": "FreeTube es un cliente de YouTube solo para uso personal/sideload. Utiliza YouTubeKit (basado en cookies, sin clave de API de Google) y yt-dlp para las descargas. YouTube puede cambiar su API interna en cualquier momento — ten paciencia cuando algo falle.",
        "ru": "FreeTube — клиент YouTube только для личного использования/sideload. Использует YouTubeKit (на основе cookies, без ключа Google API) и yt-dlp для загрузок. YouTube может изменить свой внутренний API в любой момент — наберитесь терпения, если что-то перестанет работать.",
        "fr": "FreeTube est un client YouTube réservé à l’usage personnel / au sideload. Il utilise YouTubeKit (basé sur les cookies, sans clé d’API Google) et yt-dlp pour les téléchargements. YouTube peut modifier son API interne à tout moment — soyez patient lorsque quelque chose se casse.",
        "de": "FreeTube ist ein YouTube-Client ausschließlich für die persönliche Nutzung bzw. das Sideloading. Er verwendet YouTubeKit (cookie-basiert, ohne Google-API-Schlüssel) sowie yt-dlp für Downloads. YouTube kann seine interne API jederzeit ändern — bitte habe Geduld, wenn etwas nicht funktioniert.",
    },
    "FreeTube uses a `WKWebView` to capture cookies. They are stored only in the Keychain.": {
        "es": "FreeTube usa un `WKWebView` para capturar cookies. Se almacenan solo en el Llavero.",
        "ru": "FreeTube использует `WKWebView` для получения cookies. Они хранятся только в Keychain.",
        "fr": "FreeTube utilise un `WKWebView` pour capturer les cookies. Ils sont stockés uniquement dans le Trousseau.",
        "de": "FreeTube verwendet einen `WKWebView`, um Cookies zu erfassen. Sie werden ausschließlich im Schlüsselbund gespeichert.",
    },
    "FreeTube — see App/RootView.swift": {
        "es": "FreeTube — ver App/RootView.swift",
        "ru": "FreeTube — см. App/RootView.swift",
        "fr": "FreeTube — voir App/RootView.swift",
        "de": "FreeTube — siehe App/RootView.swift",
    },
    "Format": {"es": "Formato", "ru": "Формат", "fr": "Format", "de": "Format"},
    "H.264 is universally playable on Apple platforms. MP3 is for audio you'll share with apps that don't accept AAC / Opus. Conversion happens on-device via FFmpeg and may take a few seconds.": {
        "es": "H.264 se reproduce universalmente en plataformas Apple. MP3 es para audio que compartirás con apps que no aceptan AAC / Opus. La conversión se hace en el dispositivo con FFmpeg y puede tardar unos segundos.",
        "ru": "H.264 воспроизводится на всех платформах Apple. MP3 нужен для аудио, которым вы поделитесь с приложениями, не принимающими AAC / Opus. Конвертация выполняется на устройстве через FFmpeg и может занять несколько секунд.",
        "fr": "Le H.264 est lisible universellement sur les plateformes Apple. Le MP3 est utile pour l’audio que vous partagez avec des apps qui n’acceptent pas AAC / Opus. La conversion s’effectue sur l’appareil via FFmpeg et peut prendre quelques secondes.",
        "de": "H.264 ist auf Apple-Plattformen universell abspielbar. MP3 ist für Audio, das du mit Apps teilst, die AAC / Opus nicht akzeptieren. Die Konvertierung erfolgt lokal über FFmpeg und kann einige Sekunden dauern.",
    },
    "History": {"es": "Historial", "ru": "История", "fr": "Historique", "de": "Verlauf"},
    "Home": {"es": "Inicio", "ru": "Главная", "fr": "Accueil", "de": "Start"},
    "If videos stop loading, tap this to wipe stored cookies and the visitor token. The next playback attempt will run anonymously.": {
        "es": "Si los vídeos dejan de cargarse, toca esto para borrar las cookies almacenadas y el token de visitante. El siguiente intento de reproducción se ejecutará de forma anónima.",
        "ru": "Если видео перестают загружаться, нажмите, чтобы стереть сохранённые cookies и visitor-токен. Следующая попытка воспроизведения пройдёт анонимно.",
        "fr": "Si les vidéos cessent de se charger, appuyez ici pour supprimer les cookies stockés et le jeton de visiteur. La prochaine tentative de lecture s’exécutera anonymement.",
        "de": "Wenn Videos nicht mehr geladen werden, hier tippen, um die gespeicherten Cookies und das Besucher-Token zu löschen. Der nächste Wiedergabeversuch erfolgt anonym.",
    },
    "LIVE": {"es": "EN DIRECTO", "ru": "LIVE", "fr": "EN DIRECT", "de": "LIVE"},
    "Last updated": {
        "es": "Última actualización",
        "ru": "Последнее обновление",
        "fr": "Dernière mise à jour",
        "de": "Zuletzt aktualisiert",
    },
    "Latest": {"es": "Más recientes", "ru": "Новые", "fr": "Récentes", "de": "Neueste"},
    "Latest from your subscriptions": {
        "es": "Lo último de tus suscripciones",
        "ru": "Новое из подписок",
        "fr": "Récent de vos abonnements",
        "de": "Neuestes aus deinen Abonnements",
    },
    "Latest videos": {
        "es": "Vídeos más recientes",
        "ru": "Новые видео",
        "fr": "Vidéos les plus récentes",
        "de": "Neueste Videos",
    },
    "Latest videos from your subscriptions.": {
        "es": "Los vídeos más recientes de tus suscripciones.",
        "ru": "Свежие видео из ваших подписок.",
        "fr": "Les vidéos les plus récentes de vos abonnements.",
        "de": "Die neuesten Videos aus deinen Abonnements.",
    },
    "Less": {"es": "Menos", "ru": "Меньше", "fr": "Moins", "de": "Weniger"},
    "Less details": {
        "es": "Menos detalles",
        "ru": "Скрыть подробности",
        "fr": "Moins de détails",
        "de": "Weniger Details",
    },
    "Library": {"es": "Biblioteca", "ru": "Библиотека", "fr": "Bibliothèque", "de": "Mediathek"},
    "Liked videos": {
        "es": "Vídeos que me gustan",
        "ru": "Понравившиеся видео",
        "fr": "Vidéos aimées",
        "de": "Gelikte Videos",
    },
    "Link": {"es": "Enlace", "ru": "Ссылка", "fr": "Lien", "de": "Link"},
    "Live": {"es": "En directo", "ru": "Прямой эфир", "fr": "Direct", "de": "Live"},
    "Loading details…": {
        "es": "Cargando detalles…",
        "ru": "Загрузка подробностей…",
        "fr": "Chargement des détails…",
        "de": "Details werden geladen…",
    },
    "Loading…": {
        "es": "Cargando…",
        "ru": "Загрузка…",
        "fr": "Chargement…",
        "de": "Wird geladen…",
    },
    "More": {"es": "Más", "ru": "Ещё", "fr": "Plus", "de": "Mehr"},
    "More details": {
        "es": "Más detalles",
        "ru": "Подробнее",
        "fr": "Plus de détails",
        "de": "Mehr Details",
    },
    "Most viewed first": {
        "es": "Más vistos primero",
        "ru": "Сначала самые просматриваемые",
        "fr": "Les plus regardées d’abord",
        "de": "Meistgesehene zuerst",
    },
    "Movies": {"es": "Películas", "ru": "Фильмы", "fr": "Films", "de": "Filme"},
    "Navigate": {"es": "Navegar", "ru": "Навигация", "fr": "Naviguer", "de": "Navigieren"},
    "Network error": {
        "es": "Error de red",
        "ru": "Ошибка сети",
        "fr": "Erreur réseau",
        "de": "Netzwerkfehler",
    },
    "New playlist": {
        "es": "Nueva lista",
        "ru": "Новый плейлист",
        "fr": "Nouvelle playlist",
        "de": "Neue Playlist",
    },
    "New playlist…": {
        "es": "Nueva lista…",
        "ru": "Новый плейлист…",
        "fr": "Nouvelle playlist…",
        "de": "Neue Playlist…",
    },
    "Newest first": {
        "es": "Más nuevos primero",
        "ru": "Сначала новые",
        "fr": "Les plus récents d’abord",
        "de": "Neueste zuerst",
    },
    "Next": {"es": "Siguiente", "ru": "Далее", "fr": "Suivant", "de": "Weiter"},
    "No channel detected": {
        "es": "No se detectó ningún canal",
        "ru": "Канал не найден",
        "fr": "Aucune chaîne détectée",
        "de": "Kein Kanal erkannt",
    },
    "No downloads": {
        "es": "Sin descargas",
        "ru": "Нет загрузок",
        "fr": "Aucun téléchargement",
        "de": "Keine Downloads",
    },
    "No playlists": {
        "es": "Sin listas",
        "ru": "Нет плейлистов",
        "fr": "Aucune playlist",
        "de": "Keine Playlists",
    },
    "No subscriptions": {
        "es": "Sin suscripciones",
        "ru": "Нет подписок",
        "fr": "Aucun abonnement",
        "de": "Keine Abonnements",
    },
    "None (audio only)": {
        "es": "Ninguno (solo audio)",
        "ru": "Нет (только аудио)",
        "fr": "Aucun (audio uniquement)",
        "de": "Keine (nur Audio)",
    },
    "None (silent video)": {
        "es": "Ninguno (vídeo silencioso)",
        "ru": "Нет (видео без звука)",
        "fr": "Aucun (vidéo muette)",
        "de": "Keine (stummes Video)",
    },
    "None (use video's embedded audio)": {
        "es": "Ninguno (usar el audio integrado del vídeo)",
        "ru": "Нет (использовать встроенное аудио видео)",
        "fr": "Aucun (utiliser l’audio intégré à la vidéo)",
        "de": "Keine (eingebettetes Video-Audio verwenden)",
    },
    "Not signed in": {
        "es": "No has iniciado sesión",
        "ru": "Вы не вошли",
        "fr": "Non connecté",
        "de": "Nicht angemeldet",
    },
    "Nothing here": {
        "es": "No hay nada aquí",
        "ru": "Здесь пусто",
        "fr": "Rien ici",
        "de": "Nichts hier",
    },
    "Nothing here yet": {
        "es": "Aún no hay nada",
        "ru": "Здесь пока пусто",
        "fr": "Rien pour l’instant",
        "de": "Noch nichts hier",
    },
    "Nothing new": {
        "es": "Nada nuevo",
        "ru": "Ничего нового",
        "fr": "Rien de nouveau",
        "de": "Nichts Neues",
    },
    "OK": {"es": "OK", "ru": "ОК", "fr": "OK", "de": "OK"},
    "Open in browser": {
        "es": "Abrir en el navegador",
        "ru": "Открыть в браузере",
        "fr": "Ouvrir dans le navigateur",
        "de": "Im Browser öffnen",
    },
    "Open in…": {
        "es": "Abrir en…",
        "ru": "Открыть в…",
        "fr": "Ouvrir dans…",
        "de": "Öffnen in…",
    },
    "Parallel fragments": {
        "es": "Fragmentos paralelos",
        "ru": "Параллельные фрагменты",
        "fr": "Fragments parallèles",
        "de": "Parallele Fragmente",
    },
    "Paste a link…": {
        "es": "Pega un enlace…",
        "ru": "Вставьте ссылку…",
        "fr": "Collez un lien…",
        "de": "Link einfügen…",
    },
    "Pause": {"es": "Pausa", "ru": "Пауза", "fr": "Pause", "de": "Pause"},
    "Paused": {"es": "En pausa", "ru": "Приостановлено", "fr": "En pause", "de": "Pausiert"},
    "Play": {"es": "Reproducir", "ru": "Воспроизвести", "fr": "Lire", "de": "Wiedergabe"},
    "Play all": {
        "es": "Reproducir todo",
        "ru": "Воспроизвести все",
        "fr": "Tout lire",
        "de": "Alle abspielen",
    },
    "Playback": {"es": "Reproducción", "ru": "Воспроизведение", "fr": "Lecture", "de": "Wiedergabe"},
    "Playbacks": {
        "es": "Reproducciones",
        "ru": "Воспроизведения",
        "fr": "Lectures",
        "de": "Wiedergaben",
    },
    "Playlist title": {
        "es": "Título de la lista",
        "ru": "Название плейлиста",
        "fr": "Titre de la playlist",
        "de": "Playlist-Titel",
    },
    "Playlists": {"es": "Listas", "ru": "Плейлисты", "fr": "Playlists", "de": "Playlists"},
    "Playlists you create on YouTube will appear here.": {
        "es": "Las listas que crees en YouTube aparecerán aquí.",
        "ru": "Плейлисты, которые вы создадите в YouTube, появятся здесь.",
        "fr": "Les playlists que vous créez sur YouTube apparaîtront ici.",
        "de": "Playlists, die du auf YouTube erstellst, erscheinen hier.",
    },
    "Popular": {"es": "Populares", "ru": "Популярные", "fr": "Populaires", "de": "Beliebt"},
    "Popular videos": {
        "es": "Vídeos populares",
        "ru": "Популярные видео",
        "fr": "Vidéos populaires",
        "de": "Beliebte Videos",
    },
    "Preferred quality": {
        "es": "Calidad preferida",
        "ru": "Предпочитаемое качество",
        "fr": "Qualité préférée",
        "de": "Bevorzugte Qualität",
    },
    "Prefetch next video": {
        "es": "Precargar el siguiente vídeo",
        "ru": "Предзагрузка следующего видео",
        "fr": "Précharger la vidéo suivante",
        "de": "Nächstes Video vorab laden",
    },
    "Preparing…": {
        "es": "Preparando…",
        "ru": "Подготовка…",
        "fr": "Préparation…",
        "de": "Wird vorbereitet…",
    },
    "Preview": {"es": "Vista previa", "ru": "Предпросмотр", "fr": "Aperçu", "de": "Vorschau"},
    "Previous": {"es": "Anterior", "ru": "Назад", "fr": "Précédent", "de": "Zurück"},
    "Private": {"es": "Privado", "ru": "Личный", "fr": "Privé", "de": "Privat"},
    "Private playlist": {
        "es": "Lista privada",
        "ru": "Личный плейлист",
        "fr": "Playlist privée",
        "de": "Private Playlist",
    },
    "Processing video…": {
        "es": "Procesando vídeo…",
        "ru": "Обработка видео…",
        "fr": "Traitement de la vidéo…",
        "de": "Video wird verarbeitet…",
    },
    "Processing…": {
        "es": "Procesando…",
        "ru": "Обработка…",
        "fr": "Traitement…",
        "de": "Wird verarbeitet…",
    },
    "Pull to refresh or sign in to see your home feed.": {
        "es": "Tira para actualizar o inicia sesión para ver tu feed de inicio.",
        "ru": "Потяните, чтобы обновить, или войдите, чтобы увидеть ленту.",
        "fr": "Tirez pour rafraîchir ou connectez-vous pour voir votre fil d’accueil.",
        "de": "Zum Aktualisieren ziehen oder anmelden, um deinen Startfeed zu sehen.",
    },
    "Pull to retry.": {
        "es": "Tira para reintentar.",
        "ru": "Потяните, чтобы повторить.",
        "fr": "Tirez pour réessayer.",
        "de": "Zum Wiederholen ziehen.",
    },
    "Queued": {"es": "En cola", "ru": "В очереди", "fr": "En file d’attente", "de": "In Warteschlange"},
    "Rate limited by YouTube": {
        "es": "Tasa limitada por YouTube",
        "ru": "Превышен лимит запросов YouTube",
        "fr": "Limité par YouTube",
        "de": "Von YouTube ratenbegrenzt",
    },
    "Reading link…": {
        "es": "Leyendo enlace…",
        "ru": "Чтение ссылки…",
        "fr": "Lecture du lien…",
        "de": "Link wird gelesen…",
    },
    "Ready · %@": {
        "es": "Listo · %@",
        "ru": "Готово · %@",
        "fr": "Prêt · %@",
        "de": "Bereit · %@",
    },
    "Recent": {"es": "Reciente", "ru": "Недавнее", "fr": "Récent", "de": "Zuletzt"},
    "Recent searches": {
        "es": "Búsquedas recientes",
        "ru": "Недавние запросы",
        "fr": "Recherches récentes",
        "de": "Letzte Suchen",
    },
    "Recently watched": {
        "es": "Vistos recientemente",
        "ru": "Недавно просмотренные",
        "fr": "Vues récemment",
        "de": "Kürzlich angesehen",
    },
    "Remove": {"es": "Eliminar", "ru": "Удалить", "fr": "Retirer", "de": "Entfernen"},
    "Remove downloaded file": {
        "es": "Eliminar archivo descargado",
        "ru": "Удалить загруженный файл",
        "fr": "Supprimer le fichier téléchargé",
        "de": "Heruntergeladene Datei entfernen",
    },
    "Remove from favorites": {
        "es": "Quitar de favoritos",
        "ru": "Убрать из избранного",
        "fr": "Retirer des favoris",
        "de": "Aus Favoriten entfernen",
    },
    "Reply": {"es": "Responder", "ru": "Ответить", "fr": "Répondre", "de": "Antworten"},
    "Reset": {"es": "Restablecer", "ru": "Сбросить", "fr": "Réinitialiser", "de": "Zurücksetzen"},
    "Reset session": {
        "es": "Restablecer sesión",
        "ru": "Сбросить сессию",
        "fr": "Réinitialiser la session",
        "de": "Sitzung zurücksetzen",
    },
    "Reset session?": {
        "es": "¿Restablecer sesión?",
        "ru": "Сбросить сессию?",
        "fr": "Réinitialiser la session ?",
        "de": "Sitzung zurücksetzen?",
    },
    "Restricted search mode": {
        "es": "Modo de búsqueda restringido",
        "ru": "Режим ограниченного поиска",
        "fr": "Mode de recherche restreinte",
        "de": "Eingeschränkter Suchmodus",
    },
    "Retry": {"es": "Reintentar", "ru": "Повторить", "fr": "Réessayer", "de": "Wiederholen"},
    "Reveal in Finder": {
        "es": "Mostrar en Finder",
        "ru": "Показать в Finder",
        "fr": "Révéler dans le Finder",
        "de": "Im Finder anzeigen",
    },
    "Save": {"es": "Guardar", "ru": "Сохранить", "fr": "Enregistrer", "de": "Speichern"},
    "Saved on device": {
        "es": "Guardado en el dispositivo",
        "ru": "Сохранено на устройстве",
        "fr": "Enregistré sur l’appareil",
        "de": "Auf dem Gerät gespeichert",
    },
    "Saved to %@": {
        "es": "Guardado en %@",
        "ru": "Сохранено в %@",
        "fr": "Enregistré dans %@",
        "de": "Gespeichert in %@",
    },
    "Search": {"es": "Buscar", "ru": "Поиск", "fr": "Rechercher", "de": "Suchen"},
    "Search YouTube": {
        "es": "Buscar en YouTube",
        "ru": "Поиск на YouTube",
        "fr": "Rechercher sur YouTube",
        "de": "YouTube durchsuchen",
    },
    "Search history": {
        "es": "Historial de búsqueda",
        "ru": "История поиска",
        "fr": "Historique de recherche",
        "de": "Suchverlauf",
    },
    "Select": {"es": "Seleccionar", "ru": "Выбрать", "fr": "Sélectionner", "de": "Auswählen"},
    "Select all": {
        "es": "Seleccionar todo",
        "ru": "Выбрать всё",
        "fr": "Tout sélectionner",
        "de": "Alles auswählen",
    },
    "Session expired": {
        "es": "Sesión expirada",
        "ru": "Сессия истекла",
        "fr": "Session expirée",
        "de": "Sitzung abgelaufen",
    },
    "Settings": {
        "es": "Configuración",
        "ru": "Настройки",
        "fr": "Réglages",
        "de": "Einstellungen",
    },
    "Settings…": {
        "es": "Configuración…",
        "ru": "Настройки…",
        "fr": "Réglages…",
        "de": "Einstellungen…",
    },
    "Share": {"es": "Compartir", "ru": "Поделиться", "fr": "Partager", "de": "Teilen"},
    "Shorts": {"es": "Shorts", "ru": "Shorts", "fr": "Shorts", "de": "Shorts"},
    "Show in Finder": {
        "es": "Mostrar en Finder",
        "ru": "Показать в Finder",
        "fr": "Afficher dans le Finder",
        "de": "Im Finder anzeigen",
    },
    "Show less": {
        "es": "Mostrar menos",
        "ru": "Свернуть",
        "fr": "Afficher moins",
        "de": "Weniger anzeigen",
    },
    "Shuffle": {"es": "Aleatorio", "ru": "Перемешать", "fr": "Aléatoire", "de": "Zufällig"},
    "Sign in": {"es": "Iniciar sesión", "ru": "Войти", "fr": "Se connecter", "de": "Anmelden"},
    "Sign in to YouTube": {
        "es": "Inicia sesión en YouTube",
        "ru": "Войти в YouTube",
        "fr": "Se connecter à YouTube",
        "de": "Bei YouTube anmelden",
    },
    "Sign in to access your watch history, playlists, liked videos, and Watch Later.": {
        "es": "Inicia sesión para acceder a tu historial, listas, vídeos que te gustan y Ver más tarde.",
        "ru": "Войдите, чтобы получить доступ к истории просмотров, плейлистам, понравившимся видео и «Смотреть позже».",
        "fr": "Connectez-vous pour accéder à votre historique, vos playlists, vos vidéos aimées et « À regarder plus tard ».",
        "de": "Melde dich an, um auf deinen Verlauf, deine Playlists, gelikten Videos und „Später ansehen“ zuzugreifen.",
    },
    "Sign out": {"es": "Cerrar sesión", "ru": "Выйти", "fr": "Se déconnecter", "de": "Abmelden"},
    "Sign-in failed": {
        "es": "Error al iniciar sesión",
        "ru": "Не удалось войти",
        "fr": "Échec de la connexion",
        "de": "Anmeldung fehlgeschlagen",
    },
    "Skip Backward 15s": {
        "es": "Retroceder 15 s",
        "ru": "Назад на 15 с",
        "fr": "Reculer de 15 s",
        "de": "15 Sek. zurück",
    },
    "Skip Forward 15s": {
        "es": "Avanzar 15 s",
        "ru": "Вперёд на 15 с",
        "fr": "Avancer de 15 s",
        "de": "15 Sek. vor",
    },
    "Sort by": {"es": "Ordenar por", "ru": "Сортировать по", "fr": "Trier par", "de": "Sortieren nach"},
    "Source codec: %@": {
        "es": "Códec original: %@",
        "ru": "Исходный кодек: %@",
        "fr": "Codec source : %@",
        "de": "Quellcodec: %@",
    },
    "Stream extraction failed": {
        "es": "Falló la extracción del stream",
        "ru": "Не удалось извлечь поток",
        "fr": "Échec de l’extraction du flux",
        "de": "Stream-Extraktion fehlgeschlagen",
    },
    "Streaming…": {
        "es": "Transmitiendo…",
        "ru": "Потоковая передача…",
        "fr": "Diffusion en cours…",
        "de": "Streamt…",
    },
    "Subscribe": {"es": "Suscribirse", "ru": "Подписаться", "fr": "S’abonner", "de": "Abonnieren"},
    "Subscribe to channels to see their latest videos here.": {
        "es": "Suscríbete a canales para ver aquí sus vídeos más recientes.",
        "ru": "Подпишитесь на каналы, чтобы видеть здесь их новые видео.",
        "fr": "Abonnez-vous à des chaînes pour voir leurs dernières vidéos ici.",
        "de": "Abonniere Kanäle, um hier deren neueste Videos zu sehen.",
    },
    "Subscribed": {"es": "Suscrito", "ru": "Подписан", "fr": "Abonné", "de": "Abonniert"},
    "Subscriptions": {
        "es": "Suscripciones",
        "ru": "Подписки",
        "fr": "Abonnements",
        "de": "Abonnements",
    },
    "Tap a video to play — it will be saved here automatically.": {
        "es": "Toca un vídeo para reproducirlo — se guardará aquí automáticamente.",
        "ru": "Коснитесь видео, чтобы воспроизвести — оно сохранится здесь автоматически.",
        "fr": "Touchez une vidéo pour la lire — elle sera enregistrée ici automatiquement.",
        "de": "Tippe auf ein Video, um es abzuspielen — es wird hier automatisch gespeichert.",
    },
    "This can take a few seconds the first time yt-dlp loads.": {
        "es": "Esto puede tardar unos segundos la primera vez que se cargue yt-dlp.",
        "ru": "Это может занять несколько секунд при первой загрузке yt-dlp.",
        "fr": "Cela peut prendre quelques secondes lors du premier chargement de yt-dlp.",
        "de": "Beim ersten Laden von yt-dlp kann dies einige Sekunden dauern.",
    },
    "This channel has no public playlists.": {
        "es": "Este canal no tiene listas públicas.",
        "ru": "На этом канале нет открытых плейлистов.",
        "fr": "Cette chaîne n’a aucune playlist publique.",
        "de": "Dieser Kanal hat keine öffentlichen Playlists.",
    },
    "This permanently removes the selected file%@ from your device.": {
        "es": "Esto elimina permanentemente el archivo seleccionado%@ de tu dispositivo.",
        "ru": "Это окончательно удалит выбранный файл%@ с устройства.",
        "fr": "Cela supprime définitivement le fichier sélectionné%@ de votre appareil.",
        "de": "Damit wird die ausgewählte Datei%@ endgültig von deinem Gerät entfernt.",
    },
    "This signs you out and clears cached cookies.": {
        "es": "Esto cierra tu sesión y borra las cookies en caché.",
        "ru": "Это выполнит выход и удалит сохранённые cookies.",
        "fr": "Cela vous déconnecte et efface les cookies en cache.",
        "de": "Damit wirst du abgemeldet und gespeicherte Cookies werden gelöscht.",
    },
    "Title": {"es": "Título", "ru": "Название", "fr": "Titre", "de": "Titel"},
    "Transfer queue": {
        "es": "Cola de transferencia",
        "ru": "Очередь передачи",
        "fr": "File de transfert",
        "de": "Übertragungswarteschlange",
    },
    "Translate": {"es": "Traducir", "ru": "Перевести", "fr": "Traduire", "de": "Übersetzen"},
    "Troubleshooting": {
        "es": "Solución de problemas",
        "ru": "Устранение неполадок",
        "fr": "Dépannage",
        "de": "Fehlerbehebung",
    },
    "Try again": {
        "es": "Reintentar",
        "ru": "Попробовать ещё раз",
        "fr": "Réessayer",
        "de": "Erneut versuchen",
    },
    "Unlimited": {"es": "Sin límite", "ru": "Без лимита", "fr": "Illimité", "de": "Unbegrenzt"},
    "Up next": {"es": "A continuación", "ru": "Далее", "fr": "À suivre", "de": "Als Nächstes"},
    "Update now": {
        "es": "Actualizar ahora",
        "ru": "Обновить сейчас",
        "fr": "Mettre à jour",
        "de": "Jetzt aktualisieren",
    },
    "Updated to %@": {
        "es": "Actualizado a %@",
        "ru": "Обновлено до %@",
        "fr": "Mis à jour vers %@",
        "de": "Aktualisiert auf %@",
    },
    "Version": {"es": "Versión", "ru": "Версия", "fr": "Version", "de": "Version"},
    "Video unavailable": {
        "es": "Vídeo no disponible",
        "ru": "Видео недоступно",
        "fr": "Vidéo indisponible",
        "de": "Video nicht verfügbar",
    },
    "Videos": {"es": "Vídeos", "ru": "Видео", "fr": "Vidéos", "de": "Videos"},
    "Videos download to your device before playback. Lower qualities save space and download faster.": {
        "es": "Los vídeos se descargan en tu dispositivo antes de reproducirse. Las calidades más bajas ahorran espacio y se descargan más rápido.",
        "ru": "Видео загружаются на устройство до начала воспроизведения. Более низкое качество экономит место и загружается быстрее.",
        "fr": "Les vidéos se téléchargent sur votre appareil avant la lecture. Les qualités inférieures économisent de l’espace et se téléchargent plus rapidement.",
        "de": "Videos werden vor der Wiedergabe auf dein Gerät geladen. Niedrigere Qualitäten sparen Speicherplatz und laden schneller.",
    },
    "Views": {"es": "Visualizaciones", "ru": "Просмотры", "fr": "Vues", "de": "Aufrufe"},
    "Watch history": {
        "es": "Historial de reproducción",
        "ru": "История просмотров",
        "fr": "Historique des lectures",
        "de": "Wiedergabeverlauf",
    },
    "Watch later": {
        "es": "Ver más tarde",
        "ru": "Смотреть позже",
        "fr": "À regarder plus tard",
        "de": "Später ansehen",
    },
    "Wi-Fi only downloads": {
        "es": "Descargas solo por Wi-Fi",
        "ru": "Загружать только по Wi-Fi",
        "fr": "Téléchargements en Wi-Fi uniquement",
        "de": "Downloads nur über WLAN",
    },
    "Will save": {
        "es": "Se guardará",
        "ru": "Будет сохранено",
        "fr": "Sera enregistré",
        "de": "Wird gespeichert",
    },
    "Wipes stored cookies and the visitor token. The next playback attempt will run anonymously. Use this if playback or sign-in is stuck.": {
        "es": "Borra las cookies almacenadas y el token de visitante. El siguiente intento de reproducción se ejecutará de forma anónima. Usa esto si la reproducción o el inicio de sesión se bloquean.",
        "ru": "Удаляет сохранённые cookies и visitor-токен. Следующая попытка воспроизведения пройдёт анонимно. Используйте это, если воспроизведение или вход зависли.",
        "fr": "Supprime les cookies stockés et le jeton de visiteur. La prochaine tentative de lecture s’exécutera anonymement. Utilisez ceci si la lecture ou la connexion est bloquée.",
        "de": "Löscht gespeicherte Cookies und das Besucher-Token. Der nächste Wiedergabeversuch erfolgt anonym. Verwende dies, wenn Wiedergabe oder Anmeldung hängen bleiben.",
    },
    "Works with YouTube, Vimeo, X/Twitter, TikTok, SoundCloud, and ~2,000 other sites supported by yt-dlp.": {
        "es": "Funciona con YouTube, Vimeo, X/Twitter, TikTok, SoundCloud y ~2.000 sitios más compatibles con yt-dlp.",
        "ru": "Работает с YouTube, Vimeo, X/Twitter, TikTok, SoundCloud и ~2 000 других сайтов, поддерживаемых yt-dlp.",
        "fr": "Fonctionne avec YouTube, Vimeo, X/Twitter, TikTok, SoundCloud et environ 2 000 autres sites pris en charge par yt-dlp.",
        "de": "Funktioniert mit YouTube, Vimeo, X/Twitter, TikTok, SoundCloud und rund 2.000 weiteren von yt-dlp unterstützten Seiten.",
    },
    "You don't have any playlists yet. Tap \"Create new playlist\" above to make one.": {
        "es": "Aún no tienes listas. Toca «Crear nueva lista» arriba para crear una.",
        "ru": "У вас пока нет плейлистов. Нажмите «Создать новый плейлист» выше, чтобы создать.",
        "fr": "Vous n’avez encore aucune playlist. Touchez « Créer une nouvelle playlist » ci-dessus pour en créer une.",
        "de": "Du hast noch keine Playlists. Tippe oben auf „Neue Playlist erstellen“, um eine zu erstellen.",
    },
    "Your YouTube channel": {
        "es": "Tu canal de YouTube",
        "ru": "Ваш канал YouTube",
        "fr": "Votre chaîne YouTube",
        "de": "Dein YouTube-Kanal",
    },
    "Your YouTube channel ID wasn't returned in the library response. Try refreshing the Library screen.": {
        "es": "El ID de tu canal de YouTube no se devolvió en la respuesta de la biblioteca. Intenta actualizar la pantalla Biblioteca.",
        "ru": "ID вашего канала YouTube не был возвращён в ответе библиотеки. Попробуйте обновить экран «Библиотека».",
        "fr": "L’identifiant de votre chaîne YouTube n’a pas été renvoyé dans la réponse de la bibliothèque. Essayez de rafraîchir l’écran Bibliothèque.",
        "de": "Deine YouTube-Kanal-ID wurde in der Mediathek-Antwort nicht zurückgegeben. Versuche, den Mediathek-Bildschirm zu aktualisieren.",
    },
    "Your playlists": {
        "es": "Tus listas",
        "ru": "Ваши плейлисты",
        "fr": "Vos playlists",
        "de": "Deine Playlists",
    },
    "Your videos": {
        "es": "Tus vídeos",
        "ru": "Ваши видео",
        "fr": "Vos vidéos",
        "de": "Deine Videos",
    },
    "v%@ — %@": {
        "es": "v%@ — %@",
        "ru": "v%@ — %@",
        "fr": "v%@ — %@",
        "de": "v%@ — %@",
    },
    "v0.1 — %@": {
        "es": "v0.1 — %@",
        "ru": "v0.1 — %@",
        "fr": "v0.1 — %@",
        "de": "v0.1 — %@",
    },
    "yt-dlp": {"es": "yt-dlp", "ru": "yt-dlp", "fr": "yt-dlp", "de": "yt-dlp"},
    "yt-dlp is the engine that resolves YouTube stream URLs. FreeTube auto-refreshes it every 7 days from the official GitHub release. Tap Update now if a video stops playing — newer versions often fix breakage caused by YouTube's API changes.": {
        "es": "yt-dlp es el motor que resuelve las URLs de stream de YouTube. FreeTube lo actualiza automáticamente cada 7 días desde la release oficial de GitHub. Toca «Actualizar ahora» si un vídeo deja de reproducirse — las versiones nuevas suelen corregir fallos provocados por cambios en la API de YouTube.",
        "ru": "yt-dlp — это движок, который получает URL потоков YouTube. FreeTube автоматически обновляет его раз в 7 дней из официального релиза на GitHub. Нажмите «Обновить сейчас», если видео перестало воспроизводиться — новые версии часто исправляют проблемы, вызванные изменениями API YouTube.",
        "fr": "yt-dlp est le moteur qui résout les URLs de flux YouTube. FreeTube le met à jour automatiquement tous les 7 jours depuis la release officielle sur GitHub. Touchez « Mettre à jour » si une vidéo ne se lit plus — les nouvelles versions corrigent souvent les pannes dues aux changements de l’API YouTube.",
        "de": "yt-dlp ist die Engine, die YouTube-Stream-URLs auflöst. FreeTube aktualisiert sie automatisch alle 7 Tage aus dem offiziellen GitHub-Release. Tippe auf „Jetzt aktualisieren“, wenn ein Video nicht mehr abspielt — neue Versionen beheben oft Brüche durch YouTube-API-Änderungen.",
    },
    "• %@": {"es": "• %@", "ru": "• %@", "fr": "• %@", "de": "• %@"},
    "≈ %@": {"es": "≈ %@", "ru": "≈ %@", "fr": "≈ %@", "de": "≈ %@"},
}


def main() -> int:
    with CATALOG.open() as f:
        cat = json.load(f)

    strings = cat["strings"]
    languages = ["en", "es", "ru", "fr", "de"]
    added = {lang: 0 for lang in languages}
    fixed_new = 0

    # 1. Every catalog key gets en/es/ru/fr/de translations.
    for key, entry in strings.items():
        locs = entry.setdefault("localizations", {})
        # English: the catalog key IS the English text. Force "translated" state so
        # the catalog editor doesn't flag it.
        en_unit = locs.setdefault("en", {"stringUnit": {"state": "translated", "value": key}})
        unit = en_unit.setdefault("stringUnit", {"value": key})
        if unit.get("state") != "translated":
            unit["state"] = "translated"
            unit["value"] = key
            fixed_new += 1
        else:
            unit.setdefault("value", key)

        # Other languages: pull from TRANSLATIONS if present.
        translations = T.get(key, {})
        for lang in ["es", "ru", "fr", "de"]:
            existing = locs.get(lang, {}).get("stringUnit", {})
            existing_state = existing.get("state")
            # Skip if already translated by a human — don't clobber.
            if existing_state == "translated":
                continue
            value = translations.get(lang)
            if value is None:
                continue
            locs[lang] = {"stringUnit": {"state": "translated", "value": value}}
            added[lang] += 1

    # 2. Also add brand-new keys present in TRANSLATIONS but missing from the
    # catalog (shouldn't happen since Xcode populates from source, but defensive).
    for key, translations in T.items():
        if key in strings:
            continue
        new_entry = {"localizations": {"en": {"stringUnit": {"state": "translated", "value": key}}}}
        for lang in ["es", "ru", "fr", "de"]:
            value = translations.get(lang)
            if value is not None:
                new_entry["localizations"][lang] = {"stringUnit": {"state": "translated", "value": value}}
        strings[key] = new_entry
        print(f"Inserted new key: {key!r}")

    with CATALOG.open("w") as f:
        json.dump(cat, f, ensure_ascii=False, indent=2)
        f.write("\n")

    print(f"Fixed {fixed_new} 'new'/missing English entries.")
    for lang, n in added.items():
        if lang == "en":
            continue
        print(f"Added {n} {lang} translations.")
    print(f"Total keys: {len(strings)}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
