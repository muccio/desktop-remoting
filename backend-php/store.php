<?php
require_once __DIR__ . '/config.php';

/**
 * Gestore dell'archiviazione su file CSV con locking concorrente (flock).
 * Schema del CSV:
 * 0: mac_id (string)
 * 1: sdp_offer (base64 string)
 * 2: sdp_answer (base64 string)
 * 3: host_candidates (json string)
 * 4: client_candidates (json string)
 * 5: updated_at (int unix timestamp)
 */
class CsvSessionStore {
    private $filePath;
    private $timeout;

    public function __construct($filePath = SESSIONS_CSV_FILE, $timeout = SESSION_TIMEOUT_SECONDS) {
        $this->filePath = $filePath;
        $this->timeout = $timeout;
        $this->ensureFileExists();
    }

    private function ensureFileExists() {
        if (!file_exists($this->filePath)) {
            $fp = @fopen($this->filePath, 'x');
            if ($fp !== false) {
                fputcsv($fp, ['mac_id', 'sdp_offer', 'sdp_answer', 'host_candidates', 'client_candidates', 'updated_at', 'status'], ",", '"', "\\");
                fclose($fp);
            }
        }
    }

    /**
     * Esegue una modifica atomica sul file CSV con blocco esclusivo LOCK_EX.
     */
    private function atomicUpdate(callable $modifier) {
        $fp = fopen($this->filePath, 'c+');
        if (!$fp) {
            throw new Exception("Impossibile aprire il file di sessioni: {$this->filePath}");
        }

        if (!flock($fp, LOCK_EX)) {
            fclose($fp);
            throw new Exception("Impossibile acquisire il lock esclusivo sul file CSV");
        }

        try {
            $sessions = [];
            $header = null;
            rewind($fp);

            while (($row = fgetcsv($fp, 0, ",", '"', "\\")) !== false) {
                if ($header === null) {
                    $header = $row;
                    continue;
                }
                if (count($row) >= 6) {
                    $macId = trim($row[0]);
                    $sessions[$macId] = [
                        'mac_id'            => $macId,
                        'sdp_offer'         => $row[1],
                        'sdp_answer'        => $row[2],
                        'host_candidates'   => $row[3],
                        'client_candidates' => $row[4],
                        'updated_at'        => (int)$row[5],
                        'status'            => isset($row[6]) && trim($row[6]) !== '' ? trim($row[6]) : (!empty($row[2]) ? 'answered' : 'waiting'),
                    ];
                }
            }

            // Pulizia sessioni scadute
            $now = time();
            foreach ($sessions as $id => $s) {
                if ($now - $s['updated_at'] > $this->timeout) {
                    unset($sessions[$id]);
                }
            }

            // Invoca la funzione di modifica
            $result = $modifier($sessions);

            // Riscrivi il file CSV aggiornato
            ftruncate($fp, 0);
            rewind($fp);

            if ($header === null) {
                $header = ['mac_id', 'sdp_offer', 'sdp_answer', 'host_candidates', 'client_candidates', 'updated_at', 'status'];
            }
            fputcsv($fp, $header, ",", '"', "\\");

            foreach ($sessions as $s) {
                fputcsv($fp, [
                    $s['mac_id'],
                    $s['sdp_offer'],
                    $s['sdp_answer'],
                    $s['host_candidates'],
                    $s['client_candidates'],
                    $s['updated_at'],
                    $s['status'] ?? 'waiting'
                ], ",", '"', "\\");
            }

            fflush($fp);
            flock($fp, LOCK_UN);
            fclose($fp);

            return $result;
        } catch (\Throwable $e) {
            flock($fp, LOCK_UN);
            fclose($fp);
            throw $e;
        }
    }

