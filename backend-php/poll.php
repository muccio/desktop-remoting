<?php
/**
 * poll.php - Endpoint di polling per recuperare SDP e candidati ICE da CSV
 */
require_once __DIR__ . '/config.php';
require_once __DIR__ . '/store.php';

sendCorsAndJsonHeaders();

$macId = $_GET['mac_id'] ?? $_POST['mac_id'] ?? null;
$role  = $_GET['role'] ?? $_POST['role'] ?? 'client'; // chi sta effettuando il polling
$sinceIndex = isset($_GET['since_index']) ? (int)$_GET['since_index'] : 0;

if (empty($macId)) {
    http_response_code(400);
    echo json_encode(['success' => false, 'error' => 'Parametro mac_id obbligatorio.']);
    exit;
}

$store = new CsvSessionStore();
$session = $store->getSession($macId);

if (!$session) {
    echo json_encode([
        'success' => false,
        'found' => false,
        'message' => 'Nessuna sessione attiva per questo mac_id (potrebbe essere scaduta o non ancora creata).',
        'stun_servers' => STUN_SERVERS,
        'ice_servers' => ICE_SERVERS
    ]);
    exit;
}

$response = [
    'success' => true,
    'found' => true,
    'mac_id' => $macId,
    'updated_at' => $session['updated_at'],
    'status' => $session['status'] ?? 'waiting',
    'reset_requested' => (($session['status'] ?? '') === 'reset_requested'),
    'stun_servers' => STUN_SERVERS,
    'ice_servers' => ICE_SERVERS
];

if ($role === 'client') {
    // Il client mobile attende l'offerta dell'host e i suoi candidati ICE
    $response['has_offer'] = !empty($session['sdp_offer']);
    $response['sdp_offer'] = $session['sdp_offer'];
    
    $candidates = $session['host_candidates'];
    $response['candidates'] = array_slice($candidates, $sinceIndex);
    $response['total_candidates'] = count($candidates);
} else {
    // L'host macOS attende la risposta del client e i suoi candidati ICE
    $response['has_answer'] = !empty($session['sdp_answer']);
    $response['sdp_answer'] = $session['sdp_answer'];
    
    $candidates = $session['client_candidates'];
    $response['candidates'] = array_slice($candidates, $sinceIndex);
    $response['total_candidates'] = count($candidates);
}

echo json_encode($response);
