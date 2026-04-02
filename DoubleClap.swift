import AVFoundation
import Cocoa
import Accelerate
import CoreAudio

// MARK: - Audio Device Helpers

struct AudioDevice {
    let id: AudioDeviceID
    let name: String
    let inputChannels: UInt32
    let outputChannels: UInt32

    var isInput: Bool { inputChannels > 0 }
    var isOutput: Bool { outputChannels > 0 }
}

func getAllAudioDevices() -> [AudioDevice] {
    var propSize: UInt32 = 0
    var address = AudioObjectPropertyAddress(
        mSelector: kAudioHardwarePropertyDevices,
        mScope: kAudioObjectPropertyScopeGlobal,
        mElement: kAudioObjectPropertyElementMain
    )

    AudioObjectGetPropertyDataSize(AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &propSize)
    let count = Int(propSize) / MemoryLayout<AudioDeviceID>.size
    var deviceIDs = [AudioDeviceID](repeating: 0, count: count)
    AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &propSize, &deviceIDs)

    var result: [AudioDevice] = []

    for deviceID in deviceIDs {
        var nameAddress = AudioObjectPropertyAddress(
            mSelector: kAudioObjectPropertyName,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var name: CFString = "" as CFString
        var nameSize = UInt32(MemoryLayout<CFString>.size)
        AudioObjectGetPropertyData(deviceID, &nameAddress, 0, nil, &nameSize, &name)

        func channelCount(scope: AudioObjectPropertyScope) -> UInt32 {
            var addr = AudioObjectPropertyAddress(
                mSelector: kAudioDevicePropertyStreamConfiguration,
                mScope: scope,
                mElement: kAudioObjectPropertyElementMain
            )
            var size: UInt32 = 0
            guard AudioObjectGetPropertyDataSize(deviceID, &addr, 0, nil, &size) == noErr, size > 0 else { return 0 }
            let ptr = UnsafeMutablePointer<AudioBufferList>.allocate(capacity: 1)
            defer { ptr.deallocate() }
            guard AudioObjectGetPropertyData(deviceID, &addr, 0, nil, &size, ptr) == noErr else { return 0 }
            return ptr.pointee.mBuffers.mNumberChannels
        }

        result.append(AudioDevice(
            id: deviceID,
            name: name as String,
            inputChannels: channelCount(scope: kAudioDevicePropertyScopeInput),
            outputChannels: channelCount(scope: kAudioDevicePropertyScopeOutput)
        ))
    }
    return result
}

func setSystemInputDevice(_ deviceID: AudioDeviceID) {
    var address = AudioObjectPropertyAddress(
        mSelector: kAudioHardwarePropertyDefaultInputDevice,
        mScope: kAudioObjectPropertyScopeGlobal,
        mElement: kAudioObjectPropertyElementMain
    )
    var id = deviceID
    let size = UInt32(MemoryLayout<AudioDeviceID>.size)
    AudioObjectSetPropertyData(AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, size, &id)
}

func audioDeviceUID(_ deviceID: AudioDeviceID) -> String? {
    var address = AudioObjectPropertyAddress(
        mSelector: kAudioDevicePropertyDeviceUID,
        mScope: kAudioObjectPropertyScopeGlobal,
        mElement: kAudioObjectPropertyElementMain
    )
    var uid: CFString = "" as CFString
    var size = UInt32(MemoryLayout<CFString>.size)
    let status = AudioObjectGetPropertyData(deviceID, &address, 0, nil, &size, &uid)
    return status == noErr ? uid as String : nil
}

// MARK: - Settings

class Settings {
    static let shared = Settings()
    private let defaults = UserDefaults.standard

    private enum Keys {
        static let apps = "apps"
        static let soundEnabled = "soundEnabled"
        static let soundPath = "soundPath"
        static let soundVolume = "soundVolume"
        static let enabled = "enabled"
        static let sensitivity = "sensitivity"
        static let soundDuration = "soundDuration"
        static let inputDeviceID = "inputDeviceID"
        static let outputDeviceID = "outputDeviceID"
    }

