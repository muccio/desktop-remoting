<?php
/**
 * Configurazione del Backend di Signaling PHP
 */

// Timeout in secondi oltre il quale una sessione inattiva viene considerata scaduta
define('SESSION_TIMEOUT_SECONDS', 300); // 5 minuti

// Percorso del file CSV contenente lo stato delle sessioni
define('SESSIONS_CSV_FILE', __DIR__ . '/sessions.csv');

/**
 * Server STUN e TURN per NAT Traversal (caricati dinamicamente da file separato ice_servers.json)
 */
$iceServersJsonPath = file_exists(__DIR__ . '/ice_servers.json')
    ? __DIR__ . '/ice_servers.json'
    : (file_exists(dirname(__DIR__) . '/ice_servers.json') ? dirname(__DIR__) . '/ice_servers.json' : null);

if ($iceServersJsonPath && ($loadedServers = json_decode(file_get_contents($iceServersJsonPath), true))) {
    define('ICE_SERVERS', $loadedServers);
} else {
    // Configurazione di fallback nel caso il file ice_servers.json non sia presente
    define('ICE_SERVERS', [
        [
            'urls' => [
                'stun:stun.l.google.com:19302',
                'stun:stun1.l.google.com:19302',
                'stun:stun2.l.google.com:19302',
                'stun:stun.cloudflare.com:3478'
            ]
        ],
        [
            'urls' => [
                'turn:openrelay.metered.ca:80',
                'turn:openrelay.metered.ca:443',
                'turn:openrelay.metered.ca:443?transport=tcp'
            ],
            'username'   => 'openrelayproject',
            'credential' => 'openrelayproject'
        ]
    ]);
}

// Estrai automaticamente la lista STUN da ICE_SERVERS per retrocompatibilità
$extractedStun = [];
foreach (ICE_SERVERS as $server) {
    $urls = is_array($server['urls']) ? $server['urls'] : [$server['urls']];
    foreach ($urls as $u) {
        if (str_starts_with($u, 'stun:')) {
            $extractedStun[] = $u;
        }
    }
}
define('STUN_SERVERS', !empty($extractedStun) ? $extractedStun : ['stun:stun.l.google.com:19302']);

/**
 * Gestione Header CORS e risposta JSON
 */
function sendCorsAndJsonHeaders() {
    header("Access-Control-Allow-Origin: *");
    header("Access-Control-Allow-Methods: GET, POST, OPTIONS");
    header("Access-Control-Allow-Headers: Content-Type, Authorization, X-Requested-With");
    header("Content-Type: application/json; charset=UTF-8");

    if (isset($_SERVER['REQUEST_METHOD']) && $_SERVER['REQUEST_METHOD'] === 'OPTIONS') {
        http_response_code(200);
        exit;
    }
}

/**
 * Legge l'input JSON o parametri POST
 */
function getRequestPayload() {
    $raw = file_get_contents('php://input');
    if (!empty($raw)) {
        $json = json_decode($raw, true);
        if (json_last_error() === JSON_ERROR_NONE && is_array($json)) {
            return $json;
        }
    }
    return $_POST;
}
