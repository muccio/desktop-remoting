import Foundation
import AppKit
import IOKit.pwr_mgt

/// Modulo dedicato per impedire la sospensione di macOS durante lo streaming:
/// 1. IOKit Assertions (`PreventUserIdleSystemSleep` e `PreventUserIdleDisplaySleep`)
/// 2. Processo di supporto `caffeinate -d -i -s -w <PID>` collegato al ciclo di vita dell'app
/// 3. Prevenzione Lid-Close Sleep (chiusura coperchio MacBook in clamshell senza monitor) via `pmset -a disablesleep 1`
/// 4. Failsafe e ripristino sicuro allo stop, su chiusura app e su segnali POSIX (SIGINT, SIGTERM)
public final class SleepPreventer: ObservableObject {
    public static let shared = SleepPreventer()

    private let lock = NSLock()

    // Assertion IDs IOKit
    private var systemSleepAssertionID: IOPMAssertionID = 0
    private var displaySleepAssertionID: IOPMAssertionID = 0

    // Processo figlio caffeinate
    private var caffeinateProcess: Process?

    // Flag per tracciare se pmset disablesleep 1 è stato abilitato da noi
    private var didEnablePmsetDisableSleep: Bool = false

    // Gestori segnali POSIX
    private var sigintSource: DispatchSourceSignal?
    private var sigtermSource: DispatchSourceSignal?

    // Stati pubblicati per la UI SwiftUI
    @Published public private(set) var isIdleSleepPrevented: Bool = false
    @Published public private(set) var isDisplaySleepPrevented: Bool = false
    @Published public private(set) var isLidCloseSleepPrevented: Bool = false
    @Published public private(set) var statusDescription: String = "Sospensione normale di sistema"

    private init() {
        setupSignalHandlers()
        setupTerminationObserver()
        refreshLidCloseStatus()
    }

    deinit {
        restoreAllSynchronous()
    }

    // MARK: - Controllo Principale

    /// Avvia la prevenzione della sospensione (Idle + Display + opzionale Lid-Close)
    @discardableResult
    public func startPrevention(preventLidClose: Bool = true) -> Bool {
        lock.lock()
        defer { lock.unlock() }

        print("[SleepPreventer] Avvio prevenzione sleep (preventLidClose: \(preventLidClose))...")

        // 1. Attiva asserzioni IOKit (System Sleep + Display Sleep)
        activateIOKitAssertions()

        // 2. Avvia caffeinate legato al PID del processo
        startCaffeinateProcess()

        // 3. Prevenzione chiusura coperchio MacBook (se richiesta)
        if preventLidClose {
            enableLidCloseInternal()
        }

        updatePublishedState()
        return true
    }

    /// Arresta la prevenzione e ripristina lo stato originale di macOS
    public func stopPrevention() {
        lock.lock()
        defer { lock.unlock() }

        print("[SleepPreventer] Arresto prevenzione sleep e ripristino stato energetico...")

        // 1. Rilascia asserzioni IOKit
        releaseIOKitAssertions()

        // 2. Termina processo caffeinate
        stopCaffeinateProcess()

        // 3. Ripristina pmset disablesleep se era stato abilitato da noi
        if didEnablePmsetDisableSleep {
            _ = SleepPreventer.runPmsetDisableSleep(enable: false)
            didEnablePmsetDisableSleep = false
        }

        updatePublishedState()
    }

    // MARK: - Gestione Lid-Close Sleep (pmset)

    /// Abilita specificamente la prevenzione della sospensione a coperchio chiuso
    @discardableResult
    public func enableLidCloseSleepPrevention() -> Bool {
        lock.lock()
        defer { lock.unlock() }
        let success = enableLidCloseInternal()
        updatePublishedState()
        return success
    }

    /// Disabilita la prevenzione della sospensione a coperchio chiuso
    @discardableResult
    public func disableLidCloseSleepPrevention() -> Bool {
        lock.lock()
        defer { lock.unlock() }

        if didEnablePmsetDisableSleep || SleepPreventer.isPmsetDisableSleepActive() {
            let res = SleepPreventer.runPmsetDisableSleep(enable: false)
            if res.success {
                didEnablePmsetDisableSleep = false
                print("[SleepPreventer] Lid-Close Sleep ripristinato (disablesleep 0).")
            } else {
                print("[SleepPreventer] Errore ripristino disablesleep: \(res.error ?? "sconosciuto")")
            }
        }
        updatePublishedState()
        return !didEnablePmsetDisableSleep
    }