    var apps: [String] {
        get { defaults.stringArray(forKey: Keys.apps) ?? ["/Applications/cmux.app"] }
        set { defaults.set(newValue, forKey: Keys.apps) }
    }

    var soundEnabled: Bool {
        get { defaults.bool(forKey: Keys.soundEnabled) }
        set { defaults.set(newValue, forKey: Keys.soundEnabled) }
    }

    var soundPath: String? {
        get { defaults.string(forKey: Keys.soundPath) }
        set { defaults.set(newValue, forKey: Keys.soundPath) }
    }

    var soundVolume: Float {
        get {
            let val = defaults.float(forKey: Keys.soundVolume)
            return val == 0 ? 0.8 : val
        }
        set { defaults.set(newValue, forKey: Keys.soundVolume) }
    }

    // 0 = full length
    var soundDuration: Double {
        get { defaults.double(forKey: Keys.soundDuration) }
        set { defaults.set(newValue, forKey: Keys.soundDuration) }
    }

    var enabled: Bool {
        get { defaults.object(forKey: Keys.enabled) == nil ? true : defaults.bool(forKey: Keys.enabled) }
        set { defaults.set(newValue, forKey: Keys.enabled) }
    }

    var sensitivity: Float {
        get {
            let val = defaults.float(forKey: Keys.sensitivity)
            return val == 0 ? 0.4 : val
        }
        set { defaults.set(newValue, forKey: Keys.sensitivity) }
    }

    var minPeak: Float {
        return 0.1 + sensitivity * 0.7
    }

    // 0 = auto (built-in mic)
    var inputDeviceID: AudioDeviceID {
        get { AudioDeviceID(defaults.integer(forKey: Keys.inputDeviceID)) }
        set { defaults.set(Int(newValue), forKey: Keys.inputDeviceID) }
    }

    // 0 = system default
    var outputDeviceID: AudioDeviceID {
        get { AudioDeviceID(defaults.integer(forKey: Keys.outputDeviceID)) }
        set { defaults.set(Int(newValue), forKey: Keys.outputDeviceID) }
    }

    func resolvedInputDeviceID() -> AudioDeviceID? {
        let saved = inputDeviceID
        if saved != 0 {
            // Verify it still exists
            let devices = getAllAudioDevices()
            if devices.contains(where: { $0.id == saved && $0.isInput }) {
                return saved
            }
        }
        // Fallback: find built-in mic
        return getAllAudioDevices().first(where: { $0.name.contains("MacBook Pro") && $0.isInput })?.id
    }
}

// MARK: - Clap Detector

class ClapDetector {
    private var audioEngine: AVAudioEngine!
    private let bufferSize: AVAudioFrameCount = 1024

    private let spikeFactor: Float = 3.0
    private let doubleWindow: TimeInterval = 0.6
    private let minGap: TimeInterval = 0.08
    private let cooldown: TimeInterval = 2.0
    private let ambientCount = 80

    private var ambientLevels: [Float] = []
    private var lastClapTime: TimeInterval = 0
    private var lastTriggerTime: TimeInterval = 0
    private var soundPlayer: AVAudioPlayer?

    var onDoubleClapDetected: (() -> Void)?

    func start() {
        if let micID = Settings.shared.resolvedInputDeviceID() {
            setSystemInputDevice(micID)
        }

        audioEngine = AVAudioEngine()
        let inputNode = audioEngine.inputNode
        let format = inputNode.outputFormat(forBus: 0)

        inputNode.installTap(onBus: 0, bufferSize: bufferSize, format: format) { [weak self] buffer, _ in
            self?.processBuffer(buffer)
        }

        do {
            try audioEngine.start()
            NSLog("DoubleClap: Listening...")
        } catch {
            NSLog("DoubleClap: FAILED to start: %@", error.localizedDescription)
        }
    }

    func stop() {
        audioEngine?.inputNode.removeTap(onBus: 0)
        audioEngine?.stop()
        audioEngine = nil
        ambientLevels.removeAll()
    }

    func restart() {
        stop()
        start()
    }

    private func isClappy(_ channelData: UnsafeMutablePointer<Float>, count: Int, peak: Float) -> Bool {
        var rms: Float = 0
        vDSP_rmsqv(channelData, 1, &rms, vDSP_Length(count))
        guard rms > 0 else { return false }
        return peak / rms > 6.0
    }

