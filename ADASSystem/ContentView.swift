import SwiftUI

struct ContentView: View {
    @StateObject private var cameraManager = CameraManager()
    @State private var selectedCameraOption: String = "Built-in"
    
    var body: some View {
        VStack {
            // Camera Options
            HStack {
                Button("Built-in Camera") {
                    cameraManager.switchToBuiltInCamera()
                }
                .buttonStyle(.bordered)
                .tint(cameraManager.selectedCamera == .builtin ? .blue : .gray)
                
                Button("iPhone Camera") {
                    cameraManager.switchToContinuityCamera()
                }
                .buttonStyle(.bordered)
                .tint(cameraManager.selectedCamera == .continuity ? .blue : .gray)
            }
            .padding()
            
            // Camera preview with detections overlay
            ZStack {
                CameraView(cameraManager: cameraManager)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .cornerRadius(12)
                    .padding()
                
                // Detection overlays
                GeometryReader { geometry in
                    ForEach(cameraManager.detections) { detection in
                        let rect = detection.boundingBox
                        let x = rect.origin.x * geometry.size.width
                        let y = rect.origin.y * geometry.size.height
                        let width = rect.width * geometry.size.width
                        let height = rect.height * geometry.size.height
                        
                        Rectangle()
                            .stroke(getColor(for: detection.label), lineWidth: 2)
                            .frame(width: width, height: height)
                            .position(x: x + width/2, y: y + height/2)
                        
                        Text("\(detection.label) \(Int(detection.confidence * 100))%")
                            .font(.caption)
                            .foregroundColor(.white)
                            .padding(4)
                            .background(getColor(for: detection.label).opacity(0.7))
                            .cornerRadius(4)
                            .position(x: x + width/2, y: y - 10)
                    }
                }
            }
            
            // Start/Stop Button
            Button(cameraManager.isRunning ? "Stop Camera" : "Start Camera") {
                if cameraManager.isRunning {
                    cameraManager.stopCapture()
                } else {
                    cameraManager.startCapture()
                }
            }
            .disabled(!cameraManager.isSetup)
            .padding()
        }
        .frame(minWidth: 800, minHeight: 600)
        .alert("Camera Error",
               isPresented: Binding<Bool>(
                get: { cameraManager.error != nil },
                set: { if !$0 { cameraManager.error = nil } }
               ),
               presenting: cameraManager.error as Error?) { _ in
            Button("OK", role: .cancel) {}
        } message: { error in
            Text(error.localizedDescription)
        }
    }
    
    private func getColor(for label: String) -> Color {
        switch label.lowercased() {
        case "car": return .blue
        case "truck": return .green
        case "bus": return .yellow
        case "person": return .red
        default: return .white
        }
    }
}