    @discardableResult
    private func enableLidCloseInternal() -> Bool {
        if SleepPreventer.isPmsetDisableSleepActive() {
            print("[SleepPreventer] pmset disablesleep 1 è già attivo a livello di sistema.")
            didEnablePmsetDisableSleep = false
            return true
        }

        print("[SleepPreventer] Richiesta abilitazione pmset -a disablesleep 1 (richiede autorizzazione admin)...")
        let res = SleepPreventer.runPmsetDisableSleep(enable: true)
        if res.success {
            didEnablePmsetDisableSleep = true
            print("[SleepPreventer] Lid-Close Awake attivato con successo via pmset!")
            return true
        } else {
            print("[SleepPreventer] Impossibile attivare pmset disablesleep: \(res.error ?? "autorizzazione negata")")
            didEnablePmsetDisableSleep = false
            return false
        }
    }

    /// Rileva se `disablesleep 1` è attualmente attivo su macOS
    public static func isPmsetDisableSleepActive() -> Bool {
        let pipe = Pipe()
        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: "/usr/bin/pmset")
        proc.arguments = ["-g"]
        proc.standardOutput = pipe
        proc.standardError = FileHandle.nullDevice

        do {
            try proc.run()
            proc.waitUntilExit()
            let data = pipe.fileHandleForReading.readDataToEndOfFile()
            if let output = String(data: data, encoding: .utf8) {
                return output.range(of: "disablesleep\\s+1", options: .regularExpression) != nil
            }
        } catch {
            print("[SleepPreventer] Errore lettura pmset: \(error.localizedDescription)")
        }
        return false
    }

    /// Esegue `pmset -a disablesleep <1|0>` con privilegi di amministratore se non già root
    public static func runPmsetDisableSleep(enable: Bool) -> (success: Bool, error: String?) {
        let val = enable ? 1 : 0

        // Se l'applicazione è già eseguita come root (es. sudo o helper da terminale)
        if geteuid() == 0 {
            let proc = Process()
            proc.executableURL = URL(fileURLWithPath: "/usr/bin/pmset")
            proc.arguments = ["-a", "disablesleep", "\(val)"]
            do {
                try proc.run()
                proc.waitUntilExit()
                return (proc.terminationStatus == 0, nil)
            } catch {
                return (false, error.localizedDescription)
            }
        }

        // Altrimenti usa NSAppleScript con autorizzazione utente standard di macOS
        let scriptText = "do shell script \"/usr/bin/pmset -a disablesleep \(val)\" with administrator privileges"
        guard let script = NSAppleScript(source: scriptText) else {
            return (false, "Impossibile creare NSAppleScript")
        }

        var errorInfo: NSDictionary?
        script.executeAndReturnError(&errorInfo)
        if let err = errorInfo {
            let errorMsg = err[NSAppleScript.errorMessage] as? String ?? "\(err)"
            return (false, errorMsg)
        }
        return (true, nil)
    }

    public func refreshLidCloseStatus() {
        let active = SleepPreventer.isPmsetDisableSleepActive()
        DispatchQueue.main.async {
            self.isLidCloseSleepPrevented = active
        }
    }

    // MARK: - IOKit Assertions

    private func activateIOKitAssertions() {
        let activityReason = "Desktop Remoting Host Attivo (Streaming ScreenCaptureKit)" as CFString

        // 1. Prevent User Idle System Sleep
        if systemSleepAssertionID == 0 {
            let ret = IOPMAssertionCreateWithName(
                kIOPMAssertionTypePreventUserIdleSystemSleep as CFString,
                IOPMAssertionLevel(kIOPMAssertionLevelOn),
                activityReason,
                &systemSleepAssertionID
            )
            if ret == kIOReturnSuccess {
                print("[SleepPreventer] Asserzione SystemSleep creata (ID: \(systemSleepAssertionID)).")
            } else {
                print("[SleepPreventer] Errore creazione asserzione SystemSleep: \(ret)")
            }
        }

        // 2. Prevent User Idle Display Sleep (fondamentale affinché ScreenCaptureKit non si arresti)
        if displaySleepAssertionID == 0 {
            let ret = IOPMAssertionCreateWithName(
                kIOPMAssertionTypePreventUserIdleDisplaySleep as CFString,
                IOPMAssertionLevel(kIOPMAssertionLevelOn),
                activityReason,
                &displaySleepAssertionID
            )
            if ret == kIOReturnSuccess {
                print("[SleepPreventer] Asserzione DisplaySleep creata (ID: \(displaySleepAssertionID)).")
            } else {
                print("[SleepPreventer] Errore creazione asserzione DisplaySleep: \(ret)")
            }
        }
    }

    private func releaseIOKitAssertions() {
        if systemSleepAssertionID != 0 {
            IOPMAssertionRelease(systemSleepAssertionID)
            print("[SleepPreventer] Asserzione SystemSleep rilasciata (ID: \(systemSleepAssertionID)).")
            systemSleepAssertionID = 0
        }
        if displaySleepAssertionID != 0 {
            IOPMAssertionRelease(displaySleepAssertionID)
            print("[SleepPreventer] Asserzione DisplaySleep rilasciata (ID: \(displaySleepAssertionID)).")
            displaySleepAssertionID = 0
        }
    }

    // MARK: - Processo Caffeinate di Supporto

    private func startCaffeinateProcess() {
        stopCaffeinateProcess()
        let pid = ProcessInfo.processInfo.processIdentifier
        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: "/usr/bin/caffeinate")
        proc.arguments = ["-d", "-i", "-s", "-w", "\(pid)"]

        do {
            try proc.run()
            self.caffeinateProcess = proc
            print("[SleepPreventer] Processo caffeinate avviato (PID: \(proc.processIdentifier), collegato a MacHost PID: \(pid)).")
        } catch {
            print("[SleepPreventer] Errore avvio caffeinate: \(error.localizedDescription)")
        }
    }

    private func stopCaffeinateProcess() {
        if let proc = caffeinateProcess, proc.isRunning {
            proc.terminate()
            print("[SleepPreventer] Processo caffeinate terminato.")
        }
        caffeinateProcess = nil
    }

    // MARK: - Ripristino Sincrono Failsafe (Segnali POSIX e Chiusura App)

    /// Metodo richiamabile sincronicamente su SIGINT, SIGTERM, crash o chiusura dell'app
    public func restoreAllSynchronous() {
        lock.lock()
        defer { lock.unlock() }

        // Rilascia le asserzioni IOKit
        if systemSleepAssertionID != 0 {
            IOPMAssertionRelease(systemSleepAssertionID)
            systemSleepAssertionID = 0
        }
        if displaySleepAssertionID != 0 {
            IOPMAssertionRelease(displaySleepAssertionID)
            displaySleepAssertionID = 0
        }

        // Termina caffeinate
        if let proc = caffeinateProcess, proc.isRunning {
            proc.terminate()
        }
        caffeinateProcess = nil

        // Ripristina pmset se era stato modificato
        if didEnablePmsetDisableSleep {
            print("[SleepPreventer] Failsafe: ripristino di emergenza pmset disablesleep 0...")
            _ = SleepPreventer.runPmsetDisableSleep(enable: false)
            didEnablePmsetDisableSleep = false
        }
    }

    private func setupTerminationObserver() {
        NotificationCenter.default.addObserver(
            forName: NSApplication.willTerminateNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            print("[SleepPreventer] Notifica willTerminate ricevuta: esecuzione ripristino energetico...")
            self?.restoreAllSynchronous()
        }
    }

    private func setupSignalHandlers() {
        // Ignora gestione di default per catturare i segnali pulitamente
        signal(SIGINT, SIG_IGN)
        signal(SIGTERM, SIG_IGN)

        let sigint = DispatchSource.makeSignalSource(signal: SIGINT, queue: .main)
        sigint.setEventHandler { [weak self] in
            print("[SleepPreventer] Intercettato segnale SIGINT (Ctrl+C). Ripristino ed uscita...")
            self?.restoreAllSynchronous()
            exit(0)
        }
        sigint.resume()
        self.sigintSource = sigint

        let sigterm = DispatchSource.makeSignalSource(signal: SIGTERM, queue: .main)
        sigterm.setEventHandler { [weak self] in
            print("[SleepPreventer] Intercettato segnale SIGTERM. Ripristino ed uscita...")
            self?.restoreAllSynchronous()
            exit(0)
        }
        sigterm.resume()
        self.sigtermSource = sigterm
    }

    private func updatePublishedState() {
        let sysActive = systemSleepAssertionID != 0
        let dispActive = displaySleepAssertionID != 0
        let lidActive = didEnablePmsetDisableSleep || SleepPreventer.isPmsetDisableSleepActive()

        var desc = "Sospensione normale di sistema"
        if lidActive {
            desc = "Lid-Close Awake: ATTIVO (Coperchio chiudibile senza sleep)"
        } else if dispActive || sysActive {
            desc = "Idle & Display Awake: ATTIVO (Sleep display/sistema impedito)"
        }

        DispatchQueue.main.async {
            self.isIdleSleepPrevented = sysActive
            self.isDisplaySleepPrevented = dispActive
            self.isLidCloseSleepPrevented = lidActive
            self.statusDescription = desc
        }
    }
}