    private func processBuffer(_ buffer: AVAudioPCMBuffer) {
        guard Settings.shared.enabled else { return }
        guard let channelData = buffer.floatChannelData?[0] else { return }
        let count = Int(buffer.frameLength)

        var peak: Float = 0
        vDSP_maxmgv(channelData, 1, &peak, vDSP_Length(count))

        let now = ProcessInfo.processInfo.systemUptime

        if now - lastTriggerTime < cooldown {
            ambientLevels.append(peak)
            if ambientLevels.count > ambientCount { ambientLevels.removeFirst() }
            return
        }

        if ambientLevels.count < 10 {
            ambientLevels.append(peak)
            return
        }

        let sorted = ambientLevels.sorted()
        let ambient = sorted[sorted.count / 2]
        let minPeak = Settings.shared.minPeak
        let threshold = max(ambient * spikeFactor, minPeak)

        if peak > threshold && isClappy(channelData, count: count, peak: peak) {
            let gap = now - lastClapTime

            if gap > minGap && gap < doubleWindow {
                NSLog("DoubleClap: >> DOUBLE CLAP! peak=%.4f", peak)
                lastTriggerTime = now
                lastClapTime = 0
                DispatchQueue.main.async { [weak self] in
                    self?.onDoubleClapDetected?()
                    self?.triggerActions()
                }
            } else {
                lastClapTime = now
            }
        } else {
            ambientLevels.append(peak)
            if ambientLevels.count > ambientCount { ambientLevels.removeFirst() }
        }
    }

    private func getSystemVolume() -> Float {
        let script = "output volume of (get volume settings)"
        let task = Process()
        task.launchPath = "/usr/bin/osascript"
        task.arguments = ["-e", script]
        let pipe = Pipe()
        task.standardOutput = pipe
        try? task.run()
        task.waitUntilExit()
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        let str = String(data: data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return Float(str) ?? 50
    }

    private func setSystemVolume(_ volume: Float) {
        let script = "set volume output volume \(Int(volume))"
        let task = Process()
        task.launchPath = "/usr/bin/osascript"
        task.arguments = ["-e", script]
        try? task.run()
    }

    private func triggerActions() {
        for appPath in Settings.shared.apps {
            let url = URL(fileURLWithPath: appPath)
            NSWorkspace.shared.openApplication(at: url, configuration: .init())
        }

        if Settings.shared.soundEnabled, let path = Settings.shared.soundPath {
            let url = URL(fileURLWithPath: path)
            soundPlayer = try? AVAudioPlayer(contentsOf: url)

            // Route to selected output device
            let outputID = Settings.shared.outputDeviceID
            if outputID != 0, let uid = audioDeviceUID(outputID) {
                soundPlayer?.currentDevice = uid
            }

            // Set system volume to configured level, play, then restore
            let originalVolume = getSystemVolume()
            let targetVolume = Settings.shared.soundVolume * 100
            setSystemVolume(targetVolume)
            soundPlayer?.play()

            let fullDuration = soundPlayer?.duration ?? 1.0
            let customDuration = Settings.shared.soundDuration
            let playDuration = (customDuration > 0 && customDuration < fullDuration) ? customDuration : fullDuration

            DispatchQueue.main.asyncAfter(deadline: .now() + playDuration) { [weak self] in
                self?.soundPlayer?.stop()
                self?.setSystemVolume(originalVolume)
            }
        }
    }
}

// MARK: - Settings Window

class SettingsWindowController: NSWindowController, NSTableViewDataSource, NSTableViewDelegate {
    private var appTableView: NSTableView!
    private var soundToggle: NSButton!
    private var soundPathLabel: NSTextField!
    private var volumeSlider: NSSlider!
    private var volumeLabel: NSTextField!
    private var durationField: NSTextField!
    private var sensitivitySlider: NSSlider!
    private var sensitivityLabel: NSTextField!
    private var inputPopup: NSPopUpButton!
    private var outputPopup: NSPopUpButton!

