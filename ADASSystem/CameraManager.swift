import AVFoundation
import CoreML
import Vision
import SwiftUI
import CoreImage

enum CameraType: String, CaseIterable {
    case builtin = "Built-in Camera"
    case continuity = "iPhone Camera"
}

protocol CameraManagerDelegate: AnyObject {
    func cameraManager(_ manager: CameraManager, didUpdate frame: CIImage)
    func cameraManager(_ manager: CameraManager, didUpdateDetections detections: [Detection])
}

class CameraManager: NSObject, ObservableObject, AVCaptureVideoDataOutputSampleBufferDelegate {
    // MARK: - Published Properties
    @Published var isSetup = false
    @Published var error: Error?
    @Published private(set) var currentFrame: CIImage?
    @Published private(set) var isRunning = false
    @Published private(set) var detections: [Detection] = []
    @Published var selectedCamera: CameraType = .builtin {
        didSet {
            if oldValue != selectedCamera {
                print("Camera selection changed from \(oldValue) to \(selectedCamera)")
                switchToCamera(selectedCamera)
            }
        }
    }
    @Published var availableCameras: [CameraType] = []
    @Published private(set) var isContinuityCameraAvailable = false
    
    // MARK: - Private Properties
    private var captureSession: AVCaptureSession?
    private var currentCameraInput: AVCaptureDeviceInput?
    private let videoOutput = AVCaptureVideoDataOutput()
    private let processingQueue = DispatchQueue(label: "com.dsu.adassystem.camera")
    private let objectDetector: ObjectDetector
    private var notificationObservers: [NSObjectProtocol] = []
    private var deviceDiscoverySession: AVCaptureDevice.DiscoverySession?
    private var retryAttempts = 0
    private let maxRetryAttempts = 3
    
    weak var delegate: CameraManagerDelegate?
    
    // MARK: - Initialization
    override init() {
        // Initialize object detector first
        self.objectDetector = ObjectDetector()
        
        // Initialize discovery session
        self.deviceDiscoverySession = AVCaptureDevice.DiscoverySession(
            deviceTypes: [.builtInWideAngleCamera, .external, .continuityCamera],
            mediaType: .video,
            position: .unspecified
        )
        
        super.init()
        setupNotificationObservers()
        setupAvailableCameras()
        checkPermissions()
    }
    
    deinit {
        notificationObservers.forEach { NotificationCenter.default.removeObserver($0) }
        stopCapture()
    }
    
    
    
    
    
    // MARK: - Notification and Device Setup
    private func setupNotificationObservers() {
        let notificationNames: [(NSNotification.Name, String)] = [
            (.AVCaptureDeviceWasConnected, "Device Connected"),
            (.AVCaptureDeviceWasDisconnected, "Device Disconnected"),
            (.AVCaptureSessionRuntimeError, "Session Error"),
            (.AVCaptureSessionDidStartRunning, "Session Started"),
            (.AVCaptureSessionDidStopRunning, "Session Stopped")
        ]
        
        for (name, description) in notificationNames {
            let observer = NotificationCenter.default.addObserver(
                forName: name,
                object: nil,
                queue: .main
            ) { [weak self] notification in
                guard let self = self else { return }
                print("Camera Notification: \(description)")
                
                switch name {
                case .AVCaptureDeviceWasConnected:
                    if let device = notification.object as? AVCaptureDevice {
                        self.handleDeviceConnection(device)
                    }
                case .AVCaptureDeviceWasDisconnected:
                    if let device = notification.object as? AVCaptureDevice {
                        self.handleDeviceDisconnection(device)
                    }
                case .AVCaptureSessionRuntimeError:
                    self.handleSessionRuntimeError(notification.userInfo)
                case .AVCaptureSessionDidStartRunning:
                    DispatchQueue.main.async {
                        self.isRunning = true
                        self.retryAttempts = 0
                    }
                case .AVCaptureSessionDidStopRunning:
                    DispatchQueue.main.async {
                        self.isRunning = false
                    }
                default:
                    break
                }
            }
            notificationObservers.append(observer)
        }
    }
    
