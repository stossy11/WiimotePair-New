//
//  ContentView.swift
//  WiimotePair-New
//
//  Created by Stossy11 on 23/12/2024.
//


import SwiftUI
import CoreBluetooth
import IOBluetooth

class WiimotePairViewModel: NSObject, ObservableObject {
    @Published var isProController = false
    @Published var isScanning = false
    @Published var errorMessage: (String, String)? = nil
    
    private var centralManager: CBCentralManager?
    private var deviceInquiry: IOBluetoothDeviceInquiry?
    private var devicePair: IOBluetoothDevicePair?
    
    override init() {
        super.init()
        centralManager = CBCentralManager(delegate: self, queue: nil)
    }
    
    private func showFatalError(title: String, text: String) {
        errorMessage = (title, text)
        // Note: Since SwiftUI handles its own lifecycle, we don't force terminate the app
    }
    
    private func startDeviceInquiry() {
        deviceInquiry = IOBluetoothDeviceInquiry(delegate: self)
        deviceInquiry?.searchType = kIOBluetoothDeviceSearchClassic.rawValue
        deviceInquiry?.start()
        isScanning = true
    }
}

// MARK: - CBCentralManagerDelegate
extension WiimotePairViewModel: CBCentralManagerDelegate {
    
    
    func centralManagerDidUpdateState(_ central: CBCentralManager) {
        switch central.state {
        case .unauthorized:
            showFatalError(
                title: "Bluetooth Permission Denied",
                text: "WiimotePair is not allowed to access Bluetooth. Please allow WiimotePair to access Bluetooth in the \"Privacy & Security\" pane within the System Settings app."
            )
        case .poweredOff:
            deviceInquiry?.stop()
            deviceInquiry = nil
            devicePair?.stop()
            devicePair = nil
            showFatalError(
                title: "Bluetooth Unavailable",
                text: "Please turn Bluetooth on before running WiimotePair."
            )
        case .unsupported, .unknown:
            showFatalError(
                title: "Unknown Bluetooth Error",
                text: "CBCentralManager is in an invalid state. Relaunch WiimotePair and try again."
            )
        case .poweredOn:
            if deviceInquiry == nil {
                startDeviceInquiry()
            }
        case .resetting:
            break
        @unknown default:
            break
        }
    }
}

// MARK: - IOBluetoothDeviceInquiryDelegate
extension WiimotePairViewModel: IOBluetoothDeviceInquiryDelegate {
    func deviceInquiryDeviceFound(_ sender: IOBluetoothDeviceInquiry!, device: IOBluetoothDevice!) {
        guard let name = device.name, name.contains("Nintendo RVL-CNT-01") || name.contains("Nintendo RVL-CNT-01-UC") else { return }
        
        isProController = name.contains("Nintendo RVL-CNT-01-UC")
        
        guard !device.isPaired() else { return }
        
        deviceInquiry?.stop()
        isScanning = false
        
        devicePair = IOBluetoothDevicePair(device: device)
        devicePair?.delegate = self
        
        // Set private API flag to ensure delegate is queried for PIN
        devicePair?.setUserDefinedPincode(true)
        
        let pairResult = devicePair?.start()
        if pairResult != kIOReturnSuccess {
            let pairResultString = String(cString: mach_error_string(pairResult ?? 0))
            errorMessage = (
                "Pairing Error",
                "An error occurred while starting the pairing process: \"\(pairResultString)\"."
            )
        }
    }
    
    func deviceInquiryComplete(_ sender: IOBluetoothDeviceInquiry!, error: IOReturn, aborted: Bool) {
        if !aborted {
            sender.clearFoundDevices()
            sender.start()
        }
    }
}

// MARK: - IOBluetoothDevicePairDelegate
extension WiimotePairViewModel: IOBluetoothDevicePairDelegate {
    func devicePairingPINCodeRequest(_ sender: Any!) {
        
        guard let pair = sender as? IOBluetoothDevicePair,
              let controller = IOBluetoothHostController.default(),
              let device = pair.device(),
              let controllerAddressStr = controller.addressAsString()
        else { return }
        
        
        var controllerAddress = BluetoothDeviceAddress()
        IOBluetoothNSStringToDeviceAddress(controllerAddressStr, &controllerAddress)
        
        var code = BluetoothPINCode()
        let address = controllerAddress.data

        code.data.0 = address.5
        code.data.1 = address.4
        code.data.2 = address.3
        code.data.3 = address.2
        code.data.4 = address.1
        code.data.5 = address.0
        
        var key: UInt64 = 0
        withUnsafeBytes(of: code.data) { buffer in
            key = buffer.load(as: UInt64.self)
        }
        
        IOBluetoothCoreBluetoothCoordinator.sharedInstance()?.pairPeer(
            device.classicPeer(),
            forType: pair.currentPairingType(),
            withKey: NSNumber(value: key)
        )
    }
    
    func devicePairingFinished(_ sender: Any!, error: IOReturn) {
        devicePair?.stop()
        devicePair = nil
        
        
        if error != kIOReturnSuccess {
            let errorString = String(cString: mach_error_string(error))
            errorMessage = (
                "Pairing Error",
                "An error occurred while attempting to pair: \"\(errorString)\"."
            )
        } else {
            
            let mac = getMacModelName()
            
            errorMessage = (
                "Paired",
                "The \(self.isProController ? "Wii U Pro Controller" : "Wii Remote") has been paired with your \(mac == nil ? "Mac" : mac!)."
            )
        }
        
        // Restart scanning after pairing attempt
        startDeviceInquiry()
    }
}

struct ContentView: View {
    @StateObject private var viewModel = WiimotePairViewModel()
    
    var body: some View {
        VStack {
            if viewModel.isScanning {
                ProgressView()
                    .controlSize(.large)
                Text("Searching for Wii Remotes and Wii U Pro Contrrollers...")
                    .padding()
            } else {
                Text("Pairing in progress...")
                    .padding()
            }
        }
        .alert(
            item: Binding(
                get: { viewModel.errorMessage.map { Alert(title: $0.0, message: $0.1) } },
                set: { _ in viewModel.errorMessage = nil }
            )
        ) { alert in
            SwiftUI.Alert(title: Text(alert.title), message: Text(alert.message))
        }
    }
}

// Helper to make error messages work with SwiftUI alerts
private struct Alert: Identifiable {
    let title: String
    let message: String
    var id: String { title + message }
}


func getMacModelName() -> String? {
    let process = Process()
    process.executableURL = URL(fileURLWithPath: "/usr/sbin/system_profiler")
    process.arguments = ["SPHardwareDataType"]

    let pipe = Pipe()
    process.standardOutput = pipe

    do {
        try process.run()
        process.waitUntilExit()

        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        if let output = String(data: data, encoding: .utf8) {
            // Look for the "Model Identifier" or "Model Name"
            if let range = output.range(of: "Model Name:") {
                let line = output[range.upperBound...].split(separator: "\n").first?.trimmingCharacters(in: .whitespacesAndNewlines)
                return line
            }
        }
    } catch {
        print("Error fetching system profile: \(error)")
    }
    return nil
}
