<?php
/**
 * register.php - Endpoint per registrare Offerte, Risposte SDP e Candidati ICE
 */
require_once __DIR__ . '/config.php';
require_once __DIR__ . '/store.php';

sendCorsAndJsonHeaders();

if ($_SERVER['REQUEST_METHOD'] !== 'POST') {
    http_response_code(405);
    echo json_encode(['success' => false, 'error' => 'Metodo non consentito. Usa POST.']);
    exit;
}

$payload = getRequestPayload();

$action   = $payload['action'] ?? null;
$macId    = $payload['mac_id'] ?? null;
$sdp      = $payload['sdp'] ?? null;
$role     = $payload['role'] ?? 'host';
$candidate= $payload['candidate'] ?? null;

if (empty($macId)) {
    http_response_code(400);
    echo json_encode(['success' => false, 'error' => 'Parametro mac_id obbligatorio.']);
    exit;
}

$store = new CsvSessionStore();

try {
    switch ($action) {
        case 'offer':
            if (empty($sdp)) {
                http_response_code(400);
                echo json_encode(['success' => false, 'error' => 'Parametro sdp mancante per offerta host.']);
                exit;
            }
            $store->saveOffer($macId, $sdp);
            echo json_encode([
                'success' => true,
                'message' => 'Offerta SDP registrata con successo',
                'mac_id' => $macId,
                'stun_servers' => STUN_SERVERS,
                'ice_servers' => ICE_SERVERS
            ]);
            break;

        case 'answer':
            if (empty($sdp)) {
                http_response_code(400);
                echo json_encode(['success' => false, 'error' => 'Parametro sdp mancante per risposta client.']);
                exit;
            }
            $ok = $store->saveAnswer($macId, $sdp);
            if (!$ok) {
                http_response_code(404);
                echo json_encode(['success' => false, 'error' => 'Sessione non trovata per questo mac_id.']);
                exit;
            }
            echo json_encode([
                'success' => true,
                'message' => 'Risposta SDP Answer salvata con successo',
                'mac_id' => $macId
            ]);
            break;

        case 'candidate':
            if (empty($candidate)) {
                http_response_code(400);
                echo json_encode(['success' => false, 'error' => 'Parametro candidate mancante.']);
                exit;
            }
            $store->addCandidate($macId, $role, $candidate);
            echo json_encode([
                'success' => true,
                'message' => 'Candidato ICE registrato',
                'mac_id' => $macId
            ]);
            break;

        case 'close':
            $store->removeSession($macId);
            echo json_encode([
                'success' => true,
                'message' => 'Sessione chiusa e rimossa dal CSV',
                'mac_id' => $macId
            ]);
            break;

        case 'reset':
        case 'reset_request':
            $store->requestReset($macId);
            echo json_encode([
                'success' => true,
                'message' => 'Richiesta di reset registrata nel CSV',
                'mac_id' => $macId
            ]);
            break;

        default:
            http_response_code(400);
            echo json_encode(['success' => false, 'error' => "Azione sconosciuta: '$action'. Usa 'offer', 'answer', 'candidate' o 'close'."]);
            break;
    }
} catch (Exception $e) {
    http_response_code(500);
    echo json_encode(['success' => false, 'error' => $e->getMessage()]);
}