    // MARK: - Device Management
    private func handleDeviceConnection(_ device: AVCaptureDevice) {
        print("Device connected: \(device.localizedName)")
        setupAvailableCameras()
        
        if device.isContinuityCamera && selectedCamera == .continuity {
            print("Continuity camera reconnected, restarting session")
            retryAttempts = 0
            switchToCamera(.continuity)
        }
    }
    
    private func handleDeviceDisconnection(_ device: AVCaptureDevice) {
        print("Device disconnected: \(device.localizedName)")
        setupAvailableCameras()
        
        if device.isContinuityCamera && selectedCamera == .continuity {
            print("Continuity camera disconnected, switching to built-in")
            DispatchQueue.main.async {
                self.selectedCamera = .builtin
            }
        }
    }
    
    private func handleSessionRuntimeError(_ userInfo: [AnyHashable: Any]?) {
        print("Session runtime error: \(String(describing: userInfo))")
        if selectedCamera == .continuity && retryAttempts < maxRetryAttempts {
            retryAttempts += 1
            print("Retrying Continuity Camera connection (Attempt \(retryAttempts)/\(maxRetryAttempts))")
            switchToCamera(.continuity)
        } else {
            print("Maximum retry attempts reached or not using continuity camera")
            DispatchQueue.main.async {
                self.selectedCamera = .builtin
            }
        }
    }
    
    private func setupAvailableCameras() {
        guard let discoverySession = deviceDiscoverySession else { return }
        
        let devices = discoverySession.devices
        print("Available devices:", devices.map { "\($0.localizedName) (\($0.deviceType))" })
        
        // Start with built-in camera
        availableCameras = [.builtin]
        
        // Look for iPhone/Continuity Camera
        let hasIphoneCamera = devices.contains {
            $0.isContinuityCamera ||
            $0.localizedName.contains("iPhone") ||
            ($0.deviceType == .external && $0.localizedName.contains("Camera"))
        }
        
        if hasIphoneCamera {
            availableCameras.append(.continuity)
            isContinuityCameraAvailable = true
            print("Found iPhone camera")
        } else {
            isContinuityCameraAvailable = false
            print("No iPhone camera found")
        }
    }
    
    private func checkPermissions() {
        switch AVCaptureDevice.authorizationStatus(for: .video) {
        case .authorized:
            setupCaptureSession()
        case .notDetermined:
            AVCaptureDevice.requestAccess(for: .video) { [weak self] granted in
                if granted {
                    DispatchQueue.main.async {
                        self?.setupCaptureSession()
                    }
                } else {
                    DispatchQueue.main.async {
                        self?.error = NSError(domain: "", code: 1,
                                              userInfo: [NSLocalizedDescriptionKey: "Camera access denied"])
                    }
                }
            }
        case .denied:
            error = NSError(domain: "", code: 1,
                            userInfo: [NSLocalizedDescriptionKey: "Camera access denied"])
        case .restricted:
            error = NSError(domain: "", code: 2,
                            userInfo: [NSLocalizedDescriptionKey: "Camera access restricted"])
        @unknown default:
            break
        }
    }
    
    // MARK: - Public Camera Selection Methods
    func switchToBuiltInCamera() {
        selectedCamera = .builtin
    }
    
    func switchToContinuityCamera() {
        if isContinuityCameraAvailable {
            selectedCamera = .continuity
        } else {
            error = NSError(domain: "", code: 3,
                            userInfo: [NSLocalizedDescriptionKey: "Continuity Camera not available"])
        }
    }
    
    
    
