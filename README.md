# Desktop Remoting System (macOS Host + Mobile Client + PHP CSV Signaling)

Questo repository contiene l'intero ecosistema per il controllo remoto a bassa latenza di macOS da dispositivi mobili (iOS / Android) tramite **WebRTC**, con cattura hardware ad alte prestazioni (**ScreenCaptureKit** + **VideoToolbox**) e un backend di signaling minimale in **PHP basato su file CSV** (senza database).

---

## Struttura del Progetto

```
.
├── backend-php/           # Server di signaling WebRTC leggero basato su CSV (senza MySQL)
│   ├── .htaccess          # Protezione del file CSV da accessi web diretti
│   ├── config.php         # Configurazione (timeout sessioni, percorsi)
│   ├── store.php          # Classe di gestione CSV con lock concorrente flock()
│   ├── register.php       # Registrazione SDP Offer, Answer e candidati ICE
│   ├── poll.php           # Polling metadati di sessione
│   └── sessions.csv       # File CSV contenente le sessioni attive (generato auto)
│
├── macos-host/            # Applicazione Host nativa macOS (Swift)
│   ├── Package.swift      # Swift Package Manager manifest
│   ├── build_app.sh       # Script per compilazione e creazione bundle MacHost.app
│   ├── Host.entitlements  # Entitlement per cattura schermo e rete
│   ├── Info.plist         # Permessi e configurazioni macOS
│   └── Sources/
│       ├── Main.swift                 # Entry point applicazione / Menu Bar / UI
│       ├── ScreenCaptureManager.swift # Cattura video/audio con ScreenCaptureKit
│       ├── VideoToolboxEncoder.swift  # Pipeline compressione hardware H.264
│       ├── WebRTCManager.swift        # Connessione WebRTC P2P e DataChannel
│       ├── InputInjector.swift        # Iniezione eventi tastiera e mouse con CGEvent
│       └── SignalingClient.swift      # Client HTTP per il backend PHP
│
├── android-client/        # Applicazione Client Nativa Android (Kotlin + WebRTC) [COMPILATA]
│   ├── build_apk.sh       # Script compilazione istantanea APK
│   ├── app/build/outputs/apk/debug/app-debug.apk # APK pronto all'uso
│   └── app/src/main/
│       ├── AndroidManifest.xml
│       └── java/com/desktopremoting/client/
│           ├── MainActivity.kt         # Schermata di connessione
│           ├── RemoteDesktopActivity.kt# Rendering SurfaceViewRenderer + Touch/Trackpad
│           ├── WebRTCManager.kt        # Engine WebRTC nativo (libjingle)
│           ├── SignalingClient.kt      # Client HTTP OkHttp per il signaling CSV
│           └── InputEvent.kt           # Modelli di serializzazione input
│
└── mobile-client/         # Applicazione Client Flutter per iOS e Android
    ├── pubspec.yaml       # Dipendenze (flutter_webrtc, http, ecc.)
    └── lib/
        ├── main.dart
        ├── models/
        │   └── remote_event.dart      # Modelli eventi mouse/tastiera
        ├── services/
        │   ├── signaling_service.dart # Polling e invio Answer/ICE via HTTP
        │   └── webrtc_client.dart     # Connessione P2P e gestione stream/data channel
        └── screens/
            ├── connect_screen.dart    # Schermata inserimento Mac ID
            └── remote_view_screen.dart# Schermata visualizzazione video + touch injection
```