    var onInputDeviceChanged: (() -> Void)?

    convenience init() {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 480, height: 660),
            styleMask: [.titled, .closable],
            backing: .buffered,
            defer: false
        )
        window.title = "DoubleClap Settings"
        window.center()
        window.isReleasedWhenClosed = false
        self.init(window: window)
        setupUI()
    }

    private func setupUI() {
        guard let contentView = window?.contentView else { return }
        contentView.wantsLayer = true

        let padding: CGFloat = 20
        var y: CGFloat = 620

        // --- Input Device ---
        let inputLabel = NSTextField(labelWithString: "Input Device (Microphone):")
        inputLabel.font = .systemFont(ofSize: 13, weight: .semibold)
        inputLabel.frame = NSRect(x: padding, y: y, width: 300, height: 20)
        contentView.addSubview(inputLabel)
        y -= 28

        inputPopup = NSPopUpButton(frame: NSRect(x: padding, y: y, width: 440, height: 26))
        inputPopup.target = self
        inputPopup.action = #selector(inputDeviceChanged)
        populateInputDevices()
        contentView.addSubview(inputPopup)
        y -= 40

        // --- Apps section ---
        let appsLabel = NSTextField(labelWithString: "Apps to launch on double clap:")
        appsLabel.font = .systemFont(ofSize: 13, weight: .semibold)
        appsLabel.frame = NSRect(x: padding, y: y, width: 300, height: 20)
        contentView.addSubview(appsLabel)
        y -= 128

        let scrollView = NSScrollView(frame: NSRect(x: padding, y: y, width: 440, height: 120))
        scrollView.hasVerticalScroller = true
        scrollView.borderType = .bezelBorder

        appTableView = NSTableView()
        let column = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("app"))
        column.title = "Application"
        column.width = 420
        appTableView.addTableColumn(column)
        appTableView.dataSource = self
        appTableView.delegate = self
        appTableView.headerView = nil
        appTableView.rowHeight = 24
        scrollView.documentView = appTableView
        contentView.addSubview(scrollView)
        y -= 35

        let addButton = NSButton(title: "Add App...", target: self, action: #selector(addApp))
        addButton.bezelStyle = .rounded
        addButton.frame = NSRect(x: padding, y: y, width: 100, height: 28)
        contentView.addSubview(addButton)

        let removeButton = NSButton(title: "Remove", target: self, action: #selector(removeApp))
        removeButton.bezelStyle = .rounded
        removeButton.frame = NSRect(x: 130, y: y, width: 80, height: 28)
        contentView.addSubview(removeButton)
        y -= 45

        // --- Sound section ---
        let soundLabel = NSTextField(labelWithString: "Sound:")
        soundLabel.font = .systemFont(ofSize: 13, weight: .semibold)
        soundLabel.frame = NSRect(x: padding, y: y, width: 100, height: 20)
        contentView.addSubview(soundLabel)
        y -= 28

        soundToggle = NSButton(checkboxWithTitle: "Play sound on double clap", target: self, action: #selector(toggleSound))
        soundToggle.frame = NSRect(x: padding, y: y, width: 250, height: 20)
        soundToggle.state = Settings.shared.soundEnabled ? .on : .off
        contentView.addSubview(soundToggle)
        y -= 28

        soundPathLabel = NSTextField(labelWithString: Settings.shared.soundPath.map { URL(fileURLWithPath: $0).lastPathComponent } ?? "No sound selected")
        soundPathLabel.frame = NSRect(x: padding, y: y, width: 300, height: 20)
        soundPathLabel.textColor = .secondaryLabelColor
        soundPathLabel.font = .systemFont(ofSize: 11)
        contentView.addSubview(soundPathLabel)

        let chooseSoundButton = NSButton(title: "Choose...", target: self, action: #selector(chooseSound))
        chooseSoundButton.bezelStyle = .rounded
        chooseSoundButton.frame = NSRect(x: 340, y: y - 4, width: 100, height: 28)
        contentView.addSubview(chooseSoundButton)
        y -= 35

        // Volume
        let volLabel = NSTextField(labelWithString: "Volume:")
        volLabel.font = .systemFont(ofSize: 12)
        volLabel.frame = NSRect(x: padding, y: y, width: 60, height: 18)
        contentView.addSubview(volLabel)

        volumeSlider = NSSlider(value: Double(Settings.shared.soundVolume), minValue: 0.0, maxValue: 1.0, target: self, action: #selector(volumeChanged))
        volumeSlider.frame = NSRect(x: padding + 60, y: y, width: 300, height: 20)
        contentView.addSubview(volumeSlider)

        volumeLabel = NSTextField(labelWithString: "\(Int(Settings.shared.soundVolume * 100))%")
        volumeLabel.font = .systemFont(ofSize: 11)
        volumeLabel.textColor = .secondaryLabelColor
        volumeLabel.frame = NSRect(x: padding + 370, y: y, width: 50, height: 18)
        contentView.addSubview(volumeLabel)
        y -= 30

        // Duration
        let durLabel = NSTextField(labelWithString: "Duration:")
        durLabel.font = .systemFont(ofSize: 12)
        durLabel.frame = NSRect(x: padding, y: y, width: 60, height: 18)
        contentView.addSubview(durLabel)

        durationField = NSTextField(frame: NSRect(x: padding + 65, y: y - 2, width: 60, height: 22))
        let savedDur = Settings.shared.soundDuration
        durationField.stringValue = savedDur > 0 ? String(format: "%.1f", savedDur) : ""
        durationField.placeholderString = "Full"
        durationField.alignment = .center
        durationField.target = self
        durationField.action = #selector(durationChanged)
        contentView.addSubview(durationField)

        let secLabel = NSTextField(labelWithString: "seconds (leave empty for full length)")
        secLabel.font = .systemFont(ofSize: 11)
        secLabel.textColor = .secondaryLabelColor
        secLabel.frame = NSRect(x: padding + 130, y: y, width: 250, height: 18)
        contentView.addSubview(secLabel)
        y -= 35

        // Output Device
        let outLabel = NSTextField(labelWithString: "Output Device:")
        outLabel.font = .systemFont(ofSize: 12)
        outLabel.frame = NSRect(x: padding, y: y, width: 100, height: 18)
        contentView.addSubview(outLabel)
        y -= 26

        outputPopup = NSPopUpButton(frame: NSRect(x: padding, y: y, width: 440, height: 26))
        outputPopup.target = self
        outputPopup.action = #selector(outputDeviceChanged)
        populateOutputDevices()
        contentView.addSubview(outputPopup)
        y -= 40

        // --- Sensitivity section ---
        let sensLabel = NSTextField(labelWithString: "Sensitivity:")
        sensLabel.font = .systemFont(ofSize: 13, weight: .semibold)
        sensLabel.frame = NSRect(x: padding, y: y, width: 100, height: 20)
        contentView.addSubview(sensLabel)
        y -= 28

        let highLabel = NSTextField(labelWithString: "High")
        highLabel.font = .systemFont(ofSize: 11)
        highLabel.textColor = .secondaryLabelColor
        highLabel.frame = NSRect(x: padding, y: y, width: 40, height: 16)
        contentView.addSubview(highLabel)

        sensitivitySlider = NSSlider(value: Double(Settings.shared.sensitivity), minValue: 0.05, maxValue: 1.0, target: self, action: #selector(sensitivityChanged))
        sensitivitySlider.frame = NSRect(x: padding + 40, y: y, width: 340, height: 20)
        contentView.addSubview(sensitivitySlider)

        let lowLabel = NSTextField(labelWithString: "Low")
        lowLabel.font = .systemFont(ofSize: 11)
        lowLabel.textColor = .secondaryLabelColor
        lowLabel.frame = NSRect(x: padding + 385, y: y, width: 40, height: 16)
        contentView.addSubview(lowLabel)

        y -= 20
        sensitivityLabel = NSTextField(labelWithString: String(format: "Threshold: %.2f", Settings.shared.minPeak))
        sensitivityLabel.font = .systemFont(ofSize: 11)
        sensitivityLabel.textColor = .tertiaryLabelColor
        sensitivityLabel.frame = NSRect(x: padding + 40, y: y, width: 200, height: 16)
        contentView.addSubview(sensitivityLabel)
    }

    // MARK: - Device Popups

    private func populateInputDevices() {
        inputPopup.removeAllItems()
        let devices = getAllAudioDevices().filter { $0.isInput }
        let savedID = Settings.shared.inputDeviceID

        inputPopup.addItem(withTitle: "Auto (Built-in Microphone)")
        inputPopup.lastItem?.tag = 0

        for device in devices {
            inputPopup.addItem(withTitle: device.name)
            inputPopup.lastItem?.tag = Int(device.id)
        }

        if savedID == 0 {
            inputPopup.selectItem(at: 0)
        } else if let idx = inputPopup.itemArray.firstIndex(where: { $0.tag == Int(savedID) }) {
            inputPopup.selectItem(at: idx)
        }
    }

    private func populateOutputDevices() {
        outputPopup.removeAllItems()
        let devices = getAllAudioDevices().filter { $0.isOutput }
        let savedID = Settings.shared.outputDeviceID

        outputPopup.addItem(withTitle: "System Default")
        outputPopup.lastItem?.tag = 0

        for device in devices {
            outputPopup.addItem(withTitle: device.name)
            outputPopup.lastItem?.tag = Int(device.id)
        }

        if savedID == 0 {
            outputPopup.selectItem(at: 0)
        } else if let idx = outputPopup.itemArray.firstIndex(where: { $0.tag == Int(savedID) }) {
            outputPopup.selectItem(at: idx)
        }
    }

    // MARK: - Actions

    @objc private func inputDeviceChanged() {
        let tag = inputPopup.selectedItem?.tag ?? 0
        Settings.shared.inputDeviceID = AudioDeviceID(tag)
        onInputDeviceChanged?()
    }

    @objc private func outputDeviceChanged() {
        let tag = outputPopup.selectedItem?.tag ?? 0
        Settings.shared.outputDeviceID = AudioDeviceID(tag)
    }

    @objc private func volumeChanged(_ sender: NSSlider) {
        Settings.shared.soundVolume = Float(sender.doubleValue)
        volumeLabel.stringValue = "\(Int(sender.doubleValue * 100))%"
    }

    @objc private func durationChanged(_ sender: NSTextField) {
        let text = sender.stringValue.trimmingCharacters(in: .whitespaces)
        if text.isEmpty {
            Settings.shared.soundDuration = 0
        } else if let val = Double(text), val > 0 {
            Settings.shared.soundDuration = val
        }
    }

    @objc private func addApp() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        panel.directoryURL = URL(fileURLWithPath: "/Applications")
        panel.allowedContentTypes = [.application]
        panel.begin { [weak self] response in
            guard response == .OK, let url = panel.url else { return }
            var apps = Settings.shared.apps
            let path = url.path
            if !apps.contains(path) {
                apps.append(path)
                Settings.shared.apps = apps
                self?.appTableView.reloadData()
            }
        }
    }

    @objc private func removeApp() {
        let row = appTableView.selectedRow
        guard row >= 0 else { return }
        var apps = Settings.shared.apps
        apps.remove(at: row)
        Settings.shared.apps = apps
        appTableView.reloadData()
    }

    @objc private func toggleSound(_ sender: NSButton) {
        Settings.shared.soundEnabled = sender.state == .on
    }

    @objc private func chooseSound() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        panel.allowedContentTypes = [.audio]
        panel.begin { [weak self] response in
            guard response == .OK, let url = panel.url else { return }
            Settings.shared.soundPath = url.path
            self?.soundPathLabel.stringValue = url.lastPathComponent
        }
    }

    @objc private func sensitivityChanged(_ sender: NSSlider) {
        Settings.shared.sensitivity = Float(sender.doubleValue)
        sensitivityLabel.stringValue = String(format: "Threshold: %.2f", Settings.shared.minPeak)
    }

    // MARK: - TableView

    func numberOfRows(in tableView: NSTableView) -> Int {
        return Settings.shared.apps.count
    }

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        let path = Settings.shared.apps[row]
        let name = FileManager.default.displayName(atPath: path)

        let cell = NSTableCellView()
        let textField = NSTextField(labelWithString: name)
        textField.frame = NSRect(x: 28, y: 2, width: 380, height: 20)
        cell.addSubview(textField)
        cell.textField = textField

        let icon = NSWorkspace.shared.icon(forFile: path)
        let imageView = NSImageView(frame: NSRect(x: 2, y: 2, width: 20, height: 20))
        imageView.image = icon
        cell.addSubview(imageView)
        cell.imageView = imageView

        return cell
    }
}

// MARK: - App Delegate

class AppDelegate: NSObject, NSApplicationDelegate {
    private var statusItem: NSStatusItem!
    private var detector: ClapDetector!
    private var settingsController: SettingsWindowController?
    private var enabledMenuItem: NSMenuItem!
    private var statusMenuItem: NSMenuItem!

    func applicationDidFinishLaunching(_ notification: Notification) {
        setupMenuBar()
        detector = ClapDetector()
        detector.onDoubleClapDetected = { [weak self] in
            self?.flashMenuBarIcon()
        }

        if Settings.shared.enabled {
            detector.start()
        }
    }

    private func setupMenuBar() {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)

        if let button = statusItem.button {
            button.image = NSImage(systemSymbolName: "hands.clap.fill", accessibilityDescription: "DoubleClap")
            button.image?.size = NSSize(width: 18, height: 18)
            button.image?.isTemplate = true
        }

        let menu = NSMenu()

        statusMenuItem = NSMenuItem(title: "Listening...", action: nil, keyEquivalent: "")
        statusMenuItem.isEnabled = false
        menu.addItem(statusMenuItem)

        menu.addItem(NSMenuItem.separator())

        enabledMenuItem = NSMenuItem(title: "Enabled", action: #selector(toggleEnabled), keyEquivalent: "e")
        enabledMenuItem.target = self
        enabledMenuItem.state = Settings.shared.enabled ? .on : .off
        menu.addItem(enabledMenuItem)

        menu.addItem(NSMenuItem.separator())

        let settingsItem = NSMenuItem(title: "Settings...", action: #selector(openSettings), keyEquivalent: ",")
        settingsItem.target = self
        menu.addItem(settingsItem)

        menu.addItem(NSMenuItem.separator())

        let quitItem = NSMenuItem(title: "Quit DoubleClap", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        menu.addItem(quitItem)

        statusItem.menu = menu
    }

    @objc private func toggleEnabled() {
        Settings.shared.enabled = !Settings.shared.enabled
        enabledMenuItem.state = Settings.shared.enabled ? .on : .off

        if Settings.shared.enabled {
            detector.start()
            statusMenuItem.title = "Listening..."
        } else {
            detector.stop()
            statusMenuItem.title = "Paused"
        }
    }

    @objc private func openSettings() {
        if settingsController == nil {
            settingsController = SettingsWindowController()
            settingsController?.onInputDeviceChanged = { [weak self] in
                guard Settings.shared.enabled else { return }
                self?.detector.restart()
            }
        }
        settingsController?.showWindow(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    private func flashMenuBarIcon() {
        guard let button = statusItem.button else { return }
        let original = button.image
        button.image = NSImage(systemSymbolName: "hands.clap", accessibilityDescription: "Clap detected")
        button.image?.size = NSSize(width: 18, height: 18)
        button.image?.isTemplate = true
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
            button.image = original
        }
    }
}

// MARK: - Main

let app = NSApplication.shared
app.setActivationPolicy(.accessory)

switch AVCaptureDevice.authorizationStatus(for: .audio) {
case .authorized:
    let delegate = AppDelegate()
    app.delegate = delegate
    app.run()

case .notDetermined:
    AVCaptureDevice.requestAccess(for: .audio) { granted in
        if granted {
            DispatchQueue.main.async {
                let delegate = AppDelegate()
                app.delegate = delegate
                app.run()
            }
        } else {
            NSLog("DoubleClap: Mic access denied")
            exit(1)
        }
    }
    RunLoop.current.run()

default:
    NSLog("DoubleClap: Mic access denied — enable in System Settings > Privacy > Microphone")
    exit(1)
}