    /**
     * Esegue una lettura atomica con blocco condiviso LOCK_SH.
     */
    public function getSession($macId) {
        $macId = trim($macId);
        $fp = fopen($this->filePath, 'r');
        if (!$fp) {
            return null;
        }

        if (!flock($fp, LOCK_SH)) {
            fclose($fp);
            return null;
        }

        $session = null;
        $headerRead = false;
        $now = time();

        while (($row = fgetcsv($fp, 0, ",", '"', "\\")) !== false) {
            if (!$headerRead) {
                $headerRead = true;
                continue;
            }
            if (count($row) >= 6 && trim($row[0]) === $macId) {
                $updatedAt = (int)$row[5];
                if ($now - $updatedAt <= $this->timeout) {
                    $session = [
                        'mac_id'            => $row[0],
                        'sdp_offer'         => !empty($row[1]) ? base64_decode($row[1]) : null,
                        'sdp_answer'        => !empty($row[2]) ? base64_decode($row[2]) : null,
                        'host_candidates'   => !empty($row[3]) ? json_decode($row[3], true) : [],
                        'client_candidates' => !empty($row[4]) ? json_decode($row[4], true) : [],
                        'updated_at'        => $updatedAt,
                        'status'            => isset($row[6]) && trim($row[6]) !== '' ? trim($row[6]) : (!empty($row[2]) ? 'answered' : 'waiting')
                    ];
                }
                break;
            }
        }

        flock($fp, LOCK_UN);
        fclose($fp);

        return $session;
    }

    /**
     * Registra o sovrascrive l'offerta SDP dell'Host macOS.
     * Svuota sdp_answer per garantire la riconnessione pulita.
     */
    public function saveOffer($macId, $offerSdp) {
        $macId = trim($macId);
        $encodedSdp = base64_encode($offerSdp);

        return $this->atomicUpdate(function (&$sessions) use ($macId, $encodedSdp) {
            $sessions[$macId] = [
                'mac_id'            => $macId,
                'sdp_offer'         => $encodedSdp,
                'sdp_answer'        => '', // Reset risposta precedente per consentire nuova connessione
                'host_candidates'   => '[]',
                'client_candidates' => '[]',
                'updated_at'        => time(),
                'status'            => 'waiting'
            ];
            return true;
        });
    }

    /**
     * Registra la risposta SDP Answer inviata dal Client Mobile.
     */
    public function saveAnswer($macId, $answerSdp) {
        $macId = trim($macId);
        $encodedAnswer = base64_encode($answerSdp);

        return $this->atomicUpdate(function (&$sessions) use ($macId, $encodedAnswer) {
            if (!isset($sessions[$macId])) {
                return false;
            }
            $sessions[$macId]['sdp_answer'] = $encodedAnswer;
            $sessions[$macId]['status'] = 'answered';
            $sessions[$macId]['updated_at'] = time();
            return true;
        });
    }

    /**
     * Richiede il reset della sessione (invocato dal client per richiedere una nuova offerta).
     */
    public function requestReset($macId) {
        $macId = trim($macId);
        return $this->atomicUpdate(function (&$sessions) use ($macId) {
            if (!isset($sessions[$macId])) {
                return false;
            }
            $sessions[$macId]['sdp_answer'] = '';
            $sessions[$macId]['client_candidates'] = '[]';
            $sessions[$macId]['status'] = 'reset_requested';
            $sessions[$macId]['updated_at'] = time();
            return true;
        });
    }

    /**
     * Aggiunge un candidato ICE (inviato dall'host o dal client).
     */
    public function addCandidate($macId, $role, $candidateData) {
        $macId = trim($macId);
        return $this->atomicUpdate(function (&$sessions) use ($macId, $role, $candidateData) {
            if (!isset($sessions[$macId])) {
                return false;
            }

            $field = ($role === 'host') ? 'host_candidates' : 'client_candidates';
            $existing = json_decode($sessions[$macId][$field], true) ?: [];

            // Evita duplicati di candidati
            $candidateStr = is_string($candidateData) ? $candidateData : json_encode($candidateData);
            if (!in_array($candidateData, $existing)) {
                $existing[] = $candidateData;
            }

            $sessions[$macId][$field] = json_encode($existing);
            $sessions[$macId]['updated_at'] = time();
            return true;
        });
    }

    /**
     * Rimuove una sessione specifica
     */
    public function removeSession($macId) {
        $macId = trim($macId);
        return $this->atomicUpdate(function (&$sessions) use ($macId) {
            if (isset($sessions[$macId])) {
                unset($sessions[$macId]);
                return true;
            }
            return false;
        });
    }
}