    // MARK: - Camera Setup and Control
    private func getVideoDevice() -> AVCaptureDevice? {
        guard let discoverySession = deviceDiscoverySession else { return nil }
        let devices = discoverySession.devices
        
        switch selectedCamera {
        case .builtin:
            let device = devices.first { !$0.isContinuityCamera }
            print("Selected built-in device: \(device?.localizedName ?? "none")")
            return device
            
        case .continuity:
            // First try to get a device that's explicitly marked as continuity camera
            if let device = AVCaptureDevice.default(.continuityCamera, for: .video, position: .unspecified) {
                print("Found dedicated Continuity Camera: \(device.localizedName)")
                return device
            }
            
            // Fall back to finding an iPhone camera
            let device = devices.first { $0.isContinuityCamera }
            print("Selected continuity device: \(device?.localizedName ?? "none")")
            return device
        }
    }
    
    private func switchToCamera(_ type: CameraType) {
        print("Attempting to switch to \(type)")
        stopCapture()
        
        // Add delay to ensure proper cleanup
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { [weak self] in
            guard let self = self else { return }
            
            // Clear existing session
            if let session = self.captureSession {
                session.beginConfiguration()
                session.inputs.forEach { session.removeInput($0) }
                session.outputs.forEach { session.removeOutput($0) }
                session.commitConfiguration()
                self.captureSession = nil
            }
            
            // Reset state
            self.currentCameraInput = nil
            
            // Create new session
            self.setupCaptureSession()
            
            // Start if needed
            if self.isRunning {
                self.startCapture()
            }
        }
    }
    
    private func setupCaptureSession() {
        print("Setting up capture session")
        let session = AVCaptureSession()
        session.beginConfiguration()
        
        // Configure for high resolution
        session.sessionPreset = .high
        
        // Get appropriate video device
        guard let videoDevice = getVideoDevice() else {
            print("Could not find video device")
            DispatchQueue.main.async {
                if self.selectedCamera == .continuity {
                    print("Falling back to built-in camera")
                    self.selectedCamera = .builtin
                }
            }
            return
        }
        
        print("Configuring device: \(videoDevice.localizedName)")
        
        do {
            // Configure device settings
            try videoDevice.lockForConfiguration()
            
            // Configure exposure
            if videoDevice.isExposureModeSupported(.continuousAutoExposure) {
                videoDevice.exposureMode = .continuousAutoExposure
            }
            
            // Configure white balance
            if videoDevice.isWhiteBalanceModeSupported(.continuousAutoWhiteBalance) {
                videoDevice.whiteBalanceMode = .continuousAutoWhiteBalance
            }
            
            // Configure focus
            if videoDevice.isFocusModeSupported(.continuousAutoFocus) {
                videoDevice.focusMode = .continuousAutoFocus
            }
            
            // Configure frame rate for continuity camera
            if videoDevice.isContinuityCamera {
                if let frameRateRange = videoDevice.activeFormat.videoSupportedFrameRateRanges.first {
                    videoDevice.activeVideoMinFrameDuration = CMTime(value: 1, timescale: CMTimeScale(frameRateRange.maxFrameRate))
                }
            }
            
            videoDevice.unlockForConfiguration()
            
            // Create and add input
            let videoInput = try AVCaptureDeviceInput(device: videoDevice)
            guard session.canAddInput(videoInput) else {
                throw NSError(domain: "", code: 1, userInfo: [NSLocalizedDescriptionKey: "Cannot add video input"])
            }
            
            session.addInput(videoInput)
            currentCameraInput = videoInput
            
            // Configure output
            if session.canAddOutput(videoOutput) {
                session.addOutput(videoOutput)
                videoOutput.videoSettings = [
                    kCVPixelBufferPixelFormatTypeKey as String: Int(kCVPixelFormatType_32BGRA)
                ]
                videoOutput.setSampleBufferDelegate(self, queue: processingQueue)
                
                if let connection = videoOutput.connection(with: .video) {
                    if connection.isVideoMirroringSupported {
                        connection.isVideoMirrored = false
                    }
                    if connection.isVideoOrientationSupported {
                        connection.videoOrientation = .portrait
                    }
                }
            }
            
            session.commitConfiguration()
            captureSession = session
            
            DispatchQueue.main.async {
                self.isSetup = true
                print("Capture session setup complete")
            }
        } catch {
            print("Error setting up capture session: \(error)")
            DispatchQueue.main.async {
                self.error = error
                if self.selectedCamera == .continuity {
                    self.selectedCamera = .builtin
                }
            }
        }
    }
    
    // MARK: - Public Control Methods
    func startCapture() {
        guard let session = captureSession else {
            print("No capture session available")
            return
        }
        
        if !session.isRunning {
            print("Starting capture session")
            DispatchQueue.global(qos: .userInitiated).async { [weak self] in
                session.startRunning()
                
                // Verify session started successfully
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { [weak self] in
                    guard let self = self else { return }
                    
                    if !session.isRunning {
                        print("Failed to start capture session")
                        if self.selectedCamera == .continuity {
                            print("Falling back to built-in camera")
                            self.selectedCamera = .builtin
                        }
                    }
                }
            }
        }
    }
    
    func stopCapture() {
        guard let session = captureSession else {
            print("No capture session available")
            return
        }
        
        if session.isRunning {
            print("Stopping capture session")
            session.stopRunning()
        }
    }
    
    
    
    // MARK: - AVCaptureVideoDataOutputSampleBufferDelegate
        func captureOutput(_ output: AVCaptureOutput,
                          didOutput sampleBuffer: CMSampleBuffer,
                          from connection: AVCaptureConnection) {
            guard let pixelBuffer = CMSampleBufferGetImageBuffer(sampleBuffer) else {
                print("Failed to get pixel buffer from sample buffer")
                return
            }
            
            let ciImage = CIImage(cvPixelBuffer: pixelBuffer)
            
            // Process frame with object detector
            objectDetector.detect(in: ciImage) { [weak self] detections in
                guard let self = self else { return }
                
                DispatchQueue.main.async {
                    self.detections = detections
                    self.currentFrame = ciImage
                    
                    // Notify delegate
                    self.delegate?.cameraManager(self, didUpdate: ciImage)
                    self.delegate?.cameraManager(self, didUpdateDetections: detections)
                }
            }
        }
        
        func captureOutput(_ output: AVCaptureOutput,
                          didDrop sampleBuffer: CMSampleBuffer,
                          from connection: AVCaptureConnection) {
            // Log frame drops for debugging performance issues
            print("Frame dropped")
        }
        
        // MARK: - Public Utility Methods
        func toggleCamera() {
            switch selectedCamera {
            case .builtin where isContinuityCameraAvailable:
                switchToContinuityCamera()
            case .continuity:
                switchToBuiltInCamera()
            default:
                break
            }
        }
        
        func resetAndRestart() {
            stopCapture()
            retryAttempts = 0
            
            // Clear existing session
            if let session = captureSession {
                session.beginConfiguration()
                session.inputs.forEach { session.removeInput($0) }
                session.outputs.forEach { session.removeOutput($0) }
                session.commitConfiguration()
                captureSession = nil
            }
            
            // Reset state
            currentCameraInput = nil
            isSetup = false
            
            // Setup new session
            setupCaptureSession()
            
            // Restart if was running
            if isRunning {
                startCapture()
            }
        }
        
        // Get current camera status
        var cameraStatus: String {
            if !isSetup {
                return "Not Setup"
            } else if let session = captureSession {
                return session.isRunning ? "Running" : "Stopped"
            } else {
                return "No Session"
            }
        }
        
        // Check if specific camera type is available
        func isCameraAvailable(_ type: CameraType) -> Bool {
            switch type {
            case .builtin:
                return true // Built-in camera is always available on Mac
            case .continuity:
                return isContinuityCameraAvailable
            }
        }
    }

    // MARK: - AVCaptureDevice Extension
    extension AVCaptureDevice {
        var isContinuityCamera: Bool {
            return deviceType == .continuityCamera ||
                   modelID.contains("Continuity") ||
                   localizedName.contains("iPhone")
        }
    }
